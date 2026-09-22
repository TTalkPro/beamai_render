%%%-------------------------------------------------------------------
%%% @doc Globalization: a block (or link) whose first strong character is
%%% right-to-left gets `dir="rtl"'; a table gets `align="right"' too.
%%%
%%% A document hook over every node except table rows, cells and list
%%% items. The direction of a node is that of its first meaningful child
%%% (task-list checkboxes are skipped) down to a text node, whose first
%%% strong character decides; ASCII letters short-circuit to LTR.
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_ext_globalization).

-include("beamai_markdown.hrl").

-export([setup/2, mark/3, is_rtl/1]).

-spec setup(map(), map()) -> map().
setup(Pipe, _Opts) ->
    beamai_markdown_pipeline:replace(
      Pipe, document_hooks, globalization,
      #{name => globalization, module => ?MODULE, function => mark}).

-spec mark(beamai_markdown_block(), map(), map()) -> beamai_markdown_block().
mark(Doc, _Pipe, _Opts) -> mark_node(Doc).

mark_node(#{k := K} = N0) ->
    N1 = case lists:member(K, [table_row, table_cell, list_item, document]) of
             true -> N0;
             false ->
                 case is_rtl(N0) of
                     true ->
                         A = add_if_missing(N0, <<"dir">>, <<"rtl">>),
                         case K of
                             table -> add_if_missing(A, <<"align">>, <<"right">>);
                             _ -> A
                         end;
                     false -> N0
                 end
         end,
    N2 = case N1 of
             #{inlines := Inlines} -> N1#{inlines => [mark_node(I) || I <- Inlines]};
             _ -> N1
         end,
    case N2 of
        #{children := Ch} when Ch =/= [] -> N2#{children => [mark_node(C) || C <- Ch]};
        _ -> N2
    end.

add_if_missing(N, K, V) ->
    case lists:keymember(K, 1, beamai_markdown_attrs:properties(N)) of
        true -> N;
        false -> beamai_markdown_attrs:add_property(N, K, V)
    end.

%% @doc Does the node's first strong character read right to left?
-spec is_rtl(beamai_markdown_node()) -> boolean().
is_rtl(#{k := text, v := V}) -> starts_rtl(V);
is_rtl(#{k := emoji, v := V}) -> starts_rtl(V);
is_rtl(#{inlines := Inlines}) -> first_decides(Inlines);
is_rtl(#{children := [First | _]}) -> is_rtl(First);
is_rtl(_) -> false.

first_decides([#{k := task} | Rest]) -> first_decides(Rest);
first_decides([First | _]) -> is_rtl(First);
first_decides([]) -> false.

starts_rtl(<<>>) -> false;
starts_rtl(<<C/utf8, Rest/binary>>) ->
    case C < 128 of
        true ->
            case beamai_markdown_char:is_alpha(C) of
                true -> false;
                false -> starts_rtl(Rest)
            end;
        false ->
            case beamai_markdown_bidi_data:is_rtl(C) of
                true -> true;
                false ->
                    case beamai_markdown_bidi_data:is_ltr(C) of
                        true -> false;
                        false -> starts_rtl(Rest)
                    end
            end
    end;
starts_rtl(_) -> false.
