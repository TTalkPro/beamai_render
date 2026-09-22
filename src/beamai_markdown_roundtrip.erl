%%%-------------------------------------------------------------------
%%% @doc The roundtrip renderer: the document back as the exact bytes it
%%% was parsed from.
%%%
%%% Every block records the source lines it came from, and the document
%%% keeps its source and the byte offset of every line. Rendering copies
%%% the source up to the end of each top-level block in turn -- which
%%% carries the blank lines and trivia between blocks along -- and the
%%% tail after the last one. Nothing is reconstructed, so nothing can be
%%% lost: the output is the input, byte for byte, line endings included.
%%%
%%% A block marked `changed => true' (an editor's job) is rendered as
%%% canonical Markdown by beamai_markdown_normalize in place of its source
%%% lines; one with no line range at all (added or rebuilt after parsing)
%%% is rendered the same way where it stands. That is where this differs
%%% from markdig, which threads whitespace trivia through every parser:
%%% here the unchanged parts are copied and only the changed parts are
%%% re-rendered.
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_roundtrip).

-include("beamai_markdown.hrl").

-export([render/3, span/2]).

-spec render(beamai_markdown_block(), map(), map()) -> binary().
render(#{source := Src, line_offsets := Offsets, children := Children} = Doc, Pipe, Opts) ->
    {Out, Cursor} = lists:foldl(
                      fun(Block, {Acc, Cur}) ->
                              Changed = maps:get(changed, Block, false),
                              case span(Block, Offsets) of
                                  {_Start, End} when not Changed, End >= Cur ->
                                      {[binary:part(Src, Cur, End - Cur) | Acc], End};
                                  {Start, End} when Changed, Start >= Cur ->
                                      %% The gap before it is kept; the
                                      %% block itself is re-rendered.
                                      Gap = binary:part(Src, Cur, Start - Cur),
                                      {[rerender(Doc, Block, Pipe, Opts), Gap | Acc], End};
                                  {_, _} ->
                                      %% Overlapping an earlier block: already emitted.
                                      {Acc, Cur};
                                  undefined ->
                                      {[rerender(Doc, Block, Pipe, Opts) | Acc], Cur}
                              end
                      end, {[], 0}, Children),
    Tail = binary:part(Src, Cursor, byte_size(Src) - Cursor),
    iolist_to_binary(lists:reverse([Tail | Out]));
render(Doc, Pipe, Opts) ->
    beamai_markdown_normalize:render(Doc, Pipe, Opts).

rerender(Doc, Block, Pipe, Opts) ->
    ensure_newline(beamai_markdown_normalize:render(Doc#{children => [Block]}, Pipe, Opts)).

ensure_newline(<<>>) -> <<>>;
ensure_newline(Bin) ->
    case binary:last(Bin) of
        $\n -> Bin;
        _ -> <<Bin/binary, "\n">>
    end.

%% @doc The byte range {Start, End} of a block in the source, from its
%% line range; `undefined' when the block has none.
-spec span(beamai_markdown_block(), tuple()) -> {non_neg_integer(), non_neg_integer()} | undefined.
span(#{line := L, end_line := E}, Offsets) when L >= 1, E >= L, E + 1 =< tuple_size(Offsets) ->
    {element(L, Offsets), element(E + 1, Offsets)};
span(_, _) -> undefined.
