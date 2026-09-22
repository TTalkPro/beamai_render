%%%-------------------------------------------------------------------
%%% @doc Bootstrap classes: `.table' on tables, `.blockquote' on quotes,
%%% `.figure' / `.figure-caption' on figures, `.img-fluid' on images, and
%%% Bootstrap's alert box on alert blocks (whose GitHub title line then
%%% disappears).
%%%
%%% A document hook that walks the finished tree.
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_ext_bootstrap).

-include("beamai_markdown.hrl").

-export([setup/2, stamp/3, setup_html/1, no_title/2]).

-spec setup(map(), map()) -> map().
setup(Pipe0, _Opts) ->
    Pipe1 = beamai_markdown_pipeline:replace(
              Pipe0, document_hooks, bootstrap,
              #{name => bootstrap, module => ?MODULE, function => stamp}),
    beamai_markdown_pipeline:add_renderer_setup(
      Pipe1, html, #{name => bootstrap, module => ?MODULE, function => setup_html}).

-spec stamp(beamai_markdown_block(), map(), map()) -> beamai_markdown_block().
stamp(Doc, _Pipe, _Opts) -> block(Doc).

block(#{k := K} = B0) ->
    B1 = case K of
             table -> beamai_markdown_attrs:add_class(B0, <<"table">>);
             alert -> alert(B0);
             quote -> beamai_markdown_attrs:add_class(B0, <<"blockquote">>);
             figure -> beamai_markdown_attrs:add_class(B0, <<"figure">>);
             figure_caption -> beamai_markdown_attrs:add_class(B0, <<"figure-caption">>);
             _ -> B0
         end,
    B2 = case B1 of
             #{inlines := Inlines} -> B1#{inlines => [inline(I) || I <- Inlines]};
             _ -> B1
         end,
    case B2 of
        #{children := Ch} when Ch =/= [] -> B2#{children => [block(C) || C <- Ch]};
        _ -> B2
    end.

inline(#{k := link, image := true} = L) ->
    children(beamai_markdown_attrs:add_class(L, <<"img-fluid">>));
inline(N) -> children(N).

children(#{children := Ch} = N) when Ch =/= [] -> N#{children => [inline(C) || C <- Ch]};
children(N) -> N.

alert(#{kind := Kind} = A0) ->
    A1 = beamai_markdown_attrs:add_class(A0, <<"alert">>),
    A2 = beamai_markdown_attrs:add_property(A1, <<"role">>, <<"alert">>),
    A3 = beamai_markdown_attrs:add_class(A2, alert_class(string:uppercase(Kind))),
    %% The last paragraph anywhere inside the alert gets mb-0.
    case last_paragraph_path(A3) of
        none -> A3;
        Path -> update_at(A3, Path, fun(P) -> beamai_markdown_attrs:add_class(P, <<"mb-0">>) end)
    end.

alert_class(<<"NOTE">>) -> <<"alert-primary">>;
alert_class(<<"TIP">>) -> <<"alert-success">>;
alert_class(<<"IMPORTANT">>) -> <<"alert-info">>;
alert_class(<<"WARNING">>) -> <<"alert-warning">>;
alert_class(<<"CAUTION">>) -> <<"alert-danger">>;
alert_class(_) -> <<"alert-dark">>.

%% The child-index path to the last paragraph in document order.
last_paragraph_path(#{children := Ch}) ->
    Paths = lists:append([case C of
                              #{k := paragraph} -> [[I]];
                              _ -> [[I | P] || P <- paragraph_paths(C)]
                          end || {I, C} <- lists:zip(lists:seq(1, length(Ch)), Ch)]),
    case Paths of
        [] -> none;
        _ -> lists:last(Paths)
    end.

paragraph_paths(#{children := Ch}) when Ch =/= [] ->
    lists:append([case C of
                      #{k := paragraph} -> [[I]];
                      _ -> [[I | P] || P <- paragraph_paths(C)]
                  end || {I, C} <- lists:zip(lists:seq(1, length(Ch)), Ch)]);
paragraph_paths(_) -> [].

update_at(B, [I], Fun) ->
    #{children := Ch} = B,
    B#{children => set_nth(I, Ch, Fun(lists:nth(I, Ch)))};
update_at(B, [I | Rest], Fun) ->
    #{children := Ch} = B,
    B#{children => set_nth(I, Ch, update_at(lists:nth(I, Ch), Rest, Fun))}.

set_nth(I, List, V) ->
    {Before, [_ | After]} = lists:split(I - 1, List),
    Before ++ [V | After].

-spec setup_html(map()) -> map().
setup_html(R) -> beamai_markdown_renderer:set(R, alert_render_kind, {?MODULE, no_title}).

-spec no_title(map(), binary()) -> map().
no_title(R, _Kind) -> R.
