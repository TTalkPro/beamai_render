%%%-------------------------------------------------------------------
%%% @doc Tests for beamai_markdown_transform: the two source forms and
%%% their diagnostics. Every case compiles a real module, as the jinja
%%% transform tests do, because that is the only way to prove a
%%% parse_transform works.
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_transform_tests).

-include_lib("eunit/include/eunit.hrl").

fixture_dir() ->
    filename:join(code:lib_dir(beamai_render), "test/fixtures_transform").

fixture_forms(Mod) ->
    {ok, Forms} = epp:parse_file(filename:join(fixture_dir(), atom_to_list(Mod) ++ ".erl.src"),
                                 [fixture_dir()], []),
    Forms.

compile_fixture(Mod, Opts) ->
    compile:forms(fixture_forms(Mod), [binary, return | Opts]).

load_fixture(Mod, Opts) ->
    {ok, Mod, Bin, _Ws} = compile_fixture(Mod, Opts),
    _ = code:purge(Mod),
    {module, Mod} = code:load_binary(Mod, atom_to_list(Mod), Bin),
    Mod.

opts() -> [{markdown_opts, [{views, fixture_dir()}, {extensions, [task_lists, emoji]}]}].

both_forms_test_() ->
    Mod = load_fixture(mf_all, opts()),
    Expected = <<"<h1>Doc</h1>\n<p>A <em>document</em> with a <a href=\"/u\">link</a>.</p>\n"
                 "<ul class=\"contains-task-list\">\n"
                 "<li class=\"task-list-item\"><input disabled=\"disabled\" type=\"checkbox\" /> todo</li>\n"
                 "</ul>\n">>,
    [{"inline folds to its HTML, through the configured extensions",
      ?_assertEqual(<<"<p>Hello <em>there</em> ", 16#1F603/utf8, "</p>\n">>, Mod:banner())},
     {"file document becomes Name/0", ?_assertEqual(Expected, Mod:doc())},
     {"and Name_iolist/0", ?_assertEqual(Expected, iolist_to_binary(Mod:doc_io()))},
     {"two expansions in one function",
      ?_assertEqual([<<"<p>a</p>\n">>, <<"<p>b</p>\n">>], Mod:twice())},
     {"the attribute is kept in the beam",
      ?_assertMatch([{page, "views/md_doc.md"}],
                    proplists:get_value(markdown_document, Mod:module_info(attributes)))},
     {"render options reach the renderer",
      fun() ->
              M = load_fixture(mf_all, [{markdown_opts, [{views, fixture_dir()},
                                                         {render, #{base_url => <<"http://h/">>}}]}]),
              ?assert(binary:match(M:doc(), <<"href=\"http://h/u\"">>) =/= nomatch)
      end},
     {"the expansion is a literal",
      fun() ->
              Forms = beamai_markdown_transform:parse_transform(fixture_forms(mf_all), opts()),
              [{function, _, banner, 0, [{clause, _, [], [], [Body]}]}] =
                  [F || {function, _, banner, 0, _} = F <- Forms],
              ?assertMatch({bin, _, _}, Body)
      end}].

%% The folded result must be what the run-time path produces.
expansion_matches_run_time_test() ->
    Mod = load_fixture(mf_all, opts()),
    ?assertEqual(beamai_markdown:to_html(<<"Hello *there* :)">>, [task_lists, emoji]), Mod:banner()).

non_literal_warns_and_still_works_test() ->
    {ok, mf_not_literal, Bin, Ws} = compile_fixture(mf_not_literal, []),
    ?assert(reason_present(Ws, inline_not_literal)),
    _ = code:purge(mf_not_literal),
    {module, _} = code:load_binary(mf_not_literal, "mf_not_literal", Bin),
    ?assertEqual(<<"<p><em>x</em></p>\n">>, mf_not_literal:f(<<"*x*">>)),
    {ok, mf_not_literal, _, Ws2} = compile_fixture(mf_not_literal, [nowarn_markdown_inline]),
    ?assertNot(reason_present(Ws2, inline_not_literal)).

missing_document_lists_the_directories_test() ->
    {error, Es, _} = compile_fixture(mf_missing, []),
    ?assert(reason_present(Es, document_not_found)),
    Msg = beamai_markdown_transform:format_error({document_not_found, "views/x.md", ["a", "b"]}),
    ?assertNotEqual(nomatch, string:find(Msg, "a, b")).

name_clash_is_an_error_test() ->
    {error, Es, _} = compile_fixture(mf_clash, opts()),
    ?assert(reason_present(Es, document_name_clash)).

bad_attributes_are_errors_test() ->
    {error, Es, _} = compile_fixture(mf_bad_attr, opts()),
    ?assert(reason_present(Es, bad_markdown_document)),
    ?assert(reason_present(Es, duplicate_document_name)).

unknown_extension_is_an_error_test() ->
    {error, Es, _} = compile_fixture(mf_all, [{markdown_opts, [{views, fixture_dir()}, {extensions, [bogus]}]}]),
    ?assert(reason_present(Es, unknown_extension)).

no_markdown_forms_is_a_no_op_test() ->
    Forms = fixture_forms(jf_filters),
    ?assertEqual(Forms, beamai_markdown_transform:parse_transform(Forms, [])).

idempotent_test() ->
    Forms = fixture_forms(mf_not_literal),
    Once = strip(beamai_markdown_transform:parse_transform(Forms, [nowarn_markdown_inline])),
    Twice = strip(beamai_markdown_transform:parse_transform(Once, [nowarn_markdown_inline])),
    ?assertEqual(Once, Twice).

strip({warning, Forms, _}) -> Forms;
strip(Forms) -> Forms.

format_error_covers_every_reason_test() ->
    [?assert(is_list(beamai_markdown_transform:format_error(R)))
     || R <- [{bad_markdown_document, x}, {duplicate_document_name, a}, {document_name_clash, {a, 0}},
              {document_not_found, "p", ["d"]}, {document_unreadable, eacces}, {unknown_extension, x},
              {render_failed, {error, boom, []}}, inline_not_literal, other]].

reason_present(Groups, Reason) ->
    lists:any(fun({_File, Ds}) -> lists:any(fun({_, _, R}) -> tag(R) =:= Reason end, Ds) end, Groups).

tag(R) when is_tuple(R) -> element(1, R);
tag(R) -> R.
