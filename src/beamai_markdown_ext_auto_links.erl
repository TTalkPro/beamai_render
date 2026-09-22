%%%-------------------------------------------------------------------
%%% @doc Bare autolinks: http://, https://, ftp://, mailto:, tel: and www.
%%%
%%% Port of markdig's AutoLinks extension: an inline parser ahead of every
%%% other that speculatively scans URL-looking text. Two context rules
%%% survive the port intact: no autolink inside a raw `<a>' tag or inside
%%% an open `[', and emphasis characters still open around the link are
%%% given back to the emphasis.
%%%
%%% Options: valid_previous_characters (<<"*_~(">>), use_https_for_www_links
%%% (false), allow_domain_without_period (false), open_in_new_window (false).
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_ext_auto_links).

-include("beamai_markdown.hrl").

-export([setup/2, match/1, is_valid_domain/3, scan_url/2]).

-spec setup(map(), map()) -> map().
setup(Pipe, Opts) ->
    %% Ahead of every other inline parser; a second use/3 replaces the
    %% options (markdig's ReplaceOrAdd).
    Entry = #{name => auto_link, module => ?MODULE, function => match,
              chars => [$h, $f, $m, $t, $w], opts => Opts},
    Others = [E || #{name := N} = E <- beamai_markdown_pipeline:get(Pipe, inline_parsers),
                   N =/= auto_link],
    beamai_markdown_pipeline:set(Pipe, inline_parsers, [Entry | Others]).

-spec match(#ip{}) -> {ok, #ip{}} | none.
match(#ip{src = Src, pos = P} = Ip) ->
    Opts = opts(Ip),
    Prev = beamai_markdown_char:prev(Src, P),
    ValidPrev = Prev =:= ?NUL orelse beamai_markdown_char:is_whitespace(Prev)
        orelse lists:member(Prev, binary_to_list(maps:get(valid_previous_characters, Opts, <<"*_~(">>))),
    C = binary:at(Src, P),
    Scheme = case C of
                 $h -> starts(Src, P, [<<"https://">>, <<"http://">>]);
                 $w -> starts(Src, P, [<<"www.">>]);
                 $f -> starts(Src, P, [<<"ftp://">>]);
                 $m -> starts(Src, P, [<<"mailto:">>]);
                 $t -> starts(Src, P, [<<"tel:">>]);
                 _ -> false
             end,
    case ValidPrev andalso Scheme of
        false -> none;
        true -> match_core(Ip, C, Opts)
    end;
match(_) -> none.

starts(Src, P, Prefixes) ->
    lists:any(fun(Pre) ->
                      N = byte_size(Pre),
                      case Src of
                          <<_:P/binary, Pre:N/binary, _/binary>> -> true;
                          _ -> false
                      end
              end, Prefixes).

opts(Ip) ->
    case beamai_markdown_pipeline:find(beamai_markdown_inline:pipe(Ip), inline_parsers, auto_link) of
        #{opts := O} -> O;
        _ -> #{}
    end.

match_core(#ip{src = Src, pos = P, nodes = Nodes} = Ip, C, Opts) ->
    case valid_context(Nodes) of
        false -> none;
        {true, Pending} ->
            case scan_url(Src, P) of
                none -> none;
                {ok, Link0, End0} ->
                    {Link, End} = trim_pending(Link0, End0, Pending),
                    case well_formed(Link, C, Opts) of
                        false -> none;
                        true ->
                            Url = case C of
                                      $w -> <<(case maps:get(use_https_for_www_links, Opts, false) of
                                                   true -> <<"https://">>;
                                                   false -> <<"http://">>
                                               end)/binary, Link/binary>>;
                                      _ -> Link
                                  end,
                            Skip = case C of $m -> 7; $t -> 4; _ -> 0 end,
                            Text = binary:part(Link, Skip, byte_size(Link) - Skip),
                            Node0 = #{k => link, url => Url, image => false, auto => true,
                                      children => [#{k => text, v => Text}]},
                            Node = case maps:get(open_in_new_window, Opts, false) of
                                       true -> beamai_markdown_attrs:add_property(Node0, <<"target">>, <<"_blank">>);
                                       false -> Node0
                                   end,
                            {ok, beamai_markdown_inline:push(Ip#ip{pos = End}, Node)}
                    end
            end
    end.

%% No autolink inside a raw <a> or an open bracket. Returns the emphasis
%% characters still open before this position.
valid_context(Nodes) ->
    case inside_raw_anchor(Nodes) of
        true -> false;
        false ->
            Brackets = length([B || #{k := bracket, active := true} = B <- Nodes]),
            case Brackets > 0 of
                true -> false;
                false -> {true, lists:usort([Ch || #{k := delim, ch := Ch} <- Nodes])}
            end
    end.

inside_raw_anchor([]) -> false;
inside_raw_anchor([#{k := html, v := V} | Rest]) ->
    case string:lowercase(binary:part(V, 0, min(3, byte_size(V)))) of
        <<"</a">> -> false;
        _ ->
            case string:lowercase(binary:part(V, 0, min(2, byte_size(V)))) of
                <<"<a">> -> true;
                _ -> inside_raw_anchor(Rest)
            end
    end;
inside_raw_anchor([_ | Rest]) -> inside_raw_anchor(Rest).

%% Trailing characters that belong to an open emphasis are given back.
trim_pending(Link, End, []) -> {Link, End};
trim_pending(Link, End, Pending) ->
    case byte_size(Link) > 0 andalso lists:member(binary:last(Link), Pending) of
        true -> trim_pending(binary:part(Link, 0, byte_size(Link) - 1), End - 1, Pending);
        false -> {Link, End}
    end.

well_formed(Link, C, Opts) ->
    case domain_offset(Link, C) of
        none -> false;
        _ when C =:= $t -> true;
        Off -> is_valid_domain(Link, Off, maps:get(allow_domain_without_period, Opts, false))
    end.

domain_offset(Link, $h) ->
    case Link of
        <<"http://">> -> none;
        <<"https://">> -> none;
        <<"https", _/binary>> -> 8;
        _ -> 7
    end;
domain_offset(_, $w) -> 4;
domain_offset(<<"ftp://">>, $f) -> none;
domain_offset(_, $f) -> 6;
domain_offset(<<"tel">>, $t) -> none;
domain_offset(_, $t) -> 0;
domain_offset(Link, $m) ->
    case binary:match(Link, <<"@">>) of
        {7, _} -> none;
        {I, _} -> I + 1;
        nomatch -> none
    end.

%% @doc GFM extended-autolink domain validation from Offset: alphanumerics,
%% `_' `-' and `.', at least one period, no underscore in the last two
%% segments.
-spec is_valid_domain(binary(), non_neg_integer(), boolean()) -> boolean().
is_valid_domain(Link, Offset, AllowNoPeriod) ->
    domain(Link, Offset, 1, false, -1, AllowNoPeriod).

domain(Link, P, Segs, Has, LastUnderscore, AllowNoPeriod) when P >= byte_size(Link) ->
    domain_done(Segs, Has, LastUnderscore, AllowNoPeriod);
domain(Link, P, Segs, Has, LastUnderscore, AllowNoPeriod) ->
    C = beamai_markdown_char:at(Link, P),
    W = beamai_markdown_char:width(C),
    case beamai_markdown_char:is_alnum(C) of
        true -> domain(Link, P + W, Segs, true, LastUnderscore, AllowNoPeriod);
        false ->
            case C of
                $. when not Has -> false;
                $. -> domain(Link, P + W, Segs + 1, false, LastUnderscore, AllowNoPeriod);
                _ when C =:= $/; C =:= $?; C =:= $#; C =:= $: ->
                    domain_done(Segs, Has, LastUnderscore, AllowNoPeriod);
                $_ -> domain(Link, P + W, Segs, true, Segs, AllowNoPeriod);
                $- -> domain(Link, P + W, Segs, true, LastUnderscore, AllowNoPeriod);
                _ ->
                    case beamai_markdown_char:is_gfm_space_or_punct(C) of
                        true -> false;
                        false -> domain(Link, P + W, Segs, true, LastUnderscore, AllowNoPeriod)
                    end
            end
    end.

domain_done(Segs, Has, LastUnderscore, AllowNoPeriod) ->
    (Segs =/= 1 orelse AllowNoPeriod) andalso Has andalso Segs - LastUnderscore >= 2.

%% @doc Scan a bare autolink URL at P: balanced parentheses, stopping at
%% whitespace, a control character, `<', an entity, or a trailing
%% punctuation character that ends the URL. Returns {ok, Url, EndPos}.
-spec scan_url(binary(), non_neg_integer()) -> {ok, binary(), non_neg_integer()} | none.
scan_url(Src, P) -> scan_url(Src, P, P, 0).

scan_url(Src, Start, P, Depth) ->
    C = beamai_markdown_char:at(Src, P),
    Stop = C =:= ?NUL andalso P >= byte_size(Src),
    case Stop orelse end_of_uri(C) of
        true -> url_done(Src, Start, P, Depth);
        false ->
            case C of
                $( -> scan_url(Src, Start, P + 1, Depth + 1);
                $) when Depth =:= 0 -> url_done(Src, Start, P, Depth);
                $) -> scan_url(Src, Start, P + 1, Depth - 1);
                $& ->
                    case beamai_markdown_scan:entity_syntax(Src, P) of
                        {ok, _} -> url_done(Src, Start, P, Depth);
                        none -> scan_url(Src, Start, P + 1, Depth)
                    end;
                _ ->
                    case trailing_stop(C) andalso end_of_uri(beamai_markdown_char:at(Src, P + 1)) of
                        true -> url_done(Src, Start, P, Depth);
                        false -> scan_url(Src, Start, P + beamai_markdown_char:width(C), Depth)
                    end
            end
    end.

url_done(_, _, _, Depth) when Depth > 0 -> none;
url_done(Src, Start, P, _) -> {ok, binary:part(Src, Start, P - Start), P}.

end_of_uri(?NUL) -> true;
end_of_uri($\s) -> true;
end_of_uri($\t) -> true;
end_of_uri($<) -> true;
end_of_uri(C) -> C < 32 orelse (C >= 127 andalso C =< 159).

trailing_stop(C) -> lists:member(C, "?!.,:*_~").
