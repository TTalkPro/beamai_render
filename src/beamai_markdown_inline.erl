%%%-------------------------------------------------------------------
%%% @doc The inline parser: a leaf block's text in, inline nodes out.
%%%
%%% The CommonMark delimiter-stack algorithm, functionally. Parsing pushes
%%% nodes onto a reversed list; emphasis delimiters and link brackets are
%%% ordinary nodes in that list until they are resolved. Resolving a link
%%% splits the list at its bracket; resolving emphasis walks a forward list
%%% with a zipper, which is what makes "the nearest opener below this
%%% closer" a plain search down the left-hand side.
%%%
%%% Inline parsers are registered per trigger character in the pipeline
%%% (`inline_parsers'); the CommonMark ones are in this module. A parser is
%%% `Module:Function(Ip)' returning `{ok, Ip}' or `none'; text between
%%% trigger characters is collected without asking anyone.
%%%
%%% Post-processing (`post_inline') runs once per leaf after parsing:
%%% emphasis pairing is one such processor and the pipe-table extension is
%%% another; they run in registration order.
%%%
%%% Inline fields set here, beyond `k':
%%%   text       v
%%%   code       v
%%%   emph       ch, count, children          (count 1 = em, 2 = strong)
%%%   link       url, title, children, image, ref (when by reference),
%%%              label (the reference label, normalised), raw_label (as
%%%              written), form (full | collapsed | shortcut), inline
%%%              (true for [a](b))
%%%   autolink   url, email
%%%   html       v
%%%   entity     v (decoded), raw
%%%   linebreak  hard, backslash
%%%   delim      ch, count, orig, can_open, can_close      (transient)
%%%   bracket    image, active, bracket_after               (transient)
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_inline).

-include("beamai_markdown.hrl").

-export([process/3, parse/4, parse_reference/2, default_parsers/0,
         default_post/0, post_process_after/3, process_emphasis/2,
         literalize/1, merge_text/1]).
%% For inline parsers.
-export([peek/1, peek/2, prev_char/1, push/2, advance/2, take/2, text/2,
         subject/1, pos/1, set_pos/2, nodes/1, set_nodes/2, last_node/1,
         replace_last/2, pipe/1, opts/1, edit_parent/3, parents/1,
         set_block/2, block/1, add_block_after/2, ext/2, ext/3, set_ext/3]).
%% The CommonMark parsers.
-export([newline/1, backslash/1, backticks/1, delimiter/1, open_bracket/1,
         bang/1, close_bracket/1, angle/1, entity/1, emphasis_post/2]).

%%%===================================================================
%%% Document pass
%%%===================================================================

%% @doc Parse the inline content of every leaf that has some. Refs are the
%% link reference definitions collected by the block pass.
-spec process(beamai_markdown_block(), map(), map()) -> beamai_markdown_block().
process(Doc, Refs, Pipe) ->
    Ctx = #{refs => Refs, pipe => Pipe},
    {[Doc1], _} = walk(Doc, [], Ctx),
    Doc1.

%% Returns the blocks that replace B (usually [B]) and the edits B wants
%% applied to its ancestors, as {Depth, Fun} with Depth relative to B's
%% parent (1 = the parent).
walk(#{k := K} = B, Parents, Ctx) ->
    case maps:get(process_inlines, B, K =:= paragraph orelse K =:= heading) of
        true ->
            Text = leaf_text(B),
            {Inlines, B1, Edits, Extra} = parse(Text, B, Parents, Ctx),
            %% A post-processor may have replaced the leaf with another
            %% kind of block (a table), which has no inlines of its own.
            B2 = case maps:get(k, B1) =:= K of
                     true -> B1#{inlines => Inlines};
                     false -> B1
                 end,
            {[B2 | Extra], Edits};
        false ->
            case maps:get(children, B, []) of
                [] -> {[B], []};
                Ch ->
                    {Groups, EditLists} =
                        lists:unzip([walk(C, [B | Parents], Ctx) || C <- Ch]),
                    B1 = B#{children => lists:append(Groups)},
                    Edits = lists:append(EditLists),
                    Mine = [F || {1, F} <- Edits],
                    Up = [{D - 1, F} || {D, F} <- Edits, D > 1],
                    {[lists:foldl(fun(F, Acc) -> F(Acc) end, B1, Mine)], Up}
            end
    end.

leaf_text(#{k := paragraph, lines := Lines}) ->
    %% Initial and final spaces or tabs are not part of the content.
    string:trim(beamai_markdown_blocks:content(Lines), both, "\s\t");
leaf_text(#{k := heading, lines := Lines}) ->
    string:trim(beamai_markdown_blocks:content(Lines), both, "\s\t");
leaf_text(#{lines := Lines}) ->
    beamai_markdown_blocks:content(Lines).

%% @doc Parse Text as the inline content of Block. Returns the inlines,
%% the block (a post-processor may have replaced it), the ancestor edits
%% and any blocks to insert after it.
-spec parse(binary(), beamai_markdown_block(), [beamai_markdown_block()], map()) ->
          {[beamai_markdown_inline()], beamai_markdown_block(),
           [{pos_integer(), fun((beamai_markdown_block()) -> beamai_markdown_block())}],
           [beamai_markdown_block()]}.
parse(Text, Block, Parents, Ctx) ->
    Pipe = maps:get(pipe, Ctx),
    Ip0 = #ip{src = Text, pos = 0, len = byte_size(Text), refs = maps:get(refs, Ctx, #{}),
              pipe = Pipe, opts = maps:get(opts, Ctx, #{}), block = Block, parents = Parents},
    Ip1 = parse_loop(Ip0),
    Nodes0 = lists:reverse(Ip1#ip.nodes),
    {Nodes1, Ip2} = post_process(maps:get(post_inline, Pipe, default_post()), Nodes0, Ip1),
    Nodes = merge_text(literalize(Nodes1)),
    {Nodes, Ip2#ip.block, lists:reverse(Ip2#ip.parent_edits), Ip2#ip.extra_blocks}.

parse_loop(#ip{pos = P, len = L} = Ip) when P >= L -> Ip;
parse_loop(Ip) ->
    C = peek(Ip),
    Parsers = parsers_for(C, Ip),
    case Parsers of
        [] -> parse_loop(text_run(Ip));
        _ ->
            case try_parsers(Parsers, Ip) of
                {ok, Ip1} -> parse_loop(Ip1);
                none ->
                    %% Nothing claimed the trigger character: it is text.
                    W = beamai_markdown_char:width(C),
                    parse_loop(text(advance(Ip, W), take(Ip, W)))
            end
    end.

try_parsers([], _) -> none;
try_parsers([#{module := M, function := F} | Rest], Ip) ->
    case M:F(Ip) of
        none -> try_parsers(Rest, Ip);
        {ok, _} = Ok -> Ok
    end.

parsers_for(C, #ip{pipe = #{inline_table := Table}}) ->
    maps:get(C, Table, []).

%% Collect text up to the next trigger character.
text_run(#ip{src = Src, pos = P, len = L, pipe = #{inline_triggers := {Pattern, NonAscii}}} = Ip) ->
    W = beamai_markdown_char:width(beamai_markdown_char:at(Src, P)),
    End = scan_text(Src, P + W, L, Pattern, NonAscii),
    text(Ip#ip{pos = End}, binary:part(Src, P, End - P)).

%% The ASCII triggers are found by a BIF; non-ASCII ones (no core parser
%% has any) by decoding the run.
scan_text(Src, P, L, Pattern, []) when P < L ->
    case Pattern =:= none orelse binary:match(Src, Pattern, [{scope, {P, L - P}}]) of
        true -> L;
        nomatch -> L;
        {I, _} -> I
    end;
scan_text(Src, P, L, Pattern, NonAscii) when P < L ->
    Next = case Pattern =:= none orelse binary:match(Src, Pattern, [{scope, {P, L - P}}]) of
               true -> L;
               nomatch -> L;
               {I, _} -> I
           end,
    scan_non_ascii(Src, P, Next, NonAscii);
scan_text(_, _, L, _, _) -> L.

scan_non_ascii(_, P, Next, _) when P >= Next -> Next;
scan_non_ascii(Src, P, Next, NonAscii) ->
    case binary:at(Src, P) of
        C when C < 128 -> scan_non_ascii(Src, P + 1, Next, NonAscii);
        _ ->
            Cp = beamai_markdown_char:at(Src, P),
            case lists:member(Cp, NonAscii) of
                true -> P;
                false -> scan_non_ascii(Src, P + beamai_markdown_char:width(Cp), Next, NonAscii)
            end
    end.

post_process([], Nodes, Ip) -> {Nodes, Ip};
post_process([#{module := M, function := F} | Rest], Nodes, Ip) ->
    {Nodes1, Ip1} = M:F(Nodes, Ip),
    post_process(Rest, Nodes1, Ip1).

%% @doc Run the post-processors registered after Name on Nodes, and finish
%% them: for an extension that carves a leaf into pieces (table cells) and
%% has to process each piece the way the leaf would have been.
-spec post_process_after(atom(), [beamai_markdown_inline()], #ip{}) ->
          {[beamai_markdown_inline()], #ip{}}.
post_process_after(Name, Nodes, #ip{pipe = Pipe} = Ip) ->
    All = maps:get(post_inline, Pipe, default_post()),
    Rest = case lists:dropwhile(fun(#{name := N}) -> N =/= Name end, All) of
               [_ | R] -> R;
               [] -> All
           end,
    {Nodes1, Ip1} = post_process(Rest, Nodes, Ip),
    {merge_text(literalize(Nodes1)), Ip1}.

%% @doc Change an ancestor of the leaf being parsed: Depth 1 is its parent.
%% The edit is applied after the ancestor's whole subtree is processed.
-spec edit_parent(#ip{}, pos_integer(), fun((beamai_markdown_block()) -> beamai_markdown_block())) -> #ip{}.
edit_parent(#ip{parent_edits = E} = Ip, Depth, Fun) ->
    Ip#ip{parent_edits = [{Depth, Fun} | E]}.

%% @doc Extension scratch space for the leaf being parsed.
-spec ext(#ip{}, term()) -> term().
ext(#ip{ext = E}, Key) -> maps:get(Key, E, undefined).

-spec ext(#ip{}, term(), term()) -> term().
ext(#ip{ext = E}, Key, Default) -> maps:get(Key, E, Default).

-spec set_ext(#ip{}, term(), term()) -> #ip{}.
set_ext(#ip{ext = E} = Ip, Key, Value) -> Ip#ip{ext = E#{Key => Value}}.

%% @doc The leaf's ancestors, nearest first.
-spec parents(#ip{}) -> [beamai_markdown_block()].
parents(#ip{parents = P}) -> P.

%% @doc Replace the leaf block being parsed (a paragraph that turned out to
%% be a table).
-spec set_block(#ip{}, beamai_markdown_block()) -> #ip{}.
set_block(Ip, Block) -> Ip#ip{block = Block}.

-spec block(#ip{}) -> beamai_markdown_block().
block(#ip{block = B}) -> B.

%% @doc Insert a block right after the leaf being parsed.
-spec add_block_after(#ip{}, beamai_markdown_block()) -> #ip{}.
add_block_after(#ip{extra_blocks = E} = Ip, Block) -> Ip#ip{extra_blocks = E ++ [Block]}.

%% @doc The CommonMark inline parsers, keyed by trigger character.
-spec default_parsers() -> [map()].
default_parsers() ->
    [#{name => newline,   module => ?MODULE, function => newline,       chars => [$\n]},
     #{name => backslash, module => ?MODULE, function => backslash,     chars => [$\\]},
     #{name => code,      module => ?MODULE, function => backticks,     chars => [$`]},
     #{name => emphasis,  module => ?MODULE, function => delimiter,     chars => [$*, $_]},
     #{name => link,      module => ?MODULE, function => open_bracket,  chars => [$[]},
     #{name => image,     module => ?MODULE, function => bang,          chars => [$!]},
     #{name => link_end,  module => ?MODULE, function => close_bracket, chars => [$]]},
     #{name => angle,     module => ?MODULE, function => angle,         chars => [$<]},
     #{name => entity,    module => ?MODULE, function => entity,        chars => [$&]}].

-spec default_post() -> [map()].
default_post() ->
    [#{name => emphasis, module => ?MODULE, function => emphasis_post}].

%%%===================================================================
%%% State access for parsers
%%%===================================================================

-spec peek(#ip{}) -> char().
peek(#ip{src = S, pos = P}) -> beamai_markdown_char:at(S, P).

-spec peek(#ip{}, integer()) -> char().
peek(#ip{src = S, pos = P}, Off) -> beamai_markdown_char:at(S, P + Off).

%% @doc The character before the current position (NUL at the start).
-spec prev_char(#ip{}) -> char().
prev_char(#ip{src = S, pos = P}) -> beamai_markdown_char:prev(S, P).

-spec advance(#ip{}, integer()) -> #ip{}.
advance(#ip{pos = P} = Ip, N) -> Ip#ip{pos = P + N}.

-spec take(#ip{}, non_neg_integer()) -> binary().
take(#ip{src = S, pos = P, len = L}, N) -> binary:part(S, P, min(N, L - P)).

-spec push(#ip{}, beamai_markdown_inline()) -> #ip{}.
push(#ip{nodes = Ns} = Ip, Node) -> Ip#ip{nodes = [Node | Ns]}.

%% @doc Push a text node, or extend the last one.
-spec text(#ip{}, binary()) -> #ip{}.
text(Ip, <<>>) -> Ip;
text(#ip{nodes = [#{k := text, v := V} = T | Ns]} = Ip, Bin) ->
    Ip#ip{nodes = [T#{v => <<V/binary, Bin/binary>>} | Ns]};
text(Ip, Bin) -> push(Ip, #{k => text, v => Bin}).

-spec subject(#ip{}) -> binary().
subject(#ip{src = S}) -> S.

-spec pos(#ip{}) -> non_neg_integer().
pos(#ip{pos = P}) -> P.

-spec set_pos(#ip{}, non_neg_integer()) -> #ip{}.
set_pos(Ip, P) -> Ip#ip{pos = P}.

-spec nodes(#ip{}) -> [beamai_markdown_inline()].
nodes(#ip{nodes = N}) -> N.

-spec set_nodes(#ip{}, [beamai_markdown_inline()]) -> #ip{}.
set_nodes(Ip, N) -> Ip#ip{nodes = N}.

-spec last_node(#ip{}) -> beamai_markdown_inline() | undefined.
last_node(#ip{nodes = [N | _]}) -> N;
last_node(_) -> undefined.

-spec replace_last(#ip{}, beamai_markdown_inline()) -> #ip{}.
replace_last(#ip{nodes = [_ | Ns]} = Ip, N) -> Ip#ip{nodes = [N | Ns]}.

-spec pipe(#ip{}) -> map().
pipe(#ip{pipe = P}) -> P.

-spec opts(#ip{}) -> map().
opts(#ip{opts = O}) -> O.

%%%===================================================================
%%% Line breaks
%%%===================================================================

-spec newline(#ip{}) -> {ok, #ip{}} | none.
newline(#ip{nodes = Ns} = Ip0) ->
    Ip1 = advance(Ip0, 1),
    {Hard, Ip2} =
        case Ns of
            [#{k := text, v := V} = T | Rest] ->
                Stripped = string:trim(V, trailing, "\s"),
                H = byte_size(V) - byte_size(Stripped) >= 2,
                case Stripped of
                    <<>> -> {H, Ip1#ip{nodes = Rest}};
                    _ -> {H, Ip1#ip{nodes = [T#{v => Stripped} | Rest]}}
                end;
            _ -> {false, Ip1}
        end,
    Hard1 = Hard orelse maps:get(soft_as_hard, Ip0#ip.pipe, false),
    Ip3 = push(Ip2, #{k => linebreak, hard => Hard1, backslash => false}),
    %% Leading spaces of the next line are not content.
    {ok, Ip3#ip{pos = beamai_markdown_scan:skip_spaces(Ip3#ip.src, Ip3#ip.pos)}}.

-spec backslash(#ip{}) -> {ok, #ip{}} | none.
backslash(Ip) ->
    case peek(Ip, 1) of
        $\n ->
            Ip1 = push(advance(Ip, 2), #{k => linebreak, hard => true, backslash => true}),
            {ok, Ip1#ip{pos = beamai_markdown_scan:skip_spaces(Ip1#ip.src, Ip1#ip.pos)}};
        C ->
            case beamai_markdown_char:is_escapable(C) of
                true ->
                    %% Its own text node, marked, so a Markdown renderer
                    %% can put the backslash back.
                    W = beamai_markdown_char:width(C),
                    Node = #{k => text, v => binary:part(Ip#ip.src, Ip#ip.pos + 1, W), escaped => true},
                    {ok, push(advance(Ip, 1 + W), Node)};
                false ->
                    {ok, text(advance(Ip, 1), <<"\\">>)}
            end
    end.

%%%===================================================================
%%% Code spans
%%%===================================================================

-spec backticks(#ip{}) -> {ok, #ip{}} | none.
backticks(#ip{src = Src, pos = P, len = L} = Ip) ->
    N = beamai_markdown_scan:count_char(Src, P, $`),
    case find_closer(Src, P + N, L, N) of
        none ->
            {ok, text(advance(Ip, N), binary:part(Src, P, N))};
        Close ->
            Raw = binary:part(Src, P + N, Close - P - N),
            Content = code_content(Raw),
            Ip1 = push(Ip#ip{pos = Close + N},
                       #{k => code, v => Content, ticks => N}),
            {ok, Ip1}
    end.

find_closer(Src, P, L, N) when P < L ->
    case binary:at(Src, P) of
        $` ->
            M = beamai_markdown_scan:count_char(Src, P, $`),
            case M =:= N of
                true -> P;
                false -> find_closer(Src, P + M, L, N)
            end;
        _ -> find_closer(Src, P + 1, L, N)
    end;
find_closer(_, _, _, _) -> none.

%% Line endings become spaces; one leading and one trailing space go when
%% both are present and the content is not all spaces.
code_content(Raw0) ->
    Raw = binary:replace(Raw0, <<"\n">>, <<" ">>, [global]),
    Size = byte_size(Raw),
    case Size >= 2 andalso binary:first(Raw) =:= $\s andalso binary:last(Raw) =:= $\s
        andalso not all_spaces(Raw) of
        true -> binary:part(Raw, 1, Size - 2);
        false -> Raw
    end.

all_spaces(<<>>) -> true;
all_spaces(<<$\s, R/binary>>) -> all_spaces(R);
all_spaces(_) -> false.

%%%===================================================================
%%% Emphasis delimiters
%%%===================================================================

-spec delimiter(#ip{}) -> {ok, #ip{}} | none.
delimiter(#ip{src = Src, pos = P, pipe = Pipe} = Ip) ->
    Ch = peek(Ip),
    case maps:get(Ch, maps:get(emphasis_descriptors, Pipe), undefined) of
        undefined -> none;
        Desc ->
            W = beamai_markdown_char:width(Ch),
            N = count_cp(Src, P, Ch, W, 0),
            %% Mid-run: an earlier match consumed part of this run and
            %% rejected it; the rest is literal.
            Prev0 = beamai_markdown_char:prev(Src, P),
            MidRun = Prev0 =:= Ch andalso beamai_markdown_char:prev(Src, P - W) =/= $\\,
            case (not MidRun) andalso N >= maps:get(min, Desc) of
                false -> none;
                true ->
                    Prev = prev_for_flanking(Ip, Prev0),
                    Next = next_for_flanking(Src, P + N * W),
                    Within = maps:get(within_word, Desc),
                    {CanOpen, CanClose} =
                        case maps:get(cjk_friendly, Pipe, false) of
                            true -> beamai_markdown_char:flanking_cjk(Prev, Next, Within);
                            false -> beamai_markdown_char:flanking(Prev, Next, Within)
                        end,
                    case CanOpen orelse CanClose of
                        false -> none;
                        true ->
                            D = #{k => delim, ch => Ch, count => N, orig => N,
                                  can_open => CanOpen, can_close => CanClose},
                            {ok, push(Ip#ip{pos = P + N * W}, D)}
                    end
            end
    end.

count_cp(Src, P, Ch, W, N) ->
    case beamai_markdown_char:at(Src, P) of
        Ch -> count_cp(Src, P + W, Ch, W, N + 1);
        _ -> N
    end.

%% The character before a run is read through a preceding entity's decoded
%% text, so `&amp;*foo*' sees `&' and not `;'.
prev_for_flanking(#ip{nodes = [#{k := entity, v := V} | _]}, _) when V =/= <<>> ->
    beamai_markdown_char:prev(V, byte_size(V));
prev_for_flanking(_, Prev) -> Prev.

next_for_flanking(Src, P) ->
    case beamai_markdown_char:at(Src, P) of
        $& ->
            case beamai_markdown_scan:entity(Src, P) of
                {ok, [C | _], _} -> C;
                _ -> $&
            end;
        C -> C
    end.

%% @doc The emphasis post-processor: pair delimiters into emph nodes.
-spec emphasis_post([beamai_markdown_inline()], #ip{}) -> {[beamai_markdown_inline()], #ip{}}.
emphasis_post(Nodes, Ip) ->
    {process_emphasis(Nodes, Ip#ip.pipe), Ip}.

%% @doc CommonMark's process-emphasis over a forward list of nodes.
-spec process_emphasis([beamai_markdown_inline()], map()) -> [beamai_markdown_inline()].
process_emphasis(Nodes, Pipe) ->
    Descs = maps:get(emphasis_descriptors, Pipe),
    Hooks = maps:get(emphasis_hooks, Pipe, []),
    pe(Nodes, [], Descs, Hooks).

pe([], Left, _, _) ->
    lists:reverse(Left);
pe([#{k := delim, can_close := true, ch := Ch} = Closer | Right], Left, Descs, Hooks) ->
    case maps:get(Ch, Descs, undefined) of
        undefined -> pe(Right, [Closer | Left], Descs, Hooks);
        Desc -> closer_loop(Closer, Right, Left, Desc, Descs, Hooks)
    end;
pe([N | Right], Left, Descs, Hooks) ->
    pe(Right, [N | Left], Descs, Hooks).

closer_loop(#{count := Count} = Closer, Right, Left, #{min := Min} = Desc, Descs, Hooks) ->
    case Count < Min of
        true ->
            pe(Right, [Closer | Left], Descs, Hooks);
        false ->
            case find_opener(Left, Closer, Min, []) of
                none ->
                    case maps:get(can_open, Closer) of
                        true -> pe(Right, [Closer | Left], Descs, Hooks);
                        false -> pe(Right, [delim_text(Closer) | Left], Descs, Hooks)
                    end;
                {Between, Opener, Below} ->
                    Delta = lists:min([maps:get(count, Opener), Count, maps:get(max, Desc)]),
                    Children = [literalize_node(N) || N <- lists:reverse(Between)],
                    Emph = make_emphasis(maps:get(ch, Closer), Delta, Children, Closer, Hooks),
                    Opener1 = Opener#{count => maps:get(count, Opener) - Delta},
                    Closer1 = Closer#{count => Count - Delta},
                    Left1 = case maps:get(count, Opener1) of
                                0 -> [Emph | Below];
                                _ -> [Emph, Opener1 | Below]
                            end,
                    case maps:get(count, Closer1) of
                        0 -> pe(Right, Left1, Descs, Hooks);
                        _ -> closer_loop(Closer1, Right, Left1, Desc, Descs, Hooks)
                    end
            end
    end.

%% The nearest opener below the closer that may pair with it: same
%% character, can open, enough characters left, and not an odd match.
find_opener([], _, _, _) -> none;
find_opener([#{k := delim, ch := Ch, can_open := true, count := C} = O | Below], #{ch := Ch} = Closer, Min, Acc)
  when C >= Min ->
    case odd_match(O, Closer) of
        true -> find_opener(Below, Closer, Min, [O | Acc]);
        false -> {lists:reverse(Acc), O, Below}
    end;
find_opener([N | Below], Closer, Min, Acc) ->
    find_opener(Below, Closer, Min, [N | Acc]).

%% The rule of 3, as markdig applies it: on the current run lengths.
odd_match(#{count := OC, can_close := OClose}, #{count := CC, can_open := COpen}) ->
    (COpen orelse OClose) andalso OC =/= CC andalso (OC + CC) rem 3 =:= 0
        andalso not (OC rem 3 =:= 0 andalso CC rem 3 =:= 0).

make_emphasis(Ch, Delta, Children, Closer, Hooks) ->
    Base = #{k => emph, ch => Ch, count => Delta, children => Children},
    Base1 = case maps:get(attrs, Closer, undefined) of
                undefined -> Base;
                A -> Base#{attrs => A}
            end,
    hook_emphasis(Hooks, Ch, Delta, Base1).

hook_emphasis([], _, _, Base) -> Base;
hook_emphasis([#{module := M, function := F} | Rest], Ch, Delta, Base) ->
    case M:F(Ch, Delta, Base) of
        none -> hook_emphasis(Rest, Ch, Delta, Base);
        Node -> Node
    end.

delim_text(#{ch := Ch, count := N}) ->
    #{k => text, v => binary:copy(<<Ch/utf8>>, N)}.

%% @doc Turn every unresolved delimiter and bracket into text.
-spec literalize([beamai_markdown_inline()]) -> [beamai_markdown_inline()].
literalize(Nodes) -> [literalize_node(N) || N <- Nodes].

literalize_node(#{k := delim} = D) -> delim_text(D);
literalize_node(#{k := bracket, v := V}) -> #{k => text, v => V};
literalize_node(#{transient := true, literal := L}) -> #{k => text, v => L};
literalize_node(N) -> N.

%% @doc Merge adjacent text nodes.
-spec merge_text([beamai_markdown_inline()]) -> [beamai_markdown_inline()].
merge_text([#{k := text, v := A} = T, #{k := text, v := B} = U | Rest])
  when not is_map_key(attrs, T), not is_map_key(attrs, U), not is_map_key(escaped, U) ->
    merge_text([T#{v => <<A/binary, B/binary>>} | Rest]);
merge_text([N | Rest]) -> [N | merge_text(Rest)];
merge_text([]) -> [].

%%%===================================================================
%%% Links
%%%===================================================================

-spec open_bracket(#ip{}) -> {ok, #ip{}} | none.
open_bracket(#ip{pos = P} = Ip) ->
    B = #{k => bracket, image => false, active => true, bracket_after => false,
          v => <<"[">>, index => P + 1},
    {ok, push(mark_bracket_after(advance(Ip, 1)), B)}.

-spec bang(#ip{}) -> {ok, #ip{}} | none.
bang(#ip{pos = P} = Ip) ->
    case peek(Ip, 1) of
        $[ ->
            B = #{k => bracket, image => true, active => true, bracket_after => false,
                  v => <<"![">>, index => P + 2},
            {ok, push(mark_bracket_after(advance(Ip, 2)), B)};
        _ -> none
    end.

%% The nearest existing bracket learns that another opened after it.
mark_bracket_after(#ip{nodes = Ns} = Ip) ->
    Ip#ip{nodes = mark_bracket_after(Ns, [])}.

mark_bracket_after([], Acc) -> lists:reverse(Acc);
mark_bracket_after([#{k := bracket} = B | Rest], Acc) ->
    lists:reverse(Acc, [B#{bracket_after => true} | Rest]);
mark_bracket_after([N | Rest], Acc) -> mark_bracket_after(Rest, [N | Acc]).

-spec close_bracket(#ip{}) -> {ok, #ip{}} | none.
close_bracket(#ip{src = Src, nodes = Ns} = Ip0) ->
    Ip1 = advance(Ip0, 1),
    StartPos = Ip1#ip.pos,
    case split_at_bracket(Ns, []) of
        none ->
            {ok, text(Ip1, <<"]">>)};
        {_InnerRev, #{active := false}, _RestRev} ->
            {ok, text(remove_bracket(Ip1), <<"]">>)};
        {InnerRev, Opener, RestRev} ->
            case inline_link(Src, StartPos) of
                {ok, Url, Title, End} ->
                    finish_link(Ip1#ip{pos = End}, InnerRev, Opener, RestRev,
                                #{url => Url, title => Title, inline => true});
                none ->
                    case reference_link(Ip1, Opener, StartPos) of
                        {ok, Def, End} ->
                            finish_link(Ip1#ip{pos = End}, InnerRev, Opener, RestRev,
                                        #{url => maps:get(url, Def), title => maps:get(title, Def),
                                          ref => true, label => maps:get(label, Def, undefined),
                                          raw_label => maps:get(link_label, Def),
                                          form => maps:get(form, Def), def => Def});
                        none ->
                            {ok, text(remove_bracket(Ip1), <<"]">>)}
                    end
            end
    end.

%% Split the reversed node list at the nearest bracket.
split_at_bracket([], _) -> none;
split_at_bracket([#{k := bracket} = B | Rest], Acc) -> {lists:reverse(Acc), B, Rest};
split_at_bracket([N | Rest], Acc) -> split_at_bracket(Rest, [N | Acc]).

%% The nearest bracket becomes the text it was.
remove_bracket(#ip{nodes = Ns} = Ip) ->
    Ip#ip{nodes = remove_bracket(Ns, [])}.

remove_bracket([], Acc) -> lists:reverse(Acc);
remove_bracket([#{k := bracket, v := V} | Rest], Acc) ->
    lists:reverse(Acc, [#{k => text, v => V} | Rest]);
remove_bracket([N | Rest], Acc) -> remove_bracket(Rest, [N | Acc]).

finish_link(#ip{pipe = Pipe} = Ip, InnerRev, Opener, RestRev, Fields) ->
    Children = merge_text(literalize(process_emphasis(lists:reverse(InnerRev), Pipe))),
    Image = maps:get(image, Opener),
    Link = Fields#{k => link, image => Image, children => Children},
    Rest = case Image of
               true -> RestRev;
               %% A link may not contain a link: deactivate every open
               %% bracket before this one.
               false -> [deactivate(N) || N <- RestRev]
           end,
    Link1 = case Ip#ip.pipe of
                #{link_hooks := Hooks} when Hooks =/= [] -> run_link_hooks(Hooks, Link, Opener, Ip);
                _ -> Link
            end,
    {ok, Ip#ip{nodes = [Link1 | Rest]}}.

deactivate(#{k := bracket, image := false} = B) -> B#{active => false};
deactivate(N) -> N.

run_link_hooks([], Link, _, _) -> Link;
run_link_hooks([#{module := M, function := F} | Rest], Link, Opener, Ip) ->
    run_link_hooks(Rest, M:F(Link, Opener, Ip), Opener, Ip).

%% `(dest "title")' right after the `]'.
inline_link(Src, P) ->
    case beamai_markdown_char:at(Src, P) of
        $( ->
            {P1, _} = beamai_markdown_scan:skip_whitespace_lines(Src, P + 1),
            case link_destination(Src, P1) of
                none -> none;
                {ok, Dest, P2} ->
                    {P3, _} = beamai_markdown_scan:skip_whitespace_lines(Src, P2),
                    {Title, P4} =
                        case P3 > P2 andalso beamai_markdown_scan:link_title(Src, P3) of
                            {ok, T, TP} ->
                                {P5, _} = beamai_markdown_scan:skip_whitespace_lines(Src, TP),
                                {beamai_markdown_scan:unescape(T), P5};
                            _ -> {undefined, P3}
                        end,
                    case beamai_markdown_char:at(Src, P4) of
                        $) -> {ok, Dest, Title, P4 + 1};
                        _ when Title =/= undefined ->
                            %% A title that is not followed by `)' is no
                            %% title; but the destination might still be
                            %% followed by `)' -- it is not, or we would
                            %% not be here.
                            none;
                        _ -> none
                    end
            end;
        _ -> none
    end.

link_destination(Src, P) ->
    case beamai_markdown_scan:link_destination(Src, P) of
        none -> none;
        {ok, <<>>, End} ->
            %% An empty bare destination is only allowed right before `)'.
            case beamai_markdown_char:at(Src, P) =:= $< orelse beamai_markdown_char:at(Src, End) =:= $) of
                true -> {ok, <<>>, End};
                false -> none
            end;
        {ok, Raw, End} -> {ok, beamai_markdown_scan:unescape(Raw), End}
    end.

%% `[label]', `[]' or nothing after the `]', resolved against the refs.
%% Returns the definition with the link's own form recorded: `full',
%% `collapsed' ([]) or `shortcut' (nothing).
reference_link(#ip{src = Src, refs = Refs}, Opener, StartPos) ->
    {RawLabel, End, Form} =
        case beamai_markdown_scan:link_label(Src, StartPos) of
            {ok, L, E} when byte_size(L) > 0 -> {L, E, full};
            Other ->
                {E, F} = case Other of
                             {ok, _, E0} -> {E0, collapsed};
                             none -> {StartPos, shortcut}
                         end,
                case maps:get(bracket_after, Opener) of
                    true -> {none, E, F};
                    false ->
                        Idx = maps:get(index, Opener),
                        {binary:part(Src, Idx, StartPos - 1 - Idx), E, F}
                end
        end,
    case RawLabel of
        none -> none;
        _ ->
            Label = beamai_markdown_char:fold_label(RawLabel),
            case Label =/= <<>> andalso maps:find(Label, Refs) of
                {ok, Def} -> {ok, Def#{form => Form, link_label => RawLabel}, End};
                _ -> none
            end
    end.

%% @doc A link reference definition at Pos in Text. Returns
%% {ok, #{label, raw_label, url, title}, EndPos}.
-spec parse_reference(binary(), non_neg_integer()) ->
          {ok, map(), non_neg_integer()} | none.
parse_reference(Src, P0) ->
    case beamai_markdown_scan:link_label(Src, P0) of
        none -> none;
        {ok, RawLabel, P1} ->
            case beamai_markdown_char:at(Src, P1) of
                $: ->
                    {P2, _} = beamai_markdown_scan:skip_whitespace_lines(Src, P1 + 1),
                    case ref_destination(Src, P2) of
                        none -> none;
                        {ok, Dest, P3} ->
                            {P4, NL} = beamai_markdown_scan:skip_whitespace_lines(Src, P3),
                            %% A title has to end its line; one that does
                            %% not is not a title, and the definition may
                            %% still be valid without it.
                            TitleEnd =
                                case P4 > P3 andalso NL =< 1 andalso
                                    beamai_markdown_scan:link_title(Src, P4) of
                                    {ok, T, TP} ->
                                        case at_line_end(Src, TP) of
                                            {true, E} -> {beamai_markdown_scan:unescape(T), E};
                                            false -> at_line_end(Src, P3)
                                        end;
                                    _ -> at_line_end(Src, P3)
                                end,
                            case TitleEnd of
                                false -> none;
                                {true, End} -> ref_done(RawLabel, Dest, <<>>, End);
                                {Title, End} -> ref_done(RawLabel, Dest, Title, End)
                            end
                    end;
                _ -> none
            end
    end.

ref_done(RawLabel, Dest, Title, End) ->
    Label = beamai_markdown_char:fold_label(RawLabel),
    case Label of
        <<>> -> none;
        _ -> {ok, #{label => Label, raw_label => RawLabel, url => Dest, title => Title}, End}
    end.

ref_destination(Src, P) ->
    case beamai_markdown_scan:link_destination(Src, P) of
        none -> none;
        {ok, <<>>, End} ->
            case beamai_markdown_char:at(Src, P) of
                $< -> {ok, <<>>, End};
                _ -> none
            end;
        {ok, Raw, End} -> {ok, beamai_markdown_scan:unescape(Raw), End}
    end.

%% Only spaces or tabs up to the end of the line; returns the offset past
%% the line ending (or the end of the text).
at_line_end(Src, P) ->
    P1 = beamai_markdown_scan:skip_spaces(Src, P),
    case beamai_markdown_char:at(Src, P1) of
        ?NUL when P1 >= byte_size(Src) -> {true, P1};
        $\n -> {true, P1 + 1};
        _ -> false
    end.

%%%===================================================================
%%% Autolinks, raw HTML, entities
%%%===================================================================

-spec angle(#ip{}) -> {ok, #ip{}} | none.
angle(#ip{src = Src, pos = P} = Ip) ->
    case autolink(Src, P) of
        {ok, Node, End} -> {ok, push(Ip#ip{pos = End}, Node)};
        none ->
            case maps:get(parse_html_inline, Ip#ip.pipe, true) andalso
                beamai_markdown_scan:html_tag(Src, P) of
                {ok, End} ->
                    {ok, push(Ip#ip{pos = End}, #{k => html, v => binary:part(Src, P, End - P)})};
                _ -> none
            end
    end.

autolink(Src, P) ->
    case uri_autolink(Src, P + 1) of
        {ok, End} ->
            Url = binary:part(Src, P + 1, End - P - 1),
            {ok, #{k => autolink, url => Url, email => false}, End + 1};
        none ->
            case email_autolink(Src, P + 1) of
                {ok, End} ->
                    Url = binary:part(Src, P + 1, End - P - 1),
                    {ok, #{k => autolink, url => Url, email => true}, End + 1};
                none -> none
            end
    end.

%% scheme ":" then anything but space, control, < and >, closed by >.
uri_autolink(Src, P) ->
    case beamai_markdown_char:is_alpha(beamai_markdown_char:at(Src, P)) of
        false -> none;
        true ->
            case scheme_end(Src, P + 1, 1) of
                none -> none;
                Colon -> uri_body(Src, Colon + 1)
            end
    end.

scheme_end(Src, P, N) when N =< 32 ->
    C = beamai_markdown_char:at(Src, P),
    if C =:= $:, N >= 2 -> P;
       true ->
            case beamai_markdown_char:is_alnum(C) orelse C =:= $+ orelse C =:= $. orelse C =:= $- of
                true -> scheme_end(Src, P + 1, N + 1);
                false -> none
            end
    end;
scheme_end(_, _, _) -> none.

uri_body(Src, P) ->
    case beamai_markdown_char:at(Src, P) of
        $> -> {ok, P};
        C when C =< 32; C =:= $<; C =:= 127 -> none;
        C -> uri_body(Src, P + beamai_markdown_char:width(C))
    end.

%% [a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*
email_autolink(Src, P) ->
    case email_local(Src, P, 0) of
        none -> none;
        At ->
            case email_domain(Src, At + 1) of
                none -> none;
                End ->
                    case beamai_markdown_char:at(Src, End) of
                        $> when End > At + 1 -> {ok, End};
                        _ -> none
                    end
            end
    end.

email_local(Src, P, N) ->
    C = beamai_markdown_char:at(Src, P),
    case C =:= $@ of
        true when N > 0 -> P;
        true -> none;
        false ->
            case beamai_markdown_char:is_alnum(C) orelse lists:member(C, ".!#$%&'*+/=?^_`{|}~-") of
                true -> email_local(Src, P + 1, N + 1);
                false -> none
            end
    end.

email_domain(Src, P) ->
    case email_label(Src, P) of
        none -> none;
        End ->
            case beamai_markdown_char:at(Src, End) of
                $. -> email_domain(Src, End + 1);
                _ -> End
            end
    end.

%% [a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?
email_label(Src, P) ->
    case beamai_markdown_char:is_alnum(beamai_markdown_char:at(Src, P)) of
        false -> none;
        true -> email_label_rest(Src, P + 1, P, 0)
    end.

email_label_rest(Src, P, LastAlnum, N) when N < 62 ->
    C = beamai_markdown_char:at(Src, P),
    case beamai_markdown_char:is_alnum(C) of
        true -> email_label_rest(Src, P + 1, P, N + 1);
        false when C =:= $- -> email_label_rest(Src, P + 1, LastAlnum, N + 1);
        false -> LastAlnum + 1
    end;
email_label_rest(_, _, LastAlnum, _) -> LastAlnum + 1.

-spec entity(#ip{}) -> {ok, #ip{}} | none.
entity(#ip{src = Src, pos = P} = Ip) ->
    case beamai_markdown_scan:entity(Src, P) of
        {ok, Cps, End} ->
            Node = #{k => entity, v => unicode:characters_to_binary(Cps),
                     raw => binary:part(Src, P, End - P)},
            {ok, push(Ip#ip{pos = End}, Node)};
        none -> none
    end.
