%%%-------------------------------------------------------------------
%%% @doc HTML attributes on AST nodes: id, classes, properties.
%%%
%%% Port of markdig's HtmlAttributes. The attributes live under the node's
%%% `attrs' key and render in the order id, class, properties. add_class/2
%%% does not duplicate; add_property/3 does not de-duplicate (markdig's
%%% behaviour, which generic attributes rely on).
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_attrs).

-include("beamai_markdown.hrl").

-export([attrs/1, set/2, id/1, set_id/2, classes/1, add_class/2, add_property/3,
         properties/1, copy_to/2, merge/2, is_empty/1]).

-spec attrs(beamai_markdown_node()) -> beamai_markdown_attrs().
attrs(#{attrs := A}) -> A;
attrs(_) -> #{}.

-spec set(beamai_markdown_node(), beamai_markdown_attrs()) -> beamai_markdown_node().
set(Node, A) ->
    case is_empty(A) of
        true -> maps:remove(attrs, Node);
        false -> Node#{attrs => A}
    end.

-spec is_empty(beamai_markdown_attrs()) -> boolean().
is_empty(A) ->
    maps:get(id, A, undefined) =:= undefined andalso maps:get(classes, A, []) =:= []
        andalso maps:get(props, A, []) =:= [].

-spec id(beamai_markdown_node()) -> binary() | undefined.
id(Node) -> maps:get(id, attrs(Node), undefined).

-spec set_id(beamai_markdown_node(), binary()) -> beamai_markdown_node().
set_id(Node, Id) -> set(Node, (attrs(Node))#{id => Id}).

-spec classes(beamai_markdown_node()) -> [binary()].
classes(Node) -> maps:get(classes, attrs(Node), []).

-spec add_class(beamai_markdown_node(), binary()) -> beamai_markdown_node().
add_class(Node, Class) ->
    A = attrs(Node),
    Cs = maps:get(classes, A, []),
    case lists:member(Class, Cs) of
        true -> Node;
        false -> set(Node, A#{classes => Cs ++ [Class]})
    end.

-spec properties(beamai_markdown_node()) -> [{binary(), binary()}].
properties(Node) -> maps:get(props, attrs(Node), []).

-spec add_property(beamai_markdown_node(), binary(), binary()) -> beamai_markdown_node().
add_property(Node, K, V) ->
    A = attrs(Node),
    set(Node, A#{props => maps:get(props, A, []) ++ [{K, V}]}).

%% @doc Copy From's attributes onto To: the id replaces, classes and
%% properties are appended.
-spec copy_to(beamai_markdown_node(), beamai_markdown_node()) -> beamai_markdown_node().
copy_to(From, To) -> set(To, merge(attrs(To), attrs(From))).

-spec merge(beamai_markdown_attrs(), beamai_markdown_attrs()) -> beamai_markdown_attrs().
merge(Base, Over) ->
    Id = case maps:get(id, Over, undefined) of
             undefined -> maps:get(id, Base, undefined);
             I -> I
         end,
    Classes = lists:foldl(fun(C, Acc) ->
                                  case lists:member(C, Acc) of true -> Acc; false -> Acc ++ [C] end
                          end, maps:get(classes, Base, []), maps:get(classes, Over, [])),
    Props = maps:get(props, Base, []) ++ maps:get(props, Over, []),
    A0 = #{classes => Classes, props => Props},
    case Id of undefined -> A0; _ -> A0#{id => Id} end.
