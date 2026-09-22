%%%-------------------------------------------------------------------
%%% @doc The markdown engine's behaviour beyond the spec files: the facade,
%%% the normalize renderer's unit cases, the roundtrip of other line
%%% endings, and the extensions markdig tests without a spec file (pragma
%%% lines, self pipeline, referral links, emoji options, SmartyPants
%%% mappings, disabled headings, non-ASCII URLs). Mirrors cl-markding's
%%% tests/test-extensions.lisp and test-normalize.lisp.
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_tests).

-include_lib("eunit/include/eunit.hrl").

-define(P(Exts), beamai_markdown:pipeline(Exts)).

%%%===================================================================
%%% Facade
%%%===================================================================

to_html_test() ->
    ?assertEqual(<<"<p>Hello <em>world</em>!</p>\n">>, beamai_markdown:to_html(<<"Hello *world*!">>)).

to_plain_text_test() ->
    ?assertEqual(<<"Hello world!\n">>, beamai_markdown:to_plain_text(<<"Hello *world*!">>)).

chardata_input_test() ->
    ?assertEqual(<<"<h1>Hi</h1>\n">>, beamai_markdown:to_html("# Hi")).

parse_and_render_test() ->
    Doc = beamai_markdown:parse(<<"# Title\n\ntext\n">>),
    ?assertEqual(document, maps:get(k, Doc)),
    ?assertEqual(<<"<h1>Title</h1>\n<p>text</p>\n">>, beamai_markdown:render(Doc, html)),
    ?assertEqual(<<"Title\ntext\n">>, beamai_markdown:render(Doc, plain)).

pipeline_forms_test() ->
    Html = <<"<p>Hello <del>x</del></p>\n">>,
    ?assertEqual(Html, beamai_markdown:to_html(<<"Hello ~~x~~">>, [emphasis_extras])),
    ?assertEqual(Html, beamai_markdown:to_html(<<"Hello ~~x~~">>, emphasis_extras)),
    ?assertEqual(Html, beamai_markdown:to_html(<<"Hello ~~x~~">>, advanced)),
    P = beamai_markdown_pipeline:use(beamai_markdown_pipeline:new(), beamai_markdown_ext_emphasis_extras),
    ?assertEqual(Html, beamai_markdown:to_html(<<"Hello ~~x~~">>, P)).

unknown_extension_test() ->
    ?assertError({unknown_markdown_extension, bogus}, beamai_markdown:pipeline([bogus])).

every_extension_is_listed_and_loads_test() ->
    [?assertEqual({module, M}, code:ensure_loaded(M)) || {_, M} <- beamai_markdown:extensions()],
    ?assertEqual(34, length(beamai_markdown:extensions())).

extensions_compose_test() ->
    %% The first-batch composition test from cl-markding.
    P = ?P([task_lists, pipe_tables, emphasis_extras, auto_links, auto_identifiers, footnotes]),
    Md = <<"# Title\n\n- [x] done ~~gone~~\n\n| a | b |\n|---|---|\n| 1 | http://x.com |\n\nSee [Title] and [^1].\n\n[^1]: note\n">>,
    Html = beamai_markdown:to_html(Md, P),
    ?assert(binary:match(Html, <<"<h1 id=\"title\">">>) =/= nomatch),
    ?assert(binary:match(Html, <<"task-list-item">>) =/= nomatch),
    ?assert(binary:match(Html, <<"<del>gone</del>">>) =/= nomatch),
    ?assert(binary:match(Html, <<"<table>">>) =/= nomatch),
    ?assert(binary:match(Html, <<"<a href=\"http://x.com\">http://x.com</a>">>) =/= nomatch),
    ?assert(binary:match(Html, <<"href=\"#title\"">>) =/= nomatch),
    ?assert(binary:match(Html, <<"class=\"footnotes\"">>) =/= nomatch).

%%%===================================================================
%%% Normalize
%%%===================================================================

normalize_test_() ->
    Same = [<<"# Heading">>, <<"a\n\nb">>, <<"> quoted">>, <<"- a\n- b">>, <<"- a\n\n- b">>,
            <<"1. a\n2. b">>, <<"- a\n  - b">>, <<"```lisp\n(code)\n```">>, <<"    code">>,
            <<"***">>, <<"> - a\n> - b">>, <<"some *text*  and __bold__">>, <<"[text](/url)">>,
            <<"[text](/url \"title\")">>, <<"![alt](/img.png)">>, <<"<http://a.b>">>, <<"`code`">>,
            <<"``a ` b``">>, <<"&amp;">>, <<"\\*not em\\*">>, <<"a  \nb">>, <<"a\\\nb">>,
            <<"This is a [link][MyLink]\n\n[MyLink]: http://company.com">>,
            <<"This is a [link][]\n\n[link]: http://company.com">>,
            <<"This is a [link]\n\n[link]: http://company.com">>],
    Changed = [{<<"#     Heading   ">>, <<"# Heading">>},
               {<<"Heading\n=======">>, <<"# Heading">>},
               {<<"> q\n> > nested">>, <<"> q\n> \n> > nested">>},
               {<<"[MyLink]: http://company.com\nThis is a [link][MyLink]">>,
                <<"This is a [link][MyLink]\n\n[MyLink]: http://company.com">>}],
    [{binary_to_list(M), fun() -> ?assertEqual(trim(E), trim(beamai_markdown:normalize(M))) end}
     || {M, E} <- [{M, M} || M <- Same] ++ Changed].

trim(B) -> string:trim(B, both, "\n ").

%%%===================================================================
%%% Roundtrip
%%%===================================================================

roundtrip_newline_styles_test_() ->
    [{Name, fun() -> ?assertEqual(Md, beamai_markdown:to_roundtrip(Md)) end}
     || {Name, Md} <- [{"crlf", <<"# Title\r\n\r\n- item one\r\n- item two\r\n\r\n    code\r\n">>},
                       {"cr", <<"# Title\r\r- item one\r- item two\r\r    code\r">>},
                       {"no final newline", <<"# Title\n\ntext">>}]].

roundtrip_renders_changed_blocks_test() ->
    Doc = beamai_markdown:parse(<<"# Title\n\n\ntext   here\n">>),
    [H, P] = maps:get(children, Doc),
    %% An unchanged block copies its source, a changed one is re-rendered
    %% in its place, and a new one where it stands.
    Doc1 = Doc#{children => [H, P#{inlines => [#{k => text, v => <<"new">>}], changed => true}]},
    ?assertEqual(<<"# Title\n\n\nnew\n">>, beamai_markdown:render(Doc1, roundtrip)),
    New = #{k => thematic_break, ch => $*, count => 3, children => []},
    Doc2 = Doc#{children => [H, New, P]},
    ?assertEqual(<<"# Title\n***\n\n\ntext   here\n">>, beamai_markdown:render(Doc2, roundtrip)).

%%%===================================================================
%%% Extensions without a spec file
%%%===================================================================

pragma_lines_test() ->
    P = ?P([pragma_lines]),
    ?assertEqual(<<"<h1 id=\"pragma-line-0\">H</h1>\n<p id=\"pragma-line-2\">para</p>\n">>,
                 beamai_markdown:to_html(<<"# H\n\npara\n">>, P)),
    %% A taken id gets an anchor instead.
    ?assertEqual(<<"<h1 id=\"my-head\"><a id=\"pragma-line-0\"></a>My Head</h1>\n"
                   "<p id=\"pragma-line-2\">para</p>\n">>,
                 beamai_markdown:to_html(<<"# My Head\n\npara\n">>, ?P([auto_identifiers, pragma_lines]))),
    Doc = beamai_markdown:parse(<<"test1\n\ntest2\n\ntest3\n\ntest4\n\n# Heading\n\nLong para\non multiple\n"
                                  "lines\nto check that\nlines are\ncorrectly \nfound\n\n- item1\n- item2\n"
                                  "- item3\n\nThis is a last paragraph\n">>, P),
    [?assertEqual(L, beamai_markdown:find_closest_line(Doc, L)) || L <- [0, 2, 4, 6, 8, 10, 18, 19, 20, 22]],
    ?assertEqual(22, beamai_markdown:find_closest_line(Doc, 23)),
    %% Inside the long paragraph: under halfway stays, at or past jumps.
    [?assertEqual(E, beamai_markdown:find_closest_line(Doc, L))
     || {L, E} <- [{11, 10}, {12, 10}, {13, 10}, {14, 18}, {15, 18}, {16, 18}]],
    Doc2 = beamai_markdown:parse(<<"- item1\n  - item11\n  - item12\n    - item121\n  - item13\n"
                                   "    - item131\n      - item1311\n">>, P),
    [?assertEqual(L, beamai_markdown:find_closest_line(Doc2, L)) || L <- lists:seq(0, 6)],
    ?assertEqual(6, beamai_markdown:find_closest_line(Doc2, 50)).

self_pipeline_test() ->
    P = ?P([self_pipeline]),
    Smile = <<16#1F603/utf8>>,
    ?assertEqual(<<"<p>", Smile/binary, "</p>\n<!--markdig:emojis-->\n">>,
                 beamai_markdown:to_html(<<":)\n<!--markdig:emojis-->\n">>, P)),
    ?assertEqual(<<"<p>:)</p>\n">>, beamai_markdown:to_html(<<":)\n">>, P)),
    ?assertEqual(<<"<h1 id=\"hi\">Hi</h1>\n<!--MARKDIG:advanced-->\n">>,
                 beamai_markdown:to_html(<<"# Hi\n<!--MARKDIG:advanced-->\n">>, P)),
    ?assertEqual(<<"<p>", Smile/binary, "</p>\n">>,
                 beamai_markdown:to_html(<<":)\n">>, ?P([{self_pipeline, #{default_extensions => <<"emojis">>}}]))),
    ?assertEqual(<<"<p>", Smile/binary, "</p>\n<!--myext:emojis-->\n">>,
                 beamai_markdown:to_html(<<":)\n<!--myext:emojis-->\n">>, ?P([{self_pipeline, #{tag => <<"myext">>}}]))),
    ?assertError(self_pipeline_must_be_alone, ?P([pipe_tables, self_pipeline])),
    ?assertError({unknown_markdown_extension, <<"bogus">>},
                 beamai_markdown_ext_self_pipeline:configure(beamai_markdown_pipeline:new(), <<"advanced+bogus">>)),
    Gfm = beamai_markdown_pipeline:build(
            beamai_markdown_ext_self_pipeline:configure(beamai_markdown_pipeline:new(), <<"gfm-pipetables">>)),
    ?assertMatch(<<"<table>", _/binary>>, beamai_markdown:to_html(<<"a | b\n-- | --\n0 | 1\n">>, Gfm)).

referral_links_test() ->
    P = ?P([{referral_links, #{rels => [<<"nofollow">>, <<"noopener">>]}}]),
    ?assertEqual(<<"<p><a href=\"/u\" rel=\"nofollow noopener\">a</a> "
                   "<a href=\"http://x.com\" rel=\"nofollow noopener\">http://x.com</a></p>\n">>,
                 beamai_markdown:to_html(<<"[a](/u) <http://x.com>">>, P)).

emoji_options_test() ->
    NoSmiley = ?P([{emoji, #{enable_smileys => false}}]),
    ?assertEqual(<<"<p>:) ", 16#1F620/utf8, "</p>\n">>, beamai_markdown:to_html(<<":) :angry:">>, NoSmiley)),
    Custom = ?P([{emoji, #{mapping => #{shortcodes => [{<<":arrow:">>, <<"->">>}],
                                       smileys => [{<<"=>">>, <<":arrow:">>}]}}}]),
    ?assertEqual(<<"<p>a -&gt; b -&gt; c :)</p>\n">>, beamai_markdown:to_html(<<"a :arrow: b => c :)">>, Custom)).

smarty_pants_mapping_test() ->
    P = ?P([{smarty_pants, #{mapping => #{left_double_quote => <<"<<">>, right_double_quote => <<">>">>}}}]),
    %% Mapping values are HTML and go out as they are.
    ?assertEqual(<<"<p><<x>> &ndash; y</p>\n">>, beamai_markdown:to_html(<<"\"x\" -- y">>, P)).

disable_headings_test() ->
    P = ?P([disable_headings]),
    ?assertEqual(<<"<p># not</p>\n">>, beamai_markdown:to_html(<<"# not">>, P)),
    ?assertEqual(<<"<p>Setext\n===</p>\n">>, beamai_markdown:to_html(<<"Setext\n===">>, P)).

non_ascii_no_escape_test() ->
    Md = <<"[a](/f\xC3\xB6\xC3\xB6/\xE2\x98\x83)">>,
    ?assertEqual(<<"<p><a href=\"/f%C3%B6%C3%B6/%E2%98%83\">a</a></p>\n">>, beamai_markdown:to_html(Md)),
    ?assertEqual(<<"<p><a href=\"/f\xC3\xB6\xC3\xB6/\xE2\x98\x83\">a</a></p>\n">>,
                 beamai_markdown:to_html(Md, [non_ascii_no_escape])).

punycode_test() ->
    ?assertEqual(<<"n3h">>, beamai_markdown_punycode:encode("\x{2603}")),
    ?assertEqual(<<"bcher-kva">>, beamai_markdown_punycode:encode("b\x{FC}cher")),
    ?assertEqual(<<"http://xn--n3h.net/x">>, beamai_markdown_punycode:encode_domain(<<"http://\xE2\x98\x83.net/x">>)).

html_renderer_options_test() ->
    ?assertEqual(<<"<p><a href=\"http://x.com/a/b\">l</a></p>\n">>,
                 beamai_markdown:to_html(<<"[l](b)">>, [], #{base_url => <<"http://x.com/a/">>})),
    ?assertEqual(<<"<p><a href=\"/rewritten\">l</a></p>\n">>,
                 beamai_markdown:to_html(<<"[l](/x)">>, [], #{link_rewriter => fun(_) -> <<"/rewritten">> end})).
