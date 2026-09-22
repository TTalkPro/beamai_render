%%%-------------------------------------------------------------------
%%% @doc Character classification for the markdown engine.
%%%
%%% Port of markdig's CharHelper. The three Unicode masks are kept distinct
%%% on purpose -- they are not interchangeable -- and so are markdig's two
%%% departures from vanilla CommonMark: NUL counts as both space and
%%% punctuation (it is what start and end of line read as), and a handful of
%%% characters are excepted from the punctuation flanking rule.
%%%
%%% Everything works on code points. Bytes come in through at/2, which
%%% decodes one UTF-8 character at a byte offset; the line and inline
%%% scanners never index into the middle of a multi-byte sequence because
%%% they only ever stop on ASCII.
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_char).

-include("beamai_markdown.hrl").

-export([at/2, prev/2, width/1, is_space/1, is_whitespace/1,
         is_space_or_tab/1, is_ascii_punct/1, is_escapable/1,
         is_digit/1, is_alpha/1, is_alnum/1, is_attr_name_char/1,
         is_punct/1, is_gfm_space_or_punct/1, category/1,
         flanking/3, flanking_cjk/3, is_cjk/1,
         add_tab/1, across_tab/1, fold_label/1, collapse_ws/1,
         is_roman/1, roman_to_int/1, is_letter/1, to_lower/1]).

%% @doc The code point at byte offset Pos, or NUL past the end.
-spec at(binary(), integer()) -> char().
at(_Bin, Pos) when Pos < 0 -> ?NUL;
at(Bin, Pos) when Pos >= byte_size(Bin) -> ?NUL;
at(Bin, Pos) ->
    case Bin of
        <<_:Pos/binary, C, _/binary>> when C < 128 -> C;
        <<_:Pos/binary, C/utf8, _/binary>>         -> C;
        _                                          -> ?REPLACEMENT_CHAR
    end.

%% @doc The code point ending just before byte offset Pos, or NUL at 0.
-spec prev(binary(), integer()) -> char().
prev(_Bin, Pos) when Pos =< 0 -> ?NUL;
prev(Bin, Pos) ->
    case binary:at(Bin, Pos - 1) of
        C when C < 128 -> C;
        _ -> prev_utf8(Bin, Pos - 1)
    end.

prev_utf8(Bin, P) when P > 0 ->
    case binary:at(Bin, P) of
        C when C band 16#C0 =:= 16#80 -> prev_utf8(Bin, P - 1);
        _ -> at(Bin, P)
    end;
prev_utf8(Bin, 0) -> at(Bin, 0).

%% @doc UTF-8 byte width of a code point.
-spec width(char()) -> 1..4.
width(C) when C < 16#80 -> 1;
width(C) when C < 16#800 -> 2;
width(C) when C < 16#10000 -> 3;
width(_) -> 4.

-spec is_space(char()) -> boolean().
is_space($\s) -> true;
is_space(_) -> false.

%% @doc CommonMark whitespace: tab, LF, FF, CR, space, plus Unicode Zs.
-spec is_whitespace(char()) -> boolean().
is_whitespace($\s) -> true;
is_whitespace($\t) -> true;
is_whitespace($\n) -> true;
is_whitespace($\f) -> true;
is_whitespace($\r) -> true;
is_whitespace(C) when C >= 128 -> beamai_markdown_unicode:is_space_separator(C);
is_whitespace(_) -> false.

-spec is_space_or_tab(char()) -> boolean().
is_space_or_tab($\s) -> true;
is_space_or_tab($\t) -> true;
is_space_or_tab(_) -> false.

-spec is_ascii_punct(char()) -> boolean().
is_ascii_punct(C) when C >= $!, C =< $/ -> true;
is_ascii_punct(C) when C >= $:, C =< $@ -> true;
is_ascii_punct(C) when C >= $[, C =< $` -> true;
is_ascii_punct(C) when C >= ${, C =< $~ -> true;
is_ascii_punct(_) -> false.

%% @doc What a backslash may escape: ASCII punctuation, plus U+2022 BULLET
%% (a markdig extension over vanilla CommonMark).
-spec is_escapable(char()) -> boolean().
is_escapable(16#2022) -> true;
is_escapable(C) -> is_ascii_punct(C).

-spec is_digit(char()) -> boolean().
is_digit(C) -> C >= $0 andalso C =< $9.

-spec is_alpha(char()) -> boolean().
is_alpha(C) -> (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z).

-spec is_alnum(char()) -> boolean().
is_alnum(C) -> is_alpha(C) orelse is_digit(C).

%% @doc Unicode letter, as far as the engine needs one: ASCII letters plus
%% any non-ASCII code point that is neither whitespace nor punctuation.
-spec is_letter(char()) -> boolean().
is_letter(C) when C < 128 -> is_alpha(C);
is_letter(C) -> not is_whitespace(C) andalso not is_punct(C).

%% @doc [A-Za-z0-9_:.-], the characters allowed after the first in an
%% attribute name. Shared by the HTML tag scanner and generic attributes.
-spec is_attr_name_char(char()) -> boolean().
is_attr_name_char($_) -> true;
is_attr_name_char($:) -> true;
is_attr_name_char($.) -> true;
is_attr_name_char($-) -> true;
is_attr_name_char(C) -> is_alnum(C).

%% @doc CommonMark punctuation (P* and S* categories).
-spec is_punct(char()) -> boolean().
is_punct(C) when C < 128 -> is_ascii_punct(C);
is_punct(C) -> beamai_markdown_unicode:is_commonmark_punctuation(C).

%% @doc GFM autolinks' own classification: P* (no symbols) plus Zs.
-spec is_gfm_space_or_punct(char()) -> boolean().
is_gfm_space_or_punct($\s) -> true;
is_gfm_space_or_punct(C) when C < 128 -> is_ascii_punct(C);
is_gfm_space_or_punct(C) ->
    beamai_markdown_unicode:is_unicode_punctuation(C)
        orelse beamai_markdown_unicode:is_space_separator(C).

%% @doc {Space, Punctuation} for the flanking rules. NUL is both.
-spec category(char()) -> {boolean(), boolean()}.
category(?NUL) -> {true, true};
category(C) ->
    case is_whitespace(C) of
        true -> {true, false};
        false when C < 128 -> {false, is_ascii_punct(C)};
        false -> {false, beamai_markdown_unicode:is_commonmark_punctuation(C)}
    end.

%% markdig excepts these from the punctuation flanking rule.
punct_exception($-) -> true;
punct_exception($+) -> true;
punct_exception(16#2212) -> true;   % MINUS SIGN
punct_exception(16#2020) -> true;   % DAGGER
punct_exception(16#2021) -> true;   % DOUBLE DAGGER
punct_exception(_) -> false.

%% @doc The left/right-flanking delimiter run rule: {CanOpen, CanClose}.
%% WithinWord is per emphasis descriptor: true for `*', false for `_'.
-spec flanking(char(), char(), boolean()) -> {boolean(), boolean()}.
flanking(Prev, Next, WithinWord) ->
    flanking(Prev, Next, WithinWord, false, false).

%% @doc The CJK-friendly variant: CJK characters count as punctuation on the
%% far side, so `**这个**吗' can close.
-spec flanking_cjk(char(), char(), boolean()) -> {boolean(), boolean()}.
flanking_cjk(Prev, Next, WithinWord) ->
    flanking(Prev, Next, WithinWord, is_cjk(Prev), is_cjk(Next)).

flanking(Prev, Next, WithinWord, PrevCjk, NextCjk) ->
    {PrevSpace, PrevPunct} = category(Prev),
    {NextSpace, NextPunct} = category(Next),
    PrevExc = punct_exception(Prev),
    NextExc = punct_exception(Next),
    CanOpen0 = (not NextSpace) andalso
        ((not NextPunct) orelse NextExc orelse PrevSpace orelse PrevPunct orelse PrevCjk),
    CanClose0 = (not PrevSpace) andalso
        ((not PrevPunct) orelse PrevExc orelse NextSpace orelse NextPunct orelse NextCjk),
    case WithinWord of
        true -> {CanOpen0, CanClose0};
        false ->
            CanOpen = CanOpen0 andalso ((not CanClose0) orelse PrevPunct orelse PrevCjk),
            CanClose = CanClose0 andalso ((not CanOpen0) orelse NextPunct orelse NextCjk),
            {CanOpen, CanClose}
    end.

-spec is_cjk(char()) -> boolean().
is_cjk(C) when C >= 16#1100, C =< 16#115F -> true;
is_cjk(C) when C >= 16#2E80, C =< 16#303E -> true;
is_cjk(C) when C >= 16#3040, C =< 16#33BF -> true;
is_cjk(C) when C >= 16#3400, C =< 16#4DBF -> true;
is_cjk(C) when C >= 16#4E00, C =< 16#9FFF -> true;
is_cjk(C) when C >= 16#A000, C =< 16#A4CF -> true;
is_cjk(C) when C >= 16#AC00, C =< 16#D7AF -> true;
is_cjk(C) when C >= 16#F900, C =< 16#FAFF -> true;
is_cjk(C) when C >= 16#FE30, C =< 16#FE4F -> true;
is_cjk(C) when C >= 16#FF00, C =< 16#FFEF -> true;
is_cjk(C) when C >= 16#20000, C =< 16#2FFFD -> true;
is_cjk(C) when C >= 16#30000, C =< 16#3FFFD -> true;
is_cjk(_) -> false.

%% @doc Column after a tab at Column.
-spec add_tab(non_neg_integer()) -> non_neg_integer().
add_tab(Column) -> ?TAB_SIZE + (Column band (bnot (?TAB_SIZE - 1))).

-spec across_tab(non_neg_integer()) -> boolean().
across_tab(Column) -> Column band (?TAB_SIZE - 1) =/= 0.

%% @doc Normalise a link label: collapse internal whitespace to one space,
%% trim, and Unicode case fold (`ẞ' becomes `ss', so `[ẞ]' finds `[SS]:').
-spec fold_label(binary()) -> binary().
fold_label(Label) ->
    string:casefold(collapse_ws(Label)).

%% @doc Collapse internal whitespace runs to one space and trim.
-spec collapse_ws(binary()) -> binary().
collapse_ws(Label) -> collapse_ws(Label, <<>>, false).

collapse_ws(<<>>, Acc, _) -> string:trim(Acc);
collapse_ws(<<C, Rest/binary>>, Acc, InWs) when C =:= $\s; C =:= $\t; C =:= $\n; C =:= $\r ->
    case InWs of
        true  -> collapse_ws(Rest, Acc, true);
        false -> collapse_ws(Rest, <<Acc/binary, $\s>>, true)
    end;
collapse_ws(<<C/utf8, Rest/binary>>, Acc, _) ->
    collapse_ws(Rest, <<Acc/binary, C/utf8>>, false).

-spec to_lower(binary()) -> binary().
to_lower(Bin) -> string:lowercase(Bin).

%% @doc A roman numeral letter (either case).
-spec is_roman(char()) -> boolean().
is_roman(C) -> lists:member(C, "ivxlcdmIVXLCDM").

-spec roman_to_int(binary()) -> non_neg_integer().
roman_to_int(Bin) ->
    Vals = [roman_val(C) || <<C>> <= Bin],
    roman_sum(Vals, 0).

roman_sum([], Acc) -> Acc;
roman_sum([A], Acc) -> Acc + A;
roman_sum([A, B | T], Acc) when A < B -> roman_sum([B | T], Acc - A);
roman_sum([A | T], Acc) -> roman_sum(T, Acc + A).

roman_val($i) -> 1; roman_val($I) -> 1;
roman_val($v) -> 5; roman_val($V) -> 5;
roman_val($x) -> 10; roman_val($X) -> 10;
roman_val($l) -> 50; roman_val($L) -> 50;
roman_val($c) -> 100; roman_val($C) -> 100;
roman_val($d) -> 500; roman_val($D) -> 500;
roman_val($m) -> 1000; roman_val($M) -> 1000;
roman_val(_) -> 0.
