%% A minimal extension, used by beamai_jinja_ext_tests.
-module(beamai_jinja_ext_tests_ext).
-behaviour(beamai_jinja_ext).
-export([filters/0, tests/0, params/0, money/2]).

filters() -> #{money => {?MODULE, money}}.
tests()   -> #{}.
params()  -> #{money => [currency]}.

money(V, Args) ->
    Cur = maps:get(currency, Args, <<"USD">>),
    <<(beamai_jinja_rt:to_binary(V))/binary, " ", Cur/binary>>.
