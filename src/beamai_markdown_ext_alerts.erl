%%%-------------------------------------------------------------------
%%% @doc GitHub alert blocks: a block quote whose first paragraph starts
%%% with `[!NOTE]', `[!TIP]', `[!IMPORTANT]', `[!WARNING]' or `[!CAUTION]'.
%%%
%%% Port of markdig's Alerts extension. The marker is recognised by an
%%% inline parser at the very start of a quote's paragraph (the quote must
%%% sit directly in the document unless `allow_nested_alerts'), and the
%%% quote is turned into an `alert' block through an ancestor edit. The
%%% title line is GitHub's icon markup, verbatim from markdig; the renderer
%%% option `alert_render_kind' ({Module, Function}) replaces it.
%%%
%%% Block kind: alert, a quote with `kind' (the marker text as written).
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_ext_alerts).

-include("beamai_markdown.hrl").

-export([setup/2, match/1, setup_html/1, render_html/2, render_kind/2, title_html/1]).

-spec setup(map(), map()) -> map().
setup(Pipe0, Opts) ->
    Pipe1 = beamai_markdown_pipeline:replace(
              Pipe0, inline_parsers, alert,
              #{name => alert, module => ?MODULE, function => match, chars => [$[], opts => Opts}),
    Pipe2 = case beamai_markdown_pipeline:find(Pipe0, inline_parsers, alert) of
                undefined ->
                    Entry = beamai_markdown_pipeline:find(Pipe1, inline_parsers, alert),
                    beamai_markdown_pipeline:insert_before(
                      beamai_markdown_pipeline:remove(Pipe1, inline_parsers, alert),
                      inline_parsers, link, Entry);
                _ -> Pipe1
            end,
    beamai_markdown_pipeline:add_renderer_setup(
      Pipe2, html, #{name => alert, module => ?MODULE, function => setup_html}).

-spec match(#ip{}) -> {ok, #ip{}} | none.
match(#ip{nodes = [], block = #{k := paragraph}, parents = [#{k := quote} | Up], src = Src, pos = 0} = Ip) ->
    Opts = case beamai_markdown_pipeline:find(beamai_markdown_inline:pipe(Ip), inline_parsers, alert) of
               #{opts := O} -> O;
               _ -> #{}
           end,
    TopLevel = case Up of [#{k := document} | _] -> true; _ -> false end,
    InsideAlert = lists:any(fun(#{k := K}) -> K =:= alert end, Up),
    case (not InsideAlert) andalso (TopLevel orelse maps:get(allow_nested_alerts, Opts, false)) of
        false -> none;
        true ->
            case scan_kind(Src) of
                none -> none;
                {ok, Kind, End} ->
                    Ip1 = beamai_markdown_inline:set_pos(Ip, End),
                    {ok, beamai_markdown_inline:edit_parent(Ip1, 1, fun(Q) -> promote(Q, Kind) end)}
            end
    end;
match(_) -> none.

%% `[!KIND]' then only spaces to the end of the line; the line ending is
%% consumed too.
scan_kind(<<"[!", Rest/binary>>) ->
    N = letters(Rest, 0),
    case N > 0 andalso beamai_markdown_char:at(Rest, N) =:= $] of
        false -> none;
        true ->
            Kind = binary:part(Rest, 0, N),
            P = beamai_markdown_scan:skip_spaces(Rest, N + 1),
            case beamai_markdown_char:at(Rest, P) of
                ?NUL when P >= byte_size(Rest) -> {ok, Kind, 2 + P};
                $\n -> {ok, Kind, 2 + P + 1};
                _ -> none
            end
    end;
scan_kind(_) -> none.

letters(Bin, N) ->
    case beamai_markdown_char:is_alpha(beamai_markdown_char:at(Bin, N)) of
        true -> letters(Bin, N + 1);
        false -> N
    end.

promote(Quote, Kind) ->
    Lower = string:lowercase(Kind),
    A1 = beamai_markdown_attrs:add_class(Quote#{k => alert, kind => Kind}, <<"markdown-alert">>),
    beamai_markdown_attrs:add_class(A1, <<"markdown-alert-", Lower/binary>>).

%%%===================================================================
%%% HTML
%%%===================================================================

-spec setup_html(map()) -> map().
setup_html(R) ->
    beamai_markdown_renderer:set_renderer(R, alert, {?MODULE, render_html}).

-spec render_html(map(), beamai_markdown_block()) -> map().
render_html(R0, #{kind := Kind} = Block) ->
    R = beamai_markdown_renderer:ensure_line(R0),
    Enabled = beamai_markdown_renderer:get(R, enable_block),
    R1 = case Enabled of
             true -> beamai_markdown_renderer:write_line(
                       beamai_markdown_html:write_attributes(beamai_markdown_renderer:write(R, <<"<div">>), Block),
                       <<">">>);
             false -> R
         end,
    {M, F} = beamai_markdown_renderer:get(R1, alert_render_kind, {?MODULE, render_kind}),
    R2 = M:F(R1, Kind),
    Saved = beamai_markdown_renderer:get(R2, implicit_paragraph),
    R3 = beamai_markdown_renderer:set(
           beamai_markdown_renderer:write_children(beamai_markdown_renderer:set(R2, implicit_paragraph, false), Block),
           implicit_paragraph, Saved),
    R4 = case Enabled of
             true -> beamai_markdown_renderer:write_line(R3, <<"</div>">>);
             false -> R3
         end,
    beamai_markdown_renderer:ensure_line(R4).

%% @doc GitHub's title paragraph for a kind; nothing for an unknown kind.
-spec render_kind(map(), binary()) -> map().
render_kind(R, Kind) ->
    case title_html(string:uppercase(Kind)) of
        undefined -> R;
        Html -> beamai_markdown_renderer:write_line(R, Html)
    end.

-spec title_html(binary()) -> binary() | undefined.
title_html(<<"NOTE">>) ->
    <<"<p class=\"markdown-alert-title\"><svg viewBox=\"0 0 16 16\" version=\"1.1\" width=\"16\" height=\"16\" aria-hidden=\"true\"><path d=\"M0 8a8 8 0 1 1 16 0A8 8 0 0 1 0 8Zm8-6.5a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13ZM6.5 7.75A.75.75 0 0 1 7.25 7h1a.75.75 0 0 1 .75.75v2.75h.25a.75.75 0 0 1 0 1.5h-2a.75.75 0 0 1 0-1.5h.25v-2h-.25a.75.75 0 0 1-.75-.75ZM8 6a1 1 0 1 1 0-2 1 1 0 0 1 0 2Z\"></path></svg>Note</p>">>;
title_html(<<"TIP">>) ->
    <<"<p class=\"markdown-alert-title\"><svg viewBox=\"0 0 16 16\" version=\"1.1\" width=\"16\" height=\"16\" aria-hidden=\"true\"><path d=\"M8 1.5c-2.363 0-4 1.69-4 3.75 0 .984.424 1.625.984 2.304l.214.253c.223.264.47.556.673.848.284.411.537.896.621 1.49a.75.75 0 0 1-1.484.211c-.04-.282-.163-.547-.37-.847a8.456 8.456 0 0 0-.542-.68c-.084-.1-.173-.205-.268-.32C3.201 7.75 2.5 6.766 2.5 5.25 2.5 2.31 4.863 0 8 0s5.5 2.31 5.5 5.25c0 1.516-.701 2.5-1.328 3.259-.095.115-.184.22-.268.319-.207.245-.383.453-.541.681-.208.3-.33.565-.37.847a.751.751 0 0 1-1.485-.212c.084-.593.337-1.078.621-1.489.203-.292.45-.584.673-.848.075-.088.147-.173.213-.253.561-.679.985-1.32.985-2.304 0-2.06-1.637-3.75-4-3.75ZM5.75 12h4.5a.75.75 0 0 1 0 1.5h-4.5a.75.75 0 0 1 0-1.5ZM6 15.25a.75.75 0 0 1 .75-.75h2.5a.75.75 0 0 1 0 1.5h-2.5a.75.75 0 0 1-.75-.75Z\"></path></svg>Tip</p>">>;
title_html(<<"IMPORTANT">>) ->
    <<"<p class=\"markdown-alert-title\"><svg viewBox=\"0 0 16 16\" version=\"1.1\" width=\"16\" height=\"16\" aria-hidden=\"true\"><path d=\"M0 1.75C0 .784.784 0 1.75 0h12.5C15.216 0 16 .784 16 1.75v9.5A1.75 1.75 0 0 1 14.25 13H8.06l-2.573 2.573A1.458 1.458 0 0 1 3 14.543V13H1.75A1.75 1.75 0 0 1 0 11.25Zm1.75-.25a.25.25 0 0 0-.25.25v9.5c0 .138.112.25.25.25h2a.75.75 0 0 1 .75.75v2.19l2.72-2.72a.749.749 0 0 1 .53-.22h6.5a.25.25 0 0 0 .25-.25v-9.5a.25.25 0 0 0-.25-.25Zm7 2.25v2.5a.75.75 0 0 1-1.5 0v-2.5a.75.75 0 0 1 1.5 0ZM9 9a1 1 0 1 1-2 0 1 1 0 0 1 2 0Z\"></path></svg>Important</p>">>;
title_html(<<"WARNING">>) ->
    <<"<p class=\"markdown-alert-title\"><svg viewBox=\"0 0 16 16\" version=\"1.1\" width=\"16\" height=\"16\" aria-hidden=\"true\"><path d=\"M6.457 1.047c.659-1.234 2.427-1.234 3.086 0l6.082 11.378A1.75 1.75 0 0 1 14.082 15H1.918a1.75 1.75 0 0 1-1.543-2.575Zm1.763.707a.25.25 0 0 0-.44 0L1.698 13.132a.25.25 0 0 0 .22.368h12.164a.25.25 0 0 0 .22-.368Zm.53 3.996v2.5a.75.75 0 0 1-1.5 0v-2.5a.75.75 0 0 1 1.5 0ZM9 11a1 1 0 1 1-2 0 1 1 0 0 1 2 0Z\"></path></svg>Warning</p>">>;
title_html(<<"CAUTION">>) ->
    <<"<p class=\"markdown-alert-title\"><svg viewBox=\"0 0 16 16\" version=\"1.1\" width=\"16\" height=\"16\" aria-hidden=\"true\"><path d=\"M4.47.22A.749.749 0 0 1 5 0h6c.199 0 .389.079.53.22l4.25 4.25c.141.14.22.331.22.53v6a.749.749 0 0 1-.22.53l-4.25 4.25A.749.749 0 0 1 11 16H5a.749.749 0 0 1-.53-.22L.22 11.53A.749.749 0 0 1 0 11V5c0-.199.079-.389.22-.53Zm.84 1.28L1.5 5.31v5.38l3.81 3.81h5.38l3.81-3.81V5.31L10.69 1.5ZM8 4a.75.75 0 0 1 .75.75v3.5a.75.75 0 0 1-1.5 0v-3.5A.75.75 0 0 1 8 4Zm0 8a1 1 0 1 1 0-2 1 1 0 0 1 0 2Z\"></path></svg>Caution</p>">>;
title_html(_) -> undefined.
