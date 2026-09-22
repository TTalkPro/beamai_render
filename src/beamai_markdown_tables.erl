%%%-------------------------------------------------------------------
%%% @doc The table AST and its HTML renderer, shared by pipe tables and grid
%%% tables. Port of markdig's Extensions/Tables shared pieces.
%%%
%%% Block kinds:
%%%   table       children are rows; `columns' is a list of
%%%               #{align => left | center | right | undefined, width => float()}
%%%   table_row   children are cells; `header' (boolean)
%%%   table_cell  children are blocks (usually one paragraph);
%%%               `col_index', `col_span', `row_span'
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_tables).

-include("beamai_markdown.hrl").

-export([new_table/0, new_row/1, new_cell/1, parse_column_header/2,
         normalize_max_width/1, normalize_header_row/1,
         setup_html/1, render_html/2]).

-import(beamai_markdown_renderer, [write/2, write_raw/2, write_line/1, write_line/2,
                                   ensure_line/1, write_children/2, get/2, set/3]).

-spec new_table() -> beamai_markdown_block().
new_table() ->
    #{k => table, line => 0, col => 1, children => [], columns => []}.

-spec new_row(boolean()) -> beamai_markdown_block().
new_row(Header) ->
    #{k => table_row, line => 0, col => 1, children => [], header => Header}.

-spec new_cell([beamai_markdown_block()]) -> beamai_markdown_block().
new_cell(Children) ->
    #{k => table_cell, line => 0, col => 1, children => Children,
      col_index => -1, col_span => 1, row_span => 1}.

%% @doc Parse `:---:' style column spec text with Delim as the run char.
%% Returns {ok, Align, Count, RestPos} or none; leading/trailing spaces are
%% skipped, and the caller checks that RestPos is the end.
-spec parse_column_header(binary(), char()) ->
          {ok, left | center | right | undefined, pos_integer(), non_neg_integer()} | none.
parse_column_header(Bin, Delim) ->
    P0 = beamai_markdown_scan:skip_spaces(Bin, 0),
    {Left, P1} = colon(Bin, P0),
    P2 = beamai_markdown_scan:skip_spaces(Bin, P1),
    N = beamai_markdown_scan:count_char(Bin, P2, Delim),
    case N of
        0 -> none;
        _ ->
            P3 = beamai_markdown_scan:skip_spaces(Bin, P2 + N),
            {Right, P4} = colon(Bin, P3),
            P5 = beamai_markdown_scan:skip_spaces(Bin, P4),
            Align = case {Left, Right} of
                        {true, true} -> center;
                        {false, true} -> right;
                        {true, false} -> left;
                        _ -> undefined
                    end,
            {ok, Align, N, P5}
    end.

colon(Bin, P) ->
    case beamai_markdown_char:at(Bin, P) of
        $: -> {true, P + 1};
        _ -> {false, P}
    end.

%% @doc Pad every row with empty cells to the widest row.
-spec normalize_max_width(beamai_markdown_block()) -> beamai_markdown_block().
normalize_max_width(#{children := Rows} = T) ->
    Max = lists:max([0 | [length(maps:get(children, R)) || R <- Rows]]),
    T#{children => [pad_row(R, Max) || R <- Rows]}.

%% @doc Pad or truncate every row to the header row's column count.
-spec normalize_header_row(beamai_markdown_block()) -> beamai_markdown_block().
normalize_header_row(#{children := []} = T) -> T;
normalize_header_row(#{children := [H | _] = Rows} = T) ->
    Max = length(maps:get(children, H)),
    T#{children => [truncate_row(pad_row(R, Max), Max) || R <- Rows]}.

pad_row(#{children := Cs} = R, Max) when length(Cs) >= Max -> R;
pad_row(#{children := Cs} = R, Max) ->
    R#{children => Cs ++ [new_cell([]) || _ <- lists:seq(1, Max - length(Cs))]}.

truncate_row(#{children := Cs} = R, Max) ->
    R#{children => lists:sublist(Cs, Max)}.

%%%===================================================================
%%% HTML
%%%===================================================================

-spec setup_html(map()) -> map().
setup_html(R) ->
    beamai_markdown_renderer:set_renderer(R, table, {?MODULE, render_html}).

-spec render_html(map(), beamai_markdown_block()) -> map().
render_html(R, #{children := Rows} = Table) ->
    case get(R, enable_block) of
        true -> table_html(R, Table);
        false ->
            Saved = get(R, implicit_paragraph),
            R1 = set(R, implicit_paragraph, true),
            R2 = lists:foldl(
                   fun(#{children := Cells}, Acc) ->
                           Acc1 = lists:foldl(fun(Cell, A) -> write(write_children(A, Cell), <<" ">>) end,
                                              Acc, Cells),
                           write_line(Acc1)
                   end, R1, Rows),
            set(R2, implicit_paragraph, Saved)
    end.

table_html(R0, #{children := Rows, columns := Columns} = Table) ->
    R1 = write_line(beamai_markdown_html:write_attributes(write(ensure_line(R0), <<"<table">>), Table), <<">">>),
    R2 = write_columns(R1, Columns),
    {R3, State} = lists:foldl(fun(Row, {Acc, St}) -> table_row(Acc, Row, Columns, St) end,
                              {R2, #{body => false, header_seen => false, header_open => false}}, Rows),
    R4 = case State of
             #{body := true} -> write_line(R3, <<"</tbody>">>);
             #{header_open := true} -> write_line(R3, <<"</thead>">>);
             _ -> R3
         end,
    write_line(R4, <<"</table>">>).

write_columns(R, Columns) ->
    case lists:any(fun(#{width := W}) -> W /= 0 andalso W /= 1 end, Columns) of
        false -> R;
        true ->
            lists:foldl(fun(#{width := W}, Acc) ->
                                write_line(Acc, [<<"<col style=\"width:">>, format_width(W), <<"%\" />">>])
                        end, R, Columns)
    end.

%% markdig formats with "0.##": at most two decimals, trailing zeros gone.
format_width(W) ->
    S = float_to_binary(W * 1.0, [{decimals, 2}]),
    S1 = string:trim(S, trailing, "0"),
    string:trim(S1, trailing, ".").

table_row(R0, #{children := Cells, header := Header} = Row, Columns, St0) ->
    {R1, St1} = open_section(R0, Header, St0),
    R2 = write_line(beamai_markdown_html:write_attributes(write(R1, <<"<tr">>), Row), <<">">>),
    {R3, _} = lists:foldl(fun(Cell, {Acc, I}) -> {table_cell(Acc, Cell, Header, Columns, I), I + 1} end,
                          {R2, 0}, Cells),
    {write_line(R3, <<"</tr>">>), St1}.

open_section(R, true, #{header_seen := false} = St) ->
    {write_line(R, <<"<thead>">>), St#{header_seen => true, header_open => true}};
open_section(R, true, St) -> {R, St};
open_section(R, false, #{body := false} = St) ->
    R1 = case St of
             #{header_open := true} -> write_line(R, <<"</thead>">>);
             _ -> R
         end,
    {write_line(R1, <<"<tbody>">>), St#{body => true, header_open => false}};
open_section(R, false, St) -> {R, St}.

table_cell(R0, #{children := Children} = Cell, Header, Columns, Index) ->
    R1 = write(ensure_line(R0), case Header of true -> <<"<th">>; false -> <<"<td">> end),
    R2 = case maps:get(col_span, Cell, 1) of
             1 -> R1;
             CS -> write(R1, [<<" colspan=\"">>, integer_to_binary(CS), <<"\"">>])
         end,
    R3 = case maps:get(row_span, Cell, 1) of
             1 -> R2;
             RS -> write(R2, [<<" rowspan=\"">>, integer_to_binary(RS), <<"\"">>])
         end,
    R4 = case alignment(Columns, Cell, Index) of
             center -> write(R3, <<" style=\"text-align: center;\"">>);
             right -> write(R3, <<" style=\"text-align: right;\"">>);
             left -> write(R3, <<" style=\"text-align: left;\"">>);
             _ -> R3
         end,
    R5 = write(beamai_markdown_html:write_attributes(R4, Cell), <<">">>),
    Saved = get(R5, implicit_paragraph),
    R6 = case length(Children) of
             1 -> set(R5, implicit_paragraph, true);
             _ -> R5
         end,
    R7 = set(beamai_markdown_renderer:render(R6, Cell), implicit_paragraph, Saved),
    write_line(R7, case Header of true -> <<"</th>">>; false -> <<"</td>">> end).

alignment([], _, _) -> undefined;
alignment(Columns, Cell, Fallback) ->
    Count = length(Columns),
    Idx0 = maps:get(col_index, Cell, -1),
    Idx = case Idx0 < 0 orelse Idx0 >= Count of
              true -> Fallback;
              false -> Idx0
          end,
    maps:get(align, lists:nth(min(Idx, Count - 1) + 1, Columns), undefined).
