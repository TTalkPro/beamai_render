%% A second extension claiming the same name, used by beamai_jinja_ext_tests.
-module(beamai_jinja_ext_tests_ext2).
-behaviour(beamai_jinja_ext).
-export([filters/0, tests/0, money/2]).

filters() -> #{money => {?MODULE, money}}.
tests()   -> #{}.

money(V, _Args) -> beamai_jinja_rt:to_binary(V).
