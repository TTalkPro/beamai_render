%%%-------------------------------------------------------------------
%%% @doc Extra emphasis: ~~strikethrough~~, ~subscript~, ^superscript^,
%%% ++inserted++ and ==marked==.
%%%
%%% No new parser: the emphasis parser takes extra descriptors, and the
%%% HTML renderer's emphasis tag function is chained so these characters
%%% get their tags and `*'/`_' still get theirs.
%%%
%%% Options (all true by default): strikethrough, subscript, superscript,
%%% inserted, marked.
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_ext_emphasis_extras).

-include("beamai_markdown.hrl").

-export([setup/2, setup_html/1, tag/2]).

-spec setup(map(), map()) -> map().
setup(Pipe0, Opts) ->
    On = fun(K) -> maps:get(K, Opts, true) end,
    Pipe1 = case On(strikethrough) orelse On(subscript) of
                true ->
                    Min = case On(subscript) of true -> 1; false -> 2 end,
                    Max = case On(strikethrough) of true -> 2; false -> 1 end,
                    add(Pipe0, $~, Min, Max);
                false -> Pipe0
            end,
    Pipe2 = case On(superscript) of true -> add(Pipe1, $^, 1, 1); false -> Pipe1 end,
    Pipe3 = case On(inserted) of true -> add(Pipe2, $+, 2, 2); false -> Pipe2 end,
    Pipe4 = case On(marked) of true -> add(Pipe3, $=, 2, 2); false -> Pipe3 end,
    beamai_markdown_pipeline:add_renderer_setup(
      Pipe4, html, #{name => emphasis_extras, module => ?MODULE, function => setup_html}).

add(Pipe, Ch, Min, Max) ->
    case maps:is_key(Ch, beamai_markdown_pipeline:get(Pipe, emphasis)) of
        true -> Pipe;
        false -> beamai_markdown_pipeline:add_emphasis(
                   Pipe, #{ch => Ch, min => Min, max => Max, within_word => true})
    end.

-spec setup_html(map()) -> map().
setup_html(R) ->
    Prev = beamai_markdown_renderer:get(R, emphasis_tag, {beamai_markdown_html, default_emphasis_tag}),
    beamai_markdown_renderer:set(beamai_markdown_renderer:set(R, emphasis_tag, {?MODULE, tag}),
                                 emphasis_tag_prev, Prev).

-spec tag(map(), beamai_markdown_inline()) -> binary() | undefined.
tag(R, #{ch := Ch, count := Count} = Node) ->
    case Ch of
        $~ when Count =:= 2 -> <<"del">>;
        $~ -> <<"sub">>;
        $^ -> <<"sup">>;
        $+ -> <<"ins">>;
        $= -> <<"mark">>;
        _ ->
            {M, F} = beamai_markdown_renderer:get(R, emphasis_tag_prev),
            M:F(R, Node)
    end.
