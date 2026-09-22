%%%-------------------------------------------------------------------
%%% @doc The low-level scanners the block and inline parsers share.
%%%
%%% Port of markdig's HtmlHelper and LinkHelper: entity references, raw HTML
%%% tags, link destinations, titles and labels, backslash unescaping and the
%%% two HTML output escapes. Everything here is a pure function of a binary
%%% and a byte offset; nothing knows about the AST.
%%%
%%% Scanners return the byte offset just past what they matched, or `none'.
%%% A caller that needs to back out simply keeps its old offset -- there is
%%% nothing to restore.
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_scan).

-include("beamai_markdown.hrl").

-export([entity/2, entity_syntax/2, lower_ascii/1, html_tag/2, html_open_tag/2, html_closing_tag/2,
         html_tag_name/2,
         link_destination/2, link_title/2, link_label/2,
         unescape/1, escape_html/1, escape_html/2, escape_url/1, escape_url/2,
         is_absolute_url/1, resolve_url/2, utf8_percent/1,
         skip_spaces/2, skip_whitespace/2, skip_whitespace_lines/2,
         starts_with_ci/3, find/3, trim_end/1, trim/1, trim_start/1,
         split_lines/1, is_blank/1, count_char/3]).

%%%===================================================================
%%% Entities
%%%===================================================================

%% @doc An entity reference starting at Pos (which must hold `&').
%% Returns {ok, CodePoints, EndPos}.
-spec entity(binary(), non_neg_integer()) ->
          {ok, [char()], non_neg_integer()} | none.
entity(Bin, Pos) ->
    case Bin of
        <<_:Pos/binary, "&#", X, _/binary>> when X =:= $x; X =:= $X ->
            hex_entity(Bin, Pos + 3, 0, 0);
        <<_:Pos/binary, "&#", _/binary>> ->
            dec_entity(Bin, Pos + 2, 0, 0);
        <<_:Pos/binary, "&", _/binary>> ->
            named_entity(Bin, Pos + 1, Pos + 1);
        _ ->
            none
    end.

%% @doc Like entity/2 but only checks the syntax: a named reference need not
%% be a known name. GFM autolinks end before anything of this shape.
-spec entity_syntax(binary(), non_neg_integer()) -> {ok, non_neg_integer()} | none.
entity_syntax(Bin, Pos) ->
    case entity(Bin, Pos) of
        {ok, _, End} -> {ok, End};
        none ->
            case Bin of
                <<_:Pos/binary, "&", _/binary>> -> named_syntax(Bin, Pos + 1, Pos + 1);
                _ -> none
            end
    end.

named_syntax(Bin, Start, P) ->
    case binary_at(Bin, P) of
        $; when P - Start >= 2 -> {ok, P + 1};
        C when P - Start < 32 ->
            case beamai_markdown_char:is_alnum(C) of
                true -> named_syntax(Bin, Start, P + 1);
                false -> none
            end;
        _ -> none
    end.

%% @doc ASCII-only lowercase, safe on any byte string.
-spec lower_ascii(binary()) -> binary().
lower_ascii(Bin) ->
    << <<(case C >= $A andalso C =< $Z of true -> C + 32; false -> C end)>> || <<C>> <= Bin >>.

hex_entity(Bin, P, N, V) ->
    case binary_at(Bin, P) of
        $; when N > 0 -> {ok, [numeric(V)], P + 1};
        C when N < 6 ->
            case hexval(C) of
                error -> none;
                D -> hex_entity(Bin, P + 1, N + 1, V * 16 + D)
            end;
        _ -> none
    end.

dec_entity(Bin, P, N, V) ->
    case binary_at(Bin, P) of
        $; when N > 0 -> {ok, [numeric(V)], P + 1};
        C when C >= $0, C =< $9, N < 7 -> dec_entity(Bin, P + 1, N + 1, V * 10 + (C - $0));
        _ -> none
    end.

numeric(0) -> ?REPLACEMENT_CHAR;
numeric(V) when V > 16#10FFFF -> ?REPLACEMENT_CHAR;
numeric(V) when V >= 16#D800, V =< 16#DFFF -> ?REPLACEMENT_CHAR;
numeric(V) -> V.

named_entity(Bin, Start, P) ->
    case binary_at(Bin, P) of
        $; when P - Start >= 2 ->
            Name = binary:part(Bin, Start, P - Start),
            case beamai_markdown_entities:lookup(Name) of
                undefined -> none;
                Cps -> {ok, Cps, P + 1}
            end;
        C when P - Start < 32 ->
            case beamai_markdown_char:is_alnum(C) of
                true -> named_entity(Bin, Start, P + 1);
                false -> none
            end;
        _ -> none
    end.

hexval(C) when C >= $0, C =< $9 -> C - $0;
hexval(C) when C >= $a, C =< $f -> C - $a + 10;
hexval(C) when C >= $A, C =< $F -> C - $A + 10;
hexval(_) -> error.

%% A byte, or -1 past the end (which no clause above accepts).
binary_at(Bin, P) when P < byte_size(Bin) -> binary:at(Bin, P);
binary_at(_, _) -> -1.

%%%===================================================================
%%% Raw HTML
%%%===================================================================

%% @doc A raw HTML construct starting at Pos (which must hold `<'): an open
%% tag, a closing tag, a comment, a processing instruction, a declaration or
%% a CDATA section. Returns the offset just past it.
-spec html_tag(binary(), non_neg_integer()) -> {ok, non_neg_integer()} | none.
html_tag(Bin, Pos) ->
    case Bin of
        <<_:Pos/binary, "<!-->", _/binary>>  -> {ok, Pos + 5};
        <<_:Pos/binary, "<!--->", _/binary>> -> {ok, Pos + 6};
        <<_:Pos/binary, "<!--", _/binary>>   -> find_end(Bin, Pos + 4, <<"-->">>);
        <<_:Pos/binary, "<![CDATA[", _/binary>> -> find_end(Bin, Pos + 9, <<"]]>">>);
        <<_:Pos/binary, "<?", _/binary>>     -> find_end(Bin, Pos + 2, <<"?>">>);
        <<_:Pos/binary, "<!", C, _/binary>> ->
            case beamai_markdown_char:is_alpha(C) of
                true  -> find_end(Bin, Pos + 3, <<">">>);
                false -> none
            end;
        <<_:Pos/binary, "</", _/binary>>     -> html_closing_tag(Bin, Pos);
        <<_:Pos/binary, "<", _/binary>>      -> html_open_tag(Bin, Pos);
        _ -> none
    end.

find_end(Bin, From, Needle) ->
    case find(Bin, From, Needle) of
        none -> none;
        I -> {ok, I + byte_size(Needle)}
    end.

%% @doc `<tag attr="v" ... >' or `<tag />' starting at Pos.
-spec html_open_tag(binary(), non_neg_integer()) -> {ok, non_neg_integer()} | none.
html_open_tag(Bin, Pos) ->
    case html_tag_name(Bin, Pos + 1) of
        none -> none;
        {ok, _Name, P1} -> open_tag_attrs(Bin, P1)
    end.

open_tag_attrs(Bin, P) ->
    case binary_at(Bin, P) of
        $> -> {ok, P + 1};
        $/ ->
            case binary_at(Bin, P + 1) of
                $> -> {ok, P + 2};
                _  -> none
            end;
        C ->
            case beamai_markdown_char:is_whitespace(C) of
                false -> none;
                true ->
                    P1 = skip_whitespace(Bin, P),
                    case binary_at(Bin, P1) of
                        $> -> {ok, P1 + 1};
                        $/ -> open_tag_attrs(Bin, P1);
                        _ when P1 =:= P -> none;
                        _ ->
                            case attribute(Bin, P1) of
                                none -> none;
                                {ok, P2} -> open_tag_attrs(Bin, P2)
                            end
                    end
            end
    end.

%% attribute name: [A-Za-z_:][A-Za-z0-9_.:-]*, then optional = value
attribute(Bin, P) ->
    C = binary_at(Bin, P),
    case beamai_markdown_char:is_alpha(C) orelse C =:= $_ orelse C =:= $: of
        false -> none;
        true ->
            P1 = attr_name_rest(Bin, P + 1),
            P2 = skip_whitespace(Bin, P1),
            case binary_at(Bin, P2) of
                $= ->
                    P3 = skip_whitespace(Bin, P2 + 1),
                    attr_value(Bin, P3);
                _ -> {ok, P1}
            end
    end.

attr_name_rest(Bin, P) ->
    case beamai_markdown_char:is_attr_name_char(binary_at(Bin, P)) of
        true  -> attr_name_rest(Bin, P + 1);
        false -> P
    end.

attr_value(Bin, P) ->
    case binary_at(Bin, P) of
        $" -> quoted_end(Bin, P + 1, $");
        $' -> quoted_end(Bin, P + 1, $');
        _  -> unquoted_value(Bin, P, P)
    end.

quoted_end(Bin, P, Q) ->
    case find(Bin, P, <<Q>>) of
        none -> none;
        I -> {ok, I + 1}
    end.

unquoted_value(Bin, Start, P) ->
    C = binary_at(Bin, P),
    Stop = C =:= -1 orelse C =:= $" orelse C =:= $' orelse C =:= $= orelse
        C =:= $< orelse C =:= $> orelse C =:= $` orelse
        beamai_markdown_char:is_whitespace(C),
    case Stop of
        true when P =:= Start -> none;
        true -> {ok, P};
        false -> unquoted_value(Bin, Start, P + 1)
    end.

%% @doc `</tag >' starting at Pos.
-spec html_closing_tag(binary(), non_neg_integer()) -> {ok, non_neg_integer()} | none.
html_closing_tag(Bin, Pos) ->
    case html_tag_name(Bin, Pos + 2) of
        none -> none;
        {ok, _Name, P1} ->
            P2 = skip_whitespace(Bin, P1),
            case binary_at(Bin, P2) of
                $> -> {ok, P2 + 1};
                _  -> none
            end
    end.

%% @doc A tag name at Pos: an ASCII letter followed by letters, digits and
%% hyphens. Returns {ok, Name, EndPos}.
-spec html_tag_name(binary(), non_neg_integer()) ->
          {ok, binary(), non_neg_integer()} | none.
html_tag_name(Bin, Pos) ->
    case beamai_markdown_char:is_alpha(binary_at(Bin, Pos)) of
        false -> none;
        true ->
            End = tag_name_rest(Bin, Pos + 1),
            {ok, binary:part(Bin, Pos, End - Pos), End}
    end.

tag_name_rest(Bin, P) ->
    C = binary_at(Bin, P),
    case beamai_markdown_char:is_alnum(C) orelse C =:= $- of
        true  -> tag_name_rest(Bin, P + 1);
        false -> P
    end.

%%%===================================================================
%%% Links
%%%===================================================================

%% @doc A link destination at Pos: either `<...>' or a bare destination with
%% balanced parentheses. Returns {ok, RawDestination, EndPos}; the raw text
%% still has its backslash escapes and entities, see unescape/1.
-spec link_destination(binary(), non_neg_integer()) ->
          {ok, binary(), non_neg_integer()} | none.
link_destination(Bin, Pos) ->
    case binary_at(Bin, Pos) of
        $< -> angle_destination(Bin, Pos + 1, Pos + 1);
        _  -> bare_destination(Bin, Pos, Pos, 0)
    end.

angle_destination(Bin, Start, P) ->
    case binary_at(Bin, P) of
        $> -> {ok, binary:part(Bin, Start, P - Start), P + 1};
        $< -> none;
        $\n -> none;
        -1 -> none;
        $\\ ->
            case beamai_markdown_char:is_escapable(binary_at(Bin, P + 1)) of
                true  -> angle_destination(Bin, Start, P + 2);
                false -> angle_destination(Bin, Start, P + 1)
            end;
        _ -> angle_destination(Bin, Start, P + 1)
    end.

bare_destination(Bin, Start, P, Depth) ->
    C = binary_at(Bin, P),
    if
        C =:= $\\ ->
            case beamai_markdown_char:is_escapable(binary_at(Bin, P + 1)) of
                true  -> bare_destination(Bin, Start, P + 2, Depth);
                false -> bare_destination(Bin, Start, P + 1, Depth)
            end;
        C =:= $( ->
            if Depth >= 32 -> none;
               true -> bare_destination(Bin, Start, P + 1, Depth + 1)
            end;
        C =:= $), Depth =:= 0 ->
            bare_done(Bin, Start, P);
        C =:= $) ->
            bare_destination(Bin, Start, P + 1, Depth - 1);
        C =:= -1; C =< 32; C =:= 127 ->
            case Depth of
                0 -> bare_done(Bin, Start, P);
                _ -> none
            end;
        true ->
            bare_destination(Bin, Start, P + 1, Depth)
    end.

bare_done(_Bin, Start, P) when P =:= Start -> {ok, <<>>, P};
bare_done(Bin, Start, P) -> {ok, binary:part(Bin, Start, P - Start), P}.

%% @doc A link title at Pos: "...", '...' or (...). Returns the raw text
%% between the delimiters and the offset past the closer.
-spec link_title(binary(), non_neg_integer()) ->
          {ok, binary(), non_neg_integer()} | none.
link_title(Bin, Pos) ->
    case binary_at(Bin, Pos) of
        $" -> title_body(Bin, Pos + 1, Pos + 1, $", $");
        $' -> title_body(Bin, Pos + 1, Pos + 1, $', $');
        $( -> title_body(Bin, Pos + 1, Pos + 1, $), $();
        _  -> none
    end.

title_body(Bin, Start, P, Close, Open) ->
    case binary_at(Bin, P) of
        -1 -> none;
        Close -> {ok, binary:part(Bin, Start, P - Start), P + 1};
        Open when Open =:= $( -> none;
        $\\ ->
            case beamai_markdown_char:is_escapable(binary_at(Bin, P + 1)) of
                true  -> title_body(Bin, Start, P + 2, Close, Open);
                false -> title_body(Bin, Start, P + 1, Close, Open)
            end;
        _ -> title_body(Bin, Start, P + 1, Close, Open)
    end.

%% @doc A link label at Pos (which must hold `['): up to 999 characters
%% with no unescaped brackets. Returns {ok, RawLabel, EndPos} where RawLabel
%% is the text between the brackets.
-spec link_label(binary(), non_neg_integer()) ->
          {ok, binary(), non_neg_integer()} | none.
link_label(Bin, Pos) ->
    case binary_at(Bin, Pos) of
        $[ -> label_body(Bin, Pos + 1, Pos + 1, 0);
        _  -> none
    end.

label_body(Bin, Start, P, N) when N =< 999 ->
    case binary_at(Bin, P) of
        -1 -> none;
        $] -> {ok, binary:part(Bin, Start, P - Start), P + 1};
        $[ -> none;
        $\\ ->
            case beamai_markdown_char:is_escapable(binary_at(Bin, P + 1)) of
                true  -> label_body(Bin, Start, P + 2, N + 2);
                false -> label_body(Bin, Start, P + 1, N + 1)
            end;
        C when C < 128 -> label_body(Bin, Start, P + 1, N + 1);
        _ ->
            W = beamai_markdown_char:width(beamai_markdown_char:at(Bin, P)),
            label_body(Bin, Start, P + W, N + 1)
    end;
label_body(_, _, _, _) -> none.

%% @doc Resolve backslash escapes and entity references.
-spec unescape(binary()) -> binary().
unescape(Bin) ->
    case has_escapes(Bin) of
        false -> Bin;
        true  -> unescape(Bin, 0, 0, [])
    end.

has_escapes(<<>>) -> false;
has_escapes(<<$\\, _/binary>>) -> true;
has_escapes(<<$&, _/binary>>) -> true;
has_escapes(<<_, R/binary>>) -> has_escapes(R).

unescape(Bin, Last, P, Acc) when P >= byte_size(Bin) ->
    iolist_to_binary(lists:reverse([binary:part(Bin, Last, P - Last) | Acc]));
unescape(Bin, Last, P, Acc) ->
    case binary:at(Bin, P) of
        $\\ ->
            case P + 1 < byte_size(Bin) andalso
                beamai_markdown_char:is_escapable(beamai_markdown_char:at(Bin, P + 1)) of
                true ->
                    Acc1 = [binary:part(Bin, Last, P - Last) | Acc],
                    unescape(Bin, P + 1, P + 1 + escaped_width(Bin, P + 1), Acc1);
                false ->
                    unescape(Bin, Last, P + 1, Acc)
            end;
        $& ->
            case entity(Bin, P) of
                {ok, Cps, End} ->
                    Acc1 = [unicode:characters_to_binary(Cps),
                            binary:part(Bin, Last, P - Last) | Acc],
                    unescape(Bin, End, End, Acc1);
                none ->
                    unescape(Bin, Last, P + 1, Acc)
            end;
        _ ->
            unescape(Bin, Last, P + 1, Acc)
    end.

escaped_width(Bin, P) -> beamai_markdown_char:width(beamai_markdown_char:at(Bin, P)).

%%%===================================================================
%%% Output escaping
%%%===================================================================

%% @doc HTML-escape `<', `>', `&' and `"'.
-spec escape_html(binary()) -> iodata().
escape_html(Bin) -> escape_html(Bin, false).

%% @doc With Soft = true only `<' and `&' are escaped (code block bodies).
-spec escape_html(binary(), boolean()) -> iodata().
escape_html(Bin, Soft) ->
    case needs_html_escape(Bin, Soft) of
        false -> Bin;
        true  -> esc_html(Bin, 0, 0, [], Soft)
    end.

needs_html_escape(Bin, true) -> binary:match(Bin, [<<"<">>, <<"&">>]) =/= nomatch;
needs_html_escape(Bin, false) -> binary:match(Bin, [<<"<">>, <<"&">>, <<">">>, <<"\"">>]) =/= nomatch.

esc_html(Bin, Last, P, Acc, _Soft) when P >= byte_size(Bin) ->
    lists:reverse([binary:part(Bin, Last, P - Last) | Acc]);
esc_html(Bin, Last, P, Acc, Soft) ->
    case binary:at(Bin, P) of
        $< -> esc_html(Bin, P + 1, P + 1, [<<"&lt;">>, binary:part(Bin, Last, P - Last) | Acc], Soft);
        $& -> esc_html(Bin, P + 1, P + 1, [<<"&amp;">>, binary:part(Bin, Last, P - Last) | Acc], Soft);
        $> when not Soft -> esc_html(Bin, P + 1, P + 1, [<<"&gt;">>, binary:part(Bin, Last, P - Last) | Acc], Soft);
        $" when not Soft -> esc_html(Bin, P + 1, P + 1, [<<"&quot;">>, binary:part(Bin, Last, P - Last) | Acc], Soft);
        _ -> esc_html(Bin, Last, P + 1, Acc, Soft)
    end.

%% @doc Percent-escape a URL the way markdig does: controls, space, DEL and
%% `"'<>[\]^`{|}~' as %XX, `&' as `&amp;', non-ASCII as UTF-8 percent
%% sequences (or verbatim when NonAsciiNoEscape is on). A non-ASCII domain
%% is punycoded first.
-spec escape_url(binary()) -> iodata().
escape_url(Url) -> escape_url(Url, false).

-spec escape_url(binary(), boolean()) -> iodata().
escape_url(Url0, NonAsciiNoEscape) ->
    Url = case is_ascii(Url0) of
              true -> Url0;
              false -> beamai_markdown_punycode:encode_domain(Url0)
          end,
    esc_url(Url, 0, 0, [], NonAsciiNoEscape).

is_ascii(<<>>) -> true;
is_ascii(<<C, R/binary>>) when C < 128 -> is_ascii(R);
is_ascii(_) -> false.

esc_url(Bin, Last, P, Acc, _) when P >= byte_size(Bin) ->
    lists:reverse([binary:part(Bin, Last, P - Last) | Acc]);
esc_url(Bin, Last, P, Acc, NoEsc) ->
    C = binary:at(Bin, P),
    case url_escape(C) of
        false when C < 128 -> esc_url(Bin, Last, P + 1, Acc, NoEsc);
        false when NoEsc -> esc_url(Bin, Last, P + 1, Acc, NoEsc);
        false ->
            Cp = beamai_markdown_char:at(Bin, P),
            W = beamai_markdown_char:width(Cp),
            Acc1 = [utf8_percent(binary:part(Bin, P, W)), binary:part(Bin, Last, P - Last) | Acc],
            esc_url(Bin, P + W, P + W, Acc1, NoEsc);
        Esc ->
            esc_url(Bin, P + 1, P + 1, [Esc, binary:part(Bin, Last, P - Last) | Acc], NoEsc)
    end.

url_escape($&) -> <<"&amp;">>;
url_escape(C) when C =< 32; C =:= 127 -> percent(C);
url_escape($") -> <<"%22">>;
url_escape($') -> <<"%27">>;
url_escape($<) -> <<"%3C">>;
url_escape($>) -> <<"%3E">>;
url_escape($[) -> <<"%5B">>;
url_escape($\\) -> <<"%5C">>;
url_escape($]) -> <<"%5D">>;
url_escape($^) -> <<"%5E">>;
url_escape($`) -> <<"%60">>;
url_escape(${) -> <<"%7B">>;
url_escape($|) -> <<"%7C">>;
url_escape($}) -> <<"%7D">>;
url_escape($~) -> <<"%7E">>;
url_escape(_) -> false.

percent(C) ->
    H = "0123456789ABCDEF",
    <<$%, (lists:nth((C bsr 4) + 1, H)), (lists:nth((C band 15) + 1, H))>>.

%% @doc Every byte of Bin as %XX.
-spec utf8_percent(binary()) -> binary().
utf8_percent(Bin) -> << <<(percent(B))/binary>> || <<B>> <= Bin >>.

%% @doc Does the URL have a scheme (`scheme:' with a letter first)?
-spec is_absolute_url(binary()) -> boolean().
is_absolute_url(<<C, R/binary>>) ->
    beamai_markdown_char:is_alpha(C) andalso scheme_rest(R);
is_absolute_url(_) -> false.

scheme_rest(<<$:, _/binary>>) -> true;
scheme_rest(<<C, R/binary>>) ->
    (beamai_markdown_char:is_alnum(C) orelse C =:= $+ orelse C =:= $. orelse C =:= $-)
        andalso scheme_rest(R);
scheme_rest(<<>>) -> false.

%% @doc RFC 3986 reference resolution, enough for a base URL option.
-spec resolve_url(binary(), binary()) -> binary().
resolve_url(Base, Ref) ->
    case is_absolute_url(Ref) of
        true -> Ref;
        false ->
            {Scheme, Authority, Path, _Query, _Frag} = split_url(Base),
            case Ref of
                <<"//", _/binary>> -> <<Scheme/binary, ":", Ref/binary>>;
                <<"/", _/binary>> -> <<Scheme/binary, "://", Authority/binary, (remove_dots(Ref))/binary>>;
                <<"?", _/binary>> -> <<Scheme/binary, "://", Authority/binary, Path/binary, Ref/binary>>;
                <<"#", _/binary>> -> <<Scheme/binary, "://", Authority/binary, Path/binary, Ref/binary>>;
                <<>> -> Base;
                _ ->
                    Dir = case binary:matches(Path, <<"/">>) of
                              [] -> <<"/">>;
                              Ms -> {L, _} = lists:last(Ms), binary:part(Path, 0, L + 1)
                          end,
                    <<Scheme/binary, "://", Authority/binary, (remove_dots(<<Dir/binary, Ref/binary>>))/binary>>
            end
    end.

split_url(Url) ->
    {Scheme, Rest0} = case binary:split(Url, <<"://">>) of
                          [S, R] -> {S, R};
                          [R] -> {<<>>, R}
                      end,
    {Auth, Rest1} = case binary:split(Rest0, <<"/">>) of
                        [A, R1] -> {A, <<"/", R1/binary>>};
                        [A] -> {A, <<"/">>}
                    end,
    {PathQ, Frag} = case binary:split(Rest1, <<"#">>) of
                        [P, F] -> {P, F};
                        [P] -> {P, <<>>}
                    end,
    {Path, Query} = case binary:split(PathQ, <<"?">>) of
                        [P1, Q] -> {P1, Q};
                        [P1] -> {P1, <<>>}
                    end,
    {Scheme, Auth, Path, Query, Frag}.

remove_dots(Path) ->
    Segs = binary:split(Path, <<"/">>, [global]),
    Out = lists:foldl(fun(<<".">>, Acc) -> Acc;
                         (<<"..">>, [_ | Acc]) -> Acc;
                         (<<"..">>, []) -> [];
                         (S, Acc) -> [S | Acc]
                      end, [], tl(Segs)),
    Tail = case lists:last(Segs) of
               <<".">> -> <<"/">>;
               <<"..">> -> <<"/">>;
               _ -> <<>>
           end,
    Joined = iolist_to_binary(lists:join(<<"/">>, lists:reverse(Out))),
    <<"/", Joined/binary, Tail/binary>>.

%%%===================================================================
%%% Small utilities
%%%===================================================================

%% @doc First offset at or after P that is not a space or tab.
-spec skip_spaces(binary(), non_neg_integer()) -> non_neg_integer().
skip_spaces(Bin, P) ->
    case binary_at(Bin, P) of
        $\s -> skip_spaces(Bin, P + 1);
        $\t -> skip_spaces(Bin, P + 1);
        _ -> P
    end.

%% @doc First offset at or after P that is not whitespace (spaces, tabs,
%% newlines).
-spec skip_whitespace(binary(), non_neg_integer()) -> non_neg_integer().
skip_whitespace(Bin, P) ->
    case binary_at(Bin, P) of
        C when C =:= $\s; C =:= $\t; C =:= $\n; C =:= $\r; C =:= $\f ->
            skip_whitespace(Bin, P + 1);
        _ -> P
    end.

%% @doc Like skip_whitespace/2 but stops after the first newline crossed,
%% i.e. allows at most one line ending. Returns {EndPos, Newlines}.
-spec skip_whitespace_lines(binary(), non_neg_integer()) ->
          {non_neg_integer(), non_neg_integer()}.
skip_whitespace_lines(Bin, P) -> skip_ws_lines(Bin, P, 0).

skip_ws_lines(Bin, P, N) ->
    case binary_at(Bin, P) of
        $\n -> skip_ws_lines(Bin, P + 1, N + 1);
        C when C =:= $\s; C =:= $\t; C =:= $\r; C =:= $\f -> skip_ws_lines(Bin, P + 1, N);
        _ -> {P, N}
    end.

%% @doc Case-insensitive ASCII prefix test at offset P.
-spec starts_with_ci(binary(), non_neg_integer(), binary()) -> boolean().
starts_with_ci(Bin, P, Prefix) ->
    N = byte_size(Prefix),
    case Bin of
        <<_:P/binary, Part:N/binary, _/binary>> ->
            string:lowercase(Part) =:= string:lowercase(Prefix);
        _ -> false
    end.

%% @doc Offset of Needle in Bin at or after From, or none.
-spec find(binary(), non_neg_integer(), binary()) -> non_neg_integer() | none.
find(Bin, From, Needle) when From =< byte_size(Bin) ->
    case binary:match(Bin, Needle, [{scope, {From, byte_size(Bin) - From}}]) of
        nomatch -> none;
        {I, _} -> I
    end;
find(_, _, _) -> none.

-spec trim_end(binary()) -> binary().
trim_end(Bin) -> string:trim(Bin, trailing, "\s\t\n\r").

-spec trim_start(binary()) -> binary().
trim_start(Bin) -> string:trim(Bin, leading, "\s\t\n\r").

-spec trim(binary()) -> binary().
trim(Bin) -> string:trim(Bin, both, "\s\t\n\r").

%% @doc Only spaces and tabs?
-spec is_blank(binary()) -> boolean().
is_blank(<<>>) -> true;
is_blank(<<$\s, R/binary>>) -> is_blank(R);
is_blank(<<$\t, R/binary>>) -> is_blank(R);
is_blank(_) -> false.

%% @doc How many times byte C repeats starting at P.
-spec count_char(binary(), non_neg_integer(), byte()) -> non_neg_integer().
count_char(Bin, P, C) -> count_char(Bin, P, C, 0).

count_char(Bin, P, C, N) ->
    case binary_at(Bin, P) of
        C -> count_char(Bin, P + 1, C, N + 1);
        _ -> N
    end.

%% @doc Split text into {Line, LineEnding} pairs. The ending is one of
%% <<"\n">>, <<"\r\n">>, <<"\r">> or <<>> for the last line when the text
%% does not end with a newline. A text ending in a newline does NOT yield an
%% extra empty line.
-spec split_lines(binary()) -> [{binary(), binary()}].
split_lines(Bin) ->
    %% binary:matches/2 is a BIF; walking bytes from Erlang was the single
    %% most expensive thing in the parser.
    Ends = binary:matches(Bin, [<<"\r\n">>, <<"\n">>, <<"\r">>]),
    split_lines(Bin, 0, Ends, []).

split_lines(Bin, Start, [], Acc) ->
    case byte_size(Bin) > Start of
        true -> lists:reverse([{binary:part(Bin, Start, byte_size(Bin) - Start), <<>>} | Acc]);
        false -> lists:reverse(Acc)
    end;
split_lines(Bin, Start, [{Pos, Len} | Rest], Acc) ->
    Line = binary:part(Bin, Start, Pos - Start),
    Eol = binary:part(Bin, Pos, Len),
    split_lines(Bin, Pos + Len, Rest, [{Line, Eol} | Acc]).
