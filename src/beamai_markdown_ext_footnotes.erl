%%%-------------------------------------------------------------------
%%% @doc Footnotes: `[^label]' in the text, `[^label]: content' at the
%%% document level.
%%%
%%% Port of markdig's Footnotes extension. A block start recognises the
%%% definition and opens a `footnote' container whose content is parsed
%%% like a list item's; each definition is also a link reference, so a
%%% plain `[^label]' resolves through the ordinary reference machinery and
%%% a link hook turns the result into a `footnote_link'. After the inline
%%% pass a document hook numbers the footnotes by first use, drops the
%%% unreferenced ones, appends the back-links and moves the whole
%%% `footnote_group' to the end of the document.
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_ext_footnotes).

-behaviour(beamai_markdown_block_kind).

-include("beamai_markdown.hrl").

-export([setup/2, start/1, link_hook/3, finish/3, setup_html/1,
         render_group/2, render_link/2]).
-export([continue/2, finalize/2, can_contain/2, accepts_lines/1, after_line/2,
         blank_line_ignored/1]).

-spec setup(map(), map()) -> map().
setup(Pipe0, _Opts) ->
    Pipe1 = beamai_markdown_pipeline:set(
              Pipe0, block_parsers,
              [#{name => footnote, module => ?MODULE, function => start, chars => [$[]}
               | beamai_markdown_pipeline:get(Pipe0, block_parsers)]),
    Pipe2 = beamai_markdown_pipeline:add_block_kind(Pipe1, footnote, ?MODULE),
    Pipe3 = beamai_markdown_pipeline:add(Pipe2, link_hooks,
                                         #{name => footnote, module => ?MODULE, function => link_hook}),
    Pipe4 = beamai_markdown_pipeline:add(Pipe3, document_hooks,
                                         #{name => footnote, module => ?MODULE, function => finish}),
    beamai_markdown_pipeline:add_renderer_setup(
      Pipe4, html, #{name => footnote, module => ?MODULE, function => setup_html}).

%%%===================================================================
%%% Block parsing
%%%===================================================================

-spec start(#bp{}) -> {container, #bp{}} | none.
start(#bp{indented = false, line = Line, next_nonspace = NN} = Bp) ->
    %% Document level only.
    Cont = beamai_markdown_block:container_for(Bp, footnote),
    case maps:get(k, Cont) of
        document -> try_open(Bp, Line, NN);
        _ -> none
    end;
start(_) -> none.

try_open(Bp, Line, NN) ->
    case beamai_markdown_scan:link_label(Line, NN) of
        {ok, <<$^, _/binary>> = Raw, End} when byte_size(Raw) > 1 ->
            case beamai_markdown_char:at(Line, End) of
                $: ->
                    Label = beamai_markdown_char:fold_label(Raw),
                    F = (beamai_markdown_block:new_block(footnote, Bp, NN))#{
                          label => Label, raw_label => Raw, order => -1, last_line_empty => false},
                    Bp1 = beamai_markdown_block:advance_offset(
                            beamai_markdown_block:advance_next_nonspace(Bp), End + 1 - NN, false),
                    Bp2 = beamai_markdown_block:add_child(Bp1, F),
                    Def = #{label => Label, raw_label => Raw, url => <<>>, title => <<>>,
                            footnote => Label},
                    {container, beamai_markdown_block:add_ref(Bp2, Label, Def)};
                _ -> none
            end;
        _ -> none
    end.

-spec continue(beamai_markdown_block(), #bp{}) ->
          {match, #bp{}} | {match, beamai_markdown_block(), #bp{}} | nomatch
        | {close, beamai_markdown_block(), #bp{}}.
continue(F, #bp{blank = true} = Bp) ->
    {match, F#{last_line_empty => true}, beamai_markdown_block:advance_next_nonspace(Bp)};
continue(#{last_line_empty := LastEmpty} = F, #bp{indent = 0, line = Line, next_nonspace = NN} = Bp) ->
    case LastEmpty of
        true -> nomatch;
        false ->
            %% Another definition right after this one ends it.
            case is_definition(Line, NN) of
                true -> nomatch;
                false -> {match, F#{last_line_empty => false}, Bp}
            end
    end;
continue(F, #bp{indent = Ind} = Bp) when Ind >= 4 ->
    {match, F#{last_line_empty => false}, beamai_markdown_block:advance_offset(Bp, 4, true)};
continue(F, Bp) ->
    {match, F#{last_line_empty => false}, Bp}.

is_definition(Line, NN) ->
    case beamai_markdown_scan:link_label(Line, NN) of
        {ok, <<$^, _/binary>>, End} -> beamai_markdown_char:at(Line, End) =:= $:;
        _ -> false
    end.

-spec finalize(beamai_markdown_block(), #bp{}) -> {[beamai_markdown_block()], #bp{}}.
finalize(F, Bp) -> {[F], Bp}.

-spec can_contain(beamai_markdown_block(), atom()) -> boolean().
can_contain(_, K) -> K =/= list_item.

-spec accepts_lines(beamai_markdown_block()) -> boolean().
accepts_lines(_) -> false.

-spec after_line(beamai_markdown_block(), #bp{}) -> #bp{}.
after_line(_, Bp) -> Bp.

-spec blank_line_ignored(beamai_markdown_block()) -> boolean().
blank_line_ignored(_) -> false.

%%%===================================================================
%%% References and finishing
%%%===================================================================

%% @doc A reference link whose definition is a footnote becomes a footnote
%% link (its content is discarded, as in markdig).
-spec link_hook(beamai_markdown_inline(), beamai_markdown_inline(), #ip{}) -> beamai_markdown_inline().
link_hook(#{def := #{footnote := Label}} = _Link, _Opener, _Ip) ->
    #{k => footnote_link, label => Label, back => false, index => 0, order => 0};
link_hook(Link, _, _) -> Link.

%% @doc After the inline pass: number by first use, prune, back-link, and
%% move the group to the end.
-spec finish(beamai_markdown_block(), map(), map()) -> beamai_markdown_block().
finish(#{children := Children} = Doc, _Pipe, _Opts) ->
    {Notes, Rest} = lists:partition(fun(#{k := K}) -> K =:= footnote end, Children),
    case Notes of
        [] -> Doc;
        _ ->
            %% References are numbered by first use; link indexes run per
            %% footnote, in that order, so footnote 1's references are
            %% fnref:1, fnref:2 and footnote 2's continue from there.
            {Rest1, {Orders, _NextOrder, Counts}} =
                lists:mapfoldl(fun number/2, {#{}, 1, #{}}, Rest),
            Referenced = [N || #{label := L} = N <- Notes, maps:is_key(L, Orders)],
            Sorted = lists:sort(fun(#{label := A}, #{label := B}) ->
                                        maps:get(A, Orders) =< maps:get(B, Orders)
                                end, Referenced),
            {Bases, _} = lists:foldl(fun(#{label := L}, {Acc, Next}) ->
                                             {Acc#{L => Next}, Next + maps:get(L, Counts, 0)}
                                     end, {#{}, 0}, Sorted),
            Rest2 = [index(B, Bases) || B <- Rest1],
            Final = [with_back_links(N#{order => maps:get(L, Orders)},
                                     lists:seq(maps:get(L, Bases) + 1,
                                               maps:get(L, Bases) + maps:get(L, Counts)))
                     || #{label := L} = N <- Sorted],
            Group = #{k => footnote_group, line => 0, col => 1, children => Final},
            case Final of
                [] -> Doc#{children => Rest2};
                _ -> Doc#{children => Rest2 ++ [Group]}
            end
    end.

%% Pass one: order footnotes by first use; count each label's references
%% and note each reference's occurrence number.
number(#{inlines := Inlines} = B, Acc0) ->
    {Inlines1, Acc1} = lists:mapfoldl(fun number_inline/2, Acc0, Inlines),
    number_children(B#{inlines => Inlines1}, Acc1);
number(B, Acc) -> number_children(B, Acc).

number_children(#{children := Ch} = B, Acc0) when Ch =/= [] ->
    {Ch1, Acc1} = lists:mapfoldl(fun number/2, Acc0, Ch),
    {B#{children => Ch1}, Acc1};
number_children(B, Acc) -> {B, Acc}.

number_inline(#{k := footnote_link, label := L, back := false} = N, {Orders, NextOrder, Counts}) ->
    {Order, Orders1, NextOrder1} =
        case maps:find(L, Orders) of
            {ok, O} -> {O, Orders, NextOrder};
            error -> {NextOrder, Orders#{L => NextOrder}, NextOrder + 1}
        end,
    Occ = maps:get(L, Counts, 0) + 1,
    {N#{order => Order, occurrence => Occ}, {Orders1, NextOrder1, Counts#{L => Occ}}};
number_inline(#{children := Ch} = N, Acc0) when Ch =/= [] ->
    {Ch1, Acc1} = lists:mapfoldl(fun number_inline/2, Acc0, Ch),
    {N#{children => Ch1}, Acc1};
number_inline(N, Acc) -> {N, Acc}.

%% Pass two: the index of a reference is its footnote's base plus its
%% occurrence number.
index(#{inlines := Inlines} = B, Bases) ->
    index_children(B#{inlines => [index_inline(I, Bases) || I <- Inlines]}, Bases);
index(B, Bases) -> index_children(B, Bases).

index_children(#{children := Ch} = B, Bases) when Ch =/= [] ->
    B#{children => [index(C, Bases) || C <- Ch]};
index_children(B, _) -> B.

index_inline(#{k := footnote_link, label := L, occurrence := Occ} = N, Bases) ->
    N#{index => maps:get(L, Bases, 0) + Occ};
index_inline(#{children := Ch} = N, Bases) when Ch =/= [] ->
    N#{children => [index_inline(C, Bases) || C <- Ch]};
index_inline(N, _) -> N.

%% One back-link per reference, appended to the footnote's last paragraph
%% (or a new one).
with_back_links(#{children := Children, order := Order} = F, Indexes) ->
    Backs = [#{k => footnote_link, label => maps:get(label, F), back => true, index => I, order => Order}
             || I <- Indexes],
    Children1 = case lists:reverse(Children) of
                    [#{k := paragraph, inlines := Inlines} = P | RevRest] ->
                        lists:reverse([P#{inlines => Inlines ++ Backs} | RevRest]);
                    _ ->
                        Children ++ [#{k => paragraph, line => 0, col => 1, children => [],
                                       lines => [], inlines => Backs}]
                end,
    F#{children => Children1}.

%%%===================================================================
%%% HTML
%%%===================================================================

-spec setup_html(map()) -> map().
setup_html(R0) ->
    R1 = beamai_markdown_renderer:set_renderer(R0, footnote_group, {?MODULE, render_group}),
    beamai_markdown_renderer:set_renderer(R1, footnote_link, {?MODULE, render_link}).

-spec render_group(map(), beamai_markdown_block()) -> map().
render_group(R0, #{children := Notes}) ->
    W = fun beamai_markdown_renderer:write_line/2,
    R1 = W(W(W(beamai_markdown_renderer:ensure_line(R0), <<"<div class=\"footnotes\">">>), <<"<hr />">>), <<"<ol>">>),
    R2 = lists:foldl(
           fun(#{order := O} = F, Acc) ->
                   A1 = W(Acc, [<<"<li id=\"fn:">>, integer_to_binary(O), <<"\">">>]),
                   A2 = beamai_markdown_renderer:write_children(A1, F),
                   W(A2, <<"</li>">>)
           end, R1, Notes),
    W(W(R2, <<"</ol>">>), <<"</div>">>).

-spec render_link(map(), beamai_markdown_inline()) -> map().
render_link(R, #{back := true, index := I}) ->
    beamai_markdown_renderer:write(
      R, [<<"<a href=\"#fnref:">>, integer_to_binary(I),
          <<"\" class=\"footnote-back-ref\">&#8617;</a>">>]);
render_link(R, #{index := I, order := O}) ->
    beamai_markdown_renderer:write(
      R, [<<"<a id=\"fnref:">>, integer_to_binary(I), <<"\" href=\"#fn:">>, integer_to_binary(O),
          <<"\" class=\"footnote-ref\"><sup>">>, integer_to_binary(O), <<"</sup></a>">>]).
