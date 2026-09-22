%%%-------------------------------------------------------------------
%%% beamai_render -- the jinja engine's data contract.
%%%
%%% Single source of truth for the types the scanner, lexer, expression
%%% parser, statement parser, AST passes, compiler, plugin and user extension
%%% modules all agree on. Types, macros and comments only -- no functions.
%%%
%%% Engine-neutral types (loc, path, the error envelope) live in beamai_html.hrl.
%%%
%%% See designs/09-jinja-syntax.md and designs/11-jinja-codegen.md.
%%%-------------------------------------------------------------------
-ifndef(BEAMAI_JINJA_HRL).
-define(BEAMAI_JINJA_HRL, true).

-include("beamai_html.hrl").

%%%===================================================================
%%% Delimiters and version
%%%===================================================================

%% Not configurable, which is why these are macros and not options
%% (designs/09-jinja-syntax.md section 1, deviation J5). Making them options
%% would put them in the build stamp, parameterise the raw scanner and turn
%% every diagnostic into string concatenation.
-define(BEAMAI_JINJA_EXPR_START, <<"{{">>).
-define(BEAMAI_JINJA_EXPR_STOP,  <<"}}">>).
-define(BEAMAI_JINJA_STMT_START, <<"{%">>).
-define(BEAMAI_JINJA_STMT_STOP,  <<"%}">>).
-define(BEAMAI_JINJA_COMM_START, <<"{#">>).
-define(BEAMAI_JINJA_COMM_STOP,  <<"#}">>).

%% Shape version of the generated code. Bump whenever beamai_jinja_compiler changes
%% what it emits -- a new function in the module contract, a different calling
%% convention, anything an already-generated module would now be wrong about.
%% Feeds both the `vsn' field of -jinja_source and source_hash/2; without the
%% bump, existing modules are considered fresh and never rebuilt.
-define(BEAMAI_JINJA_VSN, 1).

%% Names the engine binds itself. Shadowing one is legal but is nearly always
%% a typo, so the parser warns. designs/09-jinja-syntax.md section 4.
-define(BEAMAI_JINJA_RESERVED, [loop, super, caller, varargs, kwargs, self]).

%%%===================================================================
%%% Lexer output -- the interface between T37 and T38
%%%===================================================================

%% Every token carries its own position. A single {{ }} can hold dozens of
%% subexpressions, so an error has to point at the token, not at the tag
%% (designs/09-jinja-syntax.md section 6).
-type beamai_jinja_expr_token() ::
      {name,   beamai_html_loc(), atom()}
    | {int,    beamai_html_loc(), integer()}
    | {float,  beamai_html_loc(), float()}
    | {str,    beamai_html_loc(), binary()}
    | {kw,     beamai_html_loc(), atom()}      % and or not in is if else true false none
    | {op,     beamai_html_loc(), atom()}      % + - * / // % ** ~ == != < > <= >= = . , : |
    | {open,   beamai_html_loc(), $( | $[ | ${}
    | {close,  beamai_html_loc(), $) | $] | $}}.

%%%===================================================================
%%% Scanner output -- the interface between T36 and T39
%%%===================================================================

%% Comments produce no token at all, and {% raw %} is consumed by the scanner,
%% so the statement parser never has to know either exists.
-type beamai_jinja_token() ::
      {text, beamai_html_loc(), binary()}
    | {expr, beamai_html_loc(), [beamai_jinja_expr_token()]}
    | {stmt, beamai_html_loc(), Keyword :: atom(), [beamai_jinja_expr_token()]}.

%%%===================================================================
%%% Expression AST
%%%===================================================================

-type beamai_jinja_binop() ::
        '+' | '-' | '*' | '/' | '//' | '%' | '**' | '~'
      | '==' | '!=' | '<' | '<=' | '>' | '>=' | 'in' | 'not in'.

%% Positional args, keyword args, and the *seq / **map forms. The two splats
%% are kept separate rather than smuggled into the lists so that codegen can
%% see at a glance whether a call is statically shaped.
-type beamai_jinja_args() ::
        {Positional :: [beamai_jinja_expr()],
         Keyword    :: [{atom(), beamai_jinja_expr()}],
         Splat      :: beamai_jinja_expr() | undefined,
         DoubleSplat:: beamai_jinja_expr() | undefined}.

%% `and'/`or' are separate node types rather than binops because they compile
%% to a case rather than a call: both are short-circuiting and must evaluate
%% their left operand exactly once (designs/11-jinja-codegen.md section 3.2).
-type beamai_jinja_expr() ::
      {lit,    beamai_html_loc(), term()}
    | {name,   beamai_html_loc(), atom()}
    | {attr,   beamai_html_loc(), beamai_jinja_expr(), atom()}
    | {sub,    beamai_html_loc(), beamai_jinja_expr(), beamai_jinja_expr()}
    | {slice,  beamai_html_loc(), beamai_jinja_expr(),
               From :: beamai_jinja_expr() | undefined,
               To   :: beamai_jinja_expr() | undefined,
               Step :: beamai_jinja_expr() | undefined}
    | {binop,  beamai_html_loc(), beamai_jinja_binop(), beamai_jinja_expr(), beamai_jinja_expr()}
    | {unop,   beamai_html_loc(), '+' | '-' | 'not', beamai_jinja_expr()}
    | {'and',  beamai_html_loc(), beamai_jinja_expr(), beamai_jinja_expr()}
    | {'or',   beamai_html_loc(), beamai_jinja_expr(), beamai_jinja_expr()}
    | {'cond', beamai_html_loc(), beamai_jinja_expr(), beamai_jinja_expr(),
               beamai_jinja_expr() | undefined}
    %% The loc of a filter or test is the loc of its NAME, not of the whole
    %% expression: `{{ a|f1|nosuch|f3 }}' must point at nosuch.
    | {filter, beamai_html_loc(), atom(), beamai_jinja_expr(), beamai_jinja_args()}
    | {test,   beamai_html_loc(), atom(), beamai_jinja_expr(), beamai_jinja_args(),
               Negated :: boolean()}
    | {call,   beamai_html_loc(), beamai_jinja_expr(), beamai_jinja_args()}
    | {tuple,  beamai_html_loc(), [beamai_jinja_expr()]}
    | {list,   beamai_html_loc(), [beamai_jinja_expr()]}
    | {map,    beamai_html_loc(), [{beamai_jinja_expr(), beamai_jinja_expr()}]}.

%%%===================================================================
%%% Statement AST
%%%===================================================================

%% The target of extends/include/import/from starts life as the literal path
%% written in the template and becomes a module name once
%% beamai_jinja_ast:resolve_targets/2 has run -- exactly as a mustache partial does
%% (beamai_mustache.hrl, beamai_mustache_partial_target()).
%%   before: <<"layout/base.j2">>
%%   after:  j2_layout_base
%% An beamai_jinja_expr() here is a dynamic target, which is rejected in v1
%% (deviation J11); the alternative is kept in the type so the rejection has a
%% shape to match on and so v2 has somewhere to put dynamic dispatch.
-type beamai_jinja_target() :: binary() | module() | beamai_jinja_expr().

%% Left-hand side of {% set %}. The {attr, ...} form is a namespace
%% assignment; the parser produces it unconditionally and the compiler rejects
%% it (deviation J16).
-type beamai_jinja_setname() :: atom() | {attr, beamai_jinja_expr(), atom()}.

-type beamai_jinja_param() :: {atom(), Default :: beamai_jinja_expr() | undefined}.

%% NOTE: cannot be called node/0 -- that is an Erlang builtin type.
-type beamai_jinja_node() ::
      {text,      beamai_html_loc(), binary()}
    | {output,    beamai_html_loc(), beamai_jinja_expr()}
      %% Branches are a flat list, not nested ifs: an elif chain is often long
      %% and nesting would make codegen recurse once per elif
      %% (designs/09-jinja-syntax.md section 5.2).
    | {'if',      beamai_html_loc(),
                  [{beamai_jinja_expr(), [beamai_jinja_node()]}],
                  Else :: [beamai_jinja_node()]}
    | {'for',     beamai_html_loc(),
                  Targets   :: [atom()],
                  Iter      :: beamai_jinja_expr(),
                  Filter    :: beamai_jinja_expr() | undefined,
                  Recursive :: boolean(),
                  Body      :: [beamai_jinja_node()],
                  Else      :: [beamai_jinja_node()]}
    | {set,       beamai_html_loc(), beamai_jinja_setname(), beamai_jinja_expr()}
    | {set_block, beamai_html_loc(), beamai_jinja_setname(), [beamai_jinja_node()],
                  Filter :: beamai_jinja_expr() | undefined}
    | {with,      beamai_html_loc(), [{atom(), beamai_jinja_expr()}], [beamai_jinja_node()]}
    | {filter,    beamai_html_loc(), beamai_jinja_expr(), [beamai_jinja_node()]}
    | {include,   beamai_html_loc(), beamai_jinja_target(),
                  IgnoreMissing :: boolean(), WithContext :: boolean()}
    | {do,        beamai_html_loc(), beamai_jinja_expr()}
    | {block,     beamai_html_loc(), Name :: atom(),
                  Scoped :: boolean(), Required :: boolean(),
                  [beamai_jinja_node()]}
    | {extends,   beamai_html_loc(), beamai_jinja_target()}
    | {macro,     beamai_html_loc(), Name :: atom(), [beamai_jinja_param()],
                  [beamai_jinja_node()]}
    | {call,      beamai_html_loc(), [beamai_jinja_param()], beamai_jinja_expr(),
                  [beamai_jinja_node()]}
    | {import,    beamai_html_loc(), beamai_jinja_target(), As :: atom(),
                  WithContext :: boolean()}
    | {from,      beamai_html_loc(), beamai_jinja_target(),
                  [{Name :: atom(), As :: atom()}], WithContext :: boolean()}.

%%%===================================================================
%%% Options
%%%===================================================================

%% The five booleans below all change the generated code and therefore all go
%% into the build stamp. `suffix' does not (it only feeds the existence check)
%% and `views_abs' must not (it is absolute, and would stamp the developer's
%% home directory into every artefact).
%%
%% The defaults are NOT CPython jinja2's: trim_blocks and lstrip_blocks are on
%% here (designs/10-jinja-semantics.md, deviation J8).
-type beamai_jinja_opts() :: #{
        module     := module(),
        source     := beamai_html_path(),
        prefix     => beamai_html_path(),           % default <<"j2_">>
        views      => beamai_html_path(),
        views_abs  => beamai_html_path(),           % resolved; kept out of the stamp
        suffix     => beamai_html_path(),           % default <<".j2">>
        extensions => [module()],
        templates  => #{binary() => binary()},  % ad-hoc sets, no views dir
        macros     => #{module() => [atom()]},  % what each target exports
        escape                => boolean(),     % default true
        trim_blocks           => boolean(),     % default true
        lstrip_blocks         => boolean(),     % default true
        keep_trailing_newline => boolean(),     % default false
        strict_undefined      => boolean(),     % default false
        line_map              => boolean(),     % default true
        origin                => file | string
       }.

-define(BEAMAI_JINJA_DEFAULT_PREFIX, <<"j2_">>).
-define(BEAMAI_JINJA_DEFAULT_SUFFIX, <<".j2">>).

%%%===================================================================
%%% Errors
%%%===================================================================

-type beamai_jinja_reason() ::
    %% scanner / parser
      {unclosed_block, atom(), beamai_html_loc()}
    | {mismatched_end, Expected :: atom(), Got :: atom()}
    | {block_name_mismatch, atom(), atom()}
    | {duplicate_block, atom(), beamai_html_loc()}
    | {orphan_clause, atom()}
    | {unknown_statement, atom()}
    | {unexpected_token, term()}
    | {chained_comparison, beamai_html_loc()}
    | {invalid_utf8, non_neg_integer()}
    %% resolution
    | {dynamic_target_unsupported, beamai_html_loc()}
    | {template_not_found, binary()}
    | {extends_cycle, [module()]}
    | {macro_not_found, atom(), module()}
    %% compilation
    | {unknown_filter, atom()}
    | {unknown_test, atom()}
    | {filter_name_conflict, atom(), module()}
    | {namespace_assignment_unsupported, beamai_html_loc()}
    | {super_outside_block, beamai_html_loc()}
    | {target_in_inline_template, atom()}
    | {mutual_macro_in_inline, [atom()]}
    | {unexpected_remote_calls, [module()]}
    %% runtime, raised as {beamai_jinja, Reason}
    | {required_block_not_provided, atom()}
    | {undefined_operation, atom()}
    | division_by_zero
    | {unsupported_operands, atom(), term(), term()}
    | {not_iterable, term()}
    | {not_callable, term()}
    | {not_renderable, term()}.

-type beamai_jinja_error() :: beamai_html_error(beamai_jinja_reason()).

%%%===================================================================
%%% Generated module self-description
%%%===================================================================

%% Carried by every generated module as -jinja_source. The plugin reads it for
%% incremental compilation and beamai_jinja_dev reads it for hot reloading;
%% neither keeps any state of its own.
%%
%% `origin' is present only for a module compiled from a string, which has no
%% file to go stale against -- same arrangement as beamai_mustache_source().
%%
%% `opts' is a SORTED LIST rather than a map, because a map prints in
%% maps:to_list/1 order and that follows the VM's atom table: the same build
%% run twice would otherwise produce different bytes.
-type beamai_jinja_source() :: #{
        path   := binary(),
        stamp  := binary(),
        mtime  := integer(),
        vsn    := pos_integer(),
        opts   := [{atom(), term()}],
        origin => file | string
       }.

-endif.
