%%%-------------------------------------------------------------------
%%% @doc Support for the markdown conformance suites.
%%%
%%% The spec files under test/markdown_spec are markdig's own (CommonMark
%%% 0.31.2 plus one per extension), in the CommonMark spec format:
%%%
%%%     ```````````````````````````````` example
%%%     <markdown>
%%%     .
%%%     <expected html>
%%%     ````````````````````````````````
%%%
%%% with U+2192 standing in for a tab. Comparison uses markdig's own test
%%% normalisation (TestParser.Compact): both sides trimmed, whitespace
%%% around <li> collapsed, U+2122 folded to TM. markdig does not match the
%%% spec's HTML byte for byte either; this is the equivalence it claims.
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_test_lib).

-export([spec_dir/0, load/1, examples/1, compact/1, run/2, run/3, report/2,
         report/3]).

-spec spec_dir() -> file:filename().
spec_dir() ->
    Dir = filename:join(filename:dirname(code:which(?MODULE)), "markdown_spec"),
    case filelib:is_dir(Dir) of
        true -> Dir;
        false -> filename:join([code:lib_dir(beamai_render), "test", "markdown_spec"])
    end.

%% @doc Every example of a spec file: #{number, section, markdown, html, line}.
-spec load(string()) -> [map()].
load(Name) ->
    {ok, Bin} = file:read_file(filename:join(spec_dir(), Name)),
    Lines = [string:trim(L, trailing, "\r") || L <- binary:split(Bin, <<"\n">>, [global])],
    examples(Lines).

-spec examples([binary()]) -> [map()].
examples(Lines) ->
    examples(Lines, 1, [], 1, []).

examples([], _, _, _, Acc) -> lists:reverse(Acc);
examples([L | Rest], LineNo, Headings, N, Acc) ->
    case is_open_fence(L) of
        true ->
            {Md, Html, Rest1, Used} = body(Rest, [], [], markdown, 0),
            Ex = #{number => N, section => section(Headings),
                   markdown => untab(join(Md)), html => untab(join(Html)),
                   line => LineNo},
            examples(Rest1, LineNo + Used + 1, Headings, N + 1, [Ex | Acc]);
        false ->
            examples(Rest, LineNo + 1, heading(L, Headings), N, Acc)
    end.

-define(FENCE, <<"````````````````````````````````">>).

is_open_fence(<<F:32/binary, R/binary>>) when F =:= ?FENCE ->
    binary:match(R, <<"example">>) =/= nomatch;
is_open_fence(_) -> false.

is_close_fence(<<F:32/binary, R/binary>>) when F =:= ?FENCE ->
    lists:all(fun(C) -> C =:= $` end, binary_to_list(R));
is_close_fence(_) -> false.

body([], Md, Html, _, Used) -> {lists:reverse(Md), lists:reverse(Html), [], Used};
body([L | Rest], Md, Html, Target, Used) ->
    case is_close_fence(L) of
        true -> {lists:reverse(Md), lists:reverse(Html), Rest, Used + 1};
        false when Target =:= markdown, L =:= <<".">> -> body(Rest, Md, Html, html, Used + 1);
        false when Target =:= markdown -> body(Rest, [L | Md], Html, Target, Used + 1);
        false -> body(Rest, Md, [L | Html], Target, Used + 1)
    end.

join(Lines) -> iolist_to_binary([[L, "\n"] || L <- Lines]).

untab(Bin) -> binary:replace(Bin, <<16#2192/utf8>>, <<"\t">>, [global]).

heading(<<"#", _/binary>> = L, Stack) ->
    N = count_hashes(L, 0),
    case N =< 6 andalso (byte_size(L) =:= N orelse binary:at(L, N) =:= $\s) of
        true ->
            Title = string:trim(binary:part(L, N, byte_size(L) - N)),
            [{N, Title} | [H || {Lv, _} = H <- Stack, Lv < N]];
        false -> Stack
    end;
heading(_, Stack) -> Stack.

count_hashes(<<"#", R/binary>>, N) -> count_hashes(R, N + 1);
count_hashes(_, N) -> N.

section(Stack) ->
    iolist_to_binary(lists:join(<<" / ">>, [T || {_, T} <- lists:reverse(Stack)])).

%% @doc markdig's Compact normalisation.
-spec compact(binary()) -> binary().
compact(Html0) ->
    Html = binary:replace(string:trim(Html0, both, "\s\t\n\r"), <<16#2122/utf8>>, <<"TM">>, [global]),
    iolist_to_binary(compact(Html, 0, byte_size(Html), [])).

compact(_, I, L, Acc) when I >= L -> lists:reverse(Acc);
compact(S, I, L, Acc) ->
    WsEnd = ws_end(S, I, L),
    case {WsEnd > I andalso match_at(S, WsEnd, <<"</li>">>), match_at(S, I, <<"<li>">>)} of
        {true, _} -> compact(S, WsEnd + 5, L, [<<"</li>">> | Acc]);
        {_, true} -> compact(S, ws_end(S, I + 4, L), L, [<<"<li>">> | Acc]);
        _ -> compact(S, I + 1, L, [binary:at(S, I) | Acc])
    end.

ws_end(S, I, L) when I < L ->
    case binary:at(S, I) of
        C when C =:= $\s; C =:= $\t; C =:= $\n; C =:= $\r -> ws_end(S, I + 1, L);
        _ -> I
    end;
ws_end(_, I, _) -> I.

match_at(S, I, P) ->
    N = byte_size(P),
    I + N =< byte_size(S) andalso binary:part(S, I, N) =:= P.

%% @doc Run one example through a pipeline: {Passed, Actual}.
-spec run(map(), term()) -> {boolean(), binary()}.
run(Ex, Pipe) -> run(Ex, Pipe, #{}).

-spec run(map(), term(), map()) -> {boolean(), binary()}.
run(#{markdown := Md, html := Expected}, Pipe, #{renderer := normalize}) ->
    %% The normalize specs hold Markdown, compared trimmed.
    try beamai_markdown:normalize(Md, Pipe) of
        Actual -> {string:trim(Actual, both, "\n ") =:= string:trim(Expected, both, "\n "), Actual}
    catch
        C:E:St -> {false, iolist_to_binary(io_lib:format("<error> ~p:~p~n~p", [C, E, St]))}
    end;
run(#{markdown := Md}, Pipe, #{renderer := roundtrip}) ->
    %% The roundtrip spec expects the input back, byte for byte.
    try beamai_markdown:to_roundtrip(Md, Pipe) of
        Actual -> {Actual =:= Md, Actual}
    catch
        C:E:St -> {false, iolist_to_binary(io_lib:format("<error> ~p:~p~n~p", [C, E, St]))}
    end;
run(#{markdown := Md, html := Expected}, Pipe, Opts) ->
    try beamai_markdown:to_html(Md, Pipe, Opts) of
        Actual -> {compact(Actual) =:= compact(Expected), Actual}
    catch
        C:E:St -> {false, iolist_to_binary(io_lib:format("<error> ~p:~p~n~p", [C, E, St]))}
    end.

%% @doc Print a per-section pass table for a spec file. Returns {Passed, Total}.
-spec report(string(), term()) -> {non_neg_integer(), non_neg_integer()}.
report(Name, Pipe) -> report(Name, Pipe, #{}).

-spec report(string(), term(), map()) -> {non_neg_integer(), non_neg_integer()}.
report(Name, Pipe, Opts) ->
    Verbose = maps:get(verbose, Opts, false),
    Only = maps:get(only, Opts, undefined),
    Exs = [E || E <- load(Name), Only =:= undefined orelse lists:member(maps:get(number, E), Only)],
    Results = [{E, run(E, Pipe, maps:get(render_opts, Opts, #{}))} || E <- Exs],
    Sections = lists:foldl(
                 fun({#{section := S}, {Ok, _}}, Acc) ->
                         {P, T} = maps:get(S, Acc, {0, 0}),
                         Acc#{S => {P + bool(Ok), T + 1}}
                 end, #{}, Results),
    Order = lists:usort(fun(A, B) -> A =< B end, [S || {#{section := S}, _} <- Results]),
    _ = Order,
    Seen = lists:foldl(fun({#{section := S}, _}, Acc) ->
                               case lists:member(S, Acc) of true -> Acc; false -> Acc ++ [S] end
                       end, [], Results),
    [begin {P, T} = maps:get(S, Sections),
           io:format("~-52ts ~4b/~-4b~n", [S, P, T])
     end || S <- Seen],
    Passed = lists:sum([bool(Ok) || {_, {Ok, _}} <- Results]),
    io:format("~-52s ~4b/~-4b~n", ["TOTAL", Passed, length(Results)]),
    case Verbose of
        true ->
            [io:format("~n=== Example ~p (~ts) line ~p~n--- markdown ---~n~ts--- expected ---~n~ts--- actual ---~n~ts~n",
                       [N, S, L, Md, H, A])
             || {#{number := N, section := S, line := L, markdown := Md, html := H}, {false, A}} <- Results],
            ok;
        false -> ok
    end,
    {Passed, length(Results)}.

bool(true) -> 1;
bool(false) -> 0.
