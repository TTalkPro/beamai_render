%%%-------------------------------------------------------------------
%%% @doc The markdown third of the example: run-time rendering with a
%%% pipeline, and the parse_transform folding a document at compile time.
%%%
%%% Nothing is generated for this one: the engine renders at run time, and
%%% the transform's -markdown_document is compiled into this module.
%%% @end
%%%-------------------------------------------------------------------
-module(markdown_demo).

-compile({parse_transform, beamai_markdown_transform}).

-export([render/0, about/0, source/0]).

-markdown_document({about, "views/markdown/about.md"}).

-spec render() -> binary().
render() ->
    Pipe = beamai_markdown:pipeline([pipe_tables, task_lists, emphasis_extras, auto_links]),
    beamai_markdown:to_html(source(), Pipe).

-spec source() -> binary().
source() ->
    ~"""
    # Users & guests

    | name | role  |
    |------|-------|
    | ada  | admin |
    | bo   |       |

    - [x] ~~invite~~ sent
    - [ ] follow up at https://example.com
    """.
