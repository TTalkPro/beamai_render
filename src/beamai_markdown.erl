%%%-------------------------------------------------------------------
%%% @doc Markdown, the way markdig does it: a CommonMark 0.31.2 parser, its
%%% extensions, and the renderers that turn the tree into HTML, plain text,
%%% normalised Markdown or a byte-exact roundtrip.
%%%
%%% ```
%%% beamai_markdown:to_html(~"Hello *world*!").
%%% %% => <<"<p>Hello <em>world</em>!</p>\n">>
%%%
%%% P = beamai_markdown:pipeline([pipe_tables, task_lists, footnotes]),
%%% beamai_markdown:to_html(Text, P).
%%%
%%% beamai_markdown:to_html(Text, beamai_markdown:pipeline(advanced)).
%%% '''
%%%
%%% Every function takes an optional pipeline (see pipeline/1) and, where
%%% it renders, an options map for the renderer. A pipeline is built once
%%% and reused; building one per call works but throws the setup away.
%%%
%%% Compile time: beamai_markdown_transform folds a literal inline/1 call
%%% and a -markdown_document file into their HTML.
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown).

-include("beamai_markdown.hrl").

-export([to_html/1, to_html/2, to_html/3, to_plain_text/1, to_plain_text/2,
         normalize/1, normalize/2, to_roundtrip/1, to_roundtrip/2,
         parse/1, parse/2, parse/3, render/2, render/3,
         pipeline/0, pipeline/1, default_pipeline/0, extensions/0, inline/1,
         find_closest_line/2]).

-type pipeline() :: beamai_markdown_pipeline:pipe().
-type document() :: beamai_markdown_block().
-export_type([pipeline/0, document/0]).

%%%===================================================================
%%% Rendering
%%%===================================================================

-spec to_html(unicode:chardata()) -> binary().
to_html(Text) -> to_html(Text, default_pipeline()).

-spec to_html(unicode:chardata(), pipeline() | [atom()] | atom()) -> binary().
to_html(Text, Pipe) -> to_html(Text, Pipe, #{}).

%% @doc Render to HTML. Opts is the renderer's options: base_url,
%% link_rewriter, and anything an extension documents.
-spec to_html(unicode:chardata(), pipeline() | [atom()] | atom(), map()) -> binary().
to_html(Text, Pipe0, Opts) ->
    %% The renderer takes the pipeline the document was parsed with, which
    %% the self pipeline may have chosen.
    Doc = parse(Text, Pipe0, Opts),
    beamai_markdown_html:render(Doc, pipe_of(Doc), Opts).

-spec to_plain_text(unicode:chardata()) -> binary().
to_plain_text(Text) -> to_plain_text(Text, default_pipeline()).

%% @doc Render with all markup stripped: the HTML renderer with its three
%% enable flags off, as in markdig.
-spec to_plain_text(unicode:chardata(), pipeline() | [atom()] | atom()) -> binary().
to_plain_text(Text, Pipe0) ->
    Opts = #{renderer => plain, enable_inline => false, enable_block => false,
             enable_escape => false},
    Doc = parse(Text, Pipe0, Opts),
    beamai_markdown_html:render(Doc, pipe_of(Doc), Opts).

-spec normalize(unicode:chardata()) -> binary().
normalize(Text) -> normalize(Text, default_pipeline()).

%% @doc Render back to canonical Markdown.
-spec normalize(unicode:chardata(), pipeline() | [atom()] | atom()) -> binary().
normalize(Text, Pipe0) ->
    Doc = parse(Text, Pipe0, #{}),
    beamai_markdown_normalize:render(Doc, pipe_of(Doc), #{}).

-spec to_roundtrip(unicode:chardata()) -> binary().
to_roundtrip(Text) -> to_roundtrip(Text, default_pipeline()).

%% @doc Parse with trivia tracking and render back to the exact input.
-spec to_roundtrip(unicode:chardata(), pipeline() | [atom()] | atom()) -> binary().
to_roundtrip(Text, Pipe0) ->
    Doc = parse(Text, Pipe0, #{track_trivia => true}),
    beamai_markdown_roundtrip:render(Doc, pipe_of(Doc), #{}).

%% @doc Render a parsed document with a renderer module: html, plain,
%% normalize or roundtrip, or any module exporting render/3.
-spec render(document(), atom()) -> binary().
render(Doc, Renderer) -> render(Doc, Renderer, #{}).

-spec render(document(), atom(), map()) -> binary().
render(Doc, html, Opts) -> beamai_markdown_html:render(Doc, pipe_of(Doc), Opts);
render(Doc, plain, Opts) ->
    beamai_markdown_html:render(Doc, pipe_of(Doc),
                                Opts#{renderer => plain, enable_inline => false,
                                      enable_block => false, enable_escape => false});
render(Doc, normalize, Opts) -> beamai_markdown_normalize:render(Doc, pipe_of(Doc), Opts);
render(Doc, roundtrip, Opts) -> beamai_markdown_roundtrip:render(Doc, pipe_of(Doc), Opts);
render(Doc, Module, Opts) -> Module:render(Doc, pipe_of(Doc), Opts).

pipe_of(#{pipe := Pipe}) -> Pipe;
pipe_of(_) -> default_pipeline().

%%%===================================================================
%%% Parsing
%%%===================================================================

-spec parse(unicode:chardata()) -> document().
parse(Text) -> parse(Text, default_pipeline()).

-spec parse(unicode:chardata(), pipeline() | [atom()] | atom()) -> document().
parse(Text, Pipe) -> parse(Text, Pipe, #{}).

%% @doc Parse to the document tree. Opts: track_trivia (for roundtrip),
%% precise_source_location.
-spec parse(unicode:chardata(), pipeline() | [atom()] | atom(), map()) -> document().
parse(Text0, Pipe0, Opts) ->
    Text = unicode:characters_to_binary(Text0),
    %% The self pipeline lets the document choose its own extensions.
    Pipe = case pipeline(Pipe0) of
               #{resolve_pipeline := {M, F, A}} -> M:F(Text, A);
               P -> P
           end,
    Bp = beamai_markdown_block:parse(Text, Pipe, Opts),
    [Doc0] = Bp#bp.stack,
    Refs0 = beamai_markdown_block:refs(Bp),
    %% Between the passes: an extension may add reference definitions or
    %% rearrange blocks before any inline is parsed.
    {DocA, Refs} = lists:foldl(fun(#{module := M, function := F}, {D, R}) -> M:F(D, R, Pipe, Opts) end,
                               {Doc0, Refs0}, maps:get(pre_inline_hooks, Pipe, [])),
    Doc1 = beamai_markdown_inline:process(DocA, Refs, Pipe),
    %% Byte offset of every line start (and the end of the text, one past
    %% the last line): what turns a block's line range back into source.
    Offsets = line_offsets(Text),
    Doc2 = lists:foldl(fun(#{module := M, function := F}, D) -> M:F(D, Pipe, Opts) end,
                       Doc1#{refs => Refs, pipe => Pipe, source => Text, ext => Bp#bp.ext,
                             line_offsets => Offsets},
                       maps:get(document_hooks, Pipe, [])),
    Doc2.

line_offsets(Text) ->
    {Offs, End} = lists:foldl(fun({L, E}, {Acc, Off}) -> {[Off | Acc], Off + byte_size(L) + byte_size(E)} end,
                              {[], 0}, beamai_markdown_scan:split_lines(Text)),
    list_to_tuple(lists:reverse([End | Offs])).

%%%===================================================================
%%% Pipelines
%%%===================================================================

%% @doc The CommonMark-only pipeline, built. Cheap enough to build on
%% every call, and deliberately not cached anywhere: the engine keeps no
%% state of its own (no ets, no persistent_term, no process). Build a
%% pipeline once and pass it around if it matters.
-spec default_pipeline() -> pipeline().
default_pipeline() ->
    beamai_markdown_pipeline:build(beamai_markdown_pipeline:new()).

-spec pipeline() -> pipeline().
pipeline() -> default_pipeline().

%% @doc A built pipeline from a list of extension names (see extensions/0),
%% `advanced' for markdig's UseAdvancedExtensions set, or an already built
%% pipeline, which is returned as is. A `{Name, Opts}' pair passes options
%% to the extension.
-spec pipeline(pipeline() | [atom() | {atom(), map()}] | atom()) -> pipeline().
pipeline(#{built := true} = Pipe) -> Pipe;
pipeline(#{built := false} = Pipe) -> beamai_markdown_pipeline:build(Pipe);
pipeline(advanced) -> pipeline([advanced]);
pipeline(Name) when is_atom(Name) -> pipeline([Name]);
pipeline(Names) when is_list(Names) ->
    P = lists:foldl(fun({Name, Opts}, Acc) -> beamai_markdown_pipeline:use(Acc, ext_module(Name), Opts);
                       (Name, Acc) -> beamai_markdown_pipeline:use(Acc, ext_module(Name), #{})
                    end, beamai_markdown_pipeline:new(), Names),
    beamai_markdown_pipeline:build(P).

ext_module(Name) ->
    case lists:keyfind(Name, 1, extensions()) of
        {Name, Mod} -> Mod;
        false when is_atom(Name) ->
            case code:ensure_loaded(Name) of
                {module, Name} -> Name;
                _ -> erlang:error({unknown_markdown_extension, Name})
            end
    end.

%% @doc Every extension by name, with its module.
-spec extensions() -> [{atom(), module()}].
extensions() ->
    [{abbreviations,        beamai_markdown_ext_abbreviations},
     {alerts,               beamai_markdown_ext_alerts},
     {auto_identifiers,     beamai_markdown_ext_auto_identifiers},
     {auto_links,           beamai_markdown_ext_auto_links},
     {bootstrap,            beamai_markdown_ext_bootstrap},
     {citations,            beamai_markdown_ext_citations},
     {cjk_friendly_emphasis, beamai_markdown_ext_cjk_friendly_emphasis},
     {custom_containers,    beamai_markdown_ext_custom_containers},
     {definition_lists,     beamai_markdown_ext_definition_lists},
     {diagrams,             beamai_markdown_ext_diagrams},
     {disable_headings,     beamai_markdown_ext_disable_headings},
     {disable_html,         beamai_markdown_ext_disable_html},
     {emoji,                beamai_markdown_ext_emoji},
     {emphasis_extras,      beamai_markdown_ext_emphasis_extras},
     {figures,              beamai_markdown_ext_figures},
     {footers,              beamai_markdown_ext_footers},
     {footnotes,            beamai_markdown_ext_footnotes},
     {generic_attributes,   beamai_markdown_ext_generic_attributes},
     {globalization,        beamai_markdown_ext_globalization},
     {grid_tables,          beamai_markdown_ext_grid_tables},
     {hardline_breaks,      beamai_markdown_ext_hardline_breaks},
     {jira_links,           beamai_markdown_ext_jira_links},
     {list_extras,          beamai_markdown_ext_list_extras},
     {mathematics,          beamai_markdown_ext_mathematics},
     {media_links,          beamai_markdown_ext_media_links},
     {non_ascii_no_escape,  beamai_markdown_ext_non_ascii_no_escape},
     {pipe_tables,          beamai_markdown_ext_pipe_tables},
     {pragma_lines,         beamai_markdown_ext_pragma_lines},
     {referral_links,       beamai_markdown_ext_referral_links},
     {self_pipeline,        beamai_markdown_ext_self_pipeline},
     {smarty_pants,         beamai_markdown_ext_smarty_pants},
     {task_lists,           beamai_markdown_ext_task_lists},
     {yaml_front_matter,    beamai_markdown_ext_yaml},
     {advanced,             beamai_markdown_ext_advanced}].

%% @doc The zero-based source line of the block starting closest to Line
%% (zero-based): a position at or past halfway between two blocks rounds
%% to the next one. For mapping rendered output back to the source, with
%% the pragma_lines extension.
-spec find_closest_line(document(), non_neg_integer()) -> non_neg_integer().
find_closest_line(Doc, Line) ->
    case closest_block(Doc, Line + 1) of
        undefined -> 0;
        #{line := L} -> max(0, L - 1)
    end.

closest_block(#{children := Ch}, Line) when Ch =/= [] ->
    case [C || #{line := L} = C <- Ch, L =:= Line] of
        [Exact | _] -> Exact;
        [] ->
            Before = [C || #{line := L} = C <- Ch, L < Line],
            Index = length(Before),
            N = length(Ch),
            Closest = fun(I) ->
                              C = lists:nth(I, Ch),
                              case closest_block(C, Line) of
                                  undefined -> C;
                                  Found -> Found
                              end
                      end,
            if Index =:= 0 -> Closest(1);
               Index =:= N -> Closest(N);
               true -> closer(Closest(Index), Closest(Index + 1), Line)
            end
    end;
closest_block(#{line := Line} = B, Line) -> B;
closest_block(_, _) -> undefined.

closer(#{line := L} = Prev, _, L) -> Prev;
closer(_, #{line := L} = Next, L) -> Next;
closer(#{line := PL} = Prev, #{line := NL} = Next, Line) ->
    case (Line - PL) * 2 < (NL - PL) of
        true -> Prev;
        false -> Next
    end.

%% @doc Render a literal Markdown document at run time; with
%% beamai_markdown_transform the same call is folded at compile time.
-spec inline(unicode:chardata()) -> binary().
inline(Text) -> to_html(Text).
