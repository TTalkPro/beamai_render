%%%-------------------------------------------------------------------
%%% @doc GFM pipe tables.
%%%
%%% Port of markdig's PipeTable extension, on this engine's flat inline
%%% list rather than markdig's mutable tree. Three pieces:
%%%
%%% <ul>
%%%   <li>A block start, ahead of every other, that keeps a paragraph open
%%%       when the separator row (`| - : spaces') would otherwise end it or
%%%       start a list.</li>
%%%   <li>An inline parser on `|' (and on `:' in a separator row, so that
%%%       no other parser -- emoji -- claims it) that leaves a transient
%%%       `pipe' node in the paragraph's inline list.</li>
%%%   <li>A post-processor, registered before emphasis so that a column
%%%       boundary beats an emphasis span, that carves the list into rows and
%%%       cells, runs the remaining post-processors inside each cell, and
%%%       replaces the paragraph with the table -- or, when the paragraph
%%%       had lines before the first pipe, keeps them and puts the table
%%%       after it.</li>
%%% </ul>
%%%
%%% Options: require_header_separator (true), use_header_for_column_count
%%% (false, the GFM variant), infer_column_widths_from_separator (false).
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_ext_pipe_tables).

-include("beamai_markdown.hrl").

-export([setup/2, start_separator/1, match/1, post/2]).

-spec setup(map(), map()) -> map().
setup(Pipe0, Opts) ->
    Pipe1 = beamai_markdown_pipeline:set(
              Pipe0, block_parsers,
              [#{name => pipe_table_separator, module => ?MODULE, function => start_separator,
                 chars => [$|, $-, $:]}
               | beamai_markdown_pipeline:get(Pipe0, block_parsers)]),
    Pipe2 = beamai_markdown_pipeline:insert_before(
              Pipe1, inline_parsers, emphasis,
              #{name => pipe_table, module => ?MODULE, function => match, chars => [$|, $:],
                opts => Opts}),
    Pipe3 = beamai_markdown_pipeline:insert_before(
              Pipe2, post_inline, emphasis,
              #{name => pipe_table, module => ?MODULE, function => post, opts => Opts}),
    beamai_markdown_pipeline:add_renderer_setup(
      Pipe3, html, #{name => table, module => beamai_markdown_tables, function => setup_html}).

%%%===================================================================
%%% Block start: the separator row joins the paragraph
%%%===================================================================

-spec start_separator(#bp{}) -> {done, #bp{}} | none.
start_separator(#bp{indented = false, unmatched = 0, stack = [#{k := paragraph} | _]} = Bp) ->
    case separator_pipes(beamai_markdown_block:rest(Bp)) of
        N when is_integer(N), N > 0 ->
            {done, beamai_markdown_block:add_line(Bp)};
        _ -> none
    end;
start_separator(_) -> none.

%% The number of pipes when the line holds nothing but | - : and spaces.
separator_pipes(Line) -> separator_pipes(Line, 0).

separator_pipes(<<>>, N) -> N;
separator_pipes(<<$|, R/binary>>, N) -> separator_pipes(R, N + 1);
separator_pipes(<<C, R/binary>>, N) when C =:= $\s; C =:= $-; C =:= $: -> separator_pipes(R, N);
separator_pipes(_, _) -> none.

%%%===================================================================
%%% Inline parser
%%%===================================================================

-spec match(#ip{}) -> {ok, #ip{}} | none.
match(#ip{block = #{k := paragraph}} = Ip) ->
    case beamai_markdown_inline:peek(Ip) of
        $| ->
            {ok, beamai_markdown_inline:push(beamai_markdown_inline:advance(Ip, 1),
                                             #{k => pipe, transient => true, literal => <<"|">>})};
        $: ->
            case colon_in_separator(Ip) of
                true -> {ok, beamai_markdown_inline:text(beamai_markdown_inline:advance(Ip, 1), <<":">>)};
                false -> none
            end
    end;
match(_) -> none.

%% A `:' right before a `|' on a separator line whose previous line has a
%% pipe is part of the column spec.
colon_in_separator(#ip{src = Src, pos = P}) ->
    beamai_markdown_char:at(Src, P + 1) =:= $| andalso
        begin
            LineStart = line_start(Src, P),
            LineEnd = line_end(Src, P),
            is_separator_line(binary:part(Src, LineStart, LineEnd - LineStart)) andalso
                LineStart > 0 andalso
                begin
                    PrevEnd = LineStart - 1,
                    PrevStart = line_start(Src, PrevEnd),
                    binary:match(binary:part(Src, PrevStart, PrevEnd - PrevStart), <<"|">>) =/= nomatch
                end
        end.

line_start(_, 0) -> 0;
line_start(Src, P) ->
    case binary:at(Src, P - 1) of
        $\n -> P;
        _ -> line_start(Src, P - 1)
    end.

line_end(Src, P) when P >= byte_size(Src) -> P;
line_end(Src, P) ->
    case binary:at(Src, P) of
        $\n -> P;
        _ -> line_end(Src, P + 1)
    end.

is_separator_line(Line) ->
    binary:match(Line, <<"|">>) =/= nomatch andalso binary:match(Line, <<"-">>) =/= nomatch
        andalso lists:all(fun(C) -> C =:= $| orelse C =:= $- orelse C =:= $: orelse C =:= $\s orelse C =:= $\t end,
                          binary_to_list(Line)).

%%%===================================================================
%%% Post-processor
%%%===================================================================

-spec post([beamai_markdown_inline()], #ip{}) -> {[beamai_markdown_inline()], #ip{}}.
post(Nodes, #ip{block = #{k := paragraph} = Para} = Ip) ->
    case lists:any(fun(#{k := K}) -> K =:= pipe end, Nodes) of
        false -> {Nodes, Ip};
        true ->
            Opts = parser_opts(Ip),
            Lines = split_lines(Nodes),
            {Before, TableLines} = lists:splitwith(fun({L, _}) -> not has_pipe(L) end, Lines),
            case lists:all(fun({L, _}) -> has_pipe(L) end, TableLines) andalso length(TableLines) >= 2 of
                false -> {Nodes, Ip};
                true ->
                    [{Header, _}, {Sep, _} | Body] = TableLines,
                    case separator_columns(Sep, Opts) of
                        none -> {Nodes, Ip};
                        {ok, Columns} ->
                            {Table0, Ip1} = build(Header, Body, Columns, Opts, Ip),
                            Table = beamai_markdown_attrs:copy_to(Para, Table0#{line => maps:get(line, Para)}),
                            case Before of
                                [] -> {[], beamai_markdown_inline:set_block(Ip1, Table)};
                                _ ->
                                    Kept = join_lines(Before),
                                    {Kept, beamai_markdown_inline:add_block_after(Ip1, Table)}
                            end
                    end
            end
    end;
post(Nodes, Ip) -> {Nodes, Ip}.

parser_opts(Ip) ->
    case beamai_markdown_pipeline:find(beamai_markdown_inline:pipe(Ip), post_inline, pipe_table) of
        #{opts := O} -> O;
        _ -> #{}
    end.

%% [{NodesOfLine, LineBreakNode | none}], split at top-level line breaks.
split_lines(Nodes) -> split_lines(Nodes, [], []).

split_lines([], Cur, Acc) -> lists:reverse([{lists:reverse(Cur), none} | Acc]);
split_lines([#{k := linebreak} = LB | Rest], Cur, Acc) ->
    split_lines(Rest, [], [{lists:reverse(Cur), LB} | Acc]);
split_lines([N | Rest], Cur, Acc) -> split_lines(Rest, [N | Cur], Acc).

%% The paragraph lines before the table, without their final line break.
join_lines(Lines) ->
    All = lists:append([case LB of none -> L; _ -> L ++ [LB] end || {L, LB} <- Lines]),
    case lists:reverse(All) of
        [#{k := linebreak} | R] -> lists:reverse(R);
        _ -> All
    end.

has_pipe(Nodes) -> lists:any(fun(#{k := K}) -> K =:= pipe end, Nodes).

%% Split a line at its pipes: [Segment], one more than the pipe count.
segments(Nodes) -> segments(Nodes, [], []).

segments([], Cur, Acc) -> lists:reverse([lists:reverse(Cur) | Acc]);
segments([#{k := pipe} | Rest], Cur, Acc) -> segments(Rest, [], [lists:reverse(Cur) | Acc]);
segments([N | Rest], Cur, Acc) -> segments(Rest, [N | Cur], Acc).

is_blank_seg(Nodes) ->
    lists:all(fun(#{k := text, v := V}) -> beamai_markdown_scan:trim(V) =:= <<>>;
                 (_) -> false
              end, Nodes).

%%%-------------------------------------------------------------------
%%% The separator row
%%%-------------------------------------------------------------------

separator_columns(Nodes, Opts) ->
    [S0 | Rest] = segments(Nodes),
    Last = lists:last(Rest),
    Middle = lists:droplast(Rest),
    Specs0 = case is_blank_seg(S0) of true -> []; false -> [S0] end,
    Specs1 = Specs0 ++ Middle ++ case is_blank_seg(Last) of true -> []; false -> [Last] end,
    case Specs1 =/= [] andalso lists:all(fun(S) -> column_spec(S) =/= none end, Specs1) of
        false -> none;
        true ->
            Cols = [column_spec(S) || S <- Specs1],
            Total = lists:sum([N || {_, N} <- Cols]),
            case Total > 0 of
                false -> none;
                true ->
                    Infer = maps:get(infer_column_widths_from_separator, Opts, false),
                    {ok, [#{align => A, width => case Infer of
                                                     true -> N * 100 / Total;
                                                     false -> 0.0
                                                 end}
                          || {A, N} <- Cols]}
            end
    end.

%% A segment that is exactly one text node holding a column spec.
column_spec([#{k := text, v := V}]) ->
    case beamai_markdown_tables:parse_column_header(V, $-) of
        {ok, Align, N, End} when End =:= byte_size(V) -> {Align, N};
        _ -> none
    end;
column_spec(_) -> none.

%%%-------------------------------------------------------------------
%%% Rows and cells
%%%-------------------------------------------------------------------

build(Header, Body, Columns, Opts, Ip0) ->
    {HeaderRow, Ip1} = row(Header, true, Ip0),
    {BodyRows, Ip2} = lists:mapfoldl(fun({L, _}, Acc) -> row(L, false, Acc) end, Ip1, Body),
    Table0 = (beamai_markdown_tables:new_table())#{children => [HeaderRow | BodyRows],
                                                   columns => Columns},
    Table = case maps:get(use_header_for_column_count, Opts, false) of
                true -> beamai_markdown_tables:normalize_header_row(Table0);
                false -> beamai_markdown_tables:normalize_max_width(Table0)
            end,
    {Table, Ip2}.

row(Nodes, Header, Ip0) ->
    [S0 | Rest] = segments(Nodes),
    Last = lists:last(Rest),
    Middle = lists:droplast(Rest),
    Cells0 = case is_blank_seg(S0) of true -> []; false -> [S0] end,
    Cells1 = Cells0 ++ Middle ++ case is_blank_seg(Last) of true -> []; false -> [Last] end,
    {Cells, Ip1} = lists:mapfoldl(fun cell/2, Ip0, Cells1),
    {(beamai_markdown_tables:new_row(Header))#{children => Cells}, Ip1}.

cell(Seg, Ip0) ->
    Trimmed = trim_cell(Seg),
    {Inlines, Ip1} = beamai_markdown_inline:post_process_after(pipe_table, Trimmed, Ip0),
    Para = #{k => paragraph, line => 0, col => 1, children => [], lines => [], inlines => Inlines},
    {beamai_markdown_tables:new_cell([Para]), Ip1}.

trim_cell(Nodes0) ->
    Nodes1 = lists:dropwhile(fun blank_text/1, Nodes0),
    Nodes2 = lists:reverse(lists:dropwhile(fun blank_text/1, lists:reverse(Nodes1))),
    case Nodes2 of
        [] -> [];
        [#{k := text, v := V} = T | Rest] ->
            Nodes3 = [T#{v => beamai_markdown_scan:trim_start(V)} | Rest],
            trim_last(Nodes3);
        _ -> trim_last(Nodes2)
    end.

trim_last(Nodes) ->
    case lists:reverse(Nodes) of
        [#{k := text, v := V} = T | Rest] ->
            lists:reverse([T#{v => beamai_markdown_scan:trim_end(V)} | Rest]);
        _ -> Nodes
    end.

blank_text(#{k := text, v := V}) -> beamai_markdown_scan:trim(V) =:= <<>>;
blank_text(_) -> false.
