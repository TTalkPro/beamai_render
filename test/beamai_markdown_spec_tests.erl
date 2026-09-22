%%%-------------------------------------------------------------------
%%% @doc The markdown conformance suites.
%%%
%%% CommonMark 0.31.2 (652 examples) through the CommonMark-only pipeline,
%%% the normalize and roundtrip specs through their renderers, and every
%%% extension's markdig spec file through a pipeline with that extension
%%% (and whatever markdig's own test enables alongside it). One EUnit test
%%% per example, named after the spec file, section and number.
%%%
%%% The counts are asserted so that a spec file cannot quietly lose its
%%% examples to a parsing slip in the test library.
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_spec_tests).

-include_lib("eunit/include/eunit.hrl").

-define(LIB, beamai_markdown_test_lib).

%% {SpecFile, Pipeline, ExpectedCount, RenderOpts}
suites() ->
    [{"CommonMark.md", [], 652, #{}},
     {"NormalizeHeadings.md", [], 3, #{renderer => normalize}},
     {"RoundtripCommonMark.md", [], 649, #{renderer => roundtrip}}
     | extension_suites()].

%% markdig's own test configuration for each extension spec.
extension_suites() ->
    Available = [Name || {Name, Mod} <- beamai_markdown:extensions(),
                         code:ensure_loaded(Mod) =:= {module, Mod}],
    Has = fun(Names) -> lists:all(fun(N) -> lists:member(N, Available) end, Names) end,
    [S || {_, Exts, _, _} = S <- all_extension_suites(), Has(ext_names(Exts))].

ext_names(Exts) -> [case E of {N, _} -> N; N -> N end || E <- Exts].

all_extension_suites() ->
    [{"TaskListSpecs.md",          [task_lists], 2, #{}},
     {"PipeTableSpecs.md",         [pipe_tables], 28, #{}},
     {"PipeTableGfmSpecs.md",      [{pipe_tables, #{use_header_for_column_count => true}}], 25, #{}},
     {"EmphasisExtraSpecs.md",     [emphasis_extras], 6, #{}},
     {"AutoLinks.md",              [auto_links], 26, #{}},
     {"AutoIdentifierSpecs.md",    [auto_identifiers], 11, #{}},
     {"FootnotesSpecs.md",         [footnotes], 4, #{}},
     {"HardlineBreakSpecs.md",     [hardline_breaks], 1, #{}},
     {"DiagramsSpecs.md",          [diagrams], 2, #{}},
     {"NoHtmlSpecs.md",            [disable_html], 2, #{}},
     {"ListExtraSpecs.md",         [list_extras], 8, #{}},
     {"AlertBlockSpecs.md",        [alerts], 5, #{}},
     {"YamlSpecs.md",              [yaml_front_matter], 9, #{}},
     {"CustomContainerSpecs.md",   [custom_containers, generic_attributes], 9, #{}},
     {"GenericAttributesSpecs.md", [generic_attributes], 4, #{}},
     {"MathSpecs.md",              [mathematics, generic_attributes], 17, #{}},
     {"FigureFooterAndCiteSpecs.md", [figures, footers, citations], 3, #{}},
     {"AbbreviationSpecs.md",      [abbreviations], 14, #{}},
     {"JiraLinks.md",              [{jira_links, #{base_url => <<"http://your.company.abc">>}}], 14, #{}},
     {"BootstrapSpecs.md",         [bootstrap, pipe_tables, figures, generic_attributes, alerts], 4, #{}},
     {"DefinitionListSpecs.md",    [definition_lists, generic_attributes], 6, #{}},
     {"GridTableSpecs.md",         [grid_tables], 12, #{}},
     {"MediaSpecs.md",             [media_links], 1, #{}},
     {"SmartyPantsSpecs.md",       [pipe_tables, smarty_pants], 20, #{}},
     {"EmojiSpecs.md",             [pipe_tables, emoji], 6, #{}},
     {"GlobalizationSpecs.md",     [advanced, emoji, globalization], 4, #{}},
     {"CJKFriendlyEmphasis.md",    [cjk_friendly_emphasis], 3, #{skip => [2]}}].

counts_test_() ->
    [{File ++ " has " ++ integer_to_list(N) ++ " examples",
      fun() -> ?assertEqual(N, length(?LIB:load(File))) end}
     || {File, _, N, _} <- suites()].

conformance_test_() ->
    [suite(S) || S <- suites()].

suite({File, Exts, _, Opts}) ->
    Pipe = beamai_markdown:pipeline(Exts),
    Skip = maps:get(skip, Opts, []),
    RenderOpts = maps:without([skip], Opts),
    {File,
     [{title(File, Ex), fun() -> assert_example(Ex, Pipe, RenderOpts) end}
      || Ex <- ?LIB:load(File), not lists:member(maps:get(number, Ex), Skip)]}.

title(File, #{number := N, section := S}) ->
    lists:flatten(io_lib:format("~s #~b ~ts", [File, N, S])).

assert_example(#{markdown := Md, html := Expected} = Ex, Pipe, Opts) ->
    case ?LIB:run(Ex, Pipe, Opts) of
        {true, _} -> ok;
        {false, Actual} ->
            case Opts of
                #{renderer := roundtrip} -> ?assertEqual(Md, Actual);
                #{renderer := normalize} -> ?assertEqual({Md, Expected}, {Md, Actual});
                _ -> ?assertEqual({Md, ?LIB:compact(Expected)}, {Md, ?LIB:compact(Actual)})
            end
    end.
