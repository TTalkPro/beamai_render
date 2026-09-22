%%%-------------------------------------------------------------------
%%% @doc Diagram code blocks: a `mermaid' fence renders as
%%% `<pre class="mermaid">' and a `nomnoml' fence as `<div class="nomnoml">',
%%% with no inner `<code>', for client-side scripts to pick up.
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_ext_diagrams).

-export([setup/2, setup_html/1]).

-spec setup(map(), map()) -> map().
setup(Pipe, _Opts) ->
    beamai_markdown_pipeline:add_renderer_setup(
      Pipe, html, #{name => diagrams, module => ?MODULE, function => setup_html}).

-spec setup_html(map()) -> map().
setup_html(R) ->
    Pre = beamai_markdown_renderer:get(R, blocks_as_pre, []),
    Div = beamai_markdown_renderer:get(R, blocks_as_div, []),
    R1 = beamai_markdown_renderer:set(R, blocks_as_pre, lists:usort(Pre ++ [<<"mermaid">>])),
    beamai_markdown_renderer:set(R1, blocks_as_div, lists:usort(Div ++ [<<"nomnoml">>])).
