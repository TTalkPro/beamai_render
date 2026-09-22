%%%-------------------------------------------------------------------
%%% @doc Punycode (RFC 3492) for internationalised domain names.
%%%
%%% markdig runs every URL with a non-ASCII host through .NET's IdnMapping
%%% before percent-encoding the rest, so `http://☃.net' renders as
%%% `http://xn--n3h.net'. OTP has no IDN support, hence this.
%%%
%%% Only the encode direction exists; nothing here ever needs to decode.
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_punycode).

-export([encode/1, encode_domain/1]).

-define(BASE, 36).
-define(TMIN, 1).
-define(TMAX, 26).
-define(SKEW, 38).
-define(DAMP, 700).
-define(INITIAL_BIAS, 72).
-define(INITIAL_N, 128).

%% @doc Punycode one label (a list of code points) to ASCII, without the
%% `xn--' prefix.
-spec encode([char()]) -> binary().
encode(Input) ->
    Basic = [C || C <- Input, C < 128],
    B = length(Basic),
    Out0 = case B of
               0 -> [];
               _ -> Basic ++ [$-]
           end,
    Out = encode_loop(Input, ?INITIAL_N, 0, ?INITIAL_BIAS, B, B, Out0),
    list_to_binary(Out).

encode_loop(Input, N, Delta, Bias, H, B, Out) when H < length(Input) ->
    M = lists:min([C || C <- Input, C >= N]),
    Delta1 = Delta + (M - N) * (H + 1),
    {Delta2, Bias1, H1, Out1} = encode_chars(Input, M, Delta1, Bias, H, B, Out),
    encode_loop(Input, M + 1, Delta2 + 1, Bias1, H1, B, Out1);
encode_loop(_, _, _, _, _, _, Out) ->
    Out.

encode_chars([], _M, Delta, Bias, H, _B, Out) ->
    {Delta, Bias, H, Out};
encode_chars([C | Rest], M, Delta, Bias, H, B, Out) when C < M ->
    encode_chars(Rest, M, Delta + 1, Bias, H, B, Out);
encode_chars([C | Rest], M, Delta, Bias, H, B, Out) when C =:= M ->
    Out1 = Out ++ encode_delta(Delta, Bias, ?BASE, []),
    Bias1 = adapt(Delta, H + 1, H =:= B),
    encode_chars(Rest, M, 0, Bias1, H + 1, B, Out1);
encode_chars([_ | Rest], M, Delta, Bias, H, B, Out) ->
    encode_chars(Rest, M, Delta, Bias, H, B, Out).

encode_delta(Q, Bias, K, Acc) ->
    T = if K =< Bias -> ?TMIN;
           K >= Bias + ?TMAX -> ?TMAX;
           true -> K - Bias
        end,
    case Q < T of
        true -> lists:reverse([digit(Q) | Acc]);
        false ->
            D = T + ((Q - T) rem (?BASE - T)),
            encode_delta((Q - T) div (?BASE - T), Bias, K + ?BASE, [digit(D) | Acc])
    end.

digit(D) when D < 26 -> $a + D;
digit(D) -> $0 + D - 26.

adapt(Delta0, NumPoints, FirstTime) ->
    Delta1 = case FirstTime of
                 true -> Delta0 div ?DAMP;
                 false -> Delta0 div 2
             end,
    Delta2 = Delta1 + Delta1 div NumPoints,
    adapt_loop(Delta2, 0).

adapt_loop(Delta, K) when Delta > ((?BASE - ?TMIN) * ?TMAX) div 2 ->
    adapt_loop(Delta div (?BASE - ?TMIN), K + ?BASE);
adapt_loop(Delta, K) ->
    K + ((?BASE - ?TMIN + 1) * Delta) div (Delta + ?SKEW).

%% @doc If Url has a scheme and a non-ASCII host, IDN-encode the host.
%% Anything else, including a host that fails to encode, is returned as is.
-spec encode_domain(binary()) -> binary().
encode_domain(Url) ->
    case binary:split(Url, <<"://">>) of
        [Scheme, Rest] ->
            {Host, Tail} = split_host(Rest),
            case is_ascii(Host) of
                true -> Url;
                false ->
                    try
                        Labels = binary:split(Host, <<".">>, [global]),
                        Enc = [encode_label(L) || L <- Labels],
                        iolist_to_binary([Scheme, "://", lists:join(<<".">>, Enc), Tail])
                    catch _:_ -> Url
                    end
            end;
        _ -> Url
    end.

split_host(Rest) -> split_host(Rest, 0).

split_host(Rest, P) when P >= byte_size(Rest) -> {Rest, <<>>};
split_host(Rest, P) ->
    case binary:at(Rest, P) of
        C when C =:= $/; C =:= $?; C =:= $#; C =:= $: ->
            {binary:part(Rest, 0, P), binary:part(Rest, P, byte_size(Rest) - P)};
        _ -> split_host(Rest, P + 1)
    end.

encode_label(Label) ->
    case is_ascii(Label) of
        true -> Label;
        false ->
            Cps = unicode:characters_to_list(string:lowercase(Label)),
            <<"xn--", (encode(Cps))/binary>>
    end.

is_ascii(<<>>) -> true;
is_ascii(<<C, R/binary>>) when C < 128 -> is_ascii(R);
is_ascii(_) -> false.
