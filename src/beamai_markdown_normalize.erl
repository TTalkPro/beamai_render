%%%-------------------------------------------------------------------
%%% @doc The normalize renderer: the document back as canonical Markdown.
%%%
%%% Port of markdig's NormalizeRenderer. ATX headings, `#'-run and
%%% fence lengths as parsed, bullets as written (or `list_item_character'),
%%% ordered lists renumbered from their start, link reference definitions
%%% collected into a group at the end of the document.
%%%
%%% Options: space_after_quote_block (true), empty_line_after_code_block
%%% (true), empty_line_after_heading (true),
%%% empty_line_after_thematic_break (true), list_item_character (undefined),
%%% expand_auto_links (true).
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_normalize).

-include("beamai_markdown.hrl").

-import(beamai_markdown_renderer,
        [write/2, write_raw/2, write_line/1, write_line/2, ensure_line/1,
         write_children/2, write_leaf_inline/2, write_repeat/3, is_last/1,
         push_indent/2, pop_indent/1, get/2, get/3, set/3]).

-export([render/3, new/2, renderers/0, finish_block/2, write_leaf_raw_lines/3,
         write_leaf_raw_lines/4]).
-export([code_block/2, heading/2, html_block/2, list/2, paragraph/2, quote/2,
         thematic_break/2, link_ref_def/2, lrd_group/2, autolink/2, code/2, emph/2,
         linebreak/2, html/2, entity/2, link/2, text/2, ignore/2]).

-spec render(beamai_markdown_block(), map(), map()) -> binary().
render(Doc, Pipe, Opts) ->
    R = new(Pipe, Opts),
    %% Link reference definitions go in one group at the very end, in
    %% parse order.
    {Doc1, Refs} = pull_refs(Doc),
    Doc2 = case Refs of
               [] -> Doc1;
               _ -> Doc1#{children => maps:get(children, Doc1) ++ [#{k => lrd_group, children => Refs}]}
           end,
    beamai_markdown_renderer:finish(beamai_markdown_renderer:render(R, Doc2)).

pull_refs(#{children := Ch} = B) ->
    {Kept, Refs} = lists:foldl(
                     fun(#{k := link_ref_def} = D, {K, R}) -> {K, R ++ [D]};
                        (C, {K, R}) ->
                             {C1, R1} = pull_refs(C),
                             {K ++ [C1], R ++ R1}
                     end, {[], []}, Ch),
    {B#{children => Kept}, Refs};
pull_refs(B) -> {B, []}.

-spec new(map(), map()) -> beamai_markdown_renderer:renderer().
new(Pipe, Opts) ->
    R0 = beamai_markdown_renderer:new(normalize, renderers(), Pipe, Opts),
    Defaults = #{space_after_quote_block => true, empty_line_after_code_block => true,
                 empty_line_after_heading => true, empty_line_after_thematic_break => true,
                 list_item_character => undefined, expand_auto_links => true,
                 compact_paragraph => false},
    maps:merge(maps:merge(Defaults, R0), maps:with(maps:keys(Defaults), Opts)).

-spec renderers() -> map().
renderers() ->
    #{indented_code => {?MODULE, code_block},
      fenced_code => {?MODULE, code_block},
      heading => {?MODULE, heading},
      html_block => {?MODULE, html_block},
      list => {?MODULE, list},
      paragraph => {?MODULE, paragraph},
      quote => {?MODULE, quote},
      alert => {?MODULE, quote},
      thematic_break => {?MODULE, thematic_break},
      link_ref_def => {?MODULE, link_ref_def},
      lrd_group => {?MODULE, lrd_group},
      yaml_front_matter => {?MODULE, ignore},
      autolink => {?MODULE, autolink},
      code => {?MODULE, code},
      emph => {?MODULE, emph},
      linebreak => {?MODULE, linebreak},
      html => {?MODULE, html},
      entity => {?MODULE, entity},
      link => {?MODULE, link},
      text => {?MODULE, text},
      emoji => {?MODULE, text}}.

%% @doc End-of-block newline handling: nothing after a container's last
%% child.
-spec finish_block(map(), boolean()) -> map().
finish_block(R, EmptyLine) ->
    case is_last(R) of
        true -> R;
        false ->
            R1 = write_line(R),
            case EmptyLine of
                true -> write_line(R1);
                false -> R1
            end
    end.

-spec write_leaf_raw_lines(map(), beamai_markdown_block(), boolean()) -> map().
write_leaf_raw_lines(R, Block, Terminated) -> write_leaf_raw_lines(R, Block, Terminated, false).

%% @doc Raw lines; Indent prepends four spaces per line.
-spec write_leaf_raw_lines(map(), beamai_markdown_block(), boolean(), boolean()) -> map().
write_leaf_raw_lines(R, #{lines := Lines}, Terminated, Indent) ->
    lists:foldl(fun({{T, _, _}, I}, Acc0) ->
                        Acc1 = case (not Terminated) andalso I > 1 of
                                   true -> write_line(Acc0);
                                   false -> Acc0
                               end,
                        Acc2 = case Indent of true -> write(Acc1, <<"    ">>); false -> Acc1 end,
                        Acc3 = write(Acc2, T),
                        case Terminated of true -> write_line(Acc3); false -> Acc3 end
                end, R, lists:zip(Lines, lists:seq(1, length(Lines))));
write_leaf_raw_lines(R, _, _, _) -> R.

%%%===================================================================
%%% Blocks
%%%===================================================================

-spec code_block(map(), beamai_markdown_block()) -> map().
code_block(R, #{k := fenced_code, fence_char := C, fence_len := N} = B) ->
    Count = min(N, maps:get(closing_count, B, N)),
    R1 = write_repeat(R, C, Count),
    R2 = write(R1, maps:get(info, B, <<>>)),
    R3 = case maps:get(arguments, B, <<>>) of
             <<>> -> R2;
             Args -> write(write(R2, <<" ">>), Args)
         end,
    R4 = write_leaf_raw_lines(write_line(R3), B, true),
    finish_block(write_repeat(R4, C, Count), get(R, empty_line_after_code_block));
code_block(R, B) ->
    finish_block(write_leaf_raw_lines(R, B, false, true), get(R, empty_line_after_code_block)).

-spec heading(map(), beamai_markdown_block()) -> map().
heading(R, #{level := L} = B) ->
    R1 = write(write_repeat(R, $#, L), <<" ">>),
    finish_block(write_leaf_inline(R1, B), get(R, empty_line_after_heading)).

-spec html_block(map(), beamai_markdown_block()) -> map().
html_block(R, B) -> write_leaf_raw_lines(R, B, true).

-spec list(map(), beamai_markdown_block()) -> map().
list(R0, #{ordered := Ordered, children := Items} = L) ->
    R = ensure_line(R0),
    Saved = get(R, compact_paragraph),
    Loose = not maps:get(tight, L, true),
    R1 = set(R, compact_paragraph, not Loose),
    N = length(Items),
    Start = case Ordered andalso maps:get(bullet_char, L) =:= $1 of
                true -> maps:get(start, L, 1);
                false -> 0
            end,
    Bullet = case get(R, list_item_character) of
                 undefined -> <<(maps:get(bullet_char, L))>>;
                 C -> <<C>>
             end,
    {R2, _} = lists:foldl(
                fun({I, Item}, {Acc, Index}) ->
                        A1 = ensure_line(Acc),
                        {A2, Indent} =
                            case Ordered of
                                true ->
                                    Is = integer_to_binary(Index),
                                    {write(write(write(A1, Is), <<(maps:get(delimiter, L))>>), <<" ">>),
                                     binary:copy(<<" ">>, byte_size(Is) + 2)};
                                false ->
                                    {write(write(A1, Bullet), <<" ">>), <<"  ">>}
                            end,
                        A3 = pop_indent(write_children(push_indent(A2, Indent), Item)),
                        A4 = case I < N andalso Loose of
                                 true -> write_line(ensure_line(A3));
                                 false -> A3
                             end,
                        Next = case Ordered andalso maps:get(bullet_char, L) =:= $1 of
                                   true -> Index + 1;
                                   false -> Index
                               end,
                        {A4, Next}
                end, {R1, Start}, lists:zip(lists:seq(1, N), Items)),
    finish_block(set(R2, compact_paragraph, Saved), true).

-spec paragraph(map(), beamai_markdown_block()) -> map().
paragraph(R, B) ->
    finish_block(write_leaf_inline(R, B), not get(R, compact_paragraph)).

-spec quote(map(), beamai_markdown_block()) -> map().
quote(R, B) ->
    Ch = <<(maps:get(ch, B, $>))>>,
    Indent = case get(R, space_after_quote_block) of
                 true -> <<Ch/binary, " ">>;
                 false -> Ch
             end,
    R1 = pop_indent(write_children(push_indent(R, Indent), B)),
    finish_block(R1, true).

-spec thematic_break(map(), beamai_markdown_block()) -> map().
thematic_break(R, B) ->
    R1 = write_line(R, binary:copy(<<(maps:get(ch, B, $*))>>, maps:get(count, B, 3))),
    finish_block(R1, get(R, empty_line_after_thematic_break)).

-spec lrd_group(map(), beamai_markdown_block()) -> map().
lrd_group(R, B) ->
    finish_block(write_children(ensure_line(R), B), false).

-spec link_ref_def(map(), beamai_markdown_block()) -> map().
link_ref_def(R, #{raw_label := Label, url := Url, title := Title}) ->
    R1 = write(write(write(ensure_line(R), <<"[">>), Label), <<"]: ">>),
    R2 = write(R1, Url),
    R3 = case Title of
             <<>> -> R2;
             _ -> write(write(write(R2, <<" \"">>), escape_quotes(Title)), <<"\"">>)
         end,
    finish_block(R3, false).

escape_quotes(Bin) -> binary:replace(Bin, <<"\"">>, <<"\\\"">>, [global]).

-spec ignore(map(), beamai_markdown_node()) -> map().
ignore(R, _) -> R.

%%%===================================================================
%%% Inlines
%%%===================================================================

-spec autolink(map(), beamai_markdown_inline()) -> map().
autolink(R, #{url := Url}) -> write(write(write(R, <<"<">>), Url), <<">">>).

-spec code(map(), beamai_markdown_inline()) -> map().
code(R, #{v := V}) ->
    %% The delimiter run must be longer than any run inside the content;
    %% content starting or ending with a backtick needs a space buffer.
    Longest = longest_run(V, 0, 0),
    R1 = write_repeat(R, $`, Longest + 1),
    R2 = case V of
             <<>> -> write(R1, <<" ">>);
             _ ->
                 A = case binary:first(V) of $` -> write(R1, <<" ">>); _ -> R1 end,
                 B = write(A, V),
                 case binary:last(V) of $` -> write(B, <<" ">>); _ -> B end
         end,
    write_repeat(R2, $`, Longest + 1).

longest_run(<<>>, _, Best) -> Best;
longest_run(<<$`, R/binary>>, Cur, Best) -> longest_run(R, Cur + 1, max(Best, Cur + 1));
longest_run(<<_, R/binary>>, _, Best) -> longest_run(R, 0, Best).

-spec emph(map(), beamai_markdown_inline()) -> map().
emph(R, #{ch := Ch, count := N} = Node) ->
    write_repeat(write_children(write_repeat(R, Ch, N), Node), Ch, N).

-spec linebreak(map(), beamai_markdown_inline()) -> map().
linebreak(R, #{hard := Hard} = Node) ->
    R1 = case Hard of
             true -> write(R, case maps:get(backslash, Node, false) of true -> <<"\\">>; false -> <<"  ">> end);
             false -> R
         end,
    write_line(R1).

-spec html(map(), beamai_markdown_inline()) -> map().
html(R, #{v := V}) -> write(R, V).

%% The original entity text, not the decoded character.
-spec entity(map(), beamai_markdown_inline()) -> map().
entity(R, #{raw := Raw}) -> write(R, Raw).

-spec link(map(), beamai_markdown_inline()) -> map().
link(R, #{auto := true, url := Url}) ->
    case get(R, expand_auto_links) of
        false -> write(R, Url);
        true -> link_full(R, #{k => link, url => Url, image => false, children => [#{k => text, v => Url}]})
    end;
link(R, Link) -> link_full(R, Link).

link_full(R, #{image := Image, children := Children} = Link) ->
    R1 = case Image of true -> write(R, <<"!">>); false -> R end,
    R2 = write(write_children(write(R1, <<"[">>), Link), <<"]">>),
    case Link of
        #{raw_label := Label, form := Form} ->
            Matches = case Children of
                          [#{k := text, v := V}] -> V =:= Label;
                          _ -> false
                      end,
            case Matches of
                true when Form =:= shortcut -> R2;
                true -> write(R2, <<"[]">>);
                false -> write(write(write(R2, <<"[">>), Label), <<"]">>)
            end;
        #{url := Url} when Url =/= <<>> ->
            A = write(write(R2, <<"(">>), Url),
            B = case maps:get(title, Link, undefined) of
                    T when is_binary(T), T =/= <<>> -> write(write(write(A, <<" \"">>), escape_quotes(T)), <<"\"">>);
                    _ -> A
                end,
            write(B, <<")">>);
        _ -> R2
    end.

-spec text(map(), beamai_markdown_inline()) -> map().
text(R, #{v := V} = Node) ->
    R1 = case maps:get(escaped, Node, false) andalso V =/= <<>>
             andalso beamai_markdown_char:is_ascii_punct(binary:first(V)) of
             true -> write(R, <<"\\">>);
             false -> R
         end,
    write(R1, V).
