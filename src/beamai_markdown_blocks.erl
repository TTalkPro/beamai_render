%%%-------------------------------------------------------------------
%%% @doc The CommonMark block kinds and block starts.
%%%
%%% One module rather than one per kind: the kinds are small, they share
%%% the marker scanners, and a reader wants to see the whole grammar in one
%%% place. Extensions get their own modules because they are optional.
%%%
%%% Kinds: document, paragraph, heading, thematic_break, indented_code,
%%% fenced_code, html_block, quote, list, list_item, link_ref_def.
%%% Extension kinds unknown to this module get leaf, no-lines defaults.
%%%
%%% Block fields set here, beyond the common ones:
%%%   heading      level, setext (boolean)
%%%   fenced_code  fence_char, fence_len, fence_indent, info, arguments
%%%   html_block   html_type (1..7)
%%%   list         ordered, bullet_char, start, delimiter, tight
%%%   list_item    marker_offset, padding, order (ordered lists)
%%%   link_ref_def label, url, title
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_blocks).

-behaviour(beamai_markdown_block_kind).

-include("beamai_markdown.hrl").

-export([continue/2, finalize/2, can_contain/2, accepts_lines/1,
         after_line/2, blank_line_ignored/1]).
-export([start_quote/1, start_atx_heading/1, start_fenced_code/1,
         start_html_block/1, start_setext_heading/1, start_thematic_break/1,
         start_list_item/1, start_indented_code/1]).
-export([default_parsers/0, parse_list_marker/2, lists_match/2,
         extract_refs/2, content/1, is_thematic_break/1, block_attributes/3,
         fenced_continue/2, fence_open/4, split_info/1]).

-import(beamai_markdown_block,
        [find_next_nonspace/1, advance_offset/3, advance_next_nonspace/1,
         add_child/2, close_unmatched/1, container/1, tip/1, peek/2, rest/1,
         new_block/3, finalize_tip/2]).

%% @doc The CommonMark block starts, in the reference order.
-spec default_parsers() -> [map()].
default_parsers() ->
    [#{name => quote,          module => ?MODULE, function => start_quote,          chars => [$>]},
     #{name => atx_heading,    module => ?MODULE, function => start_atx_heading,    chars => [$#]},
     #{name => fenced_code,    module => ?MODULE, function => start_fenced_code,    chars => [$`, $~]},
     #{name => html_block,     module => ?MODULE, function => start_html_block,     chars => [$<]},
     #{name => setext_heading, module => ?MODULE, function => start_setext_heading, chars => [$=, $-]},
     #{name => thematic_break, module => ?MODULE, function => start_thematic_break, chars => [$*, $_, $-]},
     #{name => list_item,      module => ?MODULE, function => start_list_item,      chars => [$*, $+, $-, $0, $1, $2, $3, $4, $5, $6, $7, $8, $9]},
     #{name => indented_code,  module => ?MODULE, function => start_indented_code,  chars => []}].

%%%===================================================================
%%% Kind callbacks
%%%===================================================================

-spec continue(beamai_markdown_block(), #bp{}) ->
          {match, #bp{}} | {match, beamai_markdown_block(), #bp{}} | nomatch
        | {close, beamai_markdown_block(), #bp{}}.
continue(#{k := document}, Bp) -> {match, Bp};
continue(#{k := list}, Bp) -> {match, Bp};
continue(#{k := quote}, #bp{indented = false} = Bp) ->
    case peek(Bp, Bp#bp.next_nonspace) of
        $> ->
            Bp1 = advance_offset(advance_next_nonspace(Bp), 1, false),
            {match, skip_one_space(Bp1)};
        _ -> nomatch
    end;
continue(#{k := quote}, _) -> nomatch;
continue(#{k := list_item} = Item, #bp{blank = true} = Bp) ->
    %% A blank line right after an empty list item ends the item.
    case maps:get(children, Item) =:= [] andalso not Bp#bp.has_open_child of
        true -> nomatch;
        false -> {match, advance_next_nonspace(Bp)}
    end;
continue(#{k := list_item, marker_offset := MO, padding := Pad}, #bp{indent = Ind} = Bp)
  when Ind >= MO + Pad ->
    {match, advance_offset(Bp, MO + Pad, true)};
continue(#{k := list_item}, _) -> nomatch;
continue(#{k := paragraph}, #bp{blank = true}) -> nomatch;
continue(#{k := paragraph}, Bp) -> {match, Bp};
continue(#{k := heading}, _) -> nomatch;
continue(#{k := thematic_break}, _) -> nomatch;
continue(#{k := link_ref_def}, _) -> nomatch;
continue(#{k := indented_code}, #bp{indent = Ind} = Bp) when Ind >= 4 ->
    {match, advance_offset(Bp, 4, true)};
continue(#{k := indented_code}, #bp{blank = true} = Bp) ->
    {match, advance_next_nonspace(Bp)};
continue(#{k := indented_code}, _) -> nomatch;
continue(#{k := fenced_code} = B, Bp) ->
    fenced_continue(B, Bp);
continue(#{k := html_block, html_type := T}, #bp{blank = true}) when T =:= 6; T =:= 7 -> nomatch;
continue(#{k := html_block}, Bp) -> {match, Bp};
continue(_, _) -> nomatch.

%% @doc The continuation shared by every fenced block (code, math, custom
%% containers): a closing fence of the same character, at least as long as
%% the opening one and indented at most 3, ends the block; any other line
%% continues it with up to the opening fence's indentation skipped.
-spec fenced_continue(beamai_markdown_block(), #bp{}) ->
          {match, #bp{}} | {close, beamai_markdown_block(), #bp{}}.
fenced_continue(#{fence_char := FC, fence_len := FL, fence_indent := FI} = B, Bp) ->
    #bp{indent = Ind, next_nonspace = NN} = Bp,
    case Ind =< 3 andalso peek(Bp, NN) =:= FC of
        true ->
            N = beamai_markdown_scan:count_char(Bp#bp.line, NN, FC),
            case N >= FL andalso beamai_markdown_scan:is_blank(
                                   binary:part(Bp#bp.line, NN + N, byte_size(Bp#bp.line) - NN - N)) of
                true ->
                    Bp1 = Bp#bp{last_line_len = Bp#bp.offset + Ind + N},
                    {close, B#{closed => true, closing_count => N, fence_end_line => Bp#bp.line_no}, Bp1};
                false ->
                    {match, skip_fence_indent(Bp, FI)}
            end;
        false ->
            {match, skip_fence_indent(Bp, FI)}
    end.

%% @doc Scan an opening fence of Char at the next non-space: {Count, Info}
%% where Info is the rest of the line, or none when the count is outside
%% [Min, Max] (Max = infinity for no limit).
-spec fence_open(#bp{}, char(), pos_integer(), pos_integer() | infinity) ->
          {pos_integer(), binary()} | none.
fence_open(#bp{indented = false, line = Line, next_nonspace = NN} = Bp, Char, Min, Max) ->
    case peek(Bp, NN) =:= Char of
        false -> none;
        true ->
            N = beamai_markdown_scan:count_char(Line, NN, Char),
            case N >= Min andalso (Max =:= infinity orelse N =< Max) of
                false -> none;
                true -> {N, binary:part(Line, NN + N, byte_size(Line) - NN - N)}
            end
    end;
fence_open(_, _, _, _) -> none.

skip_one_space(Bp) ->
    case beamai_markdown_char:is_space_or_tab(peek(Bp, Bp#bp.offset)) of
        true  -> advance_offset(Bp, 1, true);
        false -> Bp
    end.

skip_fence_indent(Bp, 0) -> Bp;
skip_fence_indent(Bp, I) ->
    case beamai_markdown_char:is_space_or_tab(peek(Bp, Bp#bp.offset)) of
        true  -> skip_fence_indent(advance_offset(Bp, 1, true), I - 1);
        false -> Bp
    end.

-spec finalize(beamai_markdown_block(), #bp{}) -> {[beamai_markdown_block()], #bp{}}.
finalize(#{k := paragraph} = P, Bp) ->
    {Refs, Rest} = extract_refs(maps:get(lines, P), Bp),
    Bp1 = lists:foldl(fun(#{label := L} = D, Acc) -> beamai_markdown_block:add_ref(Acc, L, D) end, Bp, Refs),
    case Rest of
        [] -> {Refs, Bp1};
        _ ->
            %% What is left starts where its first remaining line does.
            {_, FirstLine, _} = hd(Rest),
            {Refs ++ [P#{lines => Rest, line => FirstLine}], Bp1}
    end;
finalize(#{k := list} = L, Bp) ->
    {[L#{tight => is_tight(maps:get(children, L))}], Bp};
finalize(#{k := indented_code} = C, Bp) ->
    %% Trailing blank lines are not part of an indented code block.
    Lines = lists:reverse(lists:dropwhile(fun({T, _, _}) -> beamai_markdown_scan:is_blank(T) end,
                                          lists:reverse(maps:get(lines, C)))),
    {[C#{lines => Lines}], Bp};
finalize(#{k := fenced_code} = C, Bp) ->
    %% The first line is the info string.
    case maps:get(lines, C) of
        [] -> {[C#{info => <<>>, arguments => <<>>}], Bp};
        [{Info0, _, _} | Body] ->
            Info1 = beamai_markdown_scan:unescape(beamai_markdown_scan:trim(Info0)),
            {Info, Args} = split_info(Info1),
            C1 = C#{info => Info, arguments => Args, lines => Body, raw_info => Info0},
            %% The language class is attached at parse time, as markdig does,
            %% so that generic attributes and renderers see one attribute set.
            Prefix = maps:get(info_prefix, C, <<"language-">>),
            C2 = case Info of
                     <<>> -> C1;
                     _ -> add_class(C1, <<Prefix/binary, Info/binary>>)
                 end,
            {[C2], Bp}
    end;
finalize(#{k := html_block} = H, Bp) ->
    Lines = lists:reverse(lists:dropwhile(fun({T, _, _}) -> beamai_markdown_scan:is_blank(T) end,
                                          lists:reverse(maps:get(lines, H)))),
    {[H#{lines => Lines}], Bp};
finalize(B, Bp) ->
    {[B], Bp}.

add_class(#{attrs := #{classes := Cs} = A} = B, Class) ->
    B#{attrs => A#{classes => Cs ++ [Class]}};
add_class(#{attrs := A} = B, Class) ->
    B#{attrs => A#{classes => [Class]}};
add_class(B, Class) ->
    B#{attrs => #{classes => [Class]}}.

-spec split_info(binary()) -> {binary(), binary()}.
split_info(Info) ->
    case binary:match(Info, [<<" ">>, <<"\t">>]) of
        nomatch -> {Info, <<>>};
        {I, _} -> {binary:part(Info, 0, I),
                   beamai_markdown_scan:trim(binary:part(Info, I, byte_size(Info) - I))}
    end.

-spec can_contain(beamai_markdown_block(), atom()) -> boolean().
can_contain(#{k := document}, K) -> K =/= list_item;
can_contain(#{k := quote}, K) -> K =/= list_item;
can_contain(#{k := list_item}, K) -> K =/= list_item;
can_contain(#{k := list}, K) -> K =:= list_item;
can_contain(_, _) -> false.

-spec accepts_lines(beamai_markdown_block()) -> boolean().
accepts_lines(#{k := paragraph}) -> true;
accepts_lines(#{k := indented_code}) -> true;
accepts_lines(#{k := fenced_code}) -> true;
accepts_lines(#{k := html_block}) -> true;
accepts_lines(_) -> false.

-spec after_line(beamai_markdown_block(), #bp{}) -> #bp{}.
after_line(#{k := html_block, html_type := T}, Bp) when T >= 1, T =< 5 ->
    Line = beamai_markdown_block:rest_from_offset(Bp),
    case html_block_closes(T, Line) of
        true -> finalize_tip(Bp#bp{last_line_len = byte_size(Bp#bp.line)}, Bp#bp.line_no);
        false -> Bp
    end;
after_line(_, Bp) -> Bp.

-spec blank_line_ignored(beamai_markdown_block()) -> boolean().
blank_line_ignored(_) -> false.

%%%===================================================================
%%% Block starts
%%%===================================================================

-spec start_quote(#bp{}) -> {leaf, #bp{}} | {container, #bp{}} | none.
start_quote(#bp{indented = false} = Bp) ->
    case peek(Bp, Bp#bp.next_nonspace) of
        $> ->
            Bp1 = advance_offset(advance_next_nonspace(Bp), 1, false),
            Bp2 = skip_one_space(Bp1),
            Q = (new_block(quote, Bp2, Bp#bp.next_nonspace))#{ch => $>},
            {container, add_child(Bp2, Q)};
        _ -> none
    end;
start_quote(_) -> none.

-spec start_atx_heading(#bp{}) -> {leaf, #bp{}} | {container, #bp{}} | none.
start_atx_heading(#bp{indented = false} = Bp) ->
    Line = Bp#bp.line, NN = Bp#bp.next_nonspace,
    N = beamai_markdown_scan:count_char(Line, NN, $#),
    After = peek(Bp, NN + N),
    case N >= 1 andalso N =< 6 andalso (After =:= ?NUL orelse After =:= $\s orelse After =:= $\t) of
        false -> none;
        true ->
            Bp1 = advance_offset(advance_next_nonspace(Bp), N, false),
            H0 = (new_block(heading, Bp1, NN))#{level => N, setext => false},
            %% Generic attributes are cut off the line before the closing
            %% run is stripped.
            {Rest0, H1} = block_attributes(Bp, beamai_markdown_block:rest_from_offset(Bp1), H0),
            Content = heading_content(Rest0),
            H = H1#{lines => [{Content, Bp#bp.line_no, Bp#bp.eol}]},
            Bp2 = add_child(Bp1, H),
            Bp3 = advance_offset(Bp2, byte_size(Line) - Bp2#bp.offset, false),
            {leaf, Bp3}
    end;
start_atx_heading(_) -> none.

%% @doc Let the generic attributes extension cut a `{...}' group off a
%% heading or fence line and attach it to the block.
-spec block_attributes(#bp{}, binary(), beamai_markdown_block()) ->
          {binary(), beamai_markdown_block()}.
block_attributes(#bp{pipe = Pipe}, Line, Block) ->
    case maps:get(block_attributes, Pipe, undefined) of
        undefined -> {Line, Block};
        {M, F} -> M:F(Line, Block)
    end.

%% Strip the optional closing sequence and surrounding spaces.
heading_content(Rest) ->
    T = beamai_markdown_scan:trim(Rest),
    case T of
        <<>> -> <<>>;
        _ ->
            case binary:last(T) of
                $# ->
                    Stripped = string:trim(T, trailing, "#"),
                    case Stripped of
                        <<>> -> <<>>;
                        _ ->
                            case binary:last(Stripped) of
                                C when C =:= $\s; C =:= $\t -> beamai_markdown_scan:trim(Stripped);
                                _ -> T
                            end
                    end;
                _ -> T
            end
    end.

-spec start_fenced_code(#bp{}) -> {done, #bp{}} | none.
start_fenced_code(#bp{indented = false} = Bp) ->
    Line = Bp#bp.line, NN = Bp#bp.next_nonspace,
    C = peek(Bp, NN),
    case C =:= $` orelse C =:= $~ of
        false -> none;
        true ->
            N = beamai_markdown_scan:count_char(Line, NN, C),
            Info = binary:part(Line, NN + N, byte_size(Line) - NN - N),
            InfoOk = C =:= $~ orelse binary:match(Info, <<"`">>) =:= nomatch,
            case N >= 3 andalso InfoOk of
                false -> none;
                true ->
                    F0 = (new_block(fenced_code, Bp, NN))#{fence_char => C, fence_len => N,
                                                           fence_indent => Bp#bp.indent,
                                                           closed => false},
                    {Info1, F} = block_attributes(Bp, Info, F0),
                    Bp1 = add_child(Bp, F),
                    Bp2 = advance_offset(advance_next_nonspace(Bp1), N, false),
                    %% The info line is added here (with any attributes cut
                    %% off), so the text placement must not add it again.
                    {done, beamai_markdown_block:add_line(Bp2, Info1)}
            end
    end;
start_fenced_code(_) -> none.

-spec start_html_block(#bp{}) -> {leaf, #bp{}} | {container, #bp{}} | none.
start_html_block(#bp{indented = false} = Bp) ->
    case peek(Bp, Bp#bp.next_nonspace) of
        $< ->
            S = rest(Bp),
            case html_block_type(S) of
                none -> none;
                7 ->
                    Cont = container(Bp),
                    case maps:get(k, Cont) =:= paragraph orelse
                        (beamai_markdown_block:is_lazy_paragraph(Bp) andalso not Bp#bp.blank) of
                        true -> none;
                        false -> open_html_block(Bp, 7)
                    end;
                T -> open_html_block(Bp, T)
            end;
        _ -> none
    end;
start_html_block(_) -> none.

open_html_block(Bp, T) ->
    H = (new_block(html_block, Bp, Bp#bp.offset))#{html_type => T},
    {leaf, add_child(Bp, H)}.

-spec start_setext_heading(#bp{}) -> {leaf, #bp{}} | {container, #bp{}} | none.
start_setext_heading(#bp{indented = false, unmatched = 0, stack = [#{k := paragraph} = P | _]} = Bp) ->
    S = rest(Bp),
    case setext_level(S) of
        none -> none;
        Level ->
            %% The open paragraph's lines are reversed.
            {Refs, Rest} = extract_refs(lists:reverse(maps:get(lines, P)), Bp),
            case Rest of
                [] ->
                    none;
                _ ->
                    Bp1 = lists:foldl(fun(#{label := L} = D, Acc) ->
                                              beamai_markdown_block:add_ref(Acc, L, D)
                                      end, Bp, Refs),
                    %% The paragraph becomes the heading; any reference
                    %% definitions it started with go before it.
                    H = P#{k => heading, level => Level, setext => true,
                           lines => lists:reverse(Rest),
                           underline => {beamai_markdown_scan:trim_end(S), Bp#bp.line_no}},
                    [_ | Stack] = Bp1#bp.stack,
                    [Parent | Rest2] = Stack,
                    Parent1 = Parent#{children => lists:reverse(Refs, maps:get(children, Parent))},
                    Bp2 = Bp1#bp{stack = [H, Parent1 | Rest2]},
                    Bp3 = advance_offset(Bp2, byte_size(Bp2#bp.line) - Bp2#bp.offset, false),
                    {leaf, Bp3}
            end
    end;
start_setext_heading(_) -> none.

setext_level(<<$=, _/binary>> = S) -> setext_check(S, $=, 1);
setext_level(<<$-, _/binary>> = S) -> setext_check(S, $-, 2);
setext_level(_) -> none.

setext_check(S, C, Level) ->
    N = beamai_markdown_scan:count_char(S, 0, C),
    case beamai_markdown_scan:is_blank(binary:part(S, N, byte_size(S) - N)) of
        true -> Level;
        false -> none
    end.

-spec start_thematic_break(#bp{}) -> {leaf, #bp{}} | {container, #bp{}} | none.
start_thematic_break(#bp{indented = false} = Bp) ->
    case is_thematic_break(rest(Bp)) of
        false -> none;
        true ->
            Rest = rest(Bp),
            TB = (new_block(thematic_break, Bp, Bp#bp.next_nonspace))#{
                   ch => binary:first(Rest),
                   count => length([C || <<C>> <= Rest, C =:= binary:first(Rest)])},
            Bp1 = add_child(Bp, TB),
            {leaf, advance_offset(Bp1, byte_size(Bp1#bp.line) - Bp1#bp.offset, false)}
    end;
start_thematic_break(_) -> none.

%% @doc Three or more of the same `*', `-' or `_', spaces allowed between.
-spec is_thematic_break(binary()) -> boolean().
is_thematic_break(<<C, _/binary>> = S) when C =:= $*; C =:= $-; C =:= $_ ->
    tb_count(S, C, 0);
is_thematic_break(_) -> false.

tb_count(<<>>, _, N) -> N >= 3;
tb_count(<<C, R/binary>>, C, N) -> tb_count(R, C, N + 1);
tb_count(<<$\s, R/binary>>, C, N) -> tb_count(R, C, N);
tb_count(<<$\t, R/binary>>, C, N) -> tb_count(R, C, N);
tb_count(_, _, _) -> false.

-spec start_list_item(#bp{}) -> {leaf, #bp{}} | {container, #bp{}} | none.
start_list_item(Bp) ->
    Cont = container(Bp),
    case (not Bp#bp.indented) orelse maps:get(k, Cont) =:= list of
        false -> none;
        true ->
            case parse_list_marker(Bp, Cont) of
                none -> none;
                {Data, Bp1} ->
                    Bp2 = close_unmatched(Bp1),
                    Bp3 = case tip(Bp2) of
                              #{k := list} = L ->
                                  case lists_match(L, Data) of
                                      true -> Bp2;
                                      false -> add_child(Bp2, list_block(Data, Bp))
                                  end;
                              _ -> add_child(Bp2, list_block(Data, Bp))
                          end,
                    Item = (new_block(list_item, Bp, Bp#bp.next_nonspace))#{
                             marker_offset => maps:get(marker_offset, Data),
                             padding => maps:get(padding, Data),
                             order => maps:get(start, Data),
                             marker => maps:get(marker, Data)},
                    {container, add_child(Bp3, Item)}
            end
    end.

list_block(Data, Bp) ->
    (new_block(list, Bp, Bp#bp.next_nonspace))#{
      ordered => maps:get(ordered, Data),
      bullet_char => maps:get(bullet_char, Data),
      start => maps:get(start, Data),
      delimiter => maps:get(delimiter, Data),
      tight => true}.

%% @doc Do a list block and a new marker describe the same list?
-spec lists_match(beamai_markdown_block(), map()) -> boolean().
lists_match(#{ordered := O, bullet_char := BC, delimiter := D}, Data) ->
    maps:get(ordered, Data) =:= O andalso maps:get(bullet_char, Data) =:= BC
        andalso maps:get(delimiter, Data) =:= D.

%% @doc Parse a list marker at the next non-space. Returns the marker data
%% and the processor advanced past the marker and its padding.
-spec parse_list_marker(#bp{}, beamai_markdown_block()) -> {map(), #bp{}} | none.
parse_list_marker(#bp{indent = Ind}, _) when Ind >= 4 -> none;
parse_list_marker(#bp{line = Line, next_nonspace = NN} = Bp, Cont) ->
    InPara = maps:get(k, Cont) =:= paragraph,
    Marker =
        case peek(Bp, NN) of
            C when C =:= $*; C =:= $+; C =:= $- ->
                #{ordered => false, bullet_char => C, start => 0, delimiter => 0,
                  len => 1, marker => <<C>>};
            C when C >= $0, C =< $9 ->
                N = digits(Line, NN, 0),
                case N >= 1 andalso N =< 9 of
                    false -> none;
                    true ->
                        Digits = binary:part(Line, NN, N),
                        case peek(Bp, NN + N) of
                            D when D =:= $.; D =:= $) ->
                                Start = binary_to_integer(Digits),
                                case InPara andalso Start =/= 1 of
                                    true -> none;
                                    false ->
                                        #{ordered => true, bullet_char => $1, start => Start,
                                          delimiter => D, len => N + 1,
                                          marker => binary:part(Line, NN, N + 1)}
                                end;
                            _ -> none
                        end
                end;
            _ -> none
        end,
    %% Extensions (list extras) may recognise other markers.
    Pending = case Cont of
                  #{k := list, bullet_char := BC} -> BC;
                  _ -> ?NUL
              end,
    Marker1 = case Marker of
                  none -> marker_hooks(maps:get(list_marker_parsers, Bp#bp.pipe, []), Bp, Pending, InPara);
                  _ -> Marker
              end,
    case Marker1 of
        none -> none;
        #{len := Len} ->
            NextC = peek(Bp, NN + Len),
            case NextC =:= ?NUL orelse NextC =:= $\s orelse NextC =:= $\t of
                false -> none;
                true ->
                    AfterMarker = binary:part(Line, NN + Len, byte_size(Line) - NN - Len),
                    case InPara andalso beamai_markdown_scan:is_blank(AfterMarker) of
                        true -> none;
                        false -> marker_padding(Marker1, Bp)
                    end
            end
    end.

marker_hooks([], _, _, _) -> none;
marker_hooks([#{module := M, function := F} | Rest], Bp, Pending, InPara) ->
    case M:F(Bp, Pending) of
        none -> marker_hooks(Rest, Bp, Pending, InPara);
        #{start := Start} when InPara, Start =/= 1 -> none;
        Marker -> Marker
    end.

digits(Line, P, N) ->
    case P < byte_size(Line) andalso beamai_markdown_char:is_digit(binary:at(Line, P)) of
        true -> digits(Line, P + 1, N + 1);
        false -> N
    end.

marker_padding(#{len := Len} = Marker, Bp0) ->
    Bp1 = advance_offset(advance_next_nonspace(Bp0), Len, true),
    SpacesCol = Bp1#bp.column, SpacesOff = Bp1#bp.offset, SpacesPartial = Bp1#bp.partial_tab,
    Bp2 = eat_spaces(advance_offset(Bp1, 1, true), SpacesCol),
    BlankItem = peek(Bp2, Bp2#bp.offset) =:= ?NUL,
    SpacesAfter = Bp2#bp.column - SpacesCol,
    Data0 = Marker#{marker_offset => Bp0#bp.indent},
    case SpacesAfter >= 5 orelse SpacesAfter < 1 orelse BlankItem of
        true ->
            Bp3 = Bp1#bp{column = SpacesCol, offset = SpacesOff, partial_tab = SpacesPartial},
            Bp4 = case beamai_markdown_char:is_space_or_tab(peek(Bp3, Bp3#bp.offset)) of
                      true -> advance_offset(Bp3, 1, true);
                      false -> Bp3
                  end,
            {Data0#{padding => Len + 1}, Bp4};
        false ->
            {Data0#{padding => Len + SpacesAfter}, Bp2}
    end.

eat_spaces(Bp, StartCol) ->
    case Bp#bp.column - StartCol < 5 andalso
        beamai_markdown_char:is_space_or_tab(peek(Bp, Bp#bp.offset)) of
        true -> eat_spaces(advance_offset(Bp, 1, true), StartCol);
        false -> Bp
    end.

-spec start_indented_code(#bp{}) -> {leaf, #bp{}} | {container, #bp{}} | none.
start_indented_code(#bp{indented = true, blank = false, stack = [Tip | _]} = Bp) ->
    case maps:get(k, Tip) of
        paragraph -> none;
        _ ->
            Bp1 = advance_offset(Bp, 4, true),
            C = new_block(indented_code, Bp1, Bp#bp.offset),
            {leaf, add_child(Bp1, C)}
    end;
start_indented_code(_) -> none.

%%%===================================================================
%%% List tightness
%%%===================================================================

is_tight([]) -> true;
is_tight([Item]) -> not child_gap(maps:get(children, Item));
is_tight([Item | Rest]) ->
    case ends_with_blank(Item) orelse child_gap(maps:get(children, Item)) of
        true -> false;
        false -> is_tight(Rest)
    end.

%% A blank line between two children of an item makes the list loose too,
%% in the last item as much as in any other.
child_gap([]) -> false;
child_gap([_]) -> false;
child_gap([C | Rest]) -> ends_with_blank(C) orelse child_gap(Rest).

ends_with_blank(#{last_line_blank := true}) -> true;
ends_with_blank(#{k := K, children := Ch}) when K =:= list; K =:= list_item ->
    case Ch of
        [] -> false;
        _ -> ends_with_blank(lists:last(Ch))
    end;
ends_with_blank(_) -> false.

%%%===================================================================
%%% Link reference definitions
%%%===================================================================

%% @doc Strip every link reference definition from the start of a
%% paragraph's lines. Returns {Definitions, RemainingLines}.
-spec extract_refs([{binary(), pos_integer(), binary()}], #bp{}) ->
          {[beamai_markdown_block()], [{binary(), pos_integer(), binary()}]}.
extract_refs([{<<$[, _/binary>>, _, _} | _] = Lines, Bp) ->
    Text = content(Lines),
    case beamai_markdown_inline:parse_reference(Text, 0) of
        none -> {[], Lines};
        {ok, Def, End} ->
            %% Drop the consumed prefix line by line.
            {Consumed, Rest} = drop_lines(Lines, End),
            {FirstLine, _, _} = hd(Lines),
            _ = FirstLine,
            {_, LineNo, _} = hd(Lines),
            {_, EndLine, _} = lists:last(Consumed),
            Block = #{k => link_ref_def, line => LineNo, end_line => EndLine, col => 1,
                      children => [], lines => Consumed,
                      label => maps:get(label, Def), url => maps:get(url, Def),
                      title => maps:get(title, Def), raw_label => maps:get(raw_label, Def)},
            {More, Rest2} = extract_refs(Rest, Bp),
            {[Block | More], Rest2}
    end;
extract_refs(Lines, _) -> {[], Lines}.

%% Remove the first End bytes of content (lines joined by "\n"). A partial
%% last line is kept, minus the consumed prefix.
drop_lines(Lines, End) -> drop_lines(Lines, End, []).

drop_lines([], _, Acc) -> {lists:reverse(Acc), []};
drop_lines([{T, N, E} = L | Rest], End, Acc) ->
    Size = byte_size(T) + 1,
    if End >= byte_size(T) -> drop_lines(Rest, End - Size, [L | Acc]);
       End =< 0 -> {lists:reverse(Acc), [L | Rest]};
       true ->
           Consumed = binary:part(T, 0, End),
           Remaining = binary:part(T, End, byte_size(T) - End),
           {lists:reverse([{Consumed, N, <<>>} | Acc]), [{Remaining, N, E} | Rest]}
    end.

%% @doc A leaf's lines joined with "\n".
-spec content([{binary(), pos_integer(), binary()}]) -> binary().
content(Lines) ->
    iolist_to_binary(lists:join(<<"\n">>, [T || {T, _, _} <- Lines])).

%%%===================================================================
%%% HTML blocks
%%%===================================================================

-define(HTML_BLOCK_TAGS,
        [<<"address">>, <<"article">>, <<"aside">>, <<"base">>, <<"basefont">>,
         <<"blockquote">>, <<"body">>, <<"caption">>, <<"center">>, <<"col">>,
         <<"colgroup">>, <<"dd">>, <<"details">>, <<"dialog">>, <<"dir">>,
         <<"div">>, <<"dl">>, <<"dt">>, <<"fieldset">>, <<"figcaption">>,
         <<"figure">>, <<"footer">>, <<"form">>, <<"frame">>, <<"frameset">>,
         <<"h1">>, <<"h2">>, <<"h3">>, <<"h4">>, <<"h5">>, <<"h6">>, <<"head">>,
         <<"header">>, <<"hr">>, <<"html">>, <<"iframe">>, <<"legend">>, <<"li">>,
         <<"link">>, <<"main">>, <<"menu">>, <<"menuitem">>, <<"nav">>,
         <<"noframes">>, <<"ol">>, <<"optgroup">>, <<"option">>, <<"p">>,
         <<"param">>, <<"search">>, <<"section">>, <<"summary">>, <<"table">>,
         <<"tbody">>, <<"td">>, <<"tfoot">>, <<"th">>, <<"thead">>, <<"title">>,
         <<"tr">>, <<"track">>, <<"ul">>]).

-define(RAW_TAGS, [<<"script">>, <<"pre">>, <<"textarea">>, <<"style">>]).

html_block_type(S) ->
    case S of
        <<"<!--", _/binary>> -> 2;
        <<"<?", _/binary>> -> 3;
        <<"<![CDATA[", _/binary>> -> 5;
        <<"<!", C, _/binary>> when (C >= $a andalso C =< $z); (C >= $A andalso C =< $Z) -> 4;
        _ ->
            case html_block_1(S) of
                true -> 1;
                false ->
                    case html_block_6(S) of
                        true -> 6;
                        false ->
                            case html_block_7(S) of
                                true -> 7;
                                false -> none
                            end
                    end
            end
    end.

html_block_1(<<$<, R/binary>>) ->
    lists:any(fun(Tag) -> tag_then_end(R, Tag, [$\s, $\t, $>]) end, ?RAW_TAGS);
html_block_1(_) -> false.

tag_then_end(R, Tag, Ends) ->
    N = byte_size(Tag),
    case R of
        <<T:N/binary, After/binary>> ->
            beamai_markdown_scan:lower_ascii(T) =:= Tag andalso
                (After =:= <<>> orelse lists:member(binary:first(After), Ends));
        _ -> false
    end.

html_block_6(<<"</", R/binary>>) -> html_block_6_tag(R);
html_block_6(<<"<", R/binary>>) -> html_block_6_tag(R);
html_block_6(_) -> false.

html_block_6_tag(R) ->
    case beamai_markdown_scan:html_tag_name(R, 0) of
        none -> false;
        {ok, Name, End} ->
            lists:member(string:lowercase(Name), ?HTML_BLOCK_TAGS) andalso
                case binary:part(R, End, byte_size(R) - End) of
                    <<>> -> true;
                    <<C, _/binary>> when C =:= $\s; C =:= $\t; C =:= $> -> true;
                    <<"/>", _/binary>> -> true;
                    _ -> false
                end
    end.

html_block_7(S) ->
    Res = case S of
              <<"</", _/binary>> -> beamai_markdown_scan:html_closing_tag(S, 0);
              _ -> beamai_markdown_scan:html_open_tag(S, 0)
          end,
    case Res of
        none -> false;
        {ok, End} ->
            {ok, Name, _} = beamai_markdown_scan:html_tag_name(S, case S of <<"</", _/binary>> -> 2; _ -> 1 end),
            (not lists:member(string:lowercase(Name), ?RAW_TAGS)) andalso
                beamai_markdown_scan:is_blank(binary:part(S, End, byte_size(S) - End))
    end.

html_block_closes(1, Line) ->
    L = beamai_markdown_scan:lower_ascii(Line),
    lists:any(fun(T) -> binary:match(L, <<"</", T/binary, ">">>) =/= nomatch end, ?RAW_TAGS);
html_block_closes(2, Line) -> binary:match(Line, <<"-->">>) =/= nomatch;
html_block_closes(3, Line) -> binary:match(Line, <<"?>">>) =/= nomatch;
html_block_closes(4, Line) -> binary:match(Line, <<">">>) =/= nomatch;
html_block_closes(5, Line) -> binary:match(Line, <<"]]>">>) =/= nomatch.
