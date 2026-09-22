%%%-------------------------------------------------------------------
%%% @doc Definition lists:
%%%
%%% ```
%%% Term
%%% :   Definition
%%% '''
%%%
%%% Port of markdig's DefinitionLists extension. A `:' (or `~') line whose
%%% marker and indent reach 4 columns, right under a paragraph, dissolves
%%% that paragraph into terms and opens a definition item; a paragraph that
%%% follows a definition list joins it. Item content is indented 4 columns,
%%% with lazy continuation for a paragraph.
%%%
%%% Block kinds: definition_list (container of items), definition_item
%%% (container: terms first, then content), definition_term (leaf with
%%% inlines).
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_ext_definition_lists).

-behaviour(beamai_markdown_block_kind).

-include("beamai_markdown.hrl").

-export([setup/2, start/1, setup_html/1, render_html/2]).
-export([continue/2, finalize/2, can_contain/2, accepts_lines/1, after_line/2,
         blank_line_ignored/1]).

-spec setup(map(), map()) -> map().
setup(Pipe0, _Opts) ->
    Pipe1 = beamai_markdown_pipeline:set(
              Pipe0, block_parsers,
              [#{name => definition_list, module => ?MODULE, function => start, chars => [$:, $~]}
               | beamai_markdown_pipeline:get(Pipe0, block_parsers)]),
    Pipe2 = lists:foldl(fun(K, P) -> beamai_markdown_pipeline:add_block_kind(P, K, ?MODULE) end,
                        Pipe1, [definition_list, definition_item, definition_term]),
    beamai_markdown_pipeline:add_renderer_setup(
      Pipe2, html, #{name => definition_list, module => ?MODULE, function => setup_html}).

%%%===================================================================
%%% Parsing
%%%===================================================================

-spec start(#bp{}) -> {container, #bp{}} | none.
start(#bp{indented = false} = Bp) ->
    case marker(Bp) of
        none -> none;
        {ok, Bp1} ->
            case beamai_markdown_block:container_for(Bp, definition_item) of
                #{k := definition_list} ->
                    %% Another definition of the same term(s).
                    Item = new_item(Bp),
                    {container, beamai_markdown_block:add_child(Bp1, Item)};
                _ -> start_from_paragraph(Bp, Bp1)
            end
    end;
start(_) -> none.

%% The marker plus its indent must reach 4 columns; more is content.
marker(#bp{next_nonspace = NN, column = Base} = Bp) ->
    C = beamai_markdown_block:peek(Bp, NN),
    case C =:= $: orelse C =:= $~ of
        false -> none;
        true ->
            Bp1 = beamai_markdown_block:advance_offset(beamai_markdown_block:advance_next_nonspace(Bp), 1, false),
            Bp2 = beamai_markdown_block:find_next_nonspace(Bp1),
            case Bp2#bp.next_nonspace_col - Base >= 4 of
                false -> none;
                true ->
                    %% Content starts 4 columns in, whatever the spacing.
                    {ok, beamai_markdown_block:advance_offset(Bp1, Base + 4 - Bp1#bp.column, true)}
            end
    end.

new_item(Bp) ->
    (beamai_markdown_block:new_block(definition_item, Bp, Bp#bp.next_nonspace))#{
      marker => beamai_markdown_block:peek(Bp, Bp#bp.next_nonspace), last_blank => false}.

%% The paragraph right above -- the open tip, or the container's last
%% child -- dissolves into terms.
start_from_paragraph(Bp, Bp1) ->
    case Bp#bp.stack of
        [#{k := paragraph} = P | Rest] when Bp#bp.unmatched =:= 0 ->
            Lines = lists:reverse(maps:get(lines, P)),
            open_item(Bp1#bp{stack = Rest}, Lines, P);
        _ ->
            Cont = beamai_markdown_block:container(Bp),
            case beamai_markdown_block:last_child(Cont) of
                #{k := paragraph, lines := Lines} = P ->
                    %% Remove the closed paragraph from its parent, which
                    %% sits at position `unmatched' in the stack.
                    Bp2 = beamai_markdown_block:close_unmatched(Bp1),
                    [Cont1 | Rest] = Bp2#bp.stack,
                    #{children := [_ | Others]} = Cont1,
                    open_item(Bp2#bp{stack = [Cont1#{children => Others} | Rest]}, Lines, P);
                _ -> none
            end
    end.

open_item(#bp{stack = [Parent | Rest]} = Bp, Lines, Para) ->
    Terms = [#{k => definition_term, line => N, col => maps:get(col, Para), children => [],
               lines => [{T, N, E}], process_inlines => true}
             || {T, N, E} <- Lines],
    Item = (new_item(Bp))#{children => lists:reverse(Terms)},
    %% Reuse a definition list right above the paragraph, else make one.
    {List, Parent1} =
        case maps:get(children, Parent) of
            [#{k := definition_list} = L | Others] ->
                {L#{children => lists:reverse(maps:get(children, L))}, Parent#{children => Others}};
            _ ->
                {#{k => definition_list, line => maps:get(line, Para), col => maps:get(col, Para),
                   children => [], lines => [], last_line_blank => false}, Parent}
        end,
    {container, Bp#bp{stack = [Item, List, Parent1 | Rest], unmatched = 0}}.

-spec continue(beamai_markdown_block(), #bp{}) ->
          {match, #bp{}} | {match, beamai_markdown_block(), #bp{}} | nomatch
        | {close, beamai_markdown_block(), #bp{}}.
continue(#{k := definition_list}, Bp) -> {match, Bp};
continue(#{k := definition_item} = Item, #bp{indent = Ind} = Bp) when Ind >= 4 ->
    {match, Item#{last_blank => false}, beamai_markdown_block:advance_offset(Bp, 4, true)};
continue(#{k := definition_item} = Item, #bp{blank = true} = Bp) ->
    {match, Item#{last_blank => true}, beamai_markdown_block:advance_next_nonspace(Bp)};
continue(#{k := definition_item, last_blank := LastBlank} = Item, Bp) ->
    C = beamai_markdown_block:peek(Bp, Bp#bp.next_nonspace),
    case C =:= $: orelse C =:= $~ of
        true -> nomatch;   % a sibling item, opened by start/1
        false ->
            %% Lazy continuation of an open paragraph.
            case (not LastBlank) andalso Bp#bp.has_open_child of
                true -> {match, Item, Bp};
                false -> nomatch
            end
    end;
continue(_, _) -> nomatch.

-spec finalize(beamai_markdown_block(), #bp{}) -> {[beamai_markdown_block()], #bp{}}.
finalize(B, Bp) -> {[B], Bp}.

-spec can_contain(beamai_markdown_block(), atom()) -> boolean().
can_contain(#{k := definition_list}, K) -> K =:= definition_item;
can_contain(#{k := definition_item}, K) -> K =/= list_item andalso K =/= definition_item;
can_contain(_, _) -> false.

-spec accepts_lines(beamai_markdown_block()) -> boolean().
accepts_lines(_) -> false.

-spec after_line(beamai_markdown_block(), #bp{}) -> #bp{}.
after_line(_, Bp) -> Bp.

-spec blank_line_ignored(beamai_markdown_block()) -> boolean().
blank_line_ignored(_) -> false.

%%%===================================================================
%%% HTML
%%%===================================================================

-spec setup_html(map()) -> map().
setup_html(R) ->
    beamai_markdown_renderer:set_renderer(R, definition_list, {?MODULE, render_html}).

-spec render_html(map(), beamai_markdown_block()) -> map().
render_html(R0, #{children := Items} = List) ->
    R = beamai_markdown_renderer:ensure_line(R0),
    R1 = beamai_markdown_renderer:write_line(
           beamai_markdown_html:write_attributes(beamai_markdown_renderer:write(R, <<"<dl">>), List), <<">">>),
    R2 = lists:foldl(fun item/2, R1, Items),
    beamai_markdown_renderer:write_line(beamai_markdown_renderer:ensure_line(R2), <<"</dl>">>).

item(#{children := Children} = Item, R0) ->
    N = length(Children),
    {R1, St} = lists:foldl(
                 fun({I, Child}, {R, St}) ->
                         case Child of
                             #{k := definition_term} -> {term(R, St, Child), St#{open => false, count => 0, simple => false}};
                             _ -> description(R, St, Item, Child, I =:= N)
                         end
                 end, {R0, #{open => false, count => 0, simple => false}},
                 lists:zip(lists:seq(1, N), Children)),
    close_dd(R1, St).

close_dd(R, #{open := true, simple := Simple}) ->
    R1 = case Simple of true -> R; false -> beamai_markdown_renderer:ensure_line(R) end,
    beamai_markdown_renderer:write_line(R1, <<"</dd>">>);
close_dd(R, _) -> R.

term(R, St, Term) ->
    R1 = close_dd(R, St),
    R2 = beamai_markdown_renderer:write(
           beamai_markdown_html:write_attributes(beamai_markdown_renderer:write(R1, <<"<dt">>), Term), <<">">>),
    beamai_markdown_renderer:write_line(beamai_markdown_renderer:write_leaf_inline(R2, Term), <<"</dt>">>).

description(R, St, Item, Child, IsLast) ->
    {R1, St1} = case St of
                    #{open := true} -> {R, St};
                    _ ->
                        A = beamai_markdown_renderer:write(
                              beamai_markdown_html:write_attributes(beamai_markdown_renderer:write(R, <<"<dd">>), Item),
                              <<">">>),
                        {A, St#{open => true, count => 0}}
                end,
    %% A lone paragraph filling the whole <dd> goes without its <p>.
    Simple = IsLast andalso maps:get(count, St1) =:= 0 andalso maps:get(k, Child) =:= paragraph,
    Saved = beamai_markdown_renderer:get(R1, implicit_paragraph),
    R2 = case Simple of
             true -> beamai_markdown_renderer:set(R1, implicit_paragraph, true);
             false -> R1
         end,
    R3 = beamai_markdown_renderer:set(beamai_markdown_renderer:render(R2, Child), implicit_paragraph, Saved),
    {R3, St1#{count => maps:get(count, St1) + 1, simple => Simple orelse maps:get(simple, St1)}}.
