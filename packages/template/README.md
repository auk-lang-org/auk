# template

Text and HTML templates with Jinja-style syntax. In HTML templates, output is escaped
automatically. Variables come from any `Data` value, usually a struct or a map.

- `{{ expr }}`: output, HTML-escaped in `html` templates unless filtered with `raw`
- `{% if %}` / `{% elif %}` / `{% else %}` / `{% end %}`; `endif` and `endfor` also work
- `{% for x in xs %}`, `{% for k, v in map %}`, `{% for i, x in list %}`, with `loop` and an `{% else %}` branch for empty input
- `{% set x = expr %}`, `{% include "name" %}`, `{% raw %}…{% endraw %}`, `{# comment #}`
- filters, as in `{{ price | round(2) }}`
- `{%-` / `-%}` whitespace control

A `{% %}` tag or `{# #}` comment that is alone on its line removes the whole line, so block tags leave no blank lines or stray indentation. **Undefined variables are errors** that carry a line and column. Write `| default(x)` for values that may be missing.

**Effects:** none. **Deps:** none.

```auk
struct Item { name: str, price: float }
struct Page { title: str, items: [Item], user: str? }

fn main(): int! {
  let page = template.html(r"""
    <h1>{{ title }}</h1>
    {% if user %}
    <p>Welcome back, {{ user }}</p>
    {% endif %}
    <ul>
      {% for it in items %}
      <li>{{ loop.index }}. {{ it.name }}: ${{ it.price | round(2) }}</li>
      {% else %}
      <li>Nothing here</li>
      {% endfor %}
    </ul>
    """)?
  let p = Page { title: "Shop <Auk>", items: [Item { name: "Rubber auk", price: 3.5 }], user: some("ann") }
  print(template.render(page, p)?)
  // <h1>Shop &lt;Auk&gt;</h1>
  // <p>Welcome back, ann</p>
  // <ul>
  //   <li>1. Rubber auk: $3.5</li>
  // </ul>
  0
}
```

Write templates as raw strings (`r"..."`, `r"""..."""`). In an ordinary Auk string, `{` starts interpolation.

## API

- `html(src): Template!TplErr` parses a template whose output is HTML-escaped. `text(src): Template!TplErr` parses one whose output is inserted as is. Parse once, render many times.
- `render(t, data): str!TplErr`. `data`'s fields or keys become the variables. It can be a struct, `{str: T}`, `Value.Map`, or `Value.Null` for no variables.
- `render(t, data, partials: {str: Template})` makes the named templates available to `{% include "name" %}`. Includes see the current variables and may nest up to 32 deep.
- `render_html(src, data)` / `render_text(src, data)` parse and render in one step.
- `escape(s)` replaces `& < > " '` with HTML entities. `json(v: Value)` gives compact JSON with `< > &` escaped, so it's safe inside `<script>`.
- `enum TplErr { Syntax(msg, line, col), Undefined(name, line, col), Type(msg, line, col), NoPartial(name, line, col) }`. `message(e)` gives `line:col: …`. Runtime errors point at the `{{ }}` or `{% %}` they came from.

### Expressions

- Literals: `"str"`/`'str'`, `42`, `3.5`, `true`, `false`, `none`, `[a, b]`.
- Access: `user.name`, `xs[0]`, `xs.0`, `xs[-1]`, `m["key"]`, `s[0]`.
- Operators, loosest first: `or`, `and`, `not`, then one comparison (`== != < <= > >= in`, `not in`), then `+ -`, then `* / %`, then unary `-`, then postfix (`.`, `[]`, `| filter`).
- Filters bind tightest: `-3 | abs` is `-(3 | abs)`.
- `and`/`or` return an operand, so `{{ name or "anonymous" }}` works. `==` compares ints and floats by value. Int `/` truncates, as in Auk. `+` also joins strings and lists.
- Truthiness: `none`, `false`, `0`, `0.0`, `""`, `[]` and `{}` are false.
- Output: strings print as they are, `none` prints as nothing, numbers and bools as Auk prints them, and lists and maps as JSON.
- `loop` inside a `for` has `index` (from 1), `index0`, `first`, `last` and `length`.
- Iterating a map gives its keys with one loop variable and key and value with two. Iterating `none` gives nothing.
- `set` assigns in the innermost scope. Each loop has its own scope, so a `set` inside a loop doesn't leak out of it.

### Filters

`default(x)` (also catches undefined names), `raw`/`safe`, `escape`/`e`, `str`, `json`, `upper`, `lower`, `trim`, `capitalize`, `title`, `length`/`len`/`count`, `first`, `last`, `reverse`, `sort` / `sort("field")`, `join(sep)`, `keys`, `values`, `items`, `split` / `split(sep)`, `replace(a, b)`, `truncate(n)` / `truncate(n, end)`, `int`, `float`, `abs`, `round` / `round(places)`, `urlencode`.

Not yet: template inheritance (`extends`/`block`), macros, custom filters, and indenting included partials to match the include line.
