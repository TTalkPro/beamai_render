%%%-------------------------------------------------------------------
%%% @doc Heading anchors: `# Foo' renders as `<h1 id="foo">'.
%%%
%%% Port of markdig's AutoIdentifiers. The id is computed from the
%%% heading's inlines rendered as plain text, so emphasis and links do not
%%% leak into it, and collisions get -1, -2... With `auto_link' (default),
%%% every heading's raw text is also a link reference label pointing at
%%% itself, so `[My Heading]' links to `#my-heading' -- resolved after the
%%% inline pass, since the id does not exist before it.
%%%
%%% Options: auto_link (true), allow_only_ascii (true), github (false).
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_ext_auto_identifiers).

-include("beamai_markdown.hrl").

-export([setup/2, register_refs/4, assign/3, urilize/2, urilize_gfm/1,
         heading_text/2]).

-spec setup(map(), map()) -> map().
setup(Pipe0, Opts) ->
    Pipe1 = beamai_markdown_pipeline:add(
              Pipe0, pre_inline_hooks,
              #{name => auto_identifiers, module => ?MODULE, function => register_refs, opts => Opts}),
    beamai_markdown_pipeline:add(
      Pipe1, document_hooks,
      #{name => auto_identifiers, module => ?MODULE, function => assign, opts => Opts}).

opts(Pipe) ->
    case beamai_markdown_pipeline:find(Pipe, document_hooks, auto_identifiers) of
        #{opts := O} -> O;
        _ -> #{}
    end.

%% @doc Before the inline pass: every heading's first line is a reference
%% label for the heading itself, unless the document defines that label.
-spec register_refs(beamai_markdown_block(), map(), map(), map()) -> {beamai_markdown_block(), map()}.
register_refs(Doc, Refs, Pipe, _Opts) ->
    case maps:get(auto_link, opts(Pipe), true) of
        false -> {Doc, Refs};
        true ->
            Texts = heading_texts(Doc),
            Refs1 = lists:foldl(
                      fun(Text, Acc) ->
                              Label = beamai_markdown_char:fold_label(Text),
                              case Label =:= <<>> orelse maps:is_key(Label, Acc) of
                                  true -> Acc;
                                  false -> Acc#{Label => #{label => Label, raw_label => Text,
                                                           url => {auto_id, Text}, title => <<>>,
                                                           auto_id => true}}
                              end
                      end, Refs, Texts),
            {Doc, Refs1}
    end.

heading_texts(#{k := heading, lines := [{T, _, _} | _]}) -> [T];
heading_texts(#{children := Ch}) -> lists:append([heading_texts(C) || C <- Ch]);
heading_texts(_) -> [].

%% @doc After the inline pass: assign ids, then resolve the auto links.
-spec assign(beamai_markdown_block(), map(), map()) -> beamai_markdown_block().
assign(Doc, Pipe, _Opts) ->
    O = opts(Pipe),
    {Doc1, {_Used, Ids}} = walk(Doc, {#{}, #{}}, O, Pipe),
    case maps:get(auto_link, O, true) of
        false -> Doc1;
        true -> resolve(Doc1, Ids)
    end.

walk(#{k := heading, inlines := _} = H, {Used, Ids}, O, Pipe) ->
    case beamai_markdown_attrs:id(H) of
        undefined ->
            Raw = heading_text(H, Pipe),
            Base0 = case maps:get(github, O, false) of
                        true -> urilize_gfm(Raw);
                        false -> urilize(Raw, maps:get(allow_only_ascii, O, true))
                    end,
            Base = case Base0 of <<>> -> <<"section">>; _ -> Base0 end,
            Id = unique(Base, Used, 0),
            Key = case H of #{lines := [{T, _, _} | _]} -> T; _ -> <<>> end,
            {beamai_markdown_attrs:set_id(H, Id), {Used#{Id => true}, Ids#{Key => Id}}};
        Id ->
            Key = case H of #{lines := [{T, _, _} | _]} -> T; _ -> <<>> end,
            {H, {Used#{Id => true}, Ids#{Key => Id}}}
    end;
walk(#{children := Ch} = B, Acc0, O, Pipe) when Ch =/= [] ->
    {Ch1, Acc1} = lists:mapfoldl(fun(C, A) -> walk(C, A, O, Pipe) end, Acc0, Ch),
    {B#{children => Ch1}, Acc1};
walk(B, Acc, _, _) -> {B, Acc}.

unique(Base, Used, 0) ->
    case maps:is_key(Base, Used) of
        false -> Base;
        true -> unique(Base, Used, 1)
    end;
unique(Base, Used, N) ->
    Id = <<Base/binary, "-", (integer_to_binary(N))/binary>>,
    case maps:is_key(Id, Used) of
        false -> Id;
        true -> unique(Base, Used, N + 1)
    end.

%% @doc A heading's inlines as plain text: the HTML renderer with all
%% emission off.
-spec heading_text(beamai_markdown_block(), map()) -> binary().
heading_text(H, Pipe) ->
    R = beamai_markdown_html:new(Pipe, #{renderer => plain, enable_inline => false,
                                          enable_block => false, enable_escape => false}),
    beamai_markdown_renderer:finish(beamai_markdown_renderer:write_leaf_inline(R, H)).

%% Replace every {auto_id, Text} url by the heading's id.
resolve(#{inlines := Inlines} = B, Ids) ->
    B#{inlines => [resolve_inline(I, Ids) || I <- Inlines]};
resolve(#{children := Ch} = B, Ids) when Ch =/= [] ->
    B#{children => [resolve(C, Ids) || C <- Ch]};
resolve(B, _) -> B.

resolve_inline(#{url := {auto_id, Text}} = L, Ids) ->
    Url = <<"#", (maps:get(Text, Ids, <<>>))/binary>>,
    resolve_children(L#{url => Url}, Ids);
resolve_inline(N, Ids) -> resolve_children(N, Ids).

resolve_children(#{children := Ch} = N, Ids) when Ch =/= [] ->
    N#{children => [resolve_inline(C, Ids) || C <- Ch]};
resolve_children(N, _) -> N.

%%%===================================================================
%%% Urilize
%%%===================================================================

%% @doc Heading text -> identifier: letters lowercased, whitespace runs to
%% one dash, `_' `-' `.' kept but never doubled, everything else dropped,
%% nothing before the first letter kept, and trailing punctuation trimmed.
-spec urilize(binary(), boolean()) -> binary().
urilize(Text, AsciiOnly) ->
    Chars = unicode:characters_to_list(Text),
    Expanded = case AsciiOnly of
                   true -> lists:append([expand(C) || C <- Chars]);
                   false -> Chars
               end,
    %% State: {Buffer (reversed), HasLetter, PrevIsSpace}
    {Buf, _, _} = lists:foldl(fun(C, St) -> put_char(C, St, AsciiOnly) end, {[], false, false}, Expanded),
    Trimmed = lists:dropwhile(fun reserved/1, Buf),
    unicode:characters_to_binary(lists:reverse(Trimmed)).

reserved($_) -> true;
reserved($-) -> true;
reserved($.) -> true;
reserved(_) -> false.

put_char(C, {Buf, HasLetter, PrevSpace}, AsciiOnly) ->
    case is_letter(C) of
        true when AsciiOnly, C >= 127 -> {Buf, HasLetter, PrevSpace};
        true -> {[lower(C) | Buf], true, false};
        false when not HasLetter -> {Buf, HasLetter, PrevSpace};
        false ->
            case reserved(C) of
                true ->
                    Buf1 = case PrevSpace of true -> tl(Buf); false -> Buf end,
                    Buf2 = case Buf1 of [C | _] -> Buf1; _ -> [C | Buf1] end,
                    {Buf2, HasLetter, false};
                false ->
                    case beamai_markdown_char:is_digit(C) of
                        true -> {[C | Buf], HasLetter, false};
                        false ->
                            case (not PrevSpace) andalso beamai_markdown_char:is_whitespace(C) of
                                true ->
                                    Buf1 = case Buf of
                                               [L | _] when not (L =:= $_ orelse L =:= $- orelse L =:= $.) -> [$- | Buf];
                                               _ -> Buf
                                           end,
                                    {Buf1, HasLetter, true};
                                false -> {Buf, HasLetter, PrevSpace}
                            end
                    end
            end
    end.

is_letter(C) when C < 128 -> beamai_markdown_char:is_alpha(C);
is_letter(C) -> beamai_markdown_char:is_letter(C).

lower(C) when C < 128 -> string:to_lower(C);
lower(C) -> hd(unicode:characters_to_list(string:lowercase([C]))).

%% German and Scandinavian transliterations, then Latin diacritics stripped.
expand($ä) -> "ae"; expand($ö) -> "oe"; expand($ü) -> "ue";
expand($Ä) -> "Ae"; expand($Ö) -> "Oe"; expand($Ü) -> "Ue";
expand($ß) -> "ss";
expand($æ) -> "ae"; expand($ø) -> "oe"; expand($å) -> "aa";
expand($Æ) -> "Ae"; expand($Ø) -> "Oe"; expand($Å) -> "Aa";
expand($þ) -> "th"; expand($Þ) -> "Th";
expand($ð) -> "d"; expand($Ð) -> "D";
expand(C) ->
    case base_letter(C) of
        undefined -> [C];
        B -> [B]
    end.

base_letter(C) ->
    Table = [{$a, "àáâãäåāăą"}, {$c, "çćĉċč"}, {$d, "ďđ"}, {$e, "èéêëēĕėęě"},
             {$g, "ĝğġģ"}, {$h, "ĥħ"}, {$i, "ìíîïĩīĭįı"}, {$j, "ĵ"}, {$k, "ķ"},
             {$l, "ĺļľŀł"}, {$n, "ñńņňŉ"}, {$o, "òóôõöōŏő"}, {$r, "ŕŗř"},
             {$s, "śŝşš"}, {$t, "ţťŧ"}, {$u, "ùúûüũūŭůűų"}, {$w, "ŵ"},
             {$y, "ýÿŷ"}, {$z, "źżž"},
             {$A, "ÀÁÂÃÄÅĀĂĄ"}, {$C, "ÇĆĈĊČ"}, {$D, "ĎĐ"}, {$E, "ÈÉÊËĒĔĖĘĚ"},
             {$G, "ĜĞĠĢ"}, {$H, "ĤĦ"}, {$I, "ÌÍÎÏĨĪĬĮİ"}, {$J, "Ĵ"}, {$K, "Ķ"},
             {$L, "ĹĻĽĿŁ"}, {$N, "ÑŃŅŇ"}, {$O, "ÒÓÔÕÖŌŎŐ"}, {$R, "ŔŖŘ"},
             {$S, "ŚŜŞŠ"}, {$T, "ŢŤŦ"}, {$U, "ÙÚÛÜŨŪŬŮŰŲ"}, {$W, "Ŵ"},
             {$Y, "ÝŸŶ"}, {$Z, "ŹŻŽ"}],
    case [B || {B, Cs} <- Table, lists:member(C, Cs)] of
        [B | _] -> B;
        [] -> undefined
    end.

%% @doc GitHub's slug: letters, digits, `-' and `_' lowercased, spaces to
%% dashes, everything else dropped.
-spec urilize_gfm(binary()) -> binary().
urilize_gfm(Text) ->
    Chars = unicode:characters_to_list(Text),
    Out = lists:append([case C of
                            $\s -> "-";
                            _ when C =:= $-; C =:= $_ -> [C];
                            _ -> case beamai_markdown_char:is_alnum(C) orelse (C >= 128 andalso is_letter(C)) of
                                     true -> [lower(C)];
                                     false -> []
                                 end
                        end || C <- Chars]),
    unicode:characters_to_binary(Out).
