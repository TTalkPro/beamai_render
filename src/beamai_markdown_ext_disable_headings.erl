%%%-------------------------------------------------------------------
%%% @doc No headings: `# x' and setext underlines are paragraph text.
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_ext_disable_headings).

-export([setup/2]).

-spec setup(map(), map()) -> map().
setup(Pipe0, _Opts) ->
    Pipe1 = beamai_markdown_pipeline:remove(Pipe0, block_parsers, atx_heading),
    beamai_markdown_pipeline:remove(Pipe1, block_parsers, setext_heading).
