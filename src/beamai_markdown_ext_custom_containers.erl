%%%-------------------------------------------------------------------
%%% @doc Custom containers: `:::name' fenced blocks rendered as `<div>',
%%% and `::text::' inline spans rendered as `<span>'.
%%%
%%% The block is a fenced container: it is opened and closed like a code
%%% fence but its content is parsed as blocks. The info string becomes a
%%% class (no prefix). The inline rides the emphasis machinery with a
%%% `:' descriptor (exactly two) and a creation hook.
%%%
%%% Block kind: custom_container (fence_char, fence_len, fence_indent,
%%% info, arguments). Inline kind: custom_span.
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_ext_custom_containers).

-behaviour(beamai_markdown_block_kind).

-include("beamai_markdown.hrl").

-export([setup/2, start/1, emphasis_hook/3, setup_html/1, render_html/2,
         render_span/2]).
-export([continue/2, finalize/2, can_contain/2, accepts_lines/1, after_line/2,
         blank_line_ignored/1]).

-spec setup(map(), map()) -> map().
setup(Pipe0, _Opts) ->
    Pipe1 = beamai_markdown_pipeline:set(
              Pipe0, block_parsers,
              [#{name => custom_container, module => ?MODULE, function => start, chars => [$:]}
               | beamai_markdown_pipeline:get(Pipe0, block_parsers)]),
    Pipe2 = beamai_markdown_pipeline:add_block_kind(Pipe1, custom_container, ?MODULE),
    Pipe3 = case maps:is_key($:, beamai_markdown_pipeline:get(Pipe2, emphasis)) of
                true -> Pipe2;
                false ->
                    P = beamai_markdown_pipeline:add_emphasis(
                          Pipe2, #{ch => $:, min => 2, max => 2, within_word => true}),
                    beamai_markdown_pipeline:add(
                      P, emphasis_hooks,
                      #{name => custom_container, module => ?MODULE, function => emphasis_hook})
            end,
    beamai_markdown_pipeline:add_renderer_setup(
      Pipe3, html, #{name => custom_container, module => ?MODULE, function => setup_html}).

-spec start(#bp{}) -> {done, #bp{}} | none.
start(Bp) ->
    case beamai_markdown_blocks:fence_open(Bp, $:, 3, infinity) of
        none -> none;
        {N, Info0} ->
            B0 = (beamai_markdown_block:new_block(custom_container, Bp, Bp#bp.next_nonspace))#{
                   fence_char => $:, fence_len => N, fence_indent => Bp#bp.indent, closed => false},
            {Info1, B1} = beamai_markdown_blocks:block_attributes(Bp, Info0, B0),
            Info2 = beamai_markdown_scan:unescape(beamai_markdown_scan:trim(Info1)),
            {Info, Args} = beamai_markdown_blocks:split_info(Info2),
            B2 = B1#{info => Info, arguments => Args, raw_info => Info0},
            B = case Info of
                    <<>> -> B2;
                    _ -> beamai_markdown_attrs:add_class(B2, Info)
                end,
            Bp1 = beamai_markdown_block:add_child(Bp, B),
            {done, beamai_markdown_block:advance_offset(Bp1, byte_size(Bp1#bp.line) - Bp1#bp.offset, false)}
    end.

-spec continue(beamai_markdown_block(), #bp{}) ->
          {match, #bp{}} | {close, beamai_markdown_block(), #bp{}}.
continue(B, Bp) -> beamai_markdown_blocks:fenced_continue(B, Bp).

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

-spec emphasis_hook(char(), pos_integer(), beamai_markdown_inline()) -> beamai_markdown_inline() | none.
emphasis_hook($:, 2, Base) -> Base#{k => custom_span};
emphasis_hook(_, _, _) -> none.

-spec setup_html(map()) -> map().
setup_html(R0) ->
    R1 = beamai_markdown_renderer:set_renderer(R0, custom_container, {?MODULE, render_html}),
    beamai_markdown_renderer:set_renderer(R1, custom_span, {?MODULE, render_span}).

-spec render_html(map(), beamai_markdown_block()) -> map().
render_html(R0, Block) ->
    R = beamai_markdown_renderer:ensure_line(R0),
    Enabled = beamai_markdown_renderer:get(R, enable_block),
    R1 = case Enabled of
             true -> beamai_markdown_renderer:write_raw(
                       beamai_markdown_html:write_attributes(beamai_markdown_renderer:write(R, <<"<div">>), Block),
                       <<">">>);
             false -> R
         end,
    R2 = beamai_markdown_renderer:write_children(R1, Block),
    case Enabled of
        true -> beamai_markdown_renderer:write_line(R2, <<"</div>">>);
        false -> R2
    end.

-spec render_span(map(), beamai_markdown_inline()) -> map().
render_span(R, Node) ->
    R1 = beamai_markdown_renderer:write_raw(
           beamai_markdown_html:write_attributes(beamai_markdown_renderer:write(R, <<"<span">>), Node), <<">">>),
    beamai_markdown_renderer:write(beamai_markdown_renderer:write_children(R1, Node), <<"</span>">>).
