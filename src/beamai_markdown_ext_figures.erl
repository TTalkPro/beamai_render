%%%-------------------------------------------------------------------
%%% @doc Figures: a `^^^' fenced container rendered as `<figure>', whose
%%% opening and closing fence lines may carry a caption
%%% (`<figcaption>').
%%%
%%% Block kinds: figure (container), figure_caption (leaf with inlines).
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_ext_figures).

-behaviour(beamai_markdown_block_kind).

-include("beamai_markdown.hrl").

-export([setup/2, start/1, setup_html/1, render_figure/2, render_caption/2]).
-export([continue/2, finalize/2, can_contain/2, accepts_lines/1, after_line/2,
         blank_line_ignored/1]).

-spec setup(map(), map()) -> map().
setup(Pipe0, _Opts) ->
    Entry = #{name => figure, module => ?MODULE, function => start, chars => [$^]},
    Pipe1 = case beamai_markdown_pipeline:find(Pipe0, block_parsers, footer) of
                undefined ->
                    beamai_markdown_pipeline:set(Pipe0, block_parsers,
                                                 [Entry | beamai_markdown_pipeline:get(Pipe0, block_parsers)]);
                _ -> beamai_markdown_pipeline:insert_before(Pipe0, block_parsers, footer, Entry)
            end,
    Pipe2 = beamai_markdown_pipeline:add_block_kind(Pipe1, figure, ?MODULE),
    Pipe3 = beamai_markdown_pipeline:add_block_kind(Pipe2, figure_caption, ?MODULE),
    beamai_markdown_pipeline:add_renderer_setup(
      Pipe3, html, #{name => figure, module => ?MODULE, function => setup_html}).

-spec start(#bp{}) -> {done, #bp{}} | none.
start(Bp) ->
    case beamai_markdown_blocks:fence_open(Bp, $^, 3, infinity) of
        none -> none;
        {N, Rest} ->
            F0 = (beamai_markdown_block:new_block(figure, Bp, Bp#bp.next_nonspace))#{
                   fence_char => $^, fence_len => N, fence_indent => Bp#bp.indent, closed => false},
            F = add_caption(F0, Rest, Bp),
            Bp1 = beamai_markdown_block:add_child(Bp, F),
            {done, beamai_markdown_block:advance_offset(Bp1, byte_size(Bp1#bp.line) - Bp1#bp.offset, false)}
    end.

%% Caption text on a fence line becomes a closed figure_caption child.
add_caption(#{children := Ch} = F, Rest, Bp) ->
    case beamai_markdown_scan:trim_start(Rest) of
        <<>> -> F;
        Text ->
            Cap = #{k => figure_caption, line => Bp#bp.line_no, col => 1, children => [],
                    lines => [{Text, Bp#bp.line_no, Bp#bp.eol}], process_inlines => true},
            F#{children => [Cap | Ch]}
    end.

-spec continue(beamai_markdown_block(), #bp{}) ->
          {match, #bp{}} | {match, beamai_markdown_block(), #bp{}} | nomatch
        | {close, beamai_markdown_block(), #bp{}}.
continue(#{k := figure, fence_len := FL} = F, #bp{indented = false, next_nonspace = NN, line = Line} = Bp) ->
    case beamai_markdown_block:peek(Bp, NN) =:= $^ of
        true ->
            N = beamai_markdown_scan:count_char(Line, NN, $^),
            case N >= FL of
                true ->
                    Rest = binary:part(Line, NN + N, byte_size(Line) - NN - N),
                    %% The closing caption must end up after the content,
                    %% so it is added when the figure is finalized.
                    {close, F#{closed => true, closing_caption => {Rest, Bp#bp.line_no, Bp#bp.eol}}, Bp};
                false -> {match, Bp}
            end;
        false -> {match, Bp}
    end;
continue(#{k := figure}, Bp) -> {match, Bp};
continue(_, _) -> nomatch.

-spec finalize(beamai_markdown_block(), #bp{}) -> {[beamai_markdown_block()], #bp{}}.
finalize(#{k := figure, closing_caption := {Rest, N, Eol}, children := Ch} = F, Bp) ->
    F1 = maps:remove(closing_caption, F),
    case beamai_markdown_scan:trim_start(Rest) of
        <<>> -> {[F1], Bp};
        Text ->
            Cap = #{k => figure_caption, line => N, col => 1, children => [],
                    lines => [{Text, N, Eol}], process_inlines => true},
            {[F1#{children => Ch ++ [Cap]}], Bp}
    end;
finalize(B, Bp) -> {[B], Bp}.

-spec can_contain(beamai_markdown_block(), atom()) -> boolean().
can_contain(#{k := figure}, K) -> K =/= list_item;
can_contain(_, _) -> false.

-spec accepts_lines(beamai_markdown_block()) -> boolean().
accepts_lines(_) -> false.

-spec after_line(beamai_markdown_block(), #bp{}) -> #bp{}.
after_line(_, Bp) -> Bp.

-spec blank_line_ignored(beamai_markdown_block()) -> boolean().
blank_line_ignored(_) -> false.

-spec setup_html(map()) -> map().
setup_html(R0) ->
    R1 = beamai_markdown_renderer:set_renderer(R0, figure, {?MODULE, render_figure}),
    beamai_markdown_renderer:set_renderer(R1, figure_caption, {?MODULE, render_caption}).

-spec render_figure(map(), beamai_markdown_block()) -> map().
render_figure(R0, Block) ->
    R = beamai_markdown_renderer:ensure_line(R0),
    R1 = beamai_markdown_renderer:write_line(
           beamai_markdown_html:write_attributes(beamai_markdown_renderer:write(R, <<"<figure">>), Block), <<">">>),
    beamai_markdown_renderer:write_line(beamai_markdown_renderer:write_children(R1, Block), <<"</figure>">>).

-spec render_caption(map(), beamai_markdown_block()) -> map().
render_caption(R0, Block) ->
    R = beamai_markdown_renderer:ensure_line(R0),
    R1 = beamai_markdown_renderer:write(
           beamai_markdown_html:write_attributes(beamai_markdown_renderer:write(R, <<"<figcaption">>), Block), <<">">>),
    beamai_markdown_renderer:write_line(beamai_markdown_renderer:write_leaf_inline(R1, Block), <<"</figcaption>">>).
