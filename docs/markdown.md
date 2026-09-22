# The Markdown engine

[English](markdown.md) · [中文](markdown.zh-CN.md)

A CommonMark 0.31.2 parser with markdig's thirty extensions and four
renderers, ported from [markdig](https://github.com/xoofx/markdig) by way of
[cl-markding](https://github.com/DavidAlphaFox/cl-markding). It renders at run
time -- there is no build step -- and, like the rest of beamai_render, it has no
process, no ETS table and no cache: a pipeline is a plain map you build once
and pass around.

- CommonMark 0.31.2: **652/652** spec examples
- **30 extensions**, each passing its markdig spec file
- Four renderers: HTML, plain text, normalize (canonical Markdown) and
  roundtrip (**649/649** byte-exact)
- Zero dependencies; ~3 MB/s on the spec document

## Quick start

```erlang
beamai_markdown:to_html(~"Hello *world*!").
%% => <<"<p>Hello <em>world</em>!</p>\n">>

beamai_markdown:to_plain_text(~"Hello *world*!").
%% => <<"Hello world!\n">>

%% Extensions are enabled on a pipeline. Build it once, reuse it.
P = beamai_markdown:pipeline([pipe_tables, task_lists, footnotes]),
beamai_markdown:to_html(Text, P).

%% markdig's UseAdvancedExtensions set, in its registration order.
beamai_markdown:to_html(Text, advanced).

%% Options go with the extension name.
P2 = beamai_markdown:pipeline([{pipe_tables, #{use_header_for_column_count => true}},
                               {jira_links, #{base_url => <<"https://jira.example">>}}]).

%% The document tree, and rendering it more than once.
Doc = beamai_markdown:parse(Text, P),
beamai_markdown:render(Doc, html),
beamai_markdown:render(Doc, plain),
beamai_markdown:render(Doc, normalize),
beamai_markdown:render(Doc, roundtrip).

%% Canonical Markdown, and the exact input back.
beamai_markdown:normalize(~"Setext\n===\n\n* item\n").   %% => "# Setext\n\n* item"
beamai_markdown:to_roundtrip(~"#  Hi   \n\n- a\n").      %% => the same bytes
```

Every function takes `unicode:chardata()`; every renderer returns a UTF-8
binary. The second argument is a pipeline, a list of extension names, one
name, or `advanced`; a list is built into a pipeline on every call, so keep the
built pipeline when it matters.

### HTML renderer options

`to_html/3` and `render/3` take a map:

| Option | |
|---|---|
| `base_url` | Relative link targets are resolved against it (RFC 3986). |
| `link_rewriter` | `fun(Url) -> Url'`, applied to every href and src. |
| `enable_inline`, `enable_block`, `enable_escape` | markdig's flags. All three off is `to_plain_text/1`. |
| `attrs_on_pre` | Put a code block's attributes on `<pre>` instead of `<code>`. |
| `blocks_as_div`, `blocks_as_pre` | Info strings rendered as `<div>` / `<pre>` without `<code>`. |
| `link_rel`, `autolink_rel` | A `rel` attribute on links. |
| `alert_render_kind` | `{Module, Function}` writing an alert's title line. |

## Extensions

The name is what `pipeline/1` takes; the module is where the details are.
Options are maps passed as `{Name, Opts}`.

| Name | What it does | Options |
|---|---|---|
| `abbreviations` | `*[HTML]: Hypertext Markup Language`, then every whole-word `HTML` becomes `<abbr>` | |
| `alerts` | GitHub alerts: a quote starting with `[!NOTE]`, `[!TIP]`, `[!IMPORTANT]`, `[!WARNING]`, `[!CAUTION]` | `allow_nested_alerts` |
| `auto_identifiers` | `id` on every heading; `[Heading text]` links to it | `auto_link`, `allow_only_ascii`, `github` |
| `auto_links` | Bare `http://`, `https://`, `ftp://`, `mailto:`, `tel:`, `www.` links | `valid_previous_characters`, `use_https_for_www_links`, `allow_domain_without_period`, `open_in_new_window` |
| `bootstrap` | Bootstrap classes on tables, quotes, figures, images and alerts | |
| `citations` | `""text""` renders as `<cite>` | |
| `cjk_friendly_emphasis` | Emphasis that opens and closes against CJK characters | |
| `custom_containers` | `:::name` fenced `<div>`s and `::text::` spans | |
| `definition_lists` | `Term` / `:   Definition` | |
| `diagrams` | `mermaid` and `nomnoml` fences as diagram containers | |
| `disable_headings` | `#` and setext underlines are text | |
| `disable_html` | Raw HTML is text (entities still decode) | |
| `emoji` | `:smile:` and `:)` become Unicode | `enable_smileys`, `mapping` |
| `emphasis_extras` | `~~del~~`, `~sub~`, `^sup^`, `++ins++`, `==mark==` | `strikethrough`, `subscript`, `superscript`, `inserted`, `marked` |
| `figures` | `^^^` fenced `<figure>` with captions on the fence lines | |
| `footers` | `^^` lines render as `<footer>` | |
| `footnotes` | `[^1]` and `[^1]: text` | |
| `generic_attributes` | `{#id .class key=value}` on the preceding inline, the block, or the next block | |
| `globalization` | `dir="rtl"` where the first strong character is right-to-left | |
| `grid_tables` | `+---+---+` tables with block content and spans | |
| `hardline_breaks` | Every soft line break is `<br />` | |
| `jira_links` | `PROJ-123` links to an issue tracker | `base_url` (required), `base_path`, `open_in_new_window` |
| `list_extras` | `a.`, `A.`, `i.`, `I.` ordered lists | |
| `mathematics` | `$inline$` and `$$` blocks | |
| `media_links` | Image links to YouTube, Vimeo and media files become `<iframe>`, `<video>`, `<audio>` | `width`, `height`, `add_controls_property`, `class`, `hosts`, `extension_mime_types` |
| `non_ascii_no_escape` | Non-ASCII stays verbatim in URLs | |
| `pipe_tables` | GFM tables | `require_header_separator`, `use_header_for_column_count`, `infer_column_widths_from_separator` |
| `pragma_lines` | `id="pragma-line-N"` on every block; see `find_closest_line/2` | |
| `referral_links` | `rel="nofollow ..."` on every link | `rels` |
| `self_pipeline` | The document picks its extensions with `<!--markdig:names-->` | `tag`, `default_extensions` |
| `smarty_pants` | Curly quotes, dashes and ellipses | `mapping` |
| `task_lists` | `- [ ]` and `- [x]` | `list_class`, `item_class` |
| `yaml_front_matter` | A leading `---` block renders as nothing | `allow_in_middle` |
| `advanced` | markdig's UseAdvancedExtensions: the nineteen above that it enables, in its order | |

Order matters the way it does in markdig: `generic_attributes` hooks the
parsers registered before it, so it goes last (as `advanced` does), and the
first parser to claim a position wins.

## Renderers

**HTML** is markdig's, output-identical: the CommonMark spec's expected HTML
differs from markdig's only in whitespace around `<li>`, and the conformance
suite compares both sides through markdig's own normalisation.

**Plain text** is the HTML renderer with markup emission off, which is also
how markdig does it: characters that would have been escaped are dropped, so
`<b>` inside text disappears rather than being printed.

**Normalize** writes the tree back as canonical Markdown: ATX headings,
fences as written, bullets as written (or the `list_item_character` option),
ordered lists renumbered from their start, link reference definitions grouped
at the end. Options: `space_after_quote_block`, `empty_line_after_code_block`,
`empty_line_after_heading`, `empty_line_after_thematic_break`,
`list_item_character`, `expand_auto_links`.

**Roundtrip** returns the exact bytes the document was parsed from, CRLF and
CR included. Every block records the source lines it came from and the
document keeps its source, so unchanged blocks are copied; a block marked
`changed => true` is re-rendered as canonical Markdown in its place, and a
block with no line range at all (one you added) is rendered where it stands.
That is a different mechanism from markdig's, which threads whitespace trivia
through every parser; the result is the same for the 649-example roundtrip
suite, and the copying makes the unchanged parts lossless by construction.

## The tree

`parse/1,2,3` returns a document: a map with `k => document` and `children`.
Every node is a map with `k` (its kind), `line` and `col` (1-based start),
and either `children` (a container), `lines` (a leaf block's raw lines) or
`v` (a leaf inline). Leaf blocks that hold text get `inlines` after the
inline pass. Attributes live under `attrs` as
`#{id, classes, props}`; `beamai_markdown_attrs` edits them.

Block kinds: `document`, `paragraph`, `heading` (`level`, `setext`),
`thematic_break`, `indented_code`, `fenced_code` (`fence_char`, `fence_len`,
`info`, `arguments`), `html_block` (`html_type`), `quote`, `list` (`ordered`,
`bullet_char`, `start`, `delimiter`, `tight`), `list_item`, `link_ref_def`
(`label`, `url`, `title`). Inline kinds: `text`, `code`, `emph` (`ch`,
`count`), `link` (`url`, `title`, `image`, `children`), `autolink`, `html`,
`entity`, `linebreak` (`hard`). Extensions add their own; each module's
documentation names them.

`find_closest_line(Doc, Line)` maps a zero-based source line to the start line
of the nearest block, which with `pragma_lines` maps rendered HTML back to the
source.

## Writing an extension

An extension is a module with `setup(Pipeline, Opts) -> Pipeline` that edits
the pipeline's ordered lists through `beamai_markdown_pipeline`:

| List | Entry | Called as |
|---|---|---|
| `block_parsers` | `#{name, module, function, chars}` | `M:F(Bp)` -> `{container, Bp}`, `{leaf, Bp}`, `{done, Bp}` or `none` |
| `block_kinds` (map) | `Kind => Module` | the `beamai_markdown_block_kind` behaviour: continue, finalize, can_contain, accepts_lines, after_line, blank_line_ignored |
| `inline_parsers` | `#{name, module, function, chars}` | `M:F(Ip)` -> `{ok, Ip}` or `none` |
| `post_inline` | `#{name, module, function}` | `M:F(Nodes, Ip)` -> `{Nodes, Ip}`, once per leaf after parsing |
| `emphasis` (map) | `Char => #{min, max, within_word}` | the emphasis parser's descriptors (`add_emphasis/2`) |
| `emphasis_hooks` | `#{name, module, function}` | `M:F(Char, Count, Node)` -> a node or `none`, when a pair is formed |
| `link_hooks` | `#{name, module, function}` | `M:F(Link, Opener, Ip)` -> the link, after each link is resolved |
| `pre_inline_hooks` | `#{name, module, function}` | `M:F(Doc, Refs, Pipe, Opts)` -> `{Doc, Refs}`, between the passes |
| `document_hooks` | `#{name, module, function}` | `M:F(Doc, Pipe, Opts)` -> `Doc`, after the inline pass |
| `renderer_setup` (map) | `Renderer => [#{name, module, function}]` | `M:F(R)` -> `R` when an `html`, `plain`, `normalize` or `roundtrip` renderer is created |

`insert_before/4`, `insert_after/4`, `replace/4`, `remove/3` and `add/3` place
an entry by the name of another. `beamai_markdown_block` and
`beamai_markdown_inline` export what a parser needs: the current line and
offset, `add_child/2`, `push/2`, `text/2`, the leaf's ancestors
(`parents/1`), and `edit_parent/3` for changing an ancestor (how task lists
put a class on their list item).

A renderer setup registers a kind's writer with
`beamai_markdown_renderer:set_renderer/3`, or a try-writer with
`add_try_writer/3` to intercept an existing kind (media links intercept
image links). The writer is `M:F(R, Node) -> R`, building output through
`write/2`, `write_raw/2`, `write_line/2`, `ensure_line/1`, `write_children/2`
and `write_leaf_inline/2`. `beamai_markdown_ext_task_lists` is the shortest
complete example; `beamai_markdown_ext_pipe_tables` the longest.

## The parse_transform

```erlang
-compile({parse_transform, beamai_markdown_transform}).

-markdown_document({about, "docs/about.md"}).   %% about/0 and about_iolist/0

banner() -> beamai_markdown:inline(~"# Hello *there*").
```

`beamai_markdown:inline/1` with a binary literal is replaced by its HTML, as
a literal; without the transform the same call renders at run time.
`-markdown_document` renders a file at compile time into `Name/0` and
`Name_iolist/0`. Both use the module's compile options:

```erlang
{erl_opts, [{parse_transform, beamai_markdown_transform},
            {markdown_opts, [{extensions, [pipe_tables, task_lists]},
                             {views, "docs"},
                             {render, #{base_url => <<"https://example.com/">>}}]}]}.
```

`extensions` builds the pipeline, `views` is where document paths resolve
(after the module's own directory), `render` is the HTML renderer's option
map. A call whose argument is not a literal is left alone with a warning
(`nowarn_markdown_inline` silences it). See
[parse-transform.md](parse-transform.md) for the diagnostics machinery the
three transforms share.

## Deviations

Everything is measured against markdig through its own test normalisation,
and the differences below are deliberate.

- **Roundtrip copies source spans instead of tracking trivia** (above).
- **Reference-link labels fold case with OTP's `string:casefold/1`**, which
  is full Unicode case folding; markdig has a hand-written table. Both send
  `[ẞ]` to `[SS]:`.
- **Extensions add no persistent state.** markdig caches the default emoji
  trie in a static; here it lives in the pipeline that enabled the extension.
- The `cjk_friendly_emphasis` spec's second example is skipped, as it is in
  cl-markding: it depends on a markdig-specific interaction between emphasis
  demotion and code spans.

## Conformance

`rebar3 eunit --module=beamai_markdown_spec_tests` runs every example of every
spec file under `test/markdown_spec/` -- markdig's own files, extracted the
way markdig's test runner extracts them, with U+2192 standing in for a tab --
as one EUnit test each: 652 CommonMark, 649 roundtrip, 3 normalize and the
27 extension suites. `beamai_markdown_test_lib:report/2,3` prints a
per-section table from the shell, with `#{verbose => true}` for the failing
examples.
