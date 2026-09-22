%%%-------------------------------------------------------------------
%%% beamai_render -- shared data contract.
%%%
%%% This header is the single source of truth for the types that scanner,
%%% parser, AST post-processing, compiler, the rebar3 plugin and user-written
%%% extension modules all agree on. It contains types, macros and comments
%%% only -- no functions.
%%%
%%% See designs/04-codegen.md and tasks/T06.md.
%%%-------------------------------------------------------------------
-ifndef(BEAMAI_MUSTACHE_HRL).
-define(BEAMAI_MUSTACHE_HRL, true).

%%%===================================================================
%%% Delimiters and version
%%%===================================================================

-define(BEAMAI_MUSTACHE_START, <<"{{">>).
-define(BEAMAI_MUSTACHE_STOP,  <<"}}">>).

%% Shape version of the generated code. Bump whenever the compiler changes
%% what it emits, otherwise previously generated modules are not recompiled.
%% Feeds both the `vsn' field of -mustache_source and the stamp computed by
%% beamai_mustache_compiler:source_hash/2.
-define(BEAMAI_MUSTACHE_VSN, 1).

%% Sentinel key for the implicit iterator {{.}}. beamai_mustache_rt:lookup/2
%% recognises a keys() of exactly [?BEAMAI_MUSTACHE_DOT] and returns hd(Stack).
-define(BEAMAI_MUSTACHE_DOT, '.').

%% Markers claimed by beamai_render itself. Extension modules may only register
%% characters outside this set; the conflict check lives in the plugin and in
%% the parse_transform, but this list is the only definition of the set.
-define(BEAMAI_MUSTACHE_BUILTIN_MARKERS,
        [$#, $^, $/, $>, $!, $=, $&, ${, $}, $+, $-, $*]).

%%%===================================================================
%%% Basic types
%%%===================================================================

-type beamai_mustache_key()  :: atom().
-type beamai_mustache_keys() :: [beamai_mustache_key()].

%% Template bodies and paths are UTF-8 binaries throughout. Callers may hand
%% in any unicode:chardata() at an entry point; beamai_mustache_text normalises it
%% once and everything downstream sees a binary.
-type beamai_mustache_template() :: binary().
-type beamai_mustache_path()     :: binary().

%% Position in the template source. Used for diagnostics and, when the
%% line_map option is on, for the line numbers of the generated forms.
-type beamai_mustache_loc()  :: {Line :: pos_integer(), Col :: pos_integer()}.

%%%===================================================================
%%% Scanner output -- the only interface between T07 and T08
%%%===================================================================

%% `none' is a plain {{x}} interpolation; anything else is the marker
%% character that introduced the tag.
-type beamai_mustache_marker() :: none | char().

-type beamai_mustache_token() ::
      {text, beamai_mustache_loc(), binary()}
    | {tag,  beamai_mustache_loc(), beamai_mustache_marker(),
             Content :: binary(),      % marker stripped, outer space trimmed
             Indent  :: binary()}.     % standalone line indent, else <<>>

%%%===================================================================
%%% AST
%%%===================================================================

%% A partial's target starts life as the raw path written in the template and
%% becomes a module name once beamai_mustache_ast:resolve_partials/2 has run.
%%   before: <<"shared/item">>
%%   after:  view_shared_item
-type beamai_mustache_partial_target() :: binary() | module().

%% NOTE: this type cannot be named node/0 -- that is an Erlang builtin and the
%% compiler rejects any attempt to redefine it.
-type beamai_mustache_node() ::
      {text,     beamai_mustache_loc(), binary()}
    | {var,      beamai_mustache_loc(), beamai_mustache_keys(), escape | raw}
    | {section,  beamai_mustache_loc(), beamai_mustache_keys(), [beamai_mustache_node()]}
    | {inverted, beamai_mustache_loc(), beamai_mustache_keys(), [beamai_mustache_node()]}
    | {has,      beamai_mustache_loc(), beamai_mustache_keys(), [beamai_mustache_node()],
                 Positive :: boolean()}
    | {lambda,   beamai_mustache_loc(), beamai_mustache_keys()}
    | {partial,  beamai_mustache_loc(), beamai_mustache_partial_target(),
                 Indent :: binary()}
    | {ext,      beamai_mustache_loc(), Marker :: char(), beamai_mustache_keys(),
                 [beamai_mustache_node()]}.

%%%===================================================================
%%% Compiler options
%%%===================================================================

-type beamai_mustache_opts() :: #{
        module     := module(),
        source     := beamai_mustache_path(),
        prefix     => beamai_mustache_path(),       % default <<"view_">>
        views      => beamai_mustache_path(),
        views_abs  => beamai_mustache_path(),       % resolved; kept out of the stamp
        suffix     => beamai_mustache_path(),
        extensions => [module()],
        ext_opts   => #{module() => term()},    % passed to compile_tag/4
        stack_var  => atom(),                   % context stack variable name
        line_map   => boolean()                 % default true
       }.

%%%===================================================================
%%% Errors
%%%===================================================================

-type beamai_mustache_reason() ::
      {unclosed_tag, beamai_mustache_keys()}
    | {mismatched_close, Expected :: beamai_mustache_keys(),
                         Got      :: beamai_mustache_keys()}
    | {partial_not_found, binary()}
    | partial_in_inline_template
    | {unknown_marker, char()}
    | {invalid_delimiter, binary()}
    | {invalid_utf8, ByteOffset :: non_neg_integer()}
    | {ext_crashed, module(), char(), term()}
    | {unexpected_remote_calls, [module()]}
    | {codegen_failed, term()}.

-type beamai_mustache_error() ::
        {error, {File   :: binary(),
                 Line   :: pos_integer(),
                 Reason :: beamai_mustache_reason()}}.

%%%===================================================================
%%% Generated module self-description
%%%===================================================================

%% Every generated module carries this as a -mustache_source attribute.
%% The plugin reads it for incremental compilation and beamai_mustache_dev reads
%% it for hot reloading; neither keeps any state of its own.
%%
%% `stamp' is deliberately not called `hash': it is the combined digest of
%% template content, normalised options and ?BEAMAI_MUSTACHE_VSN, not a digest of
%% the template text. `opts' is required, not redundant -- without it a change
%% to mustache_opts would not trigger a rebuild and beamai_mustache_dev could not
%% faithfully reproduce the compilation the plugin originally performed.
%%
%% `opts' is a SORTED LIST, not a map, and that is the whole point: a map is
%% printed in maps:to_list/1 order, which follows the VM's atom table and so
%% differs between two runs of the same build. The generated file has to be
%% byte-identical wherever it is produced.
%% `origin' is present only when the module was compiled from a string rather
%% than from a file (beamai_mustache:render_string/3 and the runtime fallback of
%% inline/2). Such a module has no file on disk, so beamai_mustache_dev must not
%% report it as a missing template. It is absent for file templates so that
%% their generated .erl is byte-for-byte what it always was, and it is not part
%% of normalize_opts/1, so it never reaches a build stamp.
-type beamai_mustache_source() :: #{
        path   := binary(),
        stamp  := binary(),
        mtime  := integer(),
        vsn    := pos_integer(),
        opts   := [{atom(), term()}],
        origin => file | string
       }.

-endif.
