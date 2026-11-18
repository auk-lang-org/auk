# markdown

Markdown to HTML, a tree, or plain text. It covers CommonMark and the GitHub extensions:
tables, `~~strikethrough~~`, task lists (`- [x]`) and bare URL autolinks.

It passes 644 of the 652 examples in the CommonMark 0.31.2 spec. Two of the 8 misses are the intended
GitHub autolink extension. The other six involve Unicode case folding of link labels, tabs inside
list and quote markers, and one reference-definition corner case.

**Safe by default.** In the input, raw HTML is escaped and `javascript:`, `vbscript:`, `file:` and
non-image `data:` URLs are dropped. `markdown.html(s)` can therefore render comments, issues and chat
messages from untrusted users. For trusted input that should keep its HTML, pass
`Opts { unsafe_html: true }`.

**Effects:** none. **Deps:** none.

```auk
fn main(): int {
  print(markdown.html("# Auk\n\nA *small* language. See [the docs](https://auk.dev).\n\n- [x] fast\n- [ ] done"))
  // <h1>Auk</h1>
  // <p>A <em>small</em> language. See <a href="https://auk.dev">the docs</a>.</p>
  // <ul>
  // <li><input checked="" disabled="" type="checkbox" /> fast</li>
  // <li><input disabled="" type="checkbox" /> done</li>
  // </ul>

  print(markdown.text("**Bold** claim &amp; a [link](/x)"))   // Bold claim & a link

  for b in markdown.parse("# One\n\n## Two") {
    match b {
      markdown.Heading(level, body) => print("h{level}")
      _ => {}
    }
  }
  0
}
```

## API

- `html(src): str` renders safe HTML. `html(src, opts: Opts)` takes options: `Opts { unsafe_html: bool }`, where `unsafe_html` passes raw HTML and every URL through untouched. `SAFE` is the default.
- `parse(src): [Block]` returns the document tree, with reference links already resolved. `to_html(blocks, opts)` renders a tree, which you may have modified first.
- `text(src): str` gives the text without markup. Paragraphs are separated by blank lines, list items go on separate lines, and table cells are separated by tabs. Use it for previews, search indexes and `<title>`.
- `esc(s)` escapes `& < > "` as HTML entities.

Tree:
- `enum Block { Heading(level, body), Para(body), CodeBlock(lang, code), Quote(blocks), List(ordered, start, tight, items: [Item]), Rule, Table(align: [Align], head: [[Inline]], rows: [[[Inline]]]), HtmlBlock(html) }`
- `struct Item { checked: bool?, blocks: [Block] }`. `checked` is set for task items.
- `enum Inline { Text(s), Code(s), Em(body), Strong(body), Del(body), Link(url, title, body), Image(url, title, alt), SoftBreak, HardBreak, Html(s) }`
- `enum Align { NoAlign, Left, Center, Right }`

Details:
- **HTML output** follows the CommonMark reference renderer: `<p>`, `<pre><code class="language-x">`, `<hr />`, `<br />`, `<ol start="3">`, and paragraphs inside tight list items are not wrapped in `<p>`. Table cells get `align="..."`. Task items get a disabled `<input type="checkbox">`.
- **Character references:** numeric references, the Latin-1 named set (`&eacute;`, `&copy;`, …) and common typographic names (`&mdash;`, `&hellip;`, `&rarr;`, …) are decoded. Any other name stays literal text (`&amp;bogus;`).
- **Link URLs** are percent-encoded the way cmark does it, and titles and alt text are HTML-escaped.

Performance: a 237 KB document renders in about 35 ms in a release build. Pathological input stays bounded; 5,000 nested `[` take about 0.1 s.

Not yet: Unicode case folding for reference labels (`[ẞ]` vs `[SS]`); footnotes; heading IDs/anchors; a few HTML-entity names (only Latin-1 and common names are decoded).
