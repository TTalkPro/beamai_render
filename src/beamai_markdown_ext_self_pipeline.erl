%%%-------------------------------------------------------------------
%%% @doc Self pipeline: a document picks its own extensions with a
%%% `<!--markdig:pipetables+emojis-->' comment (case-insensitive tag). The
%%% configured pipeline is replaced entirely, so this must be its only
%%% extension. Options: tag (<<"markdig">>), default_extensions (the
%%% `+'-separated names used when the document carries no tag).
%%%
%%% The names are markdig's, see configure/2.
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_ext_self_pipeline).

-export([setup/2, resolve/2, configure/2, names/0]).

-spec setup(map(), map()) -> map().
setup(#{extensions := Exts} = Pipe, Opts) ->
    case length(Exts) > 1 of
        true -> erlang:error(self_pipeline_must_be_alone);
        false -> ok
    end,
    Tag0 = string:trim(unicode:characters_to_binary(maps:get(tag, Opts, <<"markdig">>))),
    Tag = case Tag0 of <<>> -> <<"markdig">>; _ -> Tag0 end,
    case binary:match(Tag, [<<"<">>, <<">">>]) of
        nomatch -> ok;
        _ -> erlang:error({bad_self_pipeline_tag, Tag})
    end,
    Default = maps:get(default_extensions, Opts, undefined),
    %% Validate the default configuration eagerly.
    _ = case Default of
            undefined -> ok;
            _ -> configure(beamai_markdown_pipeline:new(), Default)
        end,
    beamai_markdown_pipeline:set(Pipe, resolve_pipeline,
                                 {?MODULE, resolve, #{tag => Tag, default => Default}}).

%% @doc The pipeline a document asks for.
-spec resolve(binary(), map()) -> map().
resolve(Text, #{tag := Tag, default := Default}) ->
    Hint = string:lowercase(<<"<!--", Tag/binary, ":">>),
    Lower = string:lowercase(Text),
    Config = case binary:match(Lower, Hint) of
                 nomatch -> Default;
                 {I, L} ->
                     Start = I + L,
                     case beamai_markdown_scan:find(Text, Start, <<"-->">>) of
                         none -> Default;
                         End -> string:trim(binary:part(Text, Start, End - Start))
                     end
             end,
    P = case Config of
            undefined -> beamai_markdown_pipeline:new();
            <<>> -> beamai_markdown_pipeline:new();
            _ -> configure(beamai_markdown_pipeline:new(), Config)
        end,
    beamai_markdown_pipeline:build(P).

%% @doc Apply a `+'-separated list of markdig extension names.
-spec configure(map(), unicode:chardata()) -> map().
configure(Pipe, Config) ->
    Names = [string:lowercase(string:trim(N))
             || N <- binary:split(unicode:characters_to_binary(Config), <<"+">>, [global])],
    lists:foldl(fun(<<>>, P) -> P;
                   (<<"common">>, P) -> P;
                   (Name, P) ->
                        case lists:keyfind(Name, 1, names()) of
                            {_, Ext, Opts} ->
                                {Ext, Mod} = lists:keyfind(Ext, 1, beamai_markdown:extensions()),
                                beamai_markdown_pipeline:use(P, Mod, Opts);
                            false -> erlang:error({unknown_markdown_extension, Name})
                        end
                end, Pipe, Names).

%% @doc markdig's names -> {extension, options}.
-spec names() -> [{binary(), atom(), map()}].
names() ->
    [{<<"advanced">>, advanced, #{}},
     {<<"alerts">>, alerts, #{}},
     {<<"pipetables">>, pipe_tables, #{}},
     {<<"gfm-pipetables">>, pipe_tables, #{use_header_for_column_count => true}},
     {<<"emphasisextras">>, emphasis_extras, #{}},
     {<<"listextras">>, list_extras, #{}},
     {<<"hardlinebreak">>, hardline_breaks, #{}},
     {<<"footnotes">>, footnotes, #{}},
     {<<"footers">>, footers, #{}},
     {<<"citations">>, citations, #{}},
     {<<"attributes">>, generic_attributes, #{}},
     {<<"gridtables">>, grid_tables, #{}},
     {<<"abbreviations">>, abbreviations, #{}},
     {<<"emojis">>, emoji, #{}},
     {<<"definitionlists">>, definition_lists, #{}},
     {<<"customcontainers">>, custom_containers, #{}},
     {<<"figures">>, figures, #{}},
     {<<"mathematics">>, mathematics, #{}},
     {<<"bootstrap">>, bootstrap, #{}},
     {<<"medialinks">>, media_links, #{}},
     {<<"smartypants">>, smarty_pants, #{}},
     {<<"autoidentifiers">>, auto_identifiers, #{}},
     {<<"tasklists">>, task_lists, #{}},
     {<<"diagrams">>, diagrams, #{}},
     {<<"nofollowlinks">>, referral_links, #{rels => [<<"nofollow">>]}},
     {<<"noopenerlinks">>, referral_links, #{rels => [<<"noopener">>]}},
     {<<"noreferrerlinks">>, referral_links, #{rels => [<<"noreferrer">>]}},
     {<<"nohtml">>, disable_html, #{}},
     {<<"yaml">>, yaml_front_matter, #{}},
     {<<"nonascii-noescape">>, non_ascii_no_escape, #{}},
     {<<"autolinks">>, auto_links, #{}},
     {<<"globalization">>, globalization, #{}},
     {<<"cjk-friendly-emphasis">>, cjk_friendly_emphasis, #{}}].
