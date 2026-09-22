%%%-------------------------------------------------------------------
%%% @doc Footers: lines prefixed with `^^', parsed like a block quote and
%%% rendered as `<footer>'.
%%%
%%% Block kind: footer (a container).
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_ext_footers).

-behaviour(beamai_markdown_block_kind).

-include("beamai_markdown.hrl").

-export([setup/2, start/1, setup_html/1, render_html/2]).
-export([continue/2, finalize/2, can_contain/2, accepts_lines/1, after_line/2,
         blank_line_ignored/1]).

-spec setup(map(), map()) -> map().
setup(Pipe0, _Opts) ->
    Entry = #{name => footer, module => ?MODULE, function => start, chars => [$^]},
    %% Figures (^^^) must be probed before footers (^^).
    Pipe1 = case beamai_markdown_pipeline:find(Pipe0, block_parsers, figure) of
                undefined ->
                    beamai_markdown_pipeline:set(Pipe0, block_parsers,
                                                 [Entry | beamai_markdown_pipeline:get(Pipe0, block_parsers)]);
                _ -> beamai_markdown_pipeline:insert_after(Pipe0, block_parsers, figure, Entry)
            end,
    Pipe2 = beamai_markdown_pipeline:add_block_kind(Pipe1, footer, ?MODULE),
    beamai_markdown_pipeline:add_renderer_setup(
      Pipe2, html, #{name => footer, module => ?MODULE, function => setup_html}).

-spec start(#bp{}) -> {container, #bp{}} | none.
start(#bp{indented = false, next_nonspace = NN} = Bp) ->
    case beamai_markdown_block:peek(Bp, NN) =:= $^ andalso beamai_markdown_block:peek(Bp, NN + 1) =:= $^ of
        false -> none;
        true ->
            F = beamai_markdown_block:new_block(footer, Bp, NN),
            {container, beamai_markdown_block:add_child(skip_marker(Bp), F)}
    end;
start(_) -> none.

skip_marker(Bp) ->
    Bp1 = beamai_markdown_block:advance_offset(beamai_markdown_block:advance_next_nonspace(Bp), 2, false),
    case beamai_markdown_char:is_space_or_tab(beamai_markdown_block:peek(Bp1, Bp1#bp.offset)) of
        true -> beamai_markdown_block:advance_offset(Bp1, 1, true);
        false -> Bp1
    end.

-spec continue(beamai_markdown_block(), #bp{}) ->
          {match, #bp{}} | {match, beamai_markdown_block(), #bp{}} | nomatch
        | {close, beamai_markdown_block(), #bp{}}.
continue(_, #bp{indented = false, next_nonspace = NN} = Bp) ->
    case beamai_markdown_block:peek(Bp, NN) =:= $^ andalso beamai_markdown_block:peek(Bp, NN + 1) =:= $^ of
        true -> {match, skip_marker(Bp)};
        false -> nomatch
    end;
continue(_, _) -> nomatch.

-spec finalize(beamai_markdown_block(), #bp{}) -> {[beamai_markdown_block()], #bp{}}.
finalize(B, Bp) -> {[B], Bp}.

-spec can_contain(beamai_markdown_block(), atom()) -> boolean().
can_contain(_, K) -> K =/= list_item.

-spec accepts_lines(beamai_markdown_block()) -> boolean().
accepts_lines(_) -> false.

-spec after_line(beamai_markdown_block(), #bp{}) -> #bp{}.
after_line(_, Bp) -> Bp.

-spec blank_line_ignored(beamai_markdown_block()) -> boolean().
blank_line_ignored(_) -> false.

-spec setup_html(map()) -> map().
setup_html(R) -> beamai_markdown_renderer:set_renderer(R, footer, {?MODULE, render_html}).

-spec render_html(map(), beamai_markdown_block()) -> map().
render_html(R0, Block) ->
    R = beamai_markdown_renderer:ensure_line(R0),
    R1 = beamai_markdown_renderer:write(
           beamai_markdown_html:write_attributes(beamai_markdown_renderer:write(R, <<"<footer">>), Block), <<">">>),
    Saved = beamai_markdown_renderer:get(R1, implicit_paragraph),
    R2 = beamai_markdown_renderer:write_children(beamai_markdown_renderer:set(R1, implicit_paragraph, true), Block),
    beamai_markdown_renderer:write_line(beamai_markdown_renderer:set(R2, implicit_paragraph, Saved), <<"</footer>">>).
