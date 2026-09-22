%%%-------------------------------------------------------------------
%%% @doc parse_transform for the two markdown source forms.
%%%
%%% ```
%%% -module(my_pages).
%%% -compile({parse_transform, beamai_markdown_transform}).
%%%
%%% -markdown_document({about, "docs/about.md"}).     % (a)
%%%
%%% banner() ->                                       % (b)
%%%     beamai_markdown:inline(~"# Hello *there*").
%%% '''
%%%
%%% <ul>
%%%   <li><b>(a) `-markdown_document'</b> renders a file at compile time into
%%%       `Name/0' (a binary) and `Name_iolist/0', and exports them. Without
%%%       the transform the functions simply are not there. The attribute is
%%%       kept in the beam, as -jinja_template is, so a module still says
%%%       which documents it was built from.</li>
%%%   <li><b>(b) `beamai_markdown:inline/1'</b> with a binary literal is
%%%       replaced by the HTML it renders to, as a literal. Without the
%%%       transform the same call renders at run time with identical
%%%       output.</li>
%%% </ul>
%%%
%%% There is no extension-declaring attribute: the pipeline comes from
%%% `{markdown_opts, [{extensions, [...]}, {views, "dir"}]}' in erl_opts
%%% (`render' passes options to the HTML renderer), and what the transform
%%% folds is exactly what beamai_markdown:to_html/3 renders at run time
%%% with the same options.
%%%
%%% The passes and diagnostics mirror beamai_jinja_transform.
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_transform).

-export([parse_transform/2, format_error/1]).

-record(st, {file            :: file:filename_all(),
             module          :: module() | undefined,
             opts            :: [term()],
             %% {Name, Path, Anno}
             documents  = [] :: [{atom(), string(), erl_anno:anno()}],
             defined    = [] :: [{atom(), arity()}],
             errors     = [] :: [diag()],
             warnings   = [] :: [diag()]}).

-type diag()  :: {file:filename_all(), erl_anno:location(), term()}.
-type forms() :: [erl_parse:abstract_form() | {eof, erl_anno:anno()}].

%%%===================================================================
%%% Entry point
%%%===================================================================

-spec parse_transform(forms(), [term()]) ->
          forms()
        | {warning, forms(), [{file:filename_all(), [tuple()]}]}
        | {error, [{file:filename_all(), [tuple()]}],
                  [{file:filename_all(), [tuple()]}]}.
parse_transform(Forms, Opts) ->
    File = file_of(Forms),
    St0 = #st{file = File, module = module_of(Forms), opts = Opts},
    St1 = lists:foldl(fun collect/2, St0, Forms),
    {Forms1, St2} = lists:mapfoldl(fun expand/2, St1#st{file = File}, Forms),
    {Forms2, St3} = inject_all(Forms1, St2#st{file = File}),
    result(Forms2, St3).

result(Forms, #st{errors = [], warnings = []}) ->
    Forms;
result(Forms, #st{errors = [], warnings = Ws}) ->
    {warning, Forms, group(Ws)};
result(_Forms, #st{errors = Es, warnings = Ws}) ->
    {error, group(Es), group(Ws)}.

group(Diags0) ->
    Diags = lists:reverse(Diags0),
    Files = lists:usort([F || {F, _, _} <- Diags]),
    [{F, lists:keysort(1, [{Loc, ?MODULE, R} || {F1, Loc, R} <- Diags, F1 =:= F])}
     || F <- Files].

%%%===================================================================
%%% Pass 1: collect
%%%===================================================================

collect({attribute, _, file, {F, _}}, St) ->
    St#st{file = F};
collect({attribute, _, module, M}, St) ->
    St#st{module = M};
collect({attribute, A, markdown_document, Term}, St) ->
    collect_document(A, Term, St);
collect({function, _, Name, Arity, _}, St) ->
    St#st{defined = [{Name, Arity} | St#st.defined]};
collect(_, St) ->
    St.

collect_document(A, Term, St) ->
    case beamai_html_path:template_spec(Term) of
        error ->
            error_at(A, {bad_markdown_document, Term}, St);
        {ok, {Name, Path}} ->
            case lists:keymember(Name, 1, St#st.documents) of
                true  -> error_at(A, {duplicate_document_name, Name}, St);
                false -> St#st{documents = St#st.documents ++ [{Name, Path, A}]}
            end
    end.

%%%===================================================================
%%% Pass 2: expand
%%%===================================================================

expand({attribute, _, file, {F, _}} = Form, St) ->
    {Form, St#st{file = F}};
expand({function, A, Name, Arity, Clauses}, St) ->
    {Clauses1, St1} = expr(Clauses, St),
    {{function, A, Name, Arity, Clauses1}, St1};
expand(Form, St) ->
    {Form, St}.

%% Blind descent through every tuple and list, except the positions that
%% are not expressions: clause patterns and guards, generator patterns.
expr({call, A, {remote, _, {atom, _, beamai_markdown}, {atom, _, inline}}, [Tpl]} = Call, St) ->
    inline_call(A, Tpl, Call, St);
expr({clause, A, Patterns, Guards, Body}, St) ->
    {Body1, St1} = expr(Body, St),
    {{clause, A, Patterns, Guards, Body1}, St1};
expr({Gen, A, Pattern, Source}, St)
  when Gen =:= generate; Gen =:= generate_strict;
       Gen =:= b_generate; Gen =:= b_generate_strict;
       Gen =:= m_generate; Gen =:= m_generate_strict ->
    {Source1, St1} = expr(Source, St),
    {{Gen, A, Pattern, Source1}, St1};
expr({'fun', _, {function, _, _}} = F, St) ->
    {F, St};
expr(T, St) when is_tuple(T) ->
    {L, St1} = expr(tuple_to_list(T), St),
    {list_to_tuple(L), St1};
expr([H | T], St) ->
    {H1, St1} = expr(H, St),
    {T1, St2} = expr(T, St1),
    {[H1 | T1], St2};
expr(Other, St) ->
    {Other, St}.

inline_call(A, Tpl, Call, St0) ->
    {Tpl1, St1} = expr(Tpl, St0),
    case literal_binary(Tpl1) of
        error     -> {rebuild(Call, Tpl1), warn_not_literal(A, St1)};
        {ok, Bin} -> do_expand(A, Bin, rebuild(Call, Tpl1), St1)
    end.

rebuild({call, A, Remote, _}, Tpl) -> {call, A, Remote, [Tpl]}.

literal_binary({bin, _, _} = Expr) ->
    try erl_parse:normalise(Expr) of
        Bin when is_binary(Bin) -> {ok, Bin};
        _                       -> error
    catch _:_ -> error
    end;
literal_binary(_) ->
    error.

warn_not_literal(A, St) ->
    case lists:member(nowarn_markdown_inline, St#st.opts) of
        true  -> St;
        false -> warn_at(A, inline_not_literal, St)
    end.

do_expand(A, Bin, Call, St) ->
    case render(Bin, St) of
        {error, Reason} ->
            {Call, error_at(A, Reason, St)};
        {ok, Html} ->
            {beamai_html_forms:bin(A, Html), St}
    end.

%% @doc Render with the module's markdown_opts: the same pipeline and the
%% same renderer options beamai_markdown:to_html/3 would use at run time.
render(Body, St) ->
    Opts = markdown_opts(St),
    try
        Pipe = beamai_markdown:pipeline(proplists:get_value(extensions, Opts, [])),
        {ok, beamai_markdown:to_html(Body, Pipe, to_map(proplists:get_value(render, Opts, #{})))}
    catch
        error:{unknown_markdown_extension, E} -> {error, {unknown_extension, E}};
        C:R:Stack -> {error, {render_failed, {C, R, Stack}}}
    end.

to_map(M) when is_map(M) -> M;
to_map(L) when is_list(L) -> maps:from_list(L).

%%%===================================================================
%%% Pass 3: inject
%%%===================================================================

inject_all(Forms, #st{documents = []} = St) ->
    {Forms, St};
inject_all(Forms, St0) ->
    {Blocks, Exports, St1} =
        lists:foldl(fun(T, Acc) -> inject_one(T, Acc) end, {[], [], St0}, St0#st.documents),
    case Exports of
        [] -> {Forms, St1};
        _  -> {splice(Forms, lists:reverse(Exports), lists:reverse(Blocks), St1), St1}
    end.

inject_one({Name, Path, A}, {Blocks, Exports, St}) ->
    IolistName = iolist_name(Name),
    case clash(Name, IolistName, St) of
        {clash, Fun} ->
            {Blocks, Exports, error_at(A, {document_name_clash, Fun}, St)};
        ok ->
            case resolve(Path, St) of
                {error, Tried} ->
                    {Blocks, Exports, error_at(A, {document_not_found, Path, Tried}, St)};
                {ok, Abs} ->
                    compile_document(Name, IolistName, Abs, {Blocks, Exports, St})
            end
    end.

clash(Name, IolistName, St) ->
    case [F || F <- [{Name, 0}, {IolistName, 0}], lists:member(F, St#st.defined)] of
        [F | _] -> {clash, F};
        []      -> ok
    end.

iolist_name(Name) -> list_to_atom(atom_to_list(Name) ++ "_iolist").

compile_document(Name, IolistName, Abs, {Blocks, Exports, St}) ->
    case file:read_file(Abs) of
        {error, Posix} ->
            {Blocks, Exports, add(errors, {to_list(Abs), 1, {document_unreadable, Posix}}, St)};
        {ok, Body} ->
            case render(Body, St) of
                {error, Reason} ->
                    {Blocks, Exports, add(errors, {to_list(Abs), 1, Reason}, St)};
                {ok, Html} ->
                    L = erl_anno:new(0),
                    Block = [{attribute, L, file, {to_list(Abs), 1}},
                             beamai_html_forms:spec(L, Name, [], beamai_html_forms:t(L, binary)),
                             beamai_html_forms:fn(L, Name, [], [beamai_html_forms:bin(L, Html)]),
                             beamai_html_forms:spec(L, IolistName, [], beamai_html_forms:t(L, iolist)),
                             beamai_html_forms:fn(L, IolistName, [],
                                                  [beamai_html_forms:loc_call(L, Name, [])])],
                    {[Block | Blocks], [{IolistName, 0}, {Name, 0} | Exports], St}
            end
    end.

splice(Forms, Exports, Blocks, St) ->
    A = erl_anno:new(0),
    Export = {attribute, A, export, Exports},
    Restore = {attribute, A, file, {to_list(St#st.file), 1}},
    {Main, Eof}  = lists:splitwith(fun(F) -> element(1, F) =/= eof end, Forms),
    {Head, Body} = lists:splitwith(fun(F) -> element(1, F) =/= function end, Main),
    Head ++ [Export] ++ Body ++ lists:append(Blocks) ++ [Restore] ++ Eof.

%%%===================================================================
%%% Options
%%%===================================================================

markdown_opts(#st{opts = Opts}) ->
    lists:foldl(fun({markdown_opts, L}, Acc) when is_list(L) -> Acc ++ L;
                   ({markdown_opts, M}, Acc) when is_map(M)  -> Acc ++ maps:to_list(M);
                   (_, Acc)                                  -> Acc
                end, [], Opts).

resolve(Path, St) ->
    Dirs = [filename:dirname(St#st.file)]
        ++ views_dirs(St)
        ++ [D || {i, D} <- St#st.opts]
        ++ ["."],
    case beamai_html_path:resolve(Path, Dirs) of
        {ok, Abs}                   -> {ok, Abs};
        {error, {not_found, Tried}} -> {error, Tried}
    end.

views_dirs(St) ->
    case proplists:get_value(views, markdown_opts(St), undefined) of
        undefined -> [];
        V         -> [to_list(V)]
    end.

%%%===================================================================
%%% Diagnostics
%%%===================================================================

error_at(A, Reason, St) -> add(errors, {St#st.file, erl_anno:line(A), Reason}, St).
warn_at(A, Reason, St)  -> add(warnings, {St#st.file, erl_anno:line(A), Reason}, St).

add(errors, D, St)   -> St#st{errors = [D | St#st.errors]};
add(warnings, D, St) -> St#st{warnings = [D | St#st.warnings]}.

file_of(Forms) ->
    case [F || {attribute, _, file, {F, _}} <- Forms] of
        [F | _] -> F;
        []      -> "nofile"
    end.

module_of(Forms) ->
    case [M || {attribute, _, module, M} <- Forms] of
        [M | _] -> M;
        []      -> undefined
    end.

to_list(B) when is_binary(B) -> unicode:characters_to_list(B);
to_list(L)                   -> L.

-spec format_error(term()) -> string().
format_error({bad_markdown_document, Term}) ->
    f("-markdown_document takes {Name, \"path/to/doc.md\"} or just the path. "
      "Got ~p", [Term]);
format_error({duplicate_document_name, Name}) ->
    f("two -markdown_document attributes both want to define ~p/0", [Name]);
format_error({document_name_clash, {F, A}}) ->
    f("-markdown_document would define ~p/~p, which this module already "
      "defines by hand", [F, A]);
format_error({document_not_found, Path, Tried}) ->
    f("-markdown_document: ~ts not found. Looked in: ~ts",
      [Path, string:join([to_list(D) || D <- Tried], ", ")]);
format_error({document_unreadable, Posix}) ->
    f("-markdown_document: the document could not be read (~p)", [Posix]);
format_error({unknown_extension, E}) ->
    f("markdown_opts names an extension that does not exist: ~p. See "
      "beamai_markdown:extensions/0", [E]);
format_error({render_failed, {C, R, _}}) ->
    f("rendering the document failed: ~p:~p", [C, R]);
format_error(inline_not_literal) ->
    "beamai_markdown:inline/1 was left as a run-time call because its argument "
    "is not a binary literal. The output is the same; only the cost differs. "
    "Silence this with the nowarn_markdown_inline compile option";
format_error(Other) ->
    f("~p", [Other]).

f(Fmt, Args) -> lists:flatten(io_lib:format(Fmt, Args)).
