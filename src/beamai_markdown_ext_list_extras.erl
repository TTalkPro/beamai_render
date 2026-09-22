%%%-------------------------------------------------------------------
%%% @doc Ordered lists with letters and roman numerals: `a.', `A.', `i.',
%%% `I.' (and `)' delimiters).
%%%
%%% A list marker parser hooked into the core list item start. Roman
%%% numerals are only recognised for a new list or a list that is already
%%% roman, so `i.' after `h.' is the letter i; and the run is not validated
%%% as a numeral, as in markdig.
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_ext_list_extras).

-include("beamai_markdown.hrl").

-export([setup/2, marker/2]).

-spec setup(map(), map()) -> map().
setup(Pipe0, _Opts) ->
    Pipe1 = beamai_markdown_pipeline:add(
              Pipe0, list_marker_parsers, #{name => list_extras, module => ?MODULE, function => marker}),
    %% The letters have to reach the block starts at all.
    beamai_markdown_pipeline:set(
      Pipe1, block_parsers,
      [case P of
           #{name := list_item, chars := Cs} -> P#{chars => Cs ++ lists:seq($a, $z) ++ lists:seq($A, $Z)};
           _ -> P
       end || P <- beamai_markdown_pipeline:get(Pipe1, block_parsers)]).

-spec marker(#bp{}, char()) -> map() | none.
marker(#bp{line = Line, next_nonspace = NN} = Bp, Pending) ->
    C = beamai_markdown_block:peek(Bp, NN),
    case beamai_markdown_char:is_alpha(C) of
        false -> none;
        true ->
            RomanLow = lists:member(C, "ivxlcdm"),
            RomanUp = (not RomanLow) andalso lists:member(C, "IVXLCDM"),
            Roman = (RomanLow orelse RomanUp) andalso
                (Pending =:= ?NUL orelse Pending =:= $i orelse Pending =:= $I),
            {Start, Bullet, Len} =
                case Roman of
                    true ->
                        Set = case RomanLow of true -> "ivxlcdm"; false -> "IVXLCDM" end,
                        N = run(Line, NN, Set, 0),
                        {beamai_markdown_char:roman_to_int(binary:part(Line, NN, N)),
                         case RomanLow of true -> $i; false -> $I end, N};
                    false ->
                        Upper = C >= $A andalso C =< $Z,
                        {(string:to_lower(C) - $a) + 1, case Upper of true -> $A; false -> $a end, 1}
                end,
            case beamai_markdown_block:peek(Bp, NN + Len) of
                D when D =:= $.; D =:= $) ->
                    #{ordered => true, bullet_char => Bullet, start => Start, delimiter => D,
                      len => Len + 1, marker => binary:part(Line, NN, Len + 1)};
                _ -> none
            end
    end.

run(Line, P, Set, N) ->
    case P < byte_size(Line) andalso lists:member(binary:at(Line, P), Set) of
        true -> run(Line, P + 1, Set, N + 1);
        false -> N
    end.
