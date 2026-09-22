%%%-------------------------------------------------------------------
%%% beamai_render -- the markdown engine's data contract.
%%%
%%% The AST is maps, not records: markdig has 30 extensions that each add
%%% node kinds and per-node fields, and a map with a `k' key lets an
%%% extension add both without touching a shared record definition. Every
%%% node has `k' (its kind), a source position, and either `children' (a
%%% container), `lines' (a leaf block) or `v' (a leaf inline).
%%%
%%% The two processor records ARE records: they are threaded through every
%%% parser callback and the field access has to be fast and dialyzer-visible.
%%%
%%% Types, macros and comments only -- no functions.
%%%
%%% See designs/14-markdown-architecture.md.
%%%-------------------------------------------------------------------
-ifndef(BEAMAI_MARKDOWN_HRL).
-define(BEAMAI_MARKDOWN_HRL, true).

-include("beamai_html.hrl").

%% NUL is the out-of-range sentinel everywhere (start and end of line both
%% read as NUL, which is what makes them flank like whitespace). Real NULs in
%% the input are rewritten to U+FFFD at parse entry, so the sentinel is safe.
-define(NUL, 0).
-define(REPLACEMENT_CHAR, 16#FFFD).
-define(TAB_SIZE, 4).

%%%===================================================================
%%% AST
%%%===================================================================

-type beamai_markdown_kind() :: atom().

%% A block or an inline. The keys every node has:
%%   k        the kind
%%   line     1-based start line (0 when synthesised)
%%   col      1-based start column
%% Container blocks and container inlines add `children'; leaf blocks add
%% `lines' (the raw lines, with the container prefixes stripped); leaf inlines
%% add `v'. Kind-specific keys are documented at the parser that sets them.
-type beamai_markdown_node() :: #{k := beamai_markdown_kind(), atom() => term()}.
-type beamai_markdown_block() :: beamai_markdown_node().
-type beamai_markdown_inline() :: beamai_markdown_node().

%% HTML attributes attached to any node (generic attributes, auto identifiers,
%% task lists...). Rendered in this order: id, class, then properties.
-type beamai_markdown_attrs() ::
        #{id => binary(), classes => [binary()], props => [{binary(), binary()}]}.

%%%===================================================================
%%% Block processor state
%%%===================================================================

%% One record per line: the line is re-scanned from the start for every open
%% block (continuation) and then for block starts, and every parser sees the
%% same fields the CommonMark reference parser keeps.
-record(bp, {line = <<>>       :: binary(),        % current line, no line ending
             eol = <<"\n">>    :: binary(),        % its line ending ("" at EOF)
             line_no = 0       :: non_neg_integer(),
             source = <<>>     :: binary(),        % the whole document
             line_start = 0    :: non_neg_integer(),  % byte offset of `line' in `source'
             offset = 0        :: non_neg_integer(),  % byte offset into line
             column = 0        :: non_neg_integer(),  % virtual column (tabs expanded)
             indent = 0        :: non_neg_integer(),  % columns from `column' to next nonspace
             indented = false  :: boolean(),          % indent >= 4
             next_nonspace = 0 :: non_neg_integer(),
             next_nonspace_col = 0 :: non_neg_integer(),
             blank = false     :: boolean(),
             partial_tab = false :: boolean(),        % a tab was partially consumed
             %% The open blocks, innermost first: [Tip, ..., Document]. A
             %% block's `children' are reversed while it is open and put in
             %% order when it closes.
             stack = []        :: [beamai_markdown_block()],
             %% How many of the open blocks, counted from the tip, the current
             %% line did NOT match during the continuation pass. They stay
             %% open until a block start or the line's text closes them,
             %% because the line may turn out to be a lazy paragraph
             %% continuation.
             unmatched = 0     :: non_neg_integer(),
             %% During the continuation pass: does the block being asked
             %% have an open child deeper in the stack? (Open children are
             %% on the stack, not yet in their parent's `children'.)
             has_open_child = false :: boolean(),
             refs = #{}        :: #{binary() => map()},
             pipe = #{}        :: map(),
             opts = #{}        :: map(),
             last_line_len = 0 :: non_neg_integer(),
             %% Extension scratch space, keyed by extension name.
             ext = #{}         :: map()}).

%%%===================================================================
%%% Inline processor state
%%%===================================================================

-record(ip, {src = <<>>        :: binary(),          % the leaf's content, lines joined by \n
             pos = 0           :: non_neg_integer(),  % byte offset
             len = 0           :: non_neg_integer(),
             nodes = []        :: [beamai_markdown_inline()],  % reversed
             refs = #{}        :: #{binary() => map()},
             pipe = #{}        :: map(),
             opts = #{}        :: map(),
             block             :: beamai_markdown_block() | undefined,
             %% The leaf's ancestors, nearest first (read-only; see
             %% beamai_markdown_inline:edit_parent/3 for changing one).
             parents = []      :: [beamai_markdown_block()],
             %% {Depth, Fun}: Fun is applied to the ancestor Depth levels up
             %% (1 = parent) once the whole subtree has been processed.
             parent_edits = [] :: [{pos_integer(), fun((beamai_markdown_block()) -> beamai_markdown_block())}],
             %% Blocks to insert right after this leaf (a pipe table that
             %% follows paragraph text).
             extra_blocks = [] :: [beamai_markdown_block()],
             %% [{ByteOffset, Line, Col}] for each source line of src, so an
             %% inline can be given a source position.
             line_starts = [] :: [{non_neg_integer(), pos_integer(), pos_integer()}],
             ext = #{}         :: map()}).

-endif.
