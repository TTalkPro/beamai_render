%%%-------------------------------------------------------------------
%%% @doc SmartyPants: `"quotes"' and `'quotes'' become curly, `<<' and `>>'
%%% become angle quotes, `--' and `---' become en and em dashes, `...'
%%% becomes an ellipsis.
%%%
%%% Port of markdig's SmartyPants. Quotes are decided by the emphasis
%%% flanking rule (as `_' is) and then paired, stack-wise, per family;
%%% anything unbalanced goes back to the character it was. Dashes are
%%% split out of text only after every other post-processor has run, so
%%% that a pipe-table separator row is not eaten.
%%%
%%% Inline kind: pant (type, ch). The `mapping' option overrides the
%%% replacement text per type (quote, double_quote, left_quote,
%%% right_quote, left_double_quote, right_double_quote, left_angle_quote,
%%% right_angle_quote, ellipsis, dash2, dash3).
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_ext_smarty_pants).

-include("beamai_markdown.hrl").

-export([setup/2, match/1, post/2, setup_html/1, render_html/2, default_mapping/0]).

-spec setup(map(), map()) -> map().
setup(Pipe0, Opts) ->
    Pipe1 = beamai_markdown_pipeline:insert_after(
              beamai_markdown_pipeline:remove(Pipe0, inline_parsers, smarty_pants),
              inline_parsers, code,
              #{name => smarty_pants, module => ?MODULE, function => match,
                chars => [$', $", $<, $>, $., $-], opts => Opts}),
    Pipe2 = beamai_markdown_pipeline:insert_after(
              beamai_markdown_pipeline:remove(Pipe1, post_inline, smarty_pants),
              post_inline, emphasis,
              #{name => smarty_pants, module => ?MODULE, function => post}),
    beamai_markdown_pipeline:add_renderer_setup(
      Pipe2, html, #{name => smarty_pants, module => ?MODULE, function => setup_html}).

%%%===================================================================
%%% Inline parser
%%%===================================================================

-spec match(#ip{}) -> {ok, #ip{}} | none.
match(#ip{src = Src, pos = P} = Ip) ->
    Prev = beamai_markdown_char:prev(Src, P),
    C = binary:at(Src, P),
    Next = beamai_markdown_char:at(Src, P + 1),
    case opening(C, Next, beamai_markdown_char:at(Src, P + 2)) of
        %% A dash run is only split out in post/2, after the other
        %% post-processors.
        dash -> none;
        none -> none;
        {Type, Len} ->
            After = beamai_markdown_char:at(Src, P + Len),
            {CanOpen, CanClose} = beamai_markdown_char:flanking(Prev, After, false),
            case resolve(Type, CanOpen, CanClose) of
                none -> none;
                Resolved ->
                    Node = #{k => pant, type => Resolved, ch => C},
                    {ok, beamai_markdown_inline:push(beamai_markdown_inline:advance(Ip, Len), Node)}
            end
    end.

opening($', $', _) -> {double_quote, 2};
opening($', _, _) -> {quote, 1};
opening($", _, _) -> {double_quote, 1};
opening($<, $<, _) -> {left_angle_quote, 2};
opening($>, $>, _) -> {right_angle_quote, 2};
opening($., $., $.) -> {ellipsis, 3};
opening($-, $-, _) -> dash;
opening(_, _, _) -> none.

resolve(quote, true, false) -> left_quote;
resolve(quote, false, true) -> right_quote;
resolve(double_quote, true, false) -> left_double_quote;
resolve(double_quote, false, true) -> right_double_quote;
resolve(left_angle_quote, true, false) -> left_angle_quote;
resolve(right_angle_quote, false, true) -> right_angle_quote;
resolve(ellipsis, false, true) -> ellipsis;
resolve(_, _, _) -> none.

%%%===================================================================
%%% Post-processing: pair the quotes, split the dashes
%%%===================================================================

-spec post([beamai_markdown_inline()], #ip{}) -> {[beamai_markdown_inline()], #ip{}}.
post(Nodes0, Ip) ->
    Nodes1 = pair(Nodes0),
    Nodes2 = case has_dash(Nodes1) of
                 true -> lists:append([split_dashes(N) || N <- Nodes1]);
                 false -> Nodes1
             end,
    {Nodes2, Ip}.

has_dash(Nodes) ->
    lists:any(fun(#{k := text, v := V}) -> binary:match(V, <<"--">>) =/= nomatch;
                 (#{children := Ch}) -> has_dash(Ch);
                 (_) -> false
              end, Nodes).

%% Stack-pair left and right quotes of the same family, in document order
%% across the whole tree; the unbalanced ones are demoted to text.
pair(Nodes) ->
    Pants = collect(Nodes, []),
    Demoted = decide(lists:reverse(Pants)),
    {Nodes1, _} = rewrite(Nodes, Demoted, 1),
    Nodes1.

collect([], Acc) -> Acc;
collect([#{k := pant, type := T} | Rest], Acc) -> collect(Rest, [T | Acc]);
collect([#{children := Ch} | Rest], Acc) -> collect(Rest, collect(Ch, Acc));
collect([_ | Rest], Acc) -> collect(Rest, Acc).

family(left_quote) -> {0, true};
family(right_quote) -> {0, false};
family(left_double_quote) -> {1, true};
family(right_double_quote) -> {1, false};
family(left_angle_quote) -> {2, true};
family(right_angle_quote) -> {2, false};
family(_) -> none.

%% The set of pant indexes (1-based, document order) to demote.
decide(Types) ->
    {Demoted, Openers} =
        lists:foldl(
          fun({I, T}, {D, Open}) ->
                  case family(T) of
                      none when T =:= ellipsis; T =:= dash2; T =:= dash3 -> {D, Open};
                      none -> {[I | D], Open};
                      {F, true} -> {D, [{F, I} | Open]};
                      {F, false} ->
                          %% Pop openers until one of this family matches;
                          %% the mismatched ones popped on the way can never
                          %% pair.
                          case close(F, Open, D) of
                              {found, Open1, D1} -> {D1, Open1};
                              {nomatch, D1} -> {[I | D1], []}
                          end
                  end
          end, {[], []}, lists:zip(lists:seq(1, length(Types)), Types)),
    sets:from_list(Demoted ++ [I || {_, I} <- Openers]).

close(_, [], D) -> {nomatch, D};
close(F, [{F, _} | Rest], D) -> {found, Rest, D};
close(F, [{_, I} | Rest], D) -> close(F, Rest, [I | D]).

rewrite([], _, N) -> {[], N};
rewrite([#{k := pant} = P | Rest], Demoted, N) ->
    P1 = case sets:is_element(N, Demoted) of
             true -> #{k => text, v => to_text(P)};
             false -> P
         end,
    {Rest1, N1} = rewrite(Rest, Demoted, N + 1),
    {[P1 | Rest1], N1};
rewrite([#{children := Ch} = C | Rest], Demoted, N) when Ch =/= [] ->
    {Ch1, N1} = rewrite(Ch, Demoted, N),
    {Rest1, N2} = rewrite(Rest, Demoted, N1),
    {[C#{children => Ch1} | Rest1], N2};
rewrite([X | Rest], Demoted, N) ->
    {Rest1, N1} = rewrite(Rest, Demoted, N),
    {[X | Rest1], N1}.

%% The source text a pant stands for (markdig's ToString, quirks included).
to_text(#{type := T, ch := Ch}) ->
    case T of
        quote -> <<"'">>;
        left_quote -> <<"'">>;
        right_quote -> <<"'">>;
        double_quote -> <<"\"">>;
        left_double_quote when Ch =:= $` -> <<"``">>;
        left_double_quote -> <<"\"">>;
        right_double_quote when Ch =:= $' -> <<"''">>;
        right_double_quote -> <<"\"">>;
        dash2 -> <<"--">>;
        dash3 -> <<"--">>;
        left_angle_quote -> <<"<<">>;
        right_angle_quote -> <<">>">>;
        _ -> <<Ch>>
    end.

split_dashes(#{k := text, v := V} = T) ->
    case binary:match(V, <<"--">>) of
        nomatch -> [T];
        {I, _} ->
            Len = case beamai_markdown_char:at(V, I + 2) of $- -> 3; _ -> 2 end,
            Type = case Len of 3 -> dash3; 2 -> dash2 end,
            Before = binary:part(V, 0, I),
            After = binary:part(V, I + Len, byte_size(V) - I - Len),
            [T#{v => Before} || Before =/= <<>>] ++ [#{k => pant, type => Type, ch => $-}]
                ++ split_dashes(T#{v => After})
    end;
split_dashes(#{children := Ch} = N) when Ch =/= [] ->
    [N#{children => lists:append([split_dashes(C) || C <- Ch])}];
split_dashes(N) -> [N].

%%%===================================================================
%%% HTML
%%%===================================================================

-spec default_mapping() -> #{atom() => binary()}.
default_mapping() ->
    #{quote => <<"'">>, double_quote => <<"\"">>,
      left_quote => <<"&lsquo;">>, right_quote => <<"&rsquo;">>,
      left_double_quote => <<"&ldquo;">>, right_double_quote => <<"&rdquo;">>,
      left_angle_quote => <<"&laquo;">>, right_angle_quote => <<"&raquo;">>,
      ellipsis => <<"&hellip;">>, dash2 => <<"&ndash;">>, dash3 => <<"&mdash;">>}.

-spec setup_html(map()) -> map().
setup_html(R) ->
    Opts = case beamai_markdown_pipeline:find(beamai_markdown_renderer:get(R, pipe), inline_parsers, smarty_pants) of
               #{opts := O} -> O;
               _ -> #{}
           end,
    Mapping = maps:merge(default_mapping(), maps:get(mapping, Opts, #{})),
    R1 = beamai_markdown_renderer:set(R, smarty_mapping, Mapping),
    beamai_markdown_renderer:set_renderer(R1, pant, {?MODULE, render_html}).

-spec render_html(map(), beamai_markdown_inline()) -> map().
render_html(R, #{type := T}) ->
    case maps:get(T, beamai_markdown_renderer:get(R, smarty_mapping, default_mapping()), undefined) of
        undefined -> R;
        Text -> beamai_markdown_renderer:write(R, Text)
    end.
