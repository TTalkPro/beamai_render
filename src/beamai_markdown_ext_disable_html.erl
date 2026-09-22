%%%-------------------------------------------------------------------
%%% @doc No raw HTML: `<div>' and `<b>' are plain text. Entities such as
%%% `&amp;' are still decoded, and `<http://x>' autolinks still work.
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_ext_disable_html).

-export([setup/2]).

-spec setup(map(), map()) -> map().
setup(Pipe0, _Opts) ->
    Pipe1 = beamai_markdown_pipeline:remove(Pipe0, block_parsers, html_block),
    beamai_markdown_pipeline:set(Pipe1, parse_html_inline, false).
