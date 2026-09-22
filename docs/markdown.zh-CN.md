# Markdown 引擎

[English](markdown.md) · [中文](markdown.zh-CN.md)

CommonMark 0.31.2 解析器，带 markdig 的全部 30 个扩展和四个渲染器，经
[cl-markding](https://github.com/DavidAlphaFox/cl-markding) 从
[markdig](https://github.com/xoofx/markdig) 移植而来。它在运行期渲染——没有构建步骤——
并且和 beamai_render 的其它部分一样没有进程、没有 ETS、没有缓存：pipeline 就是一个普通的
map，构建一次到处传。

- CommonMark 0.31.2：**652/652** 规范用例
- **30 个扩展**，各自跑通其 markdig spec 文件
- 四个渲染器：HTML、纯文本、normalize（规范化 Markdown）、roundtrip（**649/649** 字节级还原）
- 零依赖；在规范文档上约 3 MB/s

## 快速上手

```erlang
beamai_markdown:to_html(~"Hello *world*!").
%% => <<"<p>Hello <em>world</em>!</p>\n">>

beamai_markdown:to_plain_text(~"Hello *world*!").
%% => <<"Hello world!\n">>

%% 扩展挂在 pipeline 上。构建一次，重复使用。
P = beamai_markdown:pipeline([pipe_tables, task_lists, footnotes]),
beamai_markdown:to_html(Text, P).

%% markdig 的 UseAdvancedExtensions 集合，按其注册顺序。
beamai_markdown:to_html(Text, advanced).

%% 选项跟在扩展名后面。
P2 = beamai_markdown:pipeline([{pipe_tables, #{use_header_for_column_count => true}},
                               {jira_links, #{base_url => <<"https://jira.example">>}}]).

%% 文档树，以及多次渲染。
Doc = beamai_markdown:parse(Text, P),
beamai_markdown:render(Doc, html),
beamai_markdown:render(Doc, plain),
beamai_markdown:render(Doc, normalize),
beamai_markdown:render(Doc, roundtrip).

%% 规范化 Markdown，以及逐字节还原。
beamai_markdown:normalize(~"Setext\n===\n\n* item\n").   %% => "# Setext\n\n* item"
beamai_markdown:to_roundtrip(~"#  Hi   \n\n- a\n").      %% => 原样的字节
```

所有函数接受 `unicode:chardata()`；所有渲染器返回 UTF-8 binary。第二个参数可以是
pipeline、扩展名列表、单个扩展名或 `advanced`；传列表时每次调用都会重新构建 pipeline，
在意开销就把构建好的 pipeline 留着。

### HTML 渲染器选项

`to_html/3` 与 `render/3` 接受一个 map：

| 选项 | |
|---|---|
| `base_url` | 相对链接按 RFC 3986 解析到它之上 |
| `link_rewriter` | `fun(Url) -> Url'`，作用于每个 href / src |
| `enable_inline`、`enable_block`、`enable_escape` | markdig 的三个开关；全关就是 `to_plain_text/1` |
| `attrs_on_pre` | 代码块属性放在 `<pre>` 而非 `<code>` 上 |
| `blocks_as_div`、`blocks_as_pre` | 这些 info 字符串渲染成不带 `<code>` 的 `<div>` / `<pre>` |
| `link_rel`、`autolink_rel` | 链接的 `rel` 属性 |
| `alert_render_kind` | `{Module, Function}`，负责写 alert 的标题行 |

## 扩展

名字是 `pipeline/1` 认的，模块里有细节。选项以 `{Name, Opts}` 传入。

| 名字 | 作用 | 选项 |
|---|---|---|
| `abbreviations` | `*[HTML]: Hypertext Markup Language` 之后，整词 `HTML` 都变成 `<abbr>` | |
| `alerts` | GitHub alert：以 `[!NOTE]`、`[!TIP]`、`[!IMPORTANT]`、`[!WARNING]`、`[!CAUTION]` 开头的引用块 | `allow_nested_alerts` |
| `auto_identifiers` | 每个标题带 `id`；`[标题文本]` 链接到它 | `auto_link`、`allow_only_ascii`、`github` |
| `auto_links` | 裸 `http://`、`https://`、`ftp://`、`mailto:`、`tel:`、`www.` 链接 | `valid_previous_characters`、`use_https_for_www_links`、`allow_domain_without_period`、`open_in_new_window` |
| `bootstrap` | 表格、引用、figure、图片、alert 上的 Bootstrap class | |
| `citations` | `""text""` 渲染为 `<cite>` | |
| `cjk_friendly_emphasis` | 强调可以贴着 CJK 字符开合 | |
| `custom_containers` | `:::name` 围栏 `<div>` 与 `::text::` span | |
| `definition_lists` | `Term` / `:   Definition` | |
| `diagrams` | `mermaid`、`nomnoml` 围栏渲染为图表容器 | |
| `disable_headings` | `#` 与 setext 下划线当普通文本 | |
| `disable_html` | 原始 HTML 当文本（实体仍解码） | |
| `emoji` | `:smile:` 与 `:)` 变成 Unicode | `enable_smileys`、`mapping` |
| `emphasis_extras` | `~~del~~`、`~sub~`、`^sup^`、`++ins++`、`==mark==` | `strikethrough`、`subscript`、`superscript`、`inserted`、`marked` |
| `figures` | `^^^` 围栏 `<figure>`，围栏行上可带 caption | |
| `footers` | `^^` 行渲染为 `<footer>` | |
| `footnotes` | `[^1]` 与 `[^1]: text` | |
| `generic_attributes` | `{#id .class key=value}` 挂到前一个 inline、当前块或下一个块 | |
| `globalization` | 首个强字符为从右向左时加 `dir="rtl"` | |
| `grid_tables` | `+---+---+` 表格，单元格可放块级内容、可跨行跨列 | |
| `hardline_breaks` | 软换行都成 `<br />` | |
| `jira_links` | `PROJ-123` 链接到 issue tracker | `base_url`（必填）、`base_path`、`open_in_new_window` |
| `list_extras` | `a.`、`A.`、`i.`、`I.` 有序列表 | |
| `mathematics` | `$inline$` 与 `$$` 块 | |
| `media_links` | 指向 YouTube、Vimeo、媒体文件的图片链接变成 `<iframe>`、`<video>`、`<audio>` | `width`、`height`、`add_controls_property`、`class`、`hosts`、`extension_mime_types` |
| `non_ascii_no_escape` | URL 中的非 ASCII 原样保留 | |
| `pipe_tables` | GFM 表格 | `require_header_separator`、`use_header_for_column_count`、`infer_column_widths_from_separator` |
| `pragma_lines` | 每个块带 `id="pragma-line-N"`；配合 `find_closest_line/2` | |
| `referral_links` | 每个链接加 `rel="nofollow ..."` | `rels` |
| `self_pipeline` | 文档用 `<!--markdig:names-->` 自选扩展 | `tag`、`default_extensions` |
| `smarty_pants` | 弯引号、破折号、省略号 | `mapping` |
| `task_lists` | `- [ ]` 与 `- [x]` | `list_class`、`item_class` |
| `yaml_front_matter` | 开头的 `---` 块不渲染 | `allow_in_middle` |
| `advanced` | markdig 的 UseAdvancedExtensions：上面 19 个，按其顺序 | |

顺序的意义和 markdig 一样：`generic_attributes` 会挂钩在它之前注册的 parser，所以放最后
（`advanced` 就是这么做的）；同一位置先注册的 parser 先接手。

## 渲染器

**HTML** 就是 markdig 的，输出逐字节一致：CommonMark 规范的期望 HTML 与 markdig 只在
`<li>` 周围空白上有差异，一致性测试两边都经 markdig 自己的规范化再比较。

**纯文本** 是关掉标签输出的 HTML 渲染器，markdig 也是这么做的：本该转义的字符被丢弃，
所以文本里的 `<b>` 会消失而不是被打印。

**Normalize** 把树写回规范 Markdown：ATX 标题，围栏按原样，列表符按原样（或
`list_item_character` 选项），有序列表从起始值重新编号，链接引用定义集中到文末。选项：
`space_after_quote_block`、`empty_line_after_code_block`、`empty_line_after_heading`、
`empty_line_after_thematic_break`、`list_item_character`、`expand_auto_links`。

**Roundtrip** 返回解析时的原始字节，CRLF 与 CR 一并保留。每个块记录了它来自的源码行，
文档保留了源码，所以未改动的块直接拷贝；标了 `changed => true` 的块在原位重新渲染为规范
Markdown；完全没有行范围的块（你新加的）在所在位置渲染。这和 markdig 把空白 trivia 穿过
每个 parser 的做法不同；在 649 例 roundtrip 套件上结果相同，而拷贝让未改动部分天然无损。

## 树

`parse/1,2,3` 返回文档：`k => document` 加 `children` 的 map。每个节点是带 `k`（种类）、
`line`、`col`（1 起）的 map，外加 `children`（容器）、`lines`（叶子块的原始行）或 `v`
（叶子 inline）之一。含文本的叶子块在 inline 阶段后得到 `inlines`。属性在 `attrs` 下，
形如 `#{id, classes, props}`，用 `beamai_markdown_attrs` 修改。

块种类：`document`、`paragraph`、`heading`（`level`、`setext`）、`thematic_break`、
`indented_code`、`fenced_code`（`fence_char`、`fence_len`、`info`、`arguments`）、
`html_block`（`html_type`）、`quote`、`list`（`ordered`、`bullet_char`、`start`、
`delimiter`、`tight`）、`list_item`、`link_ref_def`（`label`、`url`、`title`）。inline
种类：`text`、`code`、`emph`（`ch`、`count`）、`link`（`url`、`title`、`image`、
`children`）、`autolink`、`html`、`entity`、`linebreak`（`hard`）。扩展各自增加种类，
见各模块文档。

`find_closest_line(Doc, Line)` 把 0 起的源码行号映射到最近块的起始行，配合 `pragma_lines`
可从渲染后的 HTML 找回源码位置。

## 编写扩展

扩展是一个模块，提供 `setup(Pipeline, Opts) -> Pipeline`，通过 `beamai_markdown_pipeline`
编辑 pipeline 的有序表：

| 表 | 条目 | 调用方式 |
|---|---|---|
| `block_parsers` | `#{name, module, function, chars}` | `M:F(Bp)` -> `{container, Bp}`、`{leaf, Bp}`、`{done, Bp}` 或 `none` |
| `block_kinds`（map） | `Kind => Module` | `beamai_markdown_block_kind` behaviour：continue、finalize、can_contain、accepts_lines、after_line、blank_line_ignored |
| `inline_parsers` | `#{name, module, function, chars}` | `M:F(Ip)` -> `{ok, Ip}` 或 `none` |
| `post_inline` | `#{name, module, function}` | `M:F(Nodes, Ip)` -> `{Nodes, Ip}`，每个叶子解析完后一次 |
| `emphasis`（map） | `Char => #{min, max, within_word}` | 强调 parser 的描述符（`add_emphasis/2`） |
| `emphasis_hooks` | `#{name, module, function}` | `M:F(Char, Count, Node)` -> 节点或 `none`，配对形成时 |
| `link_hooks` | `#{name, module, function}` | `M:F(Link, Opener, Ip)` -> 链接，每个链接解析出来后 |
| `pre_inline_hooks` | `#{name, module, function}` | `M:F(Doc, Refs, Pipe, Opts)` -> `{Doc, Refs}`，两个阶段之间 |
| `document_hooks` | `#{name, module, function}` | `M:F(Doc, Pipe, Opts)` -> `Doc`，inline 阶段之后 |
| `renderer_setup`（map） | `Renderer => [#{name, module, function}]` | `M:F(R)` -> `R`，创建 `html`、`plain`、`normalize`、`roundtrip` 渲染器时 |

`insert_before/4`、`insert_after/4`、`replace/4`、`remove/3`、`add/3` 按另一条目的名字定位。
`beamai_markdown_block` 与 `beamai_markdown_inline` 导出 parser 需要的东西：当前行与偏移、
`add_child/2`、`push/2`、`text/2`、叶子的祖先（`parents/1`），以及修改祖先的
`edit_parent/3`（task list 就是靠它给 list item 加 class）。

渲染器 setup 用 `beamai_markdown_renderer:set_renderer/3` 注册某种类的 writer，或用
`add_try_writer/3` 拦截已有种类（media links 拦截图片链接）。writer 形如
`M:F(R, Node) -> R`，通过 `write/2`、`write_raw/2`、`write_line/2`、`ensure_line/1`、
`write_children/2`、`write_leaf_inline/2` 产出。`beamai_markdown_ext_task_lists` 是最短的
完整示例，`beamai_markdown_ext_pipe_tables` 是最长的。

## parse_transform

```erlang
-compile({parse_transform, beamai_markdown_transform}).

-markdown_document({about, "docs/about.md"}).   %% about/0 与 about_iolist/0

banner() -> beamai_markdown:inline(~"# Hello *there*").
```

`beamai_markdown:inline/1` 的参数是 binary 字面量时，整个调用被替换为其 HTML 字面量；
没有 transform 时同一调用在运行期渲染。`-markdown_document` 在编译期把文件渲染成 `Name/0`
与 `Name_iolist/0`。两者都用模块的编译选项：

```erlang
{erl_opts, [{parse_transform, beamai_markdown_transform},
            {markdown_opts, [{extensions, [pipe_tables, task_lists]},
                             {views, "docs"},
                             {render, #{base_url => <<"https://example.com/">>}}]}]}.
```

`extensions` 构建 pipeline，`views` 是文档路径的解析目录（模块自身目录之后），`render`
是 HTML 渲染器的选项 map。参数不是字面量的调用原样保留并给出警告
（`nowarn_markdown_inline` 可关掉）。三个 transform 共用的诊断机制见
[parse-transform.md](parse-transform.md)。

## 偏离之处

一切以 markdig 为准、经其自身测试规范化比较；下列差异是有意为之。

- **Roundtrip 拷贝源码区间而不是跟踪 trivia**（见上）。
- **引用链接标签用 OTP 的 `string:casefold/1` 折叠大小写**，即完整 Unicode case folding；
  markdig 用手写表。两者都能让 `[ẞ]` 命中 `[SS]:`。
- **扩展不引入持久状态。** markdig 把默认 emoji trie 缓存在静态字段里；这里它放在启用该
  扩展的 pipeline 中。
- `cjk_friendly_emphasis` spec 的第二例被跳过，cl-markding 亦然：它取决于 markdig 特有的
  强调降级与 code span 交互。

## 一致性

`rebar3 eunit --module=beamai_markdown_spec_tests` 把 `test/markdown_spec/` 下每个 spec
文件——markdig 自己的文件，按 markdig 测试 runner 的方式提取，U+2192 代表 tab——的每个
用例跑成一条 EUnit 测试：652 条 CommonMark、649 条 roundtrip、3 条 normalize，加 27 个
扩展套件。`beamai_markdown_test_lib:report/2,3` 在 shell 里打印分节通过表，
`#{verbose => true}` 打印失败用例。
