%%%-------------------------------------------------------------------
%%% @doc Mathematics: `$inline$' / `$$inline$$' spans and `$$' fenced
%%% blocks, rendered as `<span class="math">\(...\)</span>' and
%%% `<div class="math">\[...\]</div>'.
%%%
%%% Port of markdig's Mathematics extension, including the inline span's
%%% own flanking heuristic: the opening run must follow whitespace or
%%% punctuation, the closing run must precede it, and the spacing inside
%%% must be symmetric (`$ x $' and `$x$' but not `$ x$').
%%%
%%% Block kind: math_block (a fenced leaf). Inline kind: math (v, count).
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_ext_mathematics).

-behaviour(beamai_markdown_block_kind).

-include("beamai_markdown.hrl").

-export([setup/2, start/1, match/1, setup_html/1, render_block/2, render_inline/2]).
-export([continue/2, finalize/2, can_contain/2, accepts_lines/1, after_line/2,
         blank_line_ignored/1]).

-spec setup(map(), map()) -> map().
setup(Pipe0, _Opts) ->
    Pipe1 = beamai_markdown_pipeline:set(
              Pipe0, block_parsers,
              [#{name => math_block, module => ?MODULE, function => start, chars => [$$]}
               | beamai_markdown_pipeline:get(Pipe0, block_parsers)]),
    Pipe2 = beamai_markdown_pipeline:add_block_kind(Pipe1, math_block, ?MODULE),
    Pipe3 = beamai_markdown_pipeline:set(
              Pipe2, inline_parsers,
              [#{name => math, module => ?MODULE, function => match, chars => [$$]}
               | beamai_markdown_pipeline:get(Pipe2, inline_parsers)]),
    beamai_markdown_pipeline:add_renderer_setup(
      Pipe3, html, #{name => math, module => ?MODULE, function => setup_html}).

%%%===================================================================
%%% Block
%%%===================================================================

-spec start(#bp{}) -> {done, #bp{}} | none.
start(Bp) ->
    case beamai_markdown_blocks:fence_open(Bp, $$, 2, 2) of
        none -> none;
        {N, Info0} ->
            B0 = (beamai_markdown_block:new_block(math_block, Bp, Bp#bp.next_nonspace))#{
                   fence_char => $$, fence_len => N, fence_indent => Bp#bp.indent, closed => false,
                   info => <<>>, arguments => <<>>},
            {Info1, B1} = beamai_markdown_blocks:block_attributes(Bp, Info0, B0),
            %% $$ carries no info: anything but whitespace is not a fence.
            case beamai_markdown_scan:is_blank(Info1) of
                false -> none;
                true ->
                    B = beamai_markdown_attrs:add_class(B1, <<"math">>),
                    Bp1 = beamai_markdown_block:add_child(Bp, B),
                    {done, beamai_markdown_block:advance_offset(Bp1, byte_size(Bp1#bp.line) - Bp1#bp.offset, false)}
            end
    end.

-spec continue(beamai_markdown_block(), #bp{}) ->
          {match, #bp{}} | {close, beamai_markdown_block(), #bp{}}.
continue(B, Bp) -> beamai_markdown_blocks:fenced_continue(B, Bp).

-spec finalize(beamai_markdown_block(), #bp{}) -> {[beamai_markdown_block()], #bp{}}.
finalize(B, Bp) -> {[B], Bp}.

-spec can_contain(beamai_markdown_block(), atom()) -> boolean().
can_contain(_, _) -> false.

-spec accepts_lines(beamai_markdown_block()) -> boolean().
accepts_lines(_) -> true.

-spec after_line(beamai_markdown_block(), #bp{}) -> #bp{}.
after_line(_, Bp) -> Bp.

-spec blank_line_ignored(beamai_markdown_block()) -> boolean().
blank_line_ignored(_) -> true.

%%%===================================================================
%%% Inline
%%%===================================================================

-spec match(#ip{}) -> {ok, #ip{}} | none.
match(#ip{src = Src, pos = P} = Ip) ->
    Prev = beamai_markdown_char:prev(Src, P),
    case Prev =:= $$ of
        true -> none;                           % mid-run
        false ->
            OpenCount = case beamai_markdown_char:at(Src, P + 1) of $$ -> 2; _ -> 1 end,
            {PrevSpace, PrevPunct} = beamai_markdown_char:category(Prev),
            case PrevSpace orelse PrevPunct of
                false -> none;
                true ->
                    P1 = P + OpenCount,
                    C = beamai_markdown_char:at(Src, P1),
                    {OpenNextSpace, _} = beamai_markdown_char:category(C),
                    ContentStart = beamai_markdown_scan:skip_spaces(Src, P1),
                    case scan(Src, ContentStart, OpenCount, $$, ContentStart, 0, -1) of
                        none -> none;
                        {ok, End, CloseStart, LastWs} ->
                            %% End is past the closing run; CloseStart is
                            %% where that run began.
                            PrevOfClose = beamai_markdown_char:prev(Src, CloseStart),
                            {ClosePrevSpace, _} = beamai_markdown_char:category(PrevOfClose),
                            {CloseNextSpace, CloseNextPunct} =
                                beamai_markdown_char:category(beamai_markdown_char:at(Src, End)),
                            case (CloseNextSpace orelse CloseNextPunct)
                                andalso (OpenNextSpace =:= ClosePrevSpace) of
                                false -> none;
                                true ->
                                    %% A longer closing run leaves its extra
                                    %% delimiters in the content.
                                    ContentEnd = case ClosePrevSpace andalso LastWs > 0 of
                                                     true -> LastWs;
                                                     false -> End - OpenCount
                                                 end,
                                    Content = binary:part(Src, ContentStart, max(0, ContentEnd - ContentStart)),
                                    Node = beamai_markdown_attrs:add_class(
                                             #{k => math, v => Content, count => OpenCount}, <<"math">>),
                                    {ok, beamai_markdown_inline:push(Ip#ip{pos = End}, Node)}
                            end
                    end
            end
    end.

%% Scan content to a closing run of at least OpenCount delimiters on the
%% same line. Returns {ok, EndPos, CloseStart, LastWhitespaceStart}.
scan(Src, P, OpenCount, Delim, _Start, _CloseCount, LastWs) ->
    C = beamai_markdown_char:at(Src, P),
    Prev = beamai_markdown_char:prev(Src, P),
    if
        C =:= ?NUL andalso P >= byte_size(Src) -> none;
        C =:= $\n; C =:= $\r -> none;
        Prev =:= $\\ ->
            %% Escaped: cannot close.
            scan(Src, P + 1, OpenCount, Delim, _Start, 0, -1);
        C =:= $\s; C =:= $\t ->
            Ws = case LastWs < 0 of true -> P; false -> LastWs end,
            scan(Src, P + 1, OpenCount, Delim, _Start, 0, Ws);
        C =:= Delim ->
            N = beamai_markdown_scan:count_char(Src, P, Delim),
            case N >= OpenCount of
                true -> {ok, P + N, P, LastWs};
                false -> scan(Src, P + N, OpenCount, Delim, _Start, 0, -1)
            end;
        true ->
            scan(Src, P + beamai_markdown_char:width(C), OpenCount, Delim, _Start, 0, -1)
    end.

%%%===================================================================
%%% HTML
%%%===================================================================

-spec setup_html(map()) -> map().
setup_html(R0) ->
    R1 = beamai_markdown_renderer:set_renderer(R0, math_block, {?MODULE, render_block}),
    beamai_markdown_renderer:set_renderer(R1, math, {?MODULE, render_inline}).

-spec render_block(map(), beamai_markdown_block()) -> map().
render_block(R0, Block) ->
    R = beamai_markdown_renderer:ensure_line(R0),
    Enabled = beamai_markdown_renderer:get(R, enable_block),
    R1 = case Enabled of
             true ->
                 A = beamai_markdown_renderer:write_line(
                       beamai_markdown_html:write_attributes(beamai_markdown_renderer:write(R, <<"<div">>), Block),
                       <<">">>),
                 beamai_markdown_renderer:write_line(A, <<"\\[">>);
             false -> R
         end,
    R2 = beamai_markdown_html:write_leaf_raw_lines(R1, Block, true, beamai_markdown_renderer:get(R, enable_escape)),
    case Enabled of
        true -> beamai_markdown_renderer:write_line(beamai_markdown_renderer:write(R2, <<"\\]">>), <<"</div>">>);
        false -> R2
    end.

-spec render_inline(map(), beamai_markdown_inline()) -> map().
render_inline(R, #{v := V} = Node) ->
    Inline = beamai_markdown_renderer:get(R, enable_inline),
    R1 = case Inline of
             true -> beamai_markdown_renderer:write(
                       beamai_markdown_html:write_attributes(beamai_markdown_renderer:write(R, <<"<span">>), Node),
                       <<">\\(">>);
             false -> R
         end,
    R2 = case beamai_markdown_renderer:get(R, enable_escape) of
             true -> beamai_markdown_html:write_escape(R1, V);
             false -> beamai_markdown_renderer:write(R1, V)
         end,
    case Inline of
        true -> beamai_markdown_renderer:write(R2, <<"\\)</span>">>);
        false -> R2
    end.
