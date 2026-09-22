%%%-------------------------------------------------------------------
%%% @doc Citations: `""text""' renders as `<cite>text</cite>'. An emphasis
%%% descriptor on `"' (exactly two, not within a word) and a chained tag
%%% function.
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_ext_citations).

-include("beamai_markdown.hrl").

-export([setup/2, setup_html/1, tag/2]).

-spec setup(map(), map()) -> map().
setup(Pipe0, _Opts) ->
    Pipe1 = case maps:is_key($", beamai_markdown_pipeline:get(Pipe0, emphasis)) of
                true -> Pipe0;
                false -> beamai_markdown_pipeline:add_emphasis(
                           Pipe0, #{ch => $", min => 2, max => 2, within_word => false})
            end,
    beamai_markdown_pipeline:add_renderer_setup(
      Pipe1, html, #{name => citations, module => ?MODULE, function => setup_html}).

-spec setup_html(map()) -> map().
setup_html(R) ->
    Prev = beamai_markdown_renderer:get(R, emphasis_tag, {beamai_markdown_html, default_emphasis_tag}),
    beamai_markdown_renderer:set(beamai_markdown_renderer:set(R, emphasis_tag, {?MODULE, tag}),
                                 citations_tag_prev, Prev).

-spec tag(map(), beamai_markdown_inline()) -> binary() | undefined.
tag(_R, #{ch := $", count := 2}) -> <<"cite">>;
tag(R, Node) ->
    {M, F} = beamai_markdown_renderer:get(R, citations_tag_prev),
    M:F(R, Node).
