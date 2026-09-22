%%%-------------------------------------------------------------------
%%% @doc Generic attributes: `{#id .class key=value}'.
%%%
%%% Port of markdig's GenericAttributes extension. An inline parser ahead
%%% of every other consumes the group and attaches it to the preceding
%%% inline (or to the block when the preceding inline is text), or -- when
%%% a paragraph holds nothing but the group -- to the next block, after
%%% which that paragraph evaporates. Headings and fences also get a hook
%%% that cuts a group off their first line at parse time.
%%%
%%% Register it after the extensions whose blocks it should hook.
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_ext_generic_attributes).

-include("beamai_markdown.hrl").

-export([setup/2, match/1, try_parse/2, block_hook/2]).

-spec setup(map(), map()) -> map().
setup(Pipe0, _Opts) ->
    Entry = #{name => generic_attributes, module => ?MODULE, function => match, chars => [${]},
    Others = [E || #{name := N} = E <- beamai_markdown_pipeline:get(Pipe0, inline_parsers),
                   N =/= generic_attributes],
    Pipe1 = beamai_markdown_pipeline:set(Pipe0, inline_parsers, [Entry | Others]),
    beamai_markdown_pipeline:set(Pipe1, block_attributes, {?MODULE, block_hook}).

%%%===================================================================
%%% Inline parser
%%%===================================================================

-spec match(#ip{}) -> {ok, #ip{}} | none.
match(#ip{src = Src, pos = P} = Ip) ->
    case try_parse(Src, P) of
        none -> none;
        {ok, Attrs, End} ->
            Ip1 = beamai_markdown_inline:set_pos(Ip, End),
            {ok, attach(Ip1, Attrs)}
    end.

%% The preceding inline, unless it is text: text belongs to whatever
%% encloses it, which here is the block.
attach(#ip{nodes = [#{k := text} | _]} = Ip, Attrs) ->
    attach_to_block(Ip, Attrs);
attach(#ip{nodes = [Last | Rest]} = Ip, Attrs) ->
    Ip#ip{nodes = [merge(Last, Attrs) | Rest]};
attach(Ip, Attrs) ->
    attach_to_block(Ip, Attrs).

%% A paragraph holding nothing but the group binds it to the next block.
attach_to_block(#ip{nodes = [], block = #{k := paragraph, line := L, col := C} = B, src = Src, pos = P} = Ip, Attrs) ->
    case beamai_markdown_scan:trim(binary:part(Src, P, byte_size(Src) - P)) =:= <<>> of
        true ->
            Ip1 = beamai_markdown_inline:edit_parent(Ip, 1, fun(Parent) -> move_to_next(Parent, L, C, Attrs) end),
            %% The block still gets them, in case there is no next block.
            Ip1#ip{block = merge(B, Attrs)};
        false ->
            Ip#ip{block = merge(B, Attrs)}
    end;
attach_to_block(#ip{block = B} = Ip, Attrs) ->
    Ip#ip{block = merge(B, Attrs)}.

%% Drop the standalone paragraph at {L, C} and give its attributes to the
%% block after it, if any.
move_to_next(#{children := Ch} = Parent, L, C, Attrs) ->
    case lists:splitwith(fun(#{line := L1, col := C1, k := K}) ->
                                 not (K =:= paragraph andalso L1 =:= L andalso C1 =:= C)
                         end, Ch) of
        {Before, [_Para, Next | After]} ->
            Parent#{children => Before ++ [merge(Next, Attrs) | After]};
        _ -> Parent
    end.

merge(Node, Attrs) ->
    beamai_markdown_attrs:set(Node, beamai_markdown_attrs:merge(beamai_markdown_attrs:attrs(Node), Attrs)).

%%%===================================================================
%%% Block hook
%%%===================================================================

%% @doc Cut a `{...}' group off Line (a heading or fence line) and attach
%% it to Block.
-spec block_hook(binary(), beamai_markdown_block()) -> {binary(), beamai_markdown_block()}.
block_hook(Line, Block) ->
    case binary:match(Line, <<"{">>) of
        nomatch -> {Line, Block};
        {I, _} ->
            case try_parse(Line, I) of
                none -> {Line, Block};
                {ok, Attrs, _End} -> {binary:part(Line, 0, I), merge(Block, Attrs)}
            end
    end.

%%%===================================================================
%%% The scanner
%%%===================================================================

%% @doc Parse a `{#id .class key=value ...}' group at Pos (on the `{').
%% Returns {ok, Attrs, EndPos} with EndPos past the `}' and one following
%% line ending; `none' leaves nothing changed.
-spec try_parse(binary(), non_neg_integer()) -> {ok, beamai_markdown_attrs(), non_neg_integer()} | none.
try_parse(Src, Pos) ->
    case beamai_markdown_char:at(Src, Pos) =:= ${ andalso beamai_markdown_char:prev(Src, Pos) =/= ${ of
        false -> none;
        true -> scan(Src, Pos + 1, #{classes => [], props => []})
    end.

scan(Src, P, Acc) ->
    C = beamai_markdown_char:at(Src, P),
    case C of
        $} -> {ok, finish(Acc), skip_close(Src, P + 1)};
        ?NUL when P >= byte_size(Src) -> none;
        _ when C =:= $#; C =:= $. ->
            case id_or_class(Src, P + 1, C, Acc) of
                none -> none;
                {P1, Acc1} -> scan(Src, P1, Acc1)
            end;
        _ ->
            case beamai_markdown_char:is_whitespace(C) of
                true -> scan(Src, P + beamai_markdown_char:width(C), Acc);
                false ->
                    case property(Src, P, Acc) of
                        none -> none;
                        {P1, Acc1} -> scan(Src, P1, Acc1)
                    end
            end
    end.

skip_close(Src, P) ->
    case Src of
        <<_:P/binary, "\r\n", _/binary>> -> P + 2;
        <<_:P/binary, "\n", _/binary>> -> P + 1;
        _ -> P
    end.

finish(#{classes := Cs, props := Ps} = Acc) ->
    A = #{classes => lists:reverse(Cs), props => lists:reverse(Ps)},
    case Acc of
        #{id := Id} -> A#{id => Id};
        _ -> A
    end.

id_or_class(Src, Start, C, Acc) ->
    End = name_end(Src, Start),
    case End =:= Start of
        true -> none;
        false ->
            Name = binary:part(Src, Start, End - Start),
            case C of
                $. -> {End, Acc#{classes => [Name | maps:get(classes, Acc)]}};
                $# -> {End, Acc#{id => Name}}
            end
    end.

%% Up to `}', whitespace or the end.
name_end(Src, P) ->
    C = beamai_markdown_char:at(Src, P),
    case C =:= $} orelse (C =:= ?NUL andalso P >= byte_size(Src)) orelse beamai_markdown_char:is_whitespace(C) of
        true -> P;
        false -> name_end(Src, P + beamai_markdown_char:width(C))
    end.

property(Src, P, Acc) ->
    C = beamai_markdown_char:at(Src, P),
    case beamai_markdown_char:is_alpha(C) orelse C =:= $_ orelse C =:= $: of
        false -> none;
        true ->
            End = attr_name_end(Src, P + 1),
            Name = binary:part(Src, P, End - P),
            PrecededBySpace = beamai_markdown_char:is_space_or_tab(beamai_markdown_char:at(Src, End)),
            P1 = beamai_markdown_scan:skip_spaces(Src, End),
            C1 = beamai_markdown_char:at(Src, P1),
            Boolean = C1 =:= $} orelse
                (PrecededBySpace andalso (C1 =:= $. orelse C1 =:= $# orelse C1 =:= $_ orelse C1 =:= $:
                                          orelse beamai_markdown_char:is_alpha(C1))),
            case Boolean of
                true -> {P1, Acc#{props => [{Name, <<>>} | maps:get(props, Acc)]}};
                false ->
                    case C1 of
                        $= ->
                            P2 = beamai_markdown_scan:skip_spaces(Src, P1 + 1),
                            case value(Src, P2) of
                                none -> none;
                                {V, P3} -> {P3, Acc#{props => [{Name, V} | maps:get(props, Acc)]}}
                            end;
                        _ -> none
                    end
            end
    end.

attr_name_end(Src, P) ->
    case beamai_markdown_char:is_attr_name_char(beamai_markdown_char:at(Src, P)) of
        true -> attr_name_end(Src, P + 1);
        false -> P
    end.

value(Src, P) ->
    case beamai_markdown_char:at(Src, P) of
        Q when Q =:= $'; Q =:= $" ->
            case beamai_markdown_scan:find(Src, P + 1, <<Q>>) of
                none -> none;
                End -> {binary:part(Src, P + 1, End - P - 1), End + 1}
            end;
        _ ->
            End = bare_end(Src, P),
            case End =:= P orelse End >= byte_size(Src) of
                true when End >= byte_size(Src) -> none;
                true -> none;
                false -> {binary:part(Src, P, End - P), End}
            end
    end.

bare_end(Src, P) ->
    C = beamai_markdown_char:at(Src, P),
    case (C =:= ?NUL andalso P >= byte_size(Src)) orelse C =:= $} orelse beamai_markdown_char:is_whitespace(C) of
        true -> P;
        false -> bare_end(Src, P + beamai_markdown_char:width(C))
    end.
