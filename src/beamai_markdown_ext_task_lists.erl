%%%-------------------------------------------------------------------
%%% @doc Task lists: `- [ ] todo' and `- [x] done'.
%%%
%%% The smallest extension and the reference example of the protocol: an
%%% inline parser inserted at a precise position (before the link parser,
%%% which also claims `['), a new inline kind, and an HTML renderer.
%%%
%%% Inline kind: task, with `checked'. The enclosing list item gets the
%%% class `task-list-item' and its list `contains-task-list' (both
%%% configurable: `list_class', `item_class').
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_ext_task_lists).

-include("beamai_markdown.hrl").

-export([setup/2, match/1, setup_html/1, render_html/2]).

-spec setup(map(), map()) -> map().
setup(Pipe0, Opts) ->
    Pipe1 = beamai_markdown_pipeline:insert_before(
              Pipe0, inline_parsers, link,
              #{name => task_list, module => ?MODULE, function => match, chars => [$[],
                opts => Opts}),
    beamai_markdown_pipeline:add_renderer_setup(
      Pipe1, html, #{name => task_list, module => ?MODULE, function => setup_html}).

-spec match(#ip{}) -> {ok, #ip{}} | none.
match(#ip{parents = [#{k := list_item} | _]} = Ip) ->
    C = beamai_markdown_inline:peek(Ip, 1),
    case (C =:= $\s orelse C =:= $x orelse C =:= $X) andalso
        beamai_markdown_inline:peek(Ip, 2) =:= $] of
        false -> none;
        true ->
            Opts = parser_opts(Ip),
            ItemClass = maps:get(item_class, Opts, <<"task-list-item">>),
            ListClass = maps:get(list_class, Opts, <<"contains-task-list">>),
            Ip1 = beamai_markdown_inline:push(beamai_markdown_inline:advance(Ip, 3),
                                              #{k => task, checked => C =/= $\s}),
            Ip2 = beamai_markdown_inline:edit_parent(Ip1, 1, add_class_fun(ItemClass)),
            Ip3 = beamai_markdown_inline:edit_parent(Ip2, 2, add_class_fun(ListClass)),
            {ok, Ip3}
    end;
match(_) -> none.

parser_opts(Ip) ->
    case beamai_markdown_pipeline:find(beamai_markdown_inline:pipe(Ip), inline_parsers, task_list) of
        #{opts := O} -> O;
        _ -> #{}
    end.

add_class_fun(<<>>) -> fun(B) -> B end;
add_class_fun(Class) -> fun(B) -> beamai_markdown_attrs:add_class(B, Class) end.

-spec setup_html(map()) -> map().
setup_html(R) ->
    beamai_markdown_renderer:set_renderer(R, task, {?MODULE, render_html}).

-spec render_html(map(), beamai_markdown_inline()) -> map().
render_html(R, #{checked := Checked} = Node) ->
    case beamai_markdown_renderer:get(R, enable_inline) of
        true ->
            R1 = beamai_markdown_html:write_attributes(beamai_markdown_renderer:write(R, <<"<input">>), Node),
            R2 = beamai_markdown_renderer:write(R1, <<" disabled=\"disabled\" type=\"checkbox\"">>),
            R3 = case Checked of
                     true -> beamai_markdown_renderer:write(R2, <<" checked=\"checked\"">>);
                     false -> R2
                 end,
            beamai_markdown_renderer:write(R3, <<" />">>);
        false ->
            beamai_markdown_renderer:write(R, case Checked of true -> <<"[x]">>; false -> <<"[ ]">> end)
    end.
