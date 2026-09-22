%%%-------------------------------------------------------------------
%%% @doc Keep non-ASCII characters in URLs verbatim instead of
%%% percent-encoding them (domains are still punycoded).
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_ext_non_ascii_no_escape).

-export([setup/2, setup_html/1]).

-spec setup(map(), map()) -> map().
setup(Pipe, _Opts) ->
    beamai_markdown_pipeline:add_renderer_setup(
      Pipe, html, #{name => non_ascii_no_escape, module => ?MODULE, function => setup_html}).

-spec setup_html(map()) -> map().
setup_html(R) -> beamai_markdown_renderer:set(R, non_ascii_no_escape, true).
