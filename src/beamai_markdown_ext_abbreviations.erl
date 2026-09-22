%%%-------------------------------------------------------------------
%%% @doc Abbreviations: `*[HTML]: Hypertext Markup Language' definitions,
%%% after which every whole-word `HTML' in the text renders as
%%% `<abbr title="...">HTML</abbr>'.
%%%
%%% The definition line is consumed by a block start that records it in the
%%% processor's scratch space; a document hook substitutes into every text
%%% node once all inlines exist, longest label first, at word starts, and
%%% only when nothing but punctuation follows before the next whitespace.
%%%
%%% Inline kind: abbr (label, title).
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_ext_abbreviations).

-include("beamai_markdown.hrl").

-export([setup/2, start/1, substitute/3, setup_html/1, render_html/2]).

-spec setup(map(), map()) -> map().
setup(Pipe0, _Opts) ->
    Pipe1 = beamai_markdown_pipeline:add(
              Pipe0, block_parsers, #{name => abbreviation, module => ?MODULE, function => start, chars => [$*]}),
    Pipe2 = beamai_markdown_pipeline:add(
              Pipe1, document_hooks, #{name => abbreviation, module => ?MODULE, function => substitute}),
    beamai_markdown_pipeline:add_renderer_setup(
      Pipe2, html, #{name => abbreviation, module => ?MODULE, function => setup_html}).

-spec start(#bp{}) -> {done, #bp{}} | none.
start(#bp{indented = false, line = Line, next_nonspace = NN, ext = Ext} = Bp) ->
    case beamai_markdown_block:peek(Bp, NN) =:= $* andalso beamai_markdown_scan:link_label(Line, NN + 1) of
        {ok, Raw, End} when Raw =/= <<>> ->
            case beamai_markdown_char:at(Line, End) of
                $: ->
                    Label = beamai_markdown_char:collapse_ws(Raw),
                    Text = beamai_markdown_scan:trim(binary:part(Line, End + 1, byte_size(Line) - End - 1)),
                    Table = maps:get(abbreviations, Ext, #{}),
                    Bp1 = Bp#bp{ext = Ext#{abbreviations => Table#{Label => Text}}},
                    %% No block: the definition line just disappears.
                    {done, beamai_markdown_block:close_unmatched(Bp1)};
                _ -> none
            end;
        _ -> none
    end;
start(_) -> none.

%% @doc After the inline pass: splice abbr inlines into every text node.
-spec substitute(beamai_markdown_block(), map(), map()) -> beamai_markdown_block().
substitute(#{ext := #{abbreviations := Table}} = Doc, _Pipe, _Opts) when map_size(Table) > 0 ->
    Labels = lists:sort(fun(A, B) -> byte_size(A) >= byte_size(B) end, maps:keys(Table)),
    walk(Doc, Table, Labels);
substitute(Doc, _, _) -> Doc.

walk(#{inlines := Inlines} = B, Table, Labels) ->
    walk_children(B#{inlines => lists:append([sub_inline(I, Table, Labels) || I <- Inlines])}, Table, Labels);
walk(B, Table, Labels) -> walk_children(B, Table, Labels).

walk_children(#{children := Ch} = B, Table, Labels) when Ch =/= [] ->
    B#{children => [walk(C, Table, Labels) || C <- Ch]};
walk_children(B, _, _) -> B.

sub_inline(#{k := text, v := V} = T, Table, Labels) ->
    split_text(V, 0, 0, Table, Labels, T, []);
sub_inline(#{children := Ch} = N, Table, Labels) when Ch =/= [] ->
    [N#{children => lists:append([sub_inline(C, Table, Labels) || C <- Ch])}];
sub_inline(N, _, _) -> [N].

%% Scan V from P; Last is the start of the text not yet emitted.
split_text(V, Last, P, _Table, _Labels, T, Acc) when P >= byte_size(V) ->
    lists:reverse(text_node(T, binary:part(V, Last, P - Last), Acc));
split_text(V, Last, P, Table, Labels, T, Acc) ->
    case word_start(V, P) andalso longest(V, P, Labels) of
        false -> split_text(V, Last, P + 1, Table, Labels, T, Acc);
        none -> split_text(V, Last, P + 1, Table, Labels, T, Acc);
        Label ->
            After = P + byte_size(Label),
            case valid_ending(V, After) of
                false -> split_text(V, Last, P + 1, Table, Labels, T, Acc);
                true ->
                    Abbr = #{k => abbr, label => Label, title => maps:get(Label, Table)},
                    Acc1 = [Abbr | text_node(T, binary:part(V, Last, P - Last), Acc)],
                    split_text(V, After, After, Table, Labels, T, Acc1)
            end
    end.

text_node(_, <<>>, Acc) -> Acc;
text_node(T, Bin, Acc) -> [T#{v => Bin} | Acc].

word_start(_, 0) -> true;
word_start(V, P) -> beamai_markdown_char:is_whitespace(beamai_markdown_char:prev(V, P)).

longest(_, _, []) -> none;
longest(V, P, [L | Rest]) ->
    N = byte_size(L),
    case V of
        <<_:P/binary, L:N/binary, _/binary>> -> L;
        _ -> longest(V, P, Rest)
    end.

%% Only punctuation may follow the label before the next whitespace.
valid_ending(V, P) when P >= byte_size(V) -> true;
valid_ending(V, P) ->
    C = beamai_markdown_char:at(V, P),
    case beamai_markdown_char:is_whitespace(C) of
        true -> true;
        false ->
            case beamai_markdown_char:is_ascii_punct(C) of
                true -> valid_ending(V, P + beamai_markdown_char:width(C));
                false -> false
            end
    end.

-spec setup_html(map()) -> map().
setup_html(R) -> beamai_markdown_renderer:set_renderer(R, abbr, {?MODULE, render_html}).

-spec render_html(map(), beamai_markdown_inline()) -> map().
render_html(R, #{label := Label, title := Title} = Node) ->
    Inline = beamai_markdown_renderer:get(R, enable_inline),
    R1 = case Inline of
             true ->
                 A = beamai_markdown_html:write_attributes(beamai_markdown_renderer:write(R, <<"<abbr">>), Node),
                 B = beamai_markdown_html:write_escape(beamai_markdown_renderer:write(A, <<" title=\"">>), Title),
                 beamai_markdown_renderer:write(B, <<"\">">>);
             false -> R
         end,
    R2 = beamai_markdown_renderer:write(R1, Label),
    case Inline of
        true -> beamai_markdown_renderer:write(R2, <<"</abbr>">>);
        false -> R2
    end.
