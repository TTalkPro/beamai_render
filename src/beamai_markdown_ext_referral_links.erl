%%%-------------------------------------------------------------------
%%% @doc Referral links: `rel="nofollow noopener ..."' on every rendered
%%% link and autolink. Option: rels, a list of binaries; a second use merges
%%% with the first, as in markdig.
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_ext_referral_links).

-export([setup/2, setup_html/1]).

-spec setup(map(), map()) -> map().
setup(Pipe0, Opts) ->
    New = [unicode:characters_to_binary(R) || R <- maps:get(rels, Opts, []), R =/= <<>>, R =/= ""],
    Existing = beamai_markdown_pipeline:get(Pipe0, referral_rels, []),
    Rels = lists:foldl(fun(R, Acc) -> case lists:member(R, Acc) of true -> Acc; false -> Acc ++ [R] end end,
                       Existing, New),
    Pipe1 = beamai_markdown_pipeline:set(Pipe0, referral_rels, Rels),
    beamai_markdown_pipeline:add_renderer_setup(
      beamai_markdown_pipeline:update(Pipe1, renderer_setup,
                                      fun(RS) -> RS#{html => [E || #{name := N} = E <- maps:get(html, RS, []), N =/= referral_links]} end),
      html, #{name => referral_links, module => ?MODULE, function => setup_html}).

-spec setup_html(map()) -> map().
setup_html(R) ->
    Rels = beamai_markdown_pipeline:get(beamai_markdown_renderer:get(R, pipe), referral_rels, []),
    Rel = iolist_to_binary(lists:join(<<" ">>, Rels)),
    beamai_markdown_renderer:set(beamai_markdown_renderer:set(R, link_rel, Rel), autolink_rel, Rel).
