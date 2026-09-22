%%%-------------------------------------------------------------------
%%% @doc The text renderer base every markdown renderer is built on.
%%%
%%% Port of markdig's RendererBase and TextRendererBase. The state is a
%%% map threaded through every write; the output is a reversed iolist.
%%%
%%% Two writes, and the difference is load-bearing: write/2 is indent-aware
%%% and tracks whether output sits at a line start, write_raw/2 does
%%% neither. First write of a line goes through write/2, mid-line
%%% continuation through write_raw/2; mixing them up drifts indentation in
%%% the normalize and roundtrip renderers.
%%%
%%% Dispatch is by node kind through the `renderers' map, after the kind's
%%% `try_writers' have declined. A container kind with no renderer renders
%%% its children, which is how the document itself renders.
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_renderer).

-include("beamai_markdown.hrl").

-export([new/4, finish/1, render/2, write_children/2, write_leaf_inline/2,
         write/2, write_raw/2, write_line/1, write_line/2, ensure_line/1,
         write_repeat/3, at_line_start/1,
         push_indent/2, pop_indent/1, clear_indent/1,
         is_first/1, is_last/1, set/3, get/2, get/3,
         set_renderer/3, add_try_writer/3, add_before_hook/2, add_after_hook/2,
         inlines_of/1, children_of/1]).

-type renderer() :: map().
-export_type([renderer/0]).

%% @doc A renderer called Name (html, plain, normalize, roundtrip) with the
%% given kind -> {Module, Function} table, configured by the pipeline's
%% setup hooks for that name.
-spec new(atom(), map(), map(), map()) -> renderer().
new(Name, Renderers, Pipe, Opts) ->
    R0 = #{name => Name, out => [], line_start => true, indents => [],
           renderers => Renderers, try_writers => #{},
           before_hooks => [], after_hooks => [],
           first => false, last => false, depth => 0,
           max_depth => maps:get(max_nesting_depth, Opts, 128),
           pipe => Pipe, opts => Opts},
    RS = maps:get(renderer_setup, Pipe, #{}),
    %% The plain-text renderer is the HTML renderer with markup off, so it
    %% takes the HTML setups as well as its own.
    Setups = case Name of
                 plain -> maps:get(html, RS, []) ++ maps:get(plain, RS, []);
                 _ -> maps:get(Name, RS, [])
             end,
    lists:foldl(fun(#{module := M, function := F}, R) -> M:F(R) end, R0, Setups).

-spec finish(renderer()) -> binary().
finish(#{out := Out}) -> iolist_to_binary(lists:reverse(Out)).

%%%===================================================================
%%% Dispatch
%%%===================================================================

-spec render(renderer(), beamai_markdown_node()) -> renderer().
render(R0, #{k := K} = Node) ->
    R1 = run_hooks(maps:get(before_hooks, R0), R0, Node),
    R2 = case try_writers(maps:get(K, maps:get(try_writers, R1), []), R1, Node) of
             {ok, R} -> R;
             none ->
                 case maps:get(K, maps:get(renderers, R1), undefined) of
                     {M, F} -> M:F(R1, Node);
                     undefined ->
                         case Node of
                             #{children := _} -> write_children(R1, Node);
                             _ -> R1
                         end
                 end
         end,
    run_hooks(maps:get(after_hooks, R2), R2, Node).

run_hooks([], R, _) -> R;
run_hooks([{M, F} | Rest], R, Node) -> run_hooks(Rest, M:F(R, Node), Node).

try_writers([], _, _) -> none;
try_writers([{M, F} | Rest], R, Node) ->
    case M:F(R, Node) of
        none -> try_writers(Rest, R, Node);
        {ok, _} = Ok -> Ok
    end.

%% @doc Render every child, binding is_first/is_last around each.
-spec write_children(renderer(), beamai_markdown_node()) -> renderer().
write_children(#{depth := D, max_depth := Max}, _) when D >= Max ->
    erlang:error(nesting_too_deep);
write_children(#{first := F0, last := L0, depth := D} = R0, Node) ->
    Children = children_of(Node),
    R1 = write_each(Children, true, R0#{depth => D + 1}),
    R1#{first => F0, last => L0, depth => D}.

write_each([], _, R) -> R;
write_each([C | Rest], First, R) ->
    R1 = render(R#{first => First, last => Rest =:= []}, C),
    write_each(Rest, false, R1).

%% The children a node presents to a renderer: block children, or the
%% parsed inlines of a leaf.
-spec children_of(beamai_markdown_node()) -> [beamai_markdown_node()].
children_of(#{inlines := I}) -> I;
children_of(#{children := C}) -> C;
children_of(_) -> [].

-spec inlines_of(beamai_markdown_node()) -> [beamai_markdown_node()].
inlines_of(#{inlines := I}) -> I;
inlines_of(_) -> [].

%% @doc Render a leaf's inlines as the children of one container, so that
%% is_first/is_last are per inline and not inherited from the block.
-spec write_leaf_inline(renderer(), beamai_markdown_node()) -> renderer().
write_leaf_inline(R, Block) ->
    write_children(R, #{k => inline_root, children => inlines_of(Block)}).

-spec is_first(renderer()) -> boolean().
is_first(#{first := F}) -> F.

-spec is_last(renderer()) -> boolean().
is_last(#{last := L}) -> L.

%%%===================================================================
%%% Writing
%%%===================================================================

-spec write(renderer(), iodata()) -> renderer().
write(R, <<>>) -> R;
write(R, []) -> R;
write(R0, Data) ->
    #{out := Out} = R1 = write_indent(R0),
    R1#{out => [Data | Out], line_start => false}.

-spec write_raw(renderer(), iodata()) -> renderer().
write_raw(#{out := Out} = R, Data) -> R#{out => [Data | Out]}.

-spec write_line(renderer()) -> renderer().
write_line(R0) ->
    #{out := Out} = R1 = write_indent(R0),
    R1#{out => [$\n | Out], line_start => true}.

-spec write_line(renderer(), iodata()) -> renderer().
write_line(R, Data) -> write_line(write(R, Data)).

-spec ensure_line(renderer()) -> renderer().
ensure_line(#{line_start := true} = R) -> R;
ensure_line(R) -> write_line(R).

-spec write_repeat(renderer(), char(), non_neg_integer()) -> renderer().
write_repeat(R, _, 0) -> R;
write_repeat(R, C, N) -> write(R, binary:copy(<<C/utf8>>, N)).

-spec at_line_start(renderer()) -> boolean().
at_line_start(#{line_start := L}) -> L.

write_indent(#{line_start := true, indents := []} = R) -> R#{line_start => false};
write_indent(#{line_start := true, indents := Indents, out := Out} = R) ->
    {Chunks, Indents1} = lists:mapfoldr(fun indent_chunk/2, [], Indents),
    R#{line_start => false, out => [Chunks | Out], indents => Indents1};
write_indent(R) -> R.

%% An indent is a binary written on every line, or a list of per-line
%% binaries consumed one per line (empty once exhausted).
indent_chunk(Bin, Acc) when is_binary(Bin) -> {Bin, [Bin | Acc]};
indent_chunk({lines, [H | T]}, Acc) -> {H, [{lines, T} | Acc]};
indent_chunk({lines, []}, Acc) -> {<<>>, [{lines, []} | Acc]}.

-spec push_indent(renderer(), binary() | {lines, [binary()]}) -> renderer().
push_indent(#{indents := I} = R, Indent) -> R#{indents => I ++ [Indent]}.

-spec pop_indent(renderer()) -> renderer().
pop_indent(#{indents := []} = R) -> R;
pop_indent(#{indents := I} = R) -> R#{indents => lists:droplast(I)}.

-spec clear_indent(renderer()) -> renderer().
clear_indent(R) -> R#{indents => []}.

%%%===================================================================
%%% Configuration
%%%===================================================================

-spec set(renderer(), atom(), term()) -> renderer().
set(R, Key, Value) -> R#{Key => Value}.

-spec get(renderer(), atom()) -> term().
get(R, Key) -> maps:get(Key, R).

-spec get(renderer(), atom(), term()) -> term().
get(R, Key, Default) -> maps:get(Key, R, Default).

%% @doc Set (or replace) the renderer for a node kind.
-spec set_renderer(renderer(), atom(), {module(), atom()}) -> renderer().
set_renderer(#{renderers := Rs} = R, Kind, MF) -> R#{renderers => Rs#{Kind => MF}}.

%% @doc Prepend a try-writer for a kind: `M:F(R, Node)' returns `{ok, R}'
%% to claim the node or `none' to let the next one look.
-spec add_try_writer(renderer(), atom(), {module(), atom()}) -> renderer().
add_try_writer(#{try_writers := TW} = R, Kind, MF) ->
    Existing = maps:get(Kind, TW, []),
    R#{try_writers => TW#{Kind => [MF | lists:delete(MF, Existing)]}}.

-spec add_before_hook(renderer(), {module(), atom()}) -> renderer().
add_before_hook(#{before_hooks := H} = R, MF) -> R#{before_hooks => H ++ [MF]}.

-spec add_after_hook(renderer(), {module(), atom()}) -> renderer().
add_after_hook(#{after_hooks := H} = R, MF) -> R#{after_hooks => H ++ [MF]}.
