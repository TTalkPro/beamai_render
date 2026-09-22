%%%-------------------------------------------------------------------
%%% @doc The parsing pipeline: which parsers run, in what order, with what
%%% options. markdig's MarkdownPipelineBuilder and MarkdownPipeline in one
%%% map.
%%%
%%% A pipeline is built by starting from new/0, applying extensions with
%%% use/2,3 (each extension is a module with a setup/2 callback that edits
%%% the ordered lists below), and finishing with build/1, which derives the
%%% dispatch tables the parsers index by character. A built pipeline is a
%%% plain immutable map: share it, reuse it, put it in a persistent_term.
%%%
%%% The ordered lists, and what an entry looks like:
%%%   block_parsers    #{name, module, function, chars}  -- block starts
%%%   inline_parsers   #{name, module, function, chars}
%%%   post_inline      #{name, module, function}         -- after each leaf
%%%   emphasis_hooks   #{name, module, function}         -- create emph nodes
%%%   link_hooks       #{name, module, function}         -- after each link
%%%   pre_inline_hooks #{name, module, function}         -- between the passes
%%%   document_hooks   #{name, module, function}         -- after inlines
%%% and the maps:
%%%   block_kinds      Kind => Module                    -- for extension kinds
%%%   emphasis         Char => #{min, max, within_word}
%%%   renderer_setup   RendererName => [#{name, module, function}]
%%%
%%% Ordering matters the way it does in markdig: the first parser to accept
%%% a position wins, so an extension that must run before the link parser
%%% says insert_before(link, ...).
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_pipeline).

-include("beamai_markdown.hrl").

-export([new/0, build/1, use/2, use/3, uses/2, is_built/1,
         add/3, insert_before/4, insert_after/4, remove/3, replace/4, find/3,
         set/3, get/2, get/3, update/3, add_emphasis/2, add_block_kind/3,
         add_renderer_setup/3]).

-type pipe() :: map().
-export_type([pipe/0]).

%% @doc A CommonMark-only builder.
-spec new() -> pipe().
new() ->
    #{block_parsers => beamai_markdown_blocks:default_parsers(),
      block_kinds => #{},
      inline_parsers => beamai_markdown_inline:default_parsers(),
      post_inline => beamai_markdown_inline:default_post(),
      emphasis_hooks => [],
      link_hooks => [],
      pre_inline_hooks => [],
      document_hooks => [],
      emphasis => #{$* => #{min => 1, max => 2, within_word => true},
                    $_ => #{min => 1, max => 2, within_word => false}},
      renderer_setup => #{},
      extensions => [],
      built => false}.

%% @doc Apply an extension module. The module's setup/2 edits the builder.
-spec use(pipe(), module()) -> pipe().
use(Pipe, Ext) -> use(Pipe, Ext, #{}).

-spec use(pipe(), module(), map()) -> pipe().
use(#{extensions := Exts} = Pipe, Ext, Opts) ->
    case lists:keymember(Ext, 1, Exts) of
        true -> Pipe;
        false ->
            Pipe1 = Pipe#{extensions => Exts ++ [{Ext, Opts}]},
            Ext:setup(Pipe1, Opts)
    end.

%% @doc Has this extension been applied?
-spec uses(pipe(), module()) -> boolean().
uses(#{extensions := Exts}, Ext) -> lists:keymember(Ext, 1, Exts).

-spec is_built(pipe()) -> boolean().
is_built(#{built := B}) -> B.

%% @doc Derive the dispatch tables. Idempotent.
-spec build(pipe()) -> pipe().
build(#{inline_parsers := IPs, block_parsers := BPs} = Pipe) ->
    Table = lists:foldl(
              fun(#{chars := Chars} = P, Acc) ->
                      lists:foldl(fun(C, A) -> A#{C => maps:get(C, A, []) ++ [P]} end, Acc, Chars)
              end, #{}, IPs),
    Chars = lists:append([maps:get(chars, P) || P <- BPs]),
    Ascii = << <<(case lists:member(I, Chars) of true -> 1; false -> 0 end)>> || I <- lists:seq(0, 127) >>,
    NonAscii = [C || C <- Chars, not is_integer(C) orelse C >= 128],
    %% The text scanner stops at any trigger byte; a compiled pattern lets
    %% a BIF do the scanning.
    Triggers = [<<C>> || C <- maps:keys(Table), C < 128],
    NonAsciiTriggers = [C || C <- maps:keys(Table), C >= 128],
    Pipe#{inline_table => Table,
          inline_triggers => {case Triggers of [] -> none; _ -> binary:compile_pattern(Triggers) end,
                              NonAsciiTriggers},
          block_start_chars => {Ascii, NonAscii},
          emphasis_descriptors => maps:get(emphasis, Pipe),
          built => true}.

%%%===================================================================
%%% Editing the ordered lists
%%%===================================================================

%% @doc Append Entry to the list under Key.
-spec add(pipe(), atom(), map()) -> pipe().
add(Pipe, Key, Entry) ->
    List = maps:get(Key, Pipe, []),
    Pipe#{Key => List ++ [Entry]}.

-spec insert_before(pipe(), atom(), atom(), map()) -> pipe().
insert_before(Pipe, Key, Name, Entry) ->
    List = maps:get(Key, Pipe, []),
    {Before, After} = lists:splitwith(fun(#{name := N}) -> N =/= Name end, List),
    Pipe#{Key => Before ++ [Entry | After]}.

-spec insert_after(pipe(), atom(), atom(), map()) -> pipe().
insert_after(Pipe, Key, Name, Entry) ->
    List = maps:get(Key, Pipe, []),
    case lists:splitwith(fun(#{name := N}) -> N =/= Name end, List) of
        {Before, [Target | After]} -> Pipe#{Key => Before ++ [Target, Entry | After]};
        {Before, []} -> Pipe#{Key => Before ++ [Entry]}
    end.

-spec remove(pipe(), atom(), atom()) -> pipe().
remove(Pipe, Key, Name) ->
    Pipe#{Key => [E || #{name := N} = E <- maps:get(Key, Pipe, []), N =/= Name]}.

%% @doc Replace the entry called Name (or append when there is none).
-spec replace(pipe(), atom(), atom(), map()) -> pipe().
replace(Pipe, Key, Name, Entry) ->
    List = maps:get(Key, Pipe, []),
    case lists:keymember(Name, 2, [{E, N} || #{name := N} = E <- List]) of
        false -> add(Pipe, Key, Entry);
        true -> Pipe#{Key => [case N of Name -> Entry; _ -> E end || #{name := N} = E <- List]}
    end.

-spec find(pipe(), atom(), atom()) -> map() | undefined.
find(Pipe, Key, Name) ->
    case [E || #{name := N} = E <- maps:get(Key, Pipe, []), N =:= Name] of
        [E | _] -> E;
        [] -> undefined
    end.

-spec set(pipe(), atom(), term()) -> pipe().
set(Pipe, Key, Value) -> Pipe#{Key => Value}.

-spec get(pipe(), atom()) -> term().
get(Pipe, Key) -> maps:get(Key, Pipe).

-spec get(pipe(), atom(), term()) -> term().
get(Pipe, Key, Default) -> maps:get(Key, Pipe, Default).

-spec update(pipe(), atom(), fun((term()) -> term())) -> pipe().
update(Pipe, Key, Fun) -> Pipe#{Key => Fun(maps:get(Key, Pipe, undefined))}.

%% @doc Register an emphasis delimiter character.
-spec add_emphasis(pipe(), map()) -> pipe().
add_emphasis(#{emphasis := E, inline_parsers := IPs} = Pipe, #{ch := Ch} = Desc) ->
    IPs1 = [case P of
                #{name := emphasis, chars := Cs} -> P#{chars => lists:usort([Ch | Cs])};
                _ -> P
            end || P <- IPs],
    Pipe#{emphasis => E#{Ch => maps:remove(ch, Desc)}, inline_parsers => IPs1}.

-spec add_block_kind(pipe(), atom(), module()) -> pipe().
add_block_kind(#{block_kinds := K} = Pipe, Kind, Module) ->
    Pipe#{block_kinds => K#{Kind => Module}}.

%% @doc Register a function that configures a renderer of the given name
%% (html, normalize, roundtrip, plain) when one is created.
-spec add_renderer_setup(pipe(), atom(), map()) -> pipe().
add_renderer_setup(#{renderer_setup := RS} = Pipe, Renderer, Entry) ->
    Pipe#{renderer_setup => RS#{Renderer => maps:get(Renderer, RS, []) ++ [Entry]}}.
