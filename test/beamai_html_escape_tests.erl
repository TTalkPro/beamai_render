%%%-------------------------------------------------------------------
%%% Tests for the shared escape/format pair.
%%%
%%% The behaviour itself is already covered from the mustache side; what is
%%% asserted here is that it is the SAME implementation and that the error tag
%%% follows the caller rather than being hard-coded to one engine.
%%%-------------------------------------------------------------------
-module(beamai_html_escape_tests).

-include_lib("eunit/include/eunit.hrl").

escape_set_test() ->
    ?assertEqual(<<"&amp;&lt;&gt;&quot;&#39;">>,
                 iolist_to_binary(beamai_html_escape:escape(<<"&<>\"'">>))),
    %% Not escaped on purpose: escaping these corrupts URLs and prose.
    ?assertEqual(<<"/=`">>, iolist_to_binary(beamai_html_escape:escape(<<"/=`">>))).

escape_returns_the_same_binary_when_clean_test() ->
    Bin = <<"nothing to do here">>,
    ?assert(erts_debug:same(Bin, beamai_html_escape:escape(Bin))).

escape_is_utf8_safe_test() ->
    ?assertEqual(<<"中&amp;文"/utf8>>,
                 iolist_to_binary(beamai_html_escape:escape(<<"中&文"/utf8>>))).

to_binary_numbers_test() ->
    ?assertEqual(<<"85">>,   beamai_html_escape:to_binary(85)),
    ?assertEqual(<<"1.21">>, beamai_html_escape:to_binary(1.21)),
    ?assertEqual(<<"1.1">>,  beamai_html_escape:to_binary(1.1)).

to_binary_empties_test() ->
    ?assertEqual(<<>>, beamai_html_escape:to_binary(undefined)),
    ?assertEqual(<<>>, beamai_html_escape:to_binary(null)).

to_binary_binary_is_zero_copy_test() ->
    Bin = <<"x">>,
    ?assert(erts_debug:same(Bin, beamai_html_escape:to_binary(Bin))).

%% The tag travels with the caller: a jinja template must not raise
%% {beamai_mustache, ...}, and neither may be hard-coded here.
error_tag_follows_the_caller_test() ->
    ?assertError({beamai_html, {not_renderable, _}},
                 beamai_html_escape:to_binary(self())),
    ?assertError({beamai_mustache, {not_renderable, _}},
                 beamai_html_escape:to_binary(self(), beamai_mustache)),
    ?assertError({beamai_jinja, {not_renderable, _}},
                 beamai_html_escape:to_binary(self(), beamai_jinja)).

%% beamai_mustache_rt must keep forwarding under its own tag: generated modules
%% call it by name and the exception shape is part of the contract.
mustache_rt_still_forwards_test() ->
    ?assertEqual(<<"&amp;">>, iolist_to_binary(beamai_mustache_rt:escape(<<"&">>))),
    ?assertEqual(<<"1.21">>, beamai_mustache_rt:to_binary(1.21)),
    ?assertError({beamai_mustache, {not_renderable, _}},
                 beamai_mustache_rt:to_binary(self())).

depends_only_on_otp_test() ->
    {ok, {_, [{imports, Imports}]}} =
        beam_lib:chunks(code:which(beamai_html_escape), [imports]),
    ?assertEqual([], [M || {M, _, _} <- Imports,
                           lists:prefix("beamai_mustache", atom_to_list(M))
                               orelse lists:prefix("beamai_jinja", atom_to_list(M))]).
