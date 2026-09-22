%%%-------------------------------------------------------------------
%%% @doc The HTML renderer.
%%%
%%% Port of markdig's HtmlRenderer and its default object renderers,
%%% output-identical. The plain-text renderer is this one with the three
%%% enable flags off: with `enable_escape' off the characters that would be
%%% escaped are dropped, which is precisely how markup gets stripped.
%%%
%%% Renderer state keys (beyond the base's):
%%%   enable_inline, enable_block, enable_escape   the markdig flags
%%%   implicit_paragraph      true inside a tight list item
%%%   non_ascii_no_escape     keep non-ASCII in URLs
%%%   base_url, link_rewriter
%%%   attrs_on_pre            code block attributes on <pre> not <code>
%%%   blocks_as_div, blocks_as_pre   fenced info strings rendered as such
%%%   link_rel, autolink_rel  a rel= for links
%%%   soft_as_hard            render soft breaks as <br />
%%%   emphasis_tag            {M, F} deciding the tag of an emph node
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_html).

-include("beamai_markdown.hrl").

-import(beamai_markdown_renderer,
        [write/2, write_raw/2, write_line/1, write_line/2, ensure_line/1,
         write_children/2, write_leaf_inline/2, is_first/1, is_last/1,
         get/2, get/3, set/3]).

-export([render/3, new/2, renderers/0, write_escape/2, write_escape/3,
         write_escape_url/2, write_attributes/2, write_attributes/3,
         write_leaf_raw_lines/4, write_leaf_raw_lines/5, default_emphasis_tag/2,
         attrs_of/1]).
-export([code_block/2, list/2, heading/2, html_block/2, paragraph/2, quote/2,
         thematic_break/2, autolink/2, code/2, emph/2, linebreak/2, html/2,
         entity/2, link/2, text/2, link_ref_def/2]).

%% @doc Render a document to HTML (or plain text, with the flags in Opts).
-spec render(beamai_markdown_block(), map(), map()) -> binary().
render(Doc, Pipe, Opts) ->
    R = new(Pipe, Opts),
    beamai_markdown_renderer:finish(beamai_markdown_renderer:render(R, Doc)).

-spec new(map(), map()) -> beamai_markdown_renderer:renderer().
new(Pipe, Opts) ->
    Name = maps:get(renderer, Opts, html),
    R0 = beamai_markdown_renderer:new(Name, renderers(), Pipe, Opts),
    Defaults = #{enable_inline => true, enable_block => true, enable_escape => true,
                 implicit_paragraph => false, non_ascii_no_escape => false,
                 base_url => undefined, link_rewriter => undefined,
                 attrs_on_pre => false, blocks_as_div => [], blocks_as_pre => [],
                 link_rel => undefined, autolink_rel => undefined, soft_as_hard => false,
                 emphasis_tag => {?MODULE, default_emphasis_tag}},
    %% Setup hooks ran in new/4 and may already have set some of these;
    %% options override what the hooks did not set.
    maps:merge(maps:merge(Defaults, R0), maps:with(maps:keys(Defaults), Opts)).

%% @doc The kind -> renderer table.
-spec renderers() -> map().
renderers() ->
    #{code => {?MODULE, code},
      indented_code => {?MODULE, code_block},
      fenced_code => {?MODULE, code_block},
      list => {?MODULE, list},
      heading => {?MODULE, heading},
      html_block => {?MODULE, html_block},
      paragraph => {?MODULE, paragraph},
      quote => {?MODULE, quote},
      thematic_break => {?MODULE, thematic_break},
      link_ref_def => {?MODULE, link_ref_def},
      autolink => {?MODULE, autolink},
      emph => {?MODULE, emph},
      linebreak => {?MODULE, linebreak},
      html => {?MODULE, html},
      entity => {?MODULE, entity},
      link => {?MODULE, link},
      text => {?MODULE, text}}.

%%%===================================================================
%%% Escaping
%%%===================================================================

-spec write_escape(map(), binary()) -> map().
write_escape(R, Bin) -> write_escape(R, Bin, false).

%% @doc HTML-escape and write. With enable_escape off the special
%% characters are dropped, not passed through.
-spec write_escape(map(), binary(), boolean()) -> map().
write_escape(R, <<>>, _) -> R;
write_escape(R, Bin, Soft) ->
    case get(R, enable_escape) of
        true -> write(R, beamai_markdown_scan:escape_html(Bin, Soft));
        false -> write(R, strip_specials(Bin, Soft))
    end.

strip_specials(Bin, Soft) ->
    << <<C>> || <<C>> <= Bin, not is_special(C, Soft) >>.

is_special($<, _) -> true;
is_special($&, _) -> true;
is_special($>, false) -> true;
is_special($", false) -> true;
is_special(_, _) -> false.

-spec write_escape_url(map(), binary()) -> map().
write_escape_url(R, Url0) ->
    Url1 = case get(R, base_url) of
               undefined -> Url0;
               Base ->
                   case beamai_markdown_scan:is_absolute_url(Url0) of
                       true -> Url0;
                       false -> beamai_markdown_scan:resolve_url(Base, Url0)
                   end
           end,
    Url2 = case get(R, link_rewriter) of
               undefined -> Url1;
               Fun -> Fun(Url1)
           end,
    write(R, beamai_markdown_scan:escape_url(Url2, get(R, non_ascii_no_escape))).

%% @doc The attributes attached to a node, if any.
-spec attrs_of(beamai_markdown_node()) -> beamai_markdown_attrs() | undefined.
attrs_of(#{attrs := A}) -> A;
attrs_of(_) -> undefined.

-spec write_attributes(map(), beamai_markdown_node()) -> map().
write_attributes(R, Node) -> write_attributes(R, Node, fun(C) -> C end).

%% @doc id, class, then properties, in that order. Property values are
%% escaped, property names are not.
-spec write_attributes(map(), beamai_markdown_node(), fun((binary()) -> binary())) -> map().
write_attributes(R, Node, ClassFilter) ->
    case attrs_of(Node) of
        undefined -> R;
        A ->
            R1 = case A of
                     #{id := Id} when Id =/= undefined ->
                         write_raw(write_escape(write(R, <<" id=\"">>), Id), <<"\"">>);
                     _ -> R
                 end,
            R2 = case maps:get(classes, A, []) of
                     [] -> R1;
                     Classes ->
                         Esc = [beamai_markdown_scan:escape_html(ClassFilter(C)) || C <- Classes],
                         write_raw(write(R1, <<" class=\"">>), [lists:join(<<" ">>, Esc), <<"\"">>])
                 end,
            lists:foldl(fun({K, V}, Acc) ->
                                write_raw(write(Acc, <<" ">>),
                                          [K, <<"=\"">>, beamai_markdown_scan:escape_html(V), <<"\"">>])
                        end, R2, maps:get(props, A, []))
    end.

%% @doc A leaf's raw lines. Terminated = true puts a newline after each
%% line, false puts one between lines.
-spec write_leaf_raw_lines(map(), beamai_markdown_node(), boolean(), boolean()) -> map().
write_leaf_raw_lines(R, Block, Terminated, Escape) ->
    write_leaf_raw_lines(R, Block, Terminated, Escape, false).

-spec write_leaf_raw_lines(map(), beamai_markdown_node(), boolean(), boolean(), boolean()) -> map().
write_leaf_raw_lines(R, #{lines := Lines}, Terminated, Escape, Soft) ->
    write_lines(Lines, R, Terminated, Escape, Soft, true);
write_leaf_raw_lines(R, _, _, _, _) -> R.

write_lines([], R, _, _, _, _) -> R;
write_lines([{T, _, _} | Rest], R0, Terminated, Escape, Soft, First) ->
    R1 = case Terminated orelse First of
             true -> R0;
             false -> write_line(R0)
         end,
    R2 = case Escape of
             true -> write_escape(R1, T, Soft);
             false -> write(R1, T)
         end,
    R3 = case Terminated of
             true -> write_line(R2);
             false -> R2
         end,
    write_lines(Rest, R3, Terminated, Escape, Soft, false).

%%%===================================================================
%%% Block renderers
%%%===================================================================

-spec code_block(map(), beamai_markdown_node()) -> map().
code_block(R0, Block) ->
    R = ensure_line(R0),
    Info = maps:get(info, Block, undefined),
    Div = Info =/= undefined andalso member_ci(Info, get(R, blocks_as_div)),
    Pre = Info =/= undefined andalso member_ci(Info, get(R, blocks_as_pre)),
    R1 = if Pre -> container_tag(R, Block, <<"pre">>);
            Div -> container_tag(R, Block, <<"div">>);
            true -> pre_code(R, Block)
         end,
    ensure_line(R1).

member_ci(Info, List) ->
    L = string:lowercase(Info),
    lists:any(fun(X) -> string:lowercase(X) =:= L end, List).

container_tag(R, Block, Tag) ->
    Prefix = maps:get(info_prefix, Block, <<"language-">>),
    Filter = fun(Class) ->
                     N = byte_size(Prefix),
                     case Class of
                         <<Prefix:N/binary, Rest/binary>> -> Rest;
                         _ -> Class
                     end
             end,
    R1 = case get(R, enable_block) of
             true -> write_raw(write_attributes(write(write_raw(R, <<"<">>), Tag), Block, Filter), <<">">>);
             false -> R
         end,
    R2 = write_leaf_raw_lines(R1, Block, true, true, true),
    case get(R, enable_block) of
        true -> write_line(write(write(R2, <<"</">>), Tag), <<">">>);
        false -> R2
    end.

pre_code(R, Block) ->
    OnPre = get(R, attrs_on_pre),
    R1 = case get(R, enable_block) of
             true ->
                 A = write(R, <<"<pre">>),
                 B = case OnPre of true -> write_attributes(A, Block); false -> A end,
                 C = write_raw(B, <<"><code">>),
                 D = case OnPre of false -> write_attributes(C, Block); true -> C end,
                 write_raw(D, <<">">>);
             false -> R
         end,
    R2 = write_leaf_raw_lines(R1, Block, true, get(R, enable_escape)),
    case get(R, enable_block) of
        true -> write_line(R2, <<"</code></pre>">>);
        false -> R2
    end.

-spec list(map(), beamai_markdown_node()) -> map().
list(R0, #{ordered := Ordered, children := Items} = List) ->
    R = ensure_line(R0),
    R1 = case get(R, enable_block) of
             false -> R;
             true when Ordered ->
                 A = write(R, <<"<ol">>),
                 B = case maps:get(bullet_char, List) of
                         $1 -> A;
                         BC -> write_raw(A, [<<" type=\"">>, <<BC>>, <<"\"">>])
                     end,
                 C = case maps:get(start, List) of
                         1 -> B;
                         S -> write_raw(B, [<<" start=\"">>, integer_to_binary(S), <<"\"">>])
                     end,
                 write_line(write_attributes(C, List), <<">">>);
             true ->
                 write_line(write_attributes(write(R, <<"<ul">>), List), <<">">>)
         end,
    Loose = not maps:get(tight, List, true),
    R2 = lists:foldl(fun(Item, Acc) -> list_item(Acc, Item, Loose) end, R1, Items),
    R3 = case get(R, enable_block) of
             true -> write_line(R2, case Ordered of true -> <<"</ol>">>; false -> <<"</ul>">> end);
             false -> R2
         end,
    ensure_line(R3).

list_item(R0, Item, Loose) ->
    Prev = get(R0, implicit_paragraph),
    R1 = ensure_line(set(R0, implicit_paragraph, not Loose)),
    R2 = case get(R1, enable_block) of
             true -> write_raw(write_attributes(write(R1, <<"<li">>), Item), <<">">>);
             false -> R1
         end,
    R3 = write_children(R2, Item),
    R4 = case get(R3, enable_block) of
             true -> write_line(R3, <<"</li>">>);
             false -> R3
         end,
    set(ensure_line(R4), implicit_paragraph, Prev).

-spec heading(map(), beamai_markdown_node()) -> map().
heading(R, #{level := Level} = Block) ->
    Tag = <<"h", (integer_to_binary(Level))/binary>>,
    R1 = case get(R, enable_block) of
             true -> write_raw(write_attributes(write_raw(write(R, <<"<">>), Tag), Block), <<">">>);
             false -> R
         end,
    R2 = write_leaf_inline(R1, Block),
    R3 = case get(R, enable_block) of
             true -> write_line(write_raw(write(R2, <<"</">>), Tag), <<">">>);
             false -> R2
         end,
    ensure_line(R3).

-spec html_block(map(), beamai_markdown_node()) -> map().
html_block(R, Block) ->
    write_leaf_raw_lines(R, Block, true, false).

-spec paragraph(map(), beamai_markdown_node()) -> map().
paragraph(R, Block) ->
    Implicit = get(R, implicit_paragraph),
    R1 = case (not Implicit) andalso get(R, enable_block) of
             true ->
                 A = case is_first(R) of true -> R; false -> ensure_line(R) end,
                 write_raw(write_attributes(write(A, <<"<p">>), Block), <<">">>);
             false -> R
         end,
    R2 = write_leaf_inline(R1, Block),
    case Implicit of
        true -> R2;
        false ->
            R3 = case get(R2, enable_block) of
                     true -> write_line(R2, <<"</p>">>);
                     false -> R2
                 end,
            ensure_line(R3)
    end.

-spec quote(map(), beamai_markdown_node()) -> map().
quote(R0, Block) ->
    R = ensure_line(R0),
    R1 = case get(R, enable_block) of
             true -> write_line(write_attributes(write(R, <<"<blockquote">>), Block), <<">">>);
             false -> R
         end,
    Saved = get(R1, implicit_paragraph),
    R2 = set(write_children(set(R1, implicit_paragraph, false), Block), implicit_paragraph, Saved),
    R3 = case get(R2, enable_block) of
             true -> write_line(R2, <<"</blockquote>">>);
             false -> R2
         end,
    ensure_line(R3).

-spec thematic_break(map(), beamai_markdown_node()) -> map().
thematic_break(R, Block) ->
    case get(R, enable_block) of
        true -> write_line(write_attributes(write(R, <<"<hr">>), Block), <<" />">>);
        false -> R
    end.

-spec link_ref_def(map(), beamai_markdown_node()) -> map().
link_ref_def(R, _) -> R.

%%%===================================================================
%%% Inline renderers
%%%===================================================================

-spec autolink(map(), beamai_markdown_node()) -> map().
autolink(R, #{url := Url, email := Email} = Node) ->
    R1 = case get(R, enable_inline) of
             true ->
                 A = write(R, case Email of true -> <<"<a href=\"mailto:">>; false -> <<"<a href=\"">> end),
                 B = write_attributes(write_raw(write_escape_url(A, Url), <<"\"">>), Node),
                 C = case {Email, get(R, autolink_rel)} of
                         {false, Rel} when Rel =/= undefined -> write_raw(B, [<<" rel=\"">>, Rel, <<"\"">>]);
                         _ -> B
                     end,
                 write_raw(C, <<">">>);
             false -> R
         end,
    R2 = write_escape(R1, Url),
    case get(R, enable_inline) of
        true -> write_raw(R2, <<"</a>">>);
        false -> R2
    end.

-spec code(map(), beamai_markdown_node()) -> map().
code(R, #{v := V} = Node) ->
    R1 = case get(R, enable_inline) of
             true -> write_raw(write_attributes(write(R, <<"<code">>), Node), <<">">>);
             false -> R
         end,
    R2 = case get(R, enable_escape) of
             true -> write_escape(R1, V);
             false -> write(R1, V)
         end,
    case get(R, enable_inline) of
        true -> write_raw(R2, <<"</code>">>);
        false -> R2
    end.

%% @doc em / strong for * and _; nothing for anything else.
-spec default_emphasis_tag(map(), beamai_markdown_inline()) -> binary() | undefined.
default_emphasis_tag(_R, #{ch := Ch, count := Count}) when Ch =:= $*; Ch =:= $_ ->
    case Count of 2 -> <<"strong">>; _ -> <<"em">> end;
default_emphasis_tag(_, _) -> undefined.

-spec emph(map(), beamai_markdown_node()) -> map().
emph(R, Node) ->
    Inline = get(R, enable_inline),
    Tag = case Inline of
              true ->
                  {M, F} = get(R, emphasis_tag),
                  case M:F(R, Node) of undefined -> <<>>; T -> T end;
              false -> <<>>
          end,
    R1 = case Inline of
             true -> write_raw(write_attributes(write_raw(write(R, <<"<">>), Tag), Node), <<">">>);
             false -> R
         end,
    R2 = write_children(R1, Node),
    case Inline of
        true -> write_raw(write_raw(write(R2, <<"</">>), Tag), <<">">>);
        false -> R2
    end.

-spec linebreak(map(), beamai_markdown_node()) -> map().
linebreak(R, #{hard := Hard}) ->
    %% A trailing break in its container emits nothing at all.
    case is_last(R) of
        true -> R;
        false ->
            R1 = case get(R, enable_inline) andalso (Hard orelse get(R, soft_as_hard)) of
                     true -> write_line(R, <<"<br />">>);
                     false -> R
                 end,
            ensure_line(R1)
    end.

-spec html(map(), beamai_markdown_node()) -> map().
html(R, #{v := V}) ->
    case get(R, enable_inline) of
        true -> write(R, V);
        false -> R
    end.

-spec entity(map(), beamai_markdown_node()) -> map().
entity(R, #{v := V}) ->
    case get(R, enable_escape) of
        true -> write_escape(R, V);
        false -> write(R, V)
    end.

-spec link(map(), beamai_markdown_node()) -> map().
link(R, #{image := Image, children := _} = Node) ->
    Inline = get(R, enable_inline),
    Url = case maps:get(dynamic_url, Node, undefined) of
              undefined -> maps:get(url, Node, <<>>);
              Fun -> case Fun(Node) of undefined -> maps:get(url, Node, <<>>); U -> U end
          end,
    R1 = case Inline of
             true ->
                 A = write(R, case Image of true -> <<"<img src=\"">>; false -> <<"<a href=\"">> end),
                 write_attributes(write_raw(write_escape_url(A, Url), <<"\"">>), Node);
             false -> R
         end,
    R2 = case Image of
             true ->
                 A2 = case Inline of true -> write_raw(R1, <<" alt=\"">>); false -> R1 end,
                 B2 = set(write_children(set(A2, enable_inline, false), Node), enable_inline, Inline),
                 case Inline of true -> write_raw(B2, <<"\"">>); false -> B2 end;
             false -> R1
         end,
    R3 = case Inline andalso maps:get(title, Node, undefined) of
             Title when is_binary(Title), Title =/= <<>> ->
                 write_raw(write_escape(write_raw(R2, <<" title=\"">>), Title), <<"\"">>);
             _ -> R2
         end,
    case Image of
        true ->
            case Inline of true -> write_raw(R3, <<" />">>); false -> R3 end;
        false ->
            R4 = case Inline of
                     true ->
                         A4 = case get(R, link_rel) of
                                  undefined -> R3;
                                  Rel -> write_raw(R3, [<<" rel=\"">>, Rel, <<"\"">>])
                              end,
                         write_raw(A4, <<">">>);
                     false -> R3
                 end,
            R5 = write_children(R4, Node),
            case Inline of true -> write(R5, <<"</a>">>); false -> R5 end
    end.

-spec text(map(), beamai_markdown_node()) -> map().
text(R, #{v := V}) ->
    case get(R, enable_escape) of
        true -> write_escape(R, V);
        false -> write(R, V)
    end.
