%%%-------------------------------------------------------------------
%%% @doc Emoji: `:smile:' shortcodes and `:)' smileys become their Unicode
%%% characters.
%%%
%%% A longest-prefix trie over markdig's mapping (see
%%% beamai_markdown_emoji_data), matched by an inline parser triggered on
%%% every first character of a key and refused after a letter or digit.
%%%
%%% Options: enable_smileys (true); mapping, a map with `shortcodes'
%%% ([{Shortcode, Unicode}]) and `smileys' ([{Smiley, Shortcode}]) to
%%% replace the default tables.
%%%
%%% Inline kind: emoji (v = the Unicode text, match = the source text).
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_ext_emoji).

-include("beamai_markdown.hrl").

-export([setup/2, match/1, setup_html/1, build_trie/2]).

-spec setup(map(), map()) -> map().
setup(Pipe0, Opts) ->
    {Trie, Chars} = trie(Opts),
    Pipe1 = beamai_markdown_pipeline:insert_before(
              beamai_markdown_pipeline:remove(Pipe0, inline_parsers, emoji),
              inline_parsers, emphasis,
              #{name => emoji, module => ?MODULE, function => match, chars => Chars,
                opts => Opts#{trie => Trie}}),
    beamai_markdown_pipeline:add_renderer_setup(
      Pipe1, html, #{name => emoji, module => ?MODULE, function => setup_html}).

trie(#{mapping := #{shortcodes := S} = M}) ->
    build_trie(S, maps:get(smileys, M, []));
%% Built once per pipeline, and kept in it: the engine holds no global
%% state, so a pipeline is the place to keep what is expensive to make.
trie(Opts) ->
    build_trie(beamai_markdown_emoji_data:shortcodes(),
               case maps:get(enable_smileys, Opts, true) of
                   true -> beamai_markdown_emoji_data:smileys();
                   false -> []
               end).

%% @doc {Trie, FirstChars}. A trie node is {Value | undefined, #{Byte => Node}}.
-spec build_trie([{binary(), binary()}], [{binary(), binary()}]) -> {tuple(), [byte()]}.
build_trie(Shortcodes, Smileys) ->
    Lookup = maps:from_list(Shortcodes),
    Entries = Shortcodes ++ [{Sm, maps:get(Sc, Lookup)} || {Sm, Sc} <- Smileys],
    Trie = lists:foldl(fun({K, V}, T) -> add(T, K, V) end, {undefined, #{}}, Entries),
    Chars = lists:usort([binary:first(K) || {K, _} <- Entries]),
    {Trie, Chars}.

add({V0, Ch}, <<>>, V) -> {case V0 of undefined -> V; _ -> V0 end, Ch};
add({V0, Ch}, <<B, Rest/binary>>, V) ->
    Child = maps:get(B, Ch, {undefined, #{}}),
    {V0, Ch#{B => add(Child, Rest, V)}}.

-spec match(#ip{}) -> {ok, #ip{}} | none.
match(#ip{src = Src, pos = P} = Ip) ->
    Prev = beamai_markdown_char:prev(Src, P),
    case Prev =/= ?NUL andalso (beamai_markdown_char:is_alnum(Prev) orelse (Prev >= 128 andalso beamai_markdown_char:is_letter(Prev))) of
        true -> none;
        false ->
            #{opts := #{trie := Trie}} = beamai_markdown_pipeline:find(Ip#ip.pipe, inline_parsers, emoji),
            case longest(Trie, Src, P, P, none) of
                none -> none;
                {End, Value} ->
                    Node = #{k => emoji, v => Value, match => binary:part(Src, P, End - P)},
                    {ok, beamai_markdown_inline:push(Ip#ip{pos = End}, Node)}
            end
    end.

longest({V, Ch}, Src, Start, P, Best0) ->
    Best = case V of
               undefined -> Best0;
               _ when P > Start -> {P, V};
               _ -> Best0
           end,
    case P < byte_size(Src) andalso maps:find(binary:at(Src, P), Ch) of
        {ok, Child} -> longest(Child, Src, Start, P + 1, Best);
        _ -> Best
    end.

-spec setup_html(map()) -> map().
setup_html(R) -> beamai_markdown_renderer:set_renderer(R, emoji, {beamai_markdown_html, text}).
