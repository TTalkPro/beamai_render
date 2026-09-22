%%%-------------------------------------------------------------------
%%% @doc markdig's `UseAdvancedExtensions' set, in its exact registration
%%% order. Generic attributes go last because they hook the parsers the
%%% others register.
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_ext_advanced).

-export([setup/2, members/0]).

-spec members() -> [atom()].
members() ->
    [alerts, abbreviations, auto_identifiers, citations, custom_containers,
     definition_lists, emphasis_extras, figures, footers, footnotes, grid_tables,
     mathematics, media_links, pipe_tables, list_extras, task_lists, diagrams,
     auto_links, generic_attributes].

-spec setup(map(), map()) -> map().
setup(Pipe, _Opts) ->
    lists:foldl(fun(Name, P) ->
                        {Name, Mod} = lists:keyfind(Name, 1, beamai_markdown:extensions()),
                        beamai_markdown_pipeline:use(P, Mod, #{})
                end, Pipe, members()).
