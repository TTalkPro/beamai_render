%%%-------------------------------------------------------------------
%%% @doc The block-level parser: lines in, a block tree out.
%%%
%%% This is the CommonMark reference algorithm (the one in the spec's
%%% appendix, as commonmark.js implements it) written functionally. The
%%% open blocks are a stack, innermost first; each line is first offered to
%%% every open block from the document down (continuation), then to the
%%% registered block starts, and whatever text is left goes to the tip.
%%%
%%% Unmatched blocks are not closed the moment they fail to continue: the
%%% line may still be a lazy paragraph continuation. They are closed when a
%%% block start claims the line (add_child/2) or when the line's text is
%%% placed (close_unmatched/1). That ordering is load-bearing and identical
%%% to the reference.
%%%
%%% Nothing in here knows what a paragraph or a list is. Every block kind is
%%% a module with four callbacks (continue, finalize, can_contain,
%%% accepts_lines), and every block start is a function in the pipeline's
%%% ordered list; beamai_markdown_blocks provides the CommonMark set and
%%% extensions add theirs.
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_block).

-include("beamai_markdown.hrl").

-export([parse/3]).
%% For block parsers.
-export([find_next_nonspace/1, advance_offset/3, advance_next_nonspace/1,
         add_child/2, close_unmatched/1, container/1, container_for/2, tip/1, update_tip/2,
         replace_tip/2, finalize_tip/2, add_line/1, add_line/2, peek/2,
         rest/1, rest_from_offset/1, new_block/3, kind_mod/2,
         last_child/1, set_last_child/2, is_lazy_paragraph/1,
         refs/1, add_ref/3, pipe/1, opts/1, line_no/1]).

-define(CODE_INDENT, 4).

%%%===================================================================
%%% Entry point
%%%===================================================================

%% @doc Parse the block structure of Text. Returns the document block, whose
%% leaves still hold raw lines, and the link reference definitions.
-spec parse(binary(), map(), map()) -> #bp{}.
parse(Text, Pipe, Opts) ->
    Doc = (new_block(document, #bp{}, 0))#{line => 1, col => 1},
    Bp0 = #bp{stack = [Doc], pipe = Pipe, opts = Opts, source = Text},
    Lines = beamai_markdown_scan:split_lines(Text),
    {Bp1, _} = lists:foldl(fun({L, E} = Line, {Bp, Off}) ->
                                   {incorporate(Line, Bp#bp{line_start = Off}),
                                    Off + byte_size(L) + byte_size(E)}
                           end, {Bp0, 0}, Lines),
    close_all(Bp1).

%% Every open block is finalized at end of input, tip first, the document
%% last.
close_all(#bp{stack = [_Doc]} = Bp) ->
    finalize_tip(Bp, Bp#bp.line_no);
close_all(Bp) ->
    close_all(finalize_tip(Bp, Bp#bp.line_no)).

%%%===================================================================
%%% One line
%%%===================================================================

incorporate({Line0, Eol}, Bp0) ->
    Line = fixup_nul(Line0),
    Bp1 = Bp0#bp{line = Line, eol = Eol, line_no = Bp0#bp.line_no + 1,
                 offset = 0, column = 0, blank = false, partial_tab = false,
                 unmatched = 0},
    %% Continuation: offer the line to every open block, document first.
    case continue_blocks(Bp1) of
        {done, Bp2} -> Bp2#bp{last_line_len = byte_size(Line)};
        {ok, Bp2} ->
            case try_starts(Bp2) of
                {done, Bp3} -> Bp3#bp{last_line_len = byte_size(Line)};
                Bp3 -> (place_text(Bp3))#bp{last_line_len = byte_size(Line)}
            end
    end.

fixup_nul(Line) ->
    case binary:match(Line, <<0>>) of
        nomatch -> Line;
        _ -> binary:replace(Line, <<0>>, <<16#FFFD/utf8>>, [global])
    end.

%% The stack is innermost first; the continuation pass runs outermost first.
%% Blocks that match are updated in place; the first that does not marks
%% itself and every block above it as unmatched.
continue_blocks(#bp{stack = Stack} = Bp) ->
    Blocks = lists:reverse(Stack),
    continue_blocks(tl(Blocks), [hd(Blocks)], Bp).

continue_blocks([], Acc, Bp) ->
    {ok, Bp#bp{stack = Acc, unmatched = 0}};
continue_blocks([B | Rest] = Unmatched, Acc, Bp0) ->
    Bp = find_next_nonspace(Bp0#bp{has_open_child = Rest =/= []}),
    Mod = kind_mod(maps:get(k, B), Bp),
    case Mod:continue(B, Bp) of
        {match, Bp1} ->
            continue_blocks(Rest, [B | Acc], Bp1);
        {match, B1, Bp1} ->
            continue_blocks(Rest, [B1 | Acc], Bp1);
        nomatch ->
            {ok, Bp#bp{stack = lists:reverse(Unmatched) ++ Acc,
                       unmatched = length(Unmatched)}};
        {close, B1, Bp1} ->
            %% The line closes this block (a closing fence): whatever is
            %% open inside it closes first, then the block itself, and
            %% nothing else sees the line.
            Bp2 = Bp1#bp{stack = lists:reverse(Rest) ++ [B1 | Acc], unmatched = length(Rest)},
            Bp3 = close_unmatched(Bp2),
            {done, finalize_tip(Bp3, Bp3#bp.line_no)}
    end.

%% Block starts run until a leaf is opened or nothing matches. A start that
%% opens a container returns to try again inside it. Returns the state, or
%% `{done, State}' when a start consumed the whole line.
try_starts(Bp0) ->
    case matched_leaf(Bp0) of
        true -> Bp0;
        false ->
            Bp = find_next_nonspace(Bp0),
            #bp{pipe = Pipe} = Bp,
            Special = maps:get(block_start_chars, Pipe),
            C = peek(Bp, Bp#bp.next_nonspace),
            case (not Bp#bp.indented) andalso not is_special(C, Special) of
                true -> advance_next_nonspace(Bp);
                false ->
                    case run_starts(maps:get(block_parsers, Pipe), Bp) of
                        {leaf, Bp1} -> Bp1;
                        {container, Bp1} -> try_starts(Bp1);
                        %% The start consumed the line itself: nothing
                        %% else, not even the text placement, sees it.
                        {done, _} = Done -> Done;
                        none -> advance_next_nonspace(Bp)
                    end
            end
    end.

is_special(C, {Ascii, Set}) when C < 128 ->
    binary:at(Ascii, C) =:= 1 orelse (Set =/= [] andalso lists:member(C, Set));
is_special(C, {_Ascii, Set}) ->
    lists:member(C, Set) orelse lists:member(any, Set).

matched_leaf(Bp) ->
    C = container(Bp),
    K = maps:get(k, C),
    K =/= paragraph andalso (kind_mod(K, Bp)):accepts_lines(C).

run_starts([], _Bp) -> none;
run_starts([#{module := M, function := F} | Rest], Bp) ->
    case M:F(Bp) of
        none -> run_starts(Rest, Bp);
        Result -> Result
    end.

%% What is left of the line is text: a lazy paragraph continuation, lines
%% for a leaf that accepts them, or a new paragraph.
place_text(#bp{blank = Blank, line = Line} = Bp0) ->
    case is_lazy_paragraph(Bp0) andalso not Blank of
        true ->
            add_line(Bp0);
        false ->
            Bp1 = close_unmatched(Bp0),
            Bp2 = mark_blank(Bp1),
            [Tip | _] = Bp2#bp.stack,
            Mod = kind_mod(maps:get(k, Tip), Bp2),
            case Mod:accepts_lines(Tip) of
                true ->
                    Bp3 = add_line(Bp2),
                    Mod:after_line(tip(Bp3), Bp3);
                false when Bp2#bp.offset < byte_size(Line), not Blank ->
                    P = new_block(paragraph, Bp2, Bp2#bp.offset),
                    Bp3 = add_child(Bp2, P),
                    add_line(advance_next_nonspace(Bp3));
                false ->
                    Bp2
            end
    end.

%% Blank-line bookkeeping for list tightness. A blank line marks the tip's
%% last child, and `last_line_blank' is recomputed on every open block --
%% not counting block quotes, fenced code or a list item that is empty on
%% its first line.
mark_blank(#bp{blank = false, stack = Stack} = Bp) ->
    Bp#bp{stack = [B#{last_line_blank => false} || B <- Stack]};
mark_blank(#bp{blank = true, stack = [Tip0 | Rest], line_no = N} = Bp) ->
    Tip = case maps:get(children, Tip0, []) of
              [] -> Tip0;
              [Last | Others] -> Tip0#{children => [Last#{last_line_blank => true} | Others]}
          end,
    K = maps:get(k, Tip),
    LastLineBlank =
        not (K =:= quote
             orelse (K =:= fenced_code)
             orelse (K =:= list_item andalso maps:get(children, Tip, []) =:= []
                     andalso maps:get(line, Tip) =:= N)
             orelse ((kind_mod(K, Bp)):blank_line_ignored(Tip))),
    Bp#bp{stack = [B#{last_line_blank => LastLineBlank} || B <- [Tip | Rest]]}.

%%%===================================================================
%%% Line navigation
%%%===================================================================

%% @doc Locate the next non-space character from the current offset, and
%% derive `blank', `indent' and `indented' from it.
-spec find_next_nonspace(#bp{}) -> #bp{}.
find_next_nonspace(#bp{line = Line, offset = Off, column = Col} = Bp) ->
    {I, Cols} = scan_spaces(Line, Off, Col),
    Blank = I >= byte_size(Line),
    Indent = Cols - Col,
    Bp#bp{next_nonspace = I, next_nonspace_col = Cols, blank = Blank,
          indent = Indent, indented = Indent >= ?CODE_INDENT}.

scan_spaces(Line, I, Cols) when I < byte_size(Line) ->
    case binary:at(Line, I) of
        $\s -> scan_spaces(Line, I + 1, Cols + 1);
        $\t -> scan_spaces(Line, I + 1, Cols + (4 - (Cols rem 4)));
        _ -> {I, Cols}
    end;
scan_spaces(_, I, Cols) -> {I, Cols}.

%% @doc Advance by Count characters (Columns = false) or Count columns
%% (Columns = true, which may consume part of a tab).
-spec advance_offset(#bp{}, non_neg_integer(), boolean()) -> #bp{}.
advance_offset(Bp, 0, _) -> Bp;
advance_offset(#bp{line = Line, offset = Off} = Bp, _Count, _) when Off >= byte_size(Line) -> Bp;
advance_offset(#bp{line = Line, offset = Off, column = Col} = Bp, Count, Columns) ->
    case binary:at(Line, Off) of
        $\t ->
            CharsToTab = 4 - (Col rem 4),
            case Columns of
                true ->
                    Partial = CharsToTab > Count,
                    Adv = case Partial of true -> Count; false -> CharsToTab end,
                    Bp1 = Bp#bp{partial_tab = Partial, column = Col + Adv,
                                offset = case Partial of true -> Off; false -> Off + 1 end},
                    advance_offset(Bp1, Count - Adv, Columns);
                false ->
                    Bp1 = Bp#bp{partial_tab = false, column = Col + CharsToTab, offset = Off + 1},
                    advance_offset(Bp1, Count - 1, Columns)
            end;
        _ ->
            Bp1 = Bp#bp{partial_tab = false, column = Col + 1, offset = Off + 1},
            advance_offset(Bp1, Count - 1, Columns)
    end.

-spec advance_next_nonspace(#bp{}) -> #bp{}.
advance_next_nonspace(#bp{next_nonspace = I, next_nonspace_col = C} = Bp) ->
    Bp#bp{offset = I, column = C, partial_tab = false}.

%% @doc The byte at Offset in the current line, or NUL past its end.
-spec peek(#bp{}, non_neg_integer()) -> char().
peek(#bp{line = Line}, Off) -> beamai_markdown_char:at(Line, Off).

%% @doc The line from the next non-space character.
-spec rest(#bp{}) -> binary().
rest(#bp{line = Line, next_nonspace = I}) ->
    binary:part(Line, I, byte_size(Line) - I).

-spec rest_from_offset(#bp{}) -> binary().
rest_from_offset(#bp{line = Line, offset = I}) ->
    binary:part(Line, I, byte_size(Line) - I).

%%%===================================================================
%%% The block stack
%%%===================================================================

-spec tip(#bp{}) -> beamai_markdown_block().
tip(#bp{stack = [Tip | _]}) -> Tip.

%% @doc The innermost open block the current line matched. The tip when
%% nothing is unmatched.
-spec container(#bp{}) -> beamai_markdown_block().
container(#bp{stack = Stack, unmatched = U}) -> lists:nth(U + 1, Stack).

%% @doc The block a new child of Kind would actually be opened in: the
%% innermost matched block, or the nearest ancestor of it that can contain
%% Kind. (A line after a list's last item has the list as its matched
%% container, but a paragraph there belongs to whatever holds the list.)
-spec container_for(#bp{}, atom()) -> beamai_markdown_block().
container_for(#bp{stack = Stack, unmatched = U} = Bp, Kind) ->
    Candidates = lists:nthtail(U, Stack),
    first_container(Candidates, Kind, Bp).

first_container([B], _, _) -> B;
first_container([B | Rest], Kind, Bp) ->
    Mod = kind_mod(maps:get(k, B), Bp),
    case Mod:can_contain(B, Kind) of
        true -> B;
        false -> first_container(Rest, Kind, Bp)
    end.

-spec update_tip(#bp{}, fun((beamai_markdown_block()) -> beamai_markdown_block())) -> #bp{}.
update_tip(#bp{stack = [Tip | Rest]} = Bp, Fun) ->
    Bp#bp{stack = [Fun(Tip) | Rest]}.

-spec replace_tip(#bp{}, beamai_markdown_block()) -> #bp{}.
replace_tip(#bp{stack = [_ | Rest]} = Bp, Block) ->
    Bp#bp{stack = [Block | Rest]}.

%% @doc The tip's most recently closed child, if any.
-spec last_child(beamai_markdown_block()) -> beamai_markdown_block() | undefined.
last_child(#{children := [Last | _]}) -> Last;
last_child(_) -> undefined.

-spec set_last_child(beamai_markdown_block(), beamai_markdown_block()) -> beamai_markdown_block().
set_last_child(#{children := [_ | Rest]} = B, New) -> B#{children => [New | Rest]}.

%% @doc Is the line, so far, a lazy continuation of an open paragraph?
-spec is_lazy_paragraph(#bp{}) -> boolean().
is_lazy_paragraph(#bp{unmatched = U, stack = [Tip | _]}) ->
    U > 0 andalso maps:get(k, Tip) =:= paragraph.

%% @doc A fresh block of Kind starting at Offset on the current line.
-spec new_block(atom(), #bp{}, non_neg_integer()) -> beamai_markdown_block().
new_block(Kind, #bp{line_no = N, column = Col, offset = Off}, Offset) ->
    %% The column is the virtual column when Offset is the current offset
    %% (tabs expanded); otherwise the byte offset plus one.
    C = case Offset =:= Off of
            true -> Col + 1;
            false -> Offset + 1
        end,
    #{k => Kind, line => N, col => C, children => [], lines => [],
      last_line_blank => false}.

%% @doc Open Block as the new tip. Closes the unmatched blocks first, then
%% any tip that cannot contain this kind.
-spec add_child(#bp{}, beamai_markdown_block()) -> #bp{}.
add_child(Bp0, Block) ->
    Bp1 = close_unmatched(Bp0),
    Bp2 = close_until_container(Bp1, maps:get(k, Block)),
    Bp2#bp{stack = [Block | Bp2#bp.stack]}.

close_until_container(#bp{stack = [Tip | _]} = Bp, Kind) ->
    Mod = kind_mod(maps:get(k, Tip), Bp),
    case Mod:can_contain(Tip, Kind) of
        true -> Bp;
        false -> close_until_container(finalize_tip(Bp, Bp#bp.line_no - 1), Kind)
    end.

%% @doc Finalize every block the current line failed to continue.
-spec close_unmatched(#bp{}) -> #bp{}.
close_unmatched(#bp{unmatched = 0} = Bp) -> Bp;
close_unmatched(#bp{unmatched = U} = Bp) ->
    close_unmatched((finalize_tip(Bp, Bp#bp.line_no - 1))#bp{unmatched = U - 1}).

%% @doc Close the tip: its children are put in order, its kind's finalize
%% runs, and whatever that returns is appended to the parent.
-spec finalize_tip(#bp{}, non_neg_integer()) -> #bp{}.
finalize_tip(#bp{stack = [Tip0 | Rest]} = Bp0, LineNo) ->
    Tip1 = Tip0#{children => lists:reverse(maps:get(children, Tip0, [])),
                 lines => lists:reverse(maps:get(lines, Tip0, [])),
                 end_line => LineNo, end_col => Bp0#bp.last_line_len},
    Bp1 = Bp0#bp{stack = Rest},
    Mod = kind_mod(maps:get(k, Tip1), Bp1),
    {Blocks, Bp2} = Mod:finalize(Tip1, Bp1),
    case Bp2#bp.stack of
        [Parent | Rest2] ->
            Children = lists:reverse(Blocks, maps:get(children, Parent, [])),
            Bp2#bp{stack = [Parent#{children => Children} | Rest2]};
        [] ->
            %% The document itself: keep it as the whole stack.
            Bp2#bp{stack = Blocks}
    end.

%% @doc Add the rest of the current line to the tip's lines. A partially
%% consumed tab is replaced by the spaces that remain of it.
-spec add_line(#bp{}) -> #bp{}.
add_line(#bp{line = Line, offset = Off, column = Col, partial_tab = Partial} = Bp) ->
    Text = case Partial of
               true ->
                   Spaces = binary:copy(<<" ">>, 4 - (Col rem 4)),
                   <<Spaces/binary, (binary:part(Line, Off + 1, byte_size(Line) - Off - 1))/binary>>;
               false ->
                   binary:part(Line, Off, byte_size(Line) - Off)
           end,
    add_line(Bp, Text).

%% @doc Add an explicit line to the tip.
-spec add_line(#bp{}, binary()) -> #bp{}.
add_line(#bp{stack = [Tip | Rest], line_no = N, eol = Eol} = Bp, Text) ->
    Lines = maps:get(lines, Tip, []),
    Bp#bp{stack = [Tip#{lines => [{Text, N, Eol} | Lines]} | Rest]}.

%%%===================================================================
%%% Kinds, references, options
%%%===================================================================

%% @doc The module implementing a block kind's callbacks.
-spec kind_mod(atom(), #bp{}) -> module().
kind_mod(Kind, #bp{pipe = Pipe}) ->
    case Pipe of
        #{block_kinds := #{Kind := Mod}} -> Mod;
        _ -> beamai_markdown_blocks
    end.

-spec refs(#bp{}) -> map().
refs(#bp{refs = R}) -> R.

%% @doc Record a link reference definition. The first definition of a label
%% wins.
-spec add_ref(#bp{}, binary(), map()) -> #bp{}.
add_ref(#bp{refs = R} = Bp, Label, Def) ->
    case maps:is_key(Label, R) of
        true -> Bp;
        false -> Bp#bp{refs = R#{Label => Def}}
    end.

-spec pipe(#bp{}) -> map().
pipe(#bp{pipe = P}) -> P.

-spec opts(#bp{}) -> map().
opts(#bp{opts = O}) -> O.

-spec line_no(#bp{}) -> non_neg_integer().
line_no(#bp{line_no = N}) -> N.
