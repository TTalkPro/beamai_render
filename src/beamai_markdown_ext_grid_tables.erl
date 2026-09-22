%%%-------------------------------------------------------------------
%%% @doc Grid tables: `+---+---+' rows with `|' columns, block content in
%%% cells, and cells spanning columns and rows.
%%%
%%% Port of markdig's GridTables. The block collects its raw lines while
%%% open (a line starting with `+' or `|' continues it) and does the whole
%%% analysis when it closes: the first line fixes the columns, `+' lines
%%% end rows (`=' makes what precedes them the header) and decide which
%%% cells span into the next row, `|' lines carve cell text by column
%%% position. Each cell's text is then parsed as its own document. A grid
%%% that is not rectangular dissolves back into a paragraph.
%%%
%%% Block kind: grid_table while open; a `table' (see
%%% beamai_markdown_tables) once closed.
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_ext_grid_tables).

-behaviour(beamai_markdown_block_kind).

-include("beamai_markdown.hrl").

-export([setup/2, start/1]).
-export([continue/2, finalize/2, can_contain/2, accepts_lines/1, after_line/2,
         blank_line_ignored/1]).

-spec setup(map(), map()) -> map().
setup(Pipe0, _Opts) ->
    Pipe1 = beamai_markdown_pipeline:set(
              Pipe0, block_parsers,
              [#{name => grid_table, module => ?MODULE, function => start, chars => [$+]}
               | beamai_markdown_pipeline:get(Pipe0, block_parsers)]),
    Pipe2 = beamai_markdown_pipeline:add_block_kind(Pipe1, grid_table, ?MODULE),
    beamai_markdown_pipeline:add_renderer_setup(
      Pipe2, html, #{name => table, module => beamai_markdown_tables, function => setup_html}).

%%%===================================================================
%%% Block parsing
%%%===================================================================

-spec start(#bp{}) -> {done, #bp{}} | none.
start(#bp{indented = false, next_nonspace = NN, line = Line} = Bp) ->
    Rest = binary:part(Line, NN, byte_size(Line) - NN),
    case columns(Rest) of
        none -> none;
        Columns ->
            T = (beamai_markdown_block:new_block(grid_table, Bp, NN))#{columns => Columns},
            Bp1 = beamai_markdown_block:add_child(Bp, T),
            Bp2 = beamai_markdown_block:add_line(Bp1, Rest),
            {done, beamai_markdown_block:advance_offset(Bp2, byte_size(Line) - Bp2#bp.offset, false)}
    end;
start(_) -> none.

%% The column slices of a `+---+:--:+' line: [#{start, end, align}] with
%% offsets into the line, or none.
columns(<<$+, _/binary>> = Line) -> columns(Line, 0, []);
columns(_) -> none.

columns(Line, P, Acc) ->
    case beamai_markdown_char:at(Line, P) of
        $+ ->
            P1 = beamai_markdown_scan:skip_spaces(Line, P + 1),
            case P1 >= byte_size(Line) of
                true -> finish_columns(Acc);
                false ->
                    Spec = binary:part(Line, P1, byte_size(Line) - P1),
                    case beamai_markdown_tables:parse_column_header(Spec, $-) of
                        none -> none;
                        {ok, Align, _N, Used} ->
                            End = P1 + Used,
                            columns(Line, End, [#{start => P, 'end' => End, align => Align} | Acc])
                    end
            end;
        ?NUL when P >= byte_size(Line) -> finish_columns(Acc);
        _ -> none
    end.

finish_columns([]) -> none;
finish_columns(Acc) -> lists:reverse(Acc).

-spec continue(beamai_markdown_block(), #bp{}) ->
          {match, #bp{}} | {match, beamai_markdown_block(), #bp{}} | nomatch
        | {close, beamai_markdown_block(), #bp{}}.
continue(_, #bp{offset = Off} = Bp) ->
    case beamai_markdown_block:peek(Bp, Off) of
        $+ -> {match, Bp};
        $| -> {match, Bp};
        _ -> nomatch
    end.

-spec finalize(beamai_markdown_block(), #bp{}) -> {[beamai_markdown_block()], #bp{}}.
finalize(#{lines := Lines, columns := Columns} = T, Bp) ->
    Texts = [L || {L, _, _} <- Lines],
    case build(Columns, tl(Texts), Bp) of
        {ok, Rows} ->
            Total = lists:sum([E - S - 1 || #{start := S, 'end' := E} <- Columns]),
            Defs = [#{align => A, width => (E - S - 1) * 100 / Total}
                    || #{start := S, 'end' := E, align := A} <- Columns],
            Table = (beamai_markdown_tables:new_table())#{
                      line => maps:get(line, T), col => maps:get(col, T),
                      children => Rows, columns => Defs},
            {[beamai_markdown_attrs:copy_to(T, Table)], Bp};
        invalid ->
            %% Not a table after all: a paragraph with the raw lines.
            {[#{k => paragraph, line => maps:get(line, T), col => maps:get(col, T),
                children => [], lines => Lines, last_line_blank => false}], Bp}
    end.

-spec can_contain(beamai_markdown_block(), atom()) -> boolean().
can_contain(_, _) -> false.

-spec accepts_lines(beamai_markdown_block()) -> boolean().
accepts_lines(_) -> true.

-spec after_line(beamai_markdown_block(), #bp{}) -> #bp{}.
after_line(_, Bp) -> Bp.

-spec blank_line_ignored(beamai_markdown_block()) -> boolean().
blank_line_ignored(_) -> false.

%%%===================================================================
%%% Building the table
%%%===================================================================

%% State: Cols is a list of #{start, end, align, span, prev_span, cell}
%% where cell is a ref into Cells or undefined; Cells maps refs to
%% #{index, col_span, row_span, allow_close, lines (reversed), closed,
%% in_row}; Rows is the reversed list of rows, each a list of refs.
-record(gs, {cols, cells = #{}, rows = [], header_rows = 0, bp}).

build(Columns, Lines, Bp) ->
    Cols = [C#{span => -1, prev_span => 0, cell => undefined} || C <- Columns],
    S0 = #gs{cols = Cols, bp = Bp},
    S1 = lists:foldl(fun line/2, S0, Lines),
    S2 = terminate_row(S1, true),
    Rows = lists:reverse(S2#gs.rows),
    case valid(Rows, S2#gs.cells, length(Columns)) of
        false -> invalid;
        true ->
            HeaderCount = S2#gs.header_rows,
            {ok, [make_row(Refs, S2#gs.cells, I =< HeaderCount, Bp)
                  || {I, Refs} <- lists:zip(lists:seq(1, length(Rows)), Rows)]}
    end.

line(<<$+, _/binary>> = Line, S) -> new_row(Line, S);
line(<<$|, _/binary>> = Line, S) -> contents(Line, false, S);
line(_, S) -> S.

%% A `+' line: decide row spans, recompute column spans, end the row.
new_row(Line, #gs{cols = Cols0} = S0) ->
    IsHeader = beamai_markdown_char:at(Line, 1) =:= $= orelse beamai_markdown_char:at(Line, 2) =:= $=,
    {Cols1, Cells1, HasRowSpan} = row_span_state(Cols0, Line, S0#gs.cells),
    Cols2 = column_span_state(Cols1, Line),
    S1 = terminate_row(S0#gs{cols = Cols2, cells = Cells1}, false),
    S2 = case IsHeader of
             true -> S1#gs{header_rows = length(S1#gs.rows)};
             false -> S1
         end,
    case HasRowSpan of
        true -> contents(Line, true, S2);
        false -> S2
    end.

%% Under a `+' line, a cell whose column segment is not a separator spans
%% into the next row.
row_span_state(Cols, Line, Cells) ->
    lists:foldr(
      fun(#{cell := undefined} = C, {Cs, Ce, Has}) -> {[C | Cs], Ce, Has};
         (#{cell := Ref, start := St, 'end' := En} = C, {Cs, Ce, Has}) ->
              Seg = segment(Line, St, En),
              Cell = maps:get(Ref, Ce),
              case beamai_markdown_scan:trim(Seg) =:= <<>> orelse not is_separator(Seg) of
                  true ->
                      Cell1 = Cell#{row_span => maps:get(row_span, Cell) + 1, allow_close => false},
                      {[C | Cs], Ce#{Ref => Cell1}, true};
                  false ->
                      {[C | Cs], Ce#{Ref => Cell#{allow_close => true}}, Has}
              end
      end, {[], Cells, false}, Cols).

segment(Line, St, En) ->
    From = St + 1,
    To = min(En - 1, byte_size(Line)),
    case To > From of
        true -> beamai_markdown_scan:trim(binary:part(Line, From, To - From));
        false -> <<>>
    end.

is_separator(Bin) ->
    lists:all(fun(C) -> C =:= $- orelse C =:= $= orelse C =:= $: end, binary_to_list(Bin)).

%% Each column's span from the `|' / `+' positions on Line: a column whose
%% start holds neither joins the separator to its left.
column_span_state(Cols, Line) ->
    Reset = [C#{prev_span => maps:get(span, C), span => 0} || C <- Cols],
    finish_spans(Reset, Line).

finish_spans(Cols, Line) ->
    V = list_to_tuple(Cols),
    N = tuple_size(V),
    spans(V, 1, N, none, Line).

spans(V, I, N, ColIdx, Line) when I =< N ->
    C = element(I, V),
    Here = case beamai_markdown_char:at(Line, maps:get(start, C)) of
               $| -> true;
               $+ -> true;
               _ -> false
           end,
    ColIdx1 = case Here of true -> I; false -> ColIdx end,
    V1 = case ColIdx1 of
             none -> V;
             J ->
                 CJ = element(J, V),
                 setelement(J, V, CJ#{span => maps:get(span, CJ) + 1})
         end,
    spans(V1, I + 1, N, ColIdx1, Line);
spans(V, _, _, _, _) -> tuple_to_list(V).

can_continue_row(Cols) ->
    lists:all(fun(#{prev_span := P, span := S}) -> P =:= S end, Cols).

%% Close the row: open cells go into it, those that may close are closed.
terminate_row(#gs{cols = Cols, cells = Cells, rows = Rows} = S, IsLast) ->
    Open = [Ref || #{cell := Ref} <- Cols, Ref =/= undefined],
    case Open of
        [] -> S#gs{cols = [renew(C, undefined, IsLast) || C <- Cols]};
        _ ->
            %% Cells not yet in a row join this one, in column order.
            {RowRefs, Cells1} =
                lists:foldl(fun(Ref, {Acc, Ce}) ->
                                    Cell = maps:get(Ref, Ce),
                                    case maps:get(in_row, Cell) of
                                        true -> {Acc, Ce};
                                        false -> {[Ref | Acc], Ce#{Ref => Cell#{in_row => true}}}
                                    end
                            end, {[], Cells}, lists:usort(Open)),
            Cells2 = lists:foldl(fun(Ref, Ce) ->
                                         Cell = maps:get(Ref, Ce),
                                         case maps:get(allow_close, Cell) of
                                             true -> Ce#{Ref => Cell#{closed => true}};
                                             false -> Ce
                                         end
                                 end, Cells1, Open),
            Cols1 = [renew(C, cell_of(C, Cells2), IsLast) || C <- Cols],
            Rows1 = case RowRefs of
                        [] -> Rows;
                        _ -> [lists:reverse(RowRefs) | Rows]
                    end,
            S#gs{cols = Cols1, cells = Cells2, rows = Rows1}
    end.

cell_of(#{cell := undefined}, _) -> undefined;
cell_of(#{cell := Ref}, Cells) -> maps:get(Ref, Cells).

%% Drop the column's cell when the row is the last, the column spans
%% nothing, or the cell closed.
renew(#{span := Span} = C, Cell, IsLast) ->
    Drop = IsLast orelse Span =:= 0 orelse (Cell =/= undefined andalso maps:get(allow_close, Cell)),
    case Drop of
        true -> C#{cell => undefined};
        false -> C
    end.

%% A `|' line (or a `+' line with spanning cells): feed each cell.
contents(Line, IsRowLine, #gs{cols = Cols0} = S0) ->
    Cols1 = column_span_state(Cols0, Line),
    S1 = case (not IsRowLine) andalso not can_continue_row(Cols1) of
             true -> terminate_row(S0#gs{cols = Cols1}, false);
             false -> S0#gs{cols = Cols1}
         end,
    feed(1, Line, IsRowLine, S1).

feed(I, Line, IsRowLine, #gs{cols = Cols} = S) when I =< length(Cols) ->
    C = lists:nth(I, Cols),
    Next = I + maps:get(span, C),
    case Next =:= I of
        true -> S;
        false ->
            Slice = cell_slice(Line, Cols, I, Next, IsRowLine),
            S1 = feed_cell(I, Slice, IsRowLine, S),
            feed(Next, Line, IsRowLine, S1)
    end;
feed(_, _, _, S) -> S.

%% The window of Line holding the cell at column I (spanning to Next).
cell_slice(Line, Cols, I, Next, IsRowLine) ->
    #{start := St} = lists:nth(I, Cols),
    From = min(St + 1, byte_size(Line)),
    To = case Next =< length(Cols) of
             true -> min(maps:get(start, lists:nth(Next, Cols)), byte_size(Line));
             false ->
                 ColEnd = maps:get('end', lists:last(Cols)),
                 EndChar = beamai_markdown_char:at(Line, ColEnd),
                 case EndChar =:= $| orelse (IsRowLine andalso EndChar =:= $+) of
                     true -> ColEnd;
                     false ->
                         case byte_size(Line) > 0 andalso binary:last(Line) =:= $| of
                             true -> byte_size(Line) - 1;
                             false -> byte_size(Line)
                         end
                 end
         end,
    Text = case To > From of
               true -> binary:part(Line, From, To - From);
               false -> <<>>
           end,
    beamai_markdown_scan:trim_end(Text).

feed_cell(I, Slice, IsRowLine, #gs{cols = Cols, cells = Cells} = S) ->
    case IsRowLine andalso is_separator(beamai_markdown_scan:trim(Slice)) of
        true -> S;
        false ->
            C = lists:nth(I, Cols),
            {Ref, Cells1, Cols1} =
                case maps:get(cell, C) of
                    undefined ->
                        R = make_ref(),
                        Cell = #{index => I - 1, col_span => maps:get(span, C), row_span => 1,
                                 allow_close => true, lines => [], closed => false, in_row => false},
                        {R, Cells#{R => Cell}, set_nth(I, Cols, C#{cell => R})};
                    R -> {R, Cells, Cols}
                end,
            Cell1 = maps:get(Ref, Cells1),
            Cells2 = Cells1#{Ref => Cell1#{lines => [Slice | maps:get(lines, Cell1)]}},
            S#gs{cols = Cols1, cells = Cells2}
    end.

set_nth(I, List, V) ->
    {Before, [_ | After]} = lists:split(I - 1, List),
    Before ++ [V | After].

%% Every row's cells, with spans, must fit the column count; a row span
%% may not reach past the last row.
valid(Rows, Cells, ColumnCount) ->
    N = length(Rows),
    Widths0 = maps:from_list([{I, 0} || I <- lists:seq(1, N)]),
    try
        Widths = lists:foldl(
                   fun({I, Refs}, W) ->
                           lists:foldl(
                             fun(Ref, W1) ->
                                     #{col_span := CS, row_span := RS} = maps:get(Ref, Cells),
                                     lists:foldl(fun(J, W2) ->
                                                         case J > N of
                                                             true -> throw(invalid);
                                                             false -> W2#{J => maps:get(J, W2) + CS}
                                                         end
                                                 end, W1, lists:seq(I, I + RS - 1))
                             end, W, Refs)
                   end, Widths0, lists:zip(lists:seq(1, N), Rows)),
        lists:all(fun({_, Wd}) -> Wd =< ColumnCount end, maps:to_list(Widths))
    catch
        throw:invalid -> false
    end.

make_row(Refs, Cells, Header, Bp) ->
    (beamai_markdown_tables:new_row(Header))#{children => [make_cell(maps:get(R, Cells), Bp) || R <- Refs]}.

%% A cell's text is a document of its own.
make_cell(#{index := I, col_span := CS, row_span := RS, lines := Lines}, #bp{pipe = Pipe, opts = Opts}) ->
    Text = iolist_to_binary(lists:join(<<"\n">>, lists:reverse(Lines))),
    SubBp = beamai_markdown_block:parse(Text, Pipe, Opts),
    [#{children := Children}] = SubBp#bp.stack,
    (beamai_markdown_tables:new_cell(Children))#{col_index => I, col_span => CS, row_span => RS}.
