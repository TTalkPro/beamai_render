# 14 · Markdown 引擎架构

> 状态：已实现（v0.6）。本文记录把 markdig（经 cl-markding）移植到 Erlang 时做的决定，
> 尤其是那些**因为语言不同而不得不改**的地方。用法见 [docs/markdown.md](../docs/markdown.md)。

## 1. 定位

Markdown 引擎与 mustache / jinja 不同：它**只在运行期渲染**，不编译成模块，也不接 rebar3
plugin（曾经做过，决定移除——静态文档编译成模块意义不大，渲染才是主用途）。它与其它两个
引擎共享的只有 `beamai_html_forms`（parse_transform 生成字面量用）和"零依赖、无进程、无
ets、无缓存"的纪律。

模块前缀 `beamai_markdown_`：

| 模块 | 职责 |
|---|---|
| `beamai_markdown` | 门面：`to_html` / `to_plain_text` / `normalize` / `to_roundtrip` / `parse` / `render` / `pipeline` |
| `beamai_markdown_pipeline` | pipeline builder：有序 parser 表、扩展注册、`build/1` 派生分派表 |
| `beamai_markdown_block` / `_blocks` / `_block_kind` | 块级 processor、CommonMark 块种类、块种类 behaviour |
| `beamai_markdown_inline` | inline processor 与 CommonMark inline parser、强调配对 |
| `beamai_markdown_scan` / `_char` / `_punycode` | 实体、HTML tag、链接部件扫描；字符分类与 flanking；IDN |
| `beamai_markdown_renderer` / `_html` / `_normalize` / `_roundtrip` | 渲染器基类与四个渲染器（纯文本 = HTML 渲染器关标签） |
| `beamai_markdown_attrs` / `_tables` | 节点属性；表格 AST 与 HTML 渲染（pipe / grid 共用） |
| `beamai_markdown_unicode` / `_entities` / `_emoji_data` / `_bidi_data` | 生成的数据表（`tools/gen_markdown_data.py`） |
| `beamai_markdown_ext_*` | 30 个扩展，每个一模块 |
| `beamai_markdown_transform` | parse_transform：`inline/1` 折叠、`-markdown_document` |

## 2. 关键决策

### D1 · 函数式移植，而不是模拟可变对象树

markdig 的解析器全程原地修改：块 processor 维护一个 open block 栈并直接改父节点；inline
processor 是带父指针的双向链表，强调配对在树上原地 embrace。在 Erlang 上模拟这一切
（process dictionary、ets）等于放弃语言的长处。

取而代之：

- **块阶段**是 CommonMark 规范附录算法的函数式写法（`commonmark.js` 的结构）：open block
  栈是一个 list（innermost first），每行先从 document 往下做 continuation，再试 block
  start，最后放置文本。**未匹配的块不立即关闭**——它们可能是 lazy paragraph continuation，
  只在 `add_child/2`（有 block start 接手）或 `close_unmatched/1`（文本落位）时关闭。这一
  顺序与参考实现完全一致。
- **inline 阶段**产出一条扁平的节点 list（reversed），强调定界符与链接括号都是这条 list 上的
  普通节点。链接解析 = 在括号处切分 list；强调配对 = 在正向 list 上跑 zipper，"离 closer
  最近的 opener"就是往左边搜。规则（rule of 3、markdig 的 `min`/`max` 描述符、逐字符实体
  邻接）照搬。
- **对祖先的修改**（markdig 里 parser 直接改父块，例如 task list 给 list item 加 class）
  通过 `edit_parent/3` 记录成 `{Depth, Fun}`，在祖先子树全部处理完后由 walker 应用。
  Pipe table 把段落替换成表格用 `set_block/2`，段落前面有文字时用 `add_block_after/2`。

### D2 · 扩展点是有序表 + 名字，不是类层次

markdig 的 `InsertBefore<LinkInlineParser>`、"先注册者优先"的渲染器分派，以及 cl-markding
的 `try-writers`，在这里对应：

- pipeline 的每张有序表条目带 `name`，`insert_before/4`、`insert_after/4`、`replace/4`、
  `remove/3` 按名字定位；
- 节点 `k` 是原子而非类，因此"子类型由先注册者渲染"退化为"每种类一个 writer"
  （alert 是独立种类而非 quote 的子类）；需要按实例拦截的（media links）用 `try_writers`；
- block 种类的回调走 `beamai_markdown_block_kind` behaviour，核心种类在
  `beamai_markdown_blocks` 里按 `k` 分派，扩展种类经 `block_kinds` map。

post_inline 处理器的顺序按 markdig 的**有效顺序**显式给定（pipe table 在 emphasis 前，
smarty pants 在 emphasis 后），而不是依赖 inline parser 表的顺序——markdig 里二者是同一张
表，且其默认顺序（emphasis 在 code 前）与本实现不同。

### D3 · Roundtrip 用源码区间，不跟踪 trivia

markdig 的 roundtrip 在每个 parser 里记录 trivia（标记前后空白、行尾、空行……）。这是
markdig 最大的一块横切修改，且价值主要在"改 AST 后原样重排未改部分"。

这里每个块本来就记录 `line` / `end_line`，文档保留源码与每行的字节偏移。roundtrip 渲染器
按顺序拷贝到每个顶层块末尾的源码（块间空行与 trivia 随之带上），最后补上文末余下的字节。
标 `changed => true` 的块在原位用 normalize 渲染器重渲染；没有行范围的新块就地渲染。

结果：RoundtripCommonMark.md 649/649 逐字节通过，CRLF / CR 亦然，parser 零改动。代价：
改动一个深层子块时，其所在顶层块整体重渲染（markdig 能只重排那个子块）。

### D4 · 无状态，包括缓存

`default_pipeline/0` 每次调用重建（几个 map，可忽略）；emoji 的 1600 项 trie 在 `setup/2`
时构建并放进 pipeline。曾用 persistent_term 缓存，为与仓库"无 ets、无 persistent_term、无
进程"的纪律一致而移除。pipeline 是不可变 map，用户自己想放 persistent_term 随意。

### D5 · 数据表由生成器产出并入库

Unicode 标点/Zs 区间、2125 个 HTML5 实体、emoji 与 smiley 表、RTL/LTR 区间都取自 markdig
（经 cl-markding 的生成结果），由 `tools/gen_markdown_data.py` 转成 Erlang 模块入库。选
markdig 的表而不是本机 Python 的 unicodedata：引擎的目标是与 markdig 一致，字符分类必须
与它相同。

## 3. 与 markdig 的一致性验证

- 测试库 `beamai_markdown_test_lib` 复刻 markdig 的 spec 提取器与 `TestParser.Compact`
  规范化（trim、`<li>` 周围空白折叠、™→TM）；
- `beamai_markdown_spec_tests` 把 30 个 spec 文件的每个用例跑成一条 EUnit 测试，pipeline
  配置照抄 cl-markding 的 `test-extensions.lisp`；
- `beamai_markdown_tests` 覆盖门面、normalize 单元用例、roundtrip 换行风格、无 spec 文件
  的扩展（pragma lines、self pipeline、referral links、emoji / smarty 选项）；
- 参考实现可用 `sbcl --script`（cl-markding 在本机）直接对拍，移植时遇到语义存疑处即
  以此为准。

## 4. 已知偏离

见 [docs/markdown.md §Deviations](../docs/markdown.md#deviations)：roundtrip 机制、
`string:casefold/1`、无持久缓存、CJK spec 第 2 例跳过（同 cl-markding）。
