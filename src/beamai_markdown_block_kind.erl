%%%-------------------------------------------------------------------
%%% @doc The behaviour a block kind implements.
%%%
%%% beamai_markdown_block asks these questions about every open block on
%%% every line. beamai_markdown_blocks answers them for the CommonMark
%%% kinds; an extension that adds a block kind registers its module under
%%% `block_kinds' in the pipeline.
%%%
%%% A block start is not part of this behaviour: starts are plain
%%% `{Module, Function}' entries in the pipeline's ordered `block_parsers'
%%% list, and a kind may have several (a list has one per marker style) or
%%% none (a link reference definition is only ever produced by a paragraph).
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_block_kind).

-include("beamai_markdown.hrl").

%% @doc Can the current line continue this open block? The block may be
%% updated. `{close, Block, Bp}' means the line closes the block (a closing
%% fence): the line is consumed entirely, and every block open inside it
%% closes too.
-callback continue(beamai_markdown_block(), #bp{}) ->
    {match, #bp{}} | {match, beamai_markdown_block(), #bp{}} | nomatch
  | {close, beamai_markdown_block(), #bp{}}.

%% @doc The block is closing: its children and lines are in order. Return
%% the blocks to put in its place -- usually itself, possibly nothing.
-callback finalize(beamai_markdown_block(), #bp{}) -> {[beamai_markdown_block()], #bp{}}.

%% @doc May a block of Kind be opened inside this one?
-callback can_contain(beamai_markdown_block(), atom()) -> boolean().

%% @doc Does the rest of a line go into this block's `lines'?
-callback accepts_lines(beamai_markdown_block()) -> boolean().

%% @doc Called after a line was added to a block that accepts lines. An HTML
%% block closes itself here when the line held its end condition.
-callback after_line(beamai_markdown_block(), #bp{}) -> #bp{}.

%% @doc Is a blank line inside this block irrelevant to list tightness?
-callback blank_line_ignored(beamai_markdown_block()) -> boolean().
