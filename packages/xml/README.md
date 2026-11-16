# xml

Parses XML 1.0 text into an element tree and writes it back out, compact or indented. Parse errors are a typed `XmlErr` that carries the line and column.

**Effects:** none. **Dependencies:** none.

```duck
let feed = xml.parse(fs.read("feed.xml")?)?
for item in feed.descendants("item") {
  let title = item.child("title")?.text() else "(untitled)"
  print("{title}: {item.attr("href") else "-"}")
}

let order = xml.Element {
  name: "order",
  attrs: {"id": "7"},
  children: [xml.Elem(xml.leaf("item", "tea & cake"))],
}
print(xml.str(order))      // <order id="7"><item>tea &amp; cake</item></order>

match xml.parse("<a><b></a>") {
  err(e) => print(xml.message(e))   // 1:7: </a> closes <b>
  ok(_) => {}
}
```

## The tree
- `struct Element { name: str, attrs: {str: str}, children: [Node] }`. `name` keeps any namespace prefix (`soap:Body`). Attributes stay in document order, and `xmlns` declarations are ordinary attributes. Namespaces are not resolved.
- `enum Node { Elem(e: Element), Text(s: str) }`.
  - CDATA sections become `Text`, merged with the text around them.
  - Comments and processing instructions are dropped.
  - Whitespace-only text is dropped from an element whose only text is whitespace, which is the indentation between child elements. In mixed content (`<p>a <b>b</b> c</p>`), every text node is kept exactly.

## What's parsed
- An XML declaration, comments, processing instructions and a `<!DOCTYPE …>` may come before and after the root element. The DOCTYPE's internal subset is skipped. A UTF-8 BOM is allowed.
- Entities:
  - The five predefined entities `&lt; &gt; &amp; &quot; &apos;` are decoded.
  - Character references (`&#169;`, `&#xA9;`) are decoded.
  - Anything else, including DTD-declared entities, a bare `&`, and a reference to a char XML forbids (such as `&#0;`), is a `BadEntity` error.
- Attribute values are in `"…"` or `'…'`. Tabs and newlines in them become spaces, as XML specifies. A `<` in a value and a repeated attribute are both errors.
- `\r\n` and `\r` become `\n`.
- Not supported: DTD validation, custom entities, and namespace resolution.

## API
- `enum XmlErr`. All positions are 1-based `int`s, and columns count chars.
  - `Syntax(why: str, line, col)`
  - `Eof(want: str, line, col)`
  - `Mismatch(open: str, close: str, line, col)`
  - `BadEntity(text: str, line, col)`
  - `DuplicateAttr(name: str, line, col)`
  - `TooDeep(line, col)`: nested deeper than `MAX_DEPTH` (512)
- `parse(s: str): Element!XmlErr`: the root element.
- `message(e: XmlErr): str`: a one-line description, such as `2:6: </a> closes <b>`.
- Querying:
  - `attr(e, k): str?`
  - `elements(e): [Element]`: the child elements.
  - `child(e, name): Element?`: the first child element with that name.
  - `all(e, name): [Element]`: the child elements with that name.
  - `descendants(e, name): [Element]`: every element with that name below `e`, in document order.
  - `text(e): str`: all the text inside `e`, nested elements included.
- Writing:
  - `str(e: Element): str`: compact output. An empty element is written `<x/>`. `parse(str(e)) == e`.
  - `pretty(e: Element): str`: 2-space indentation. An element that contains text stays on one line, so mixed content is unchanged.
  - Neither writer adds an `<?xml …?>` declaration. Prepend one if you need it.
- `escape(s: str): str`: escapes `& < >` for element text.
- `leaf(name, text): Element`: an element with no attributes holding just `text`.
