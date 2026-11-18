struct Item { name: str, n: int }
fn main(): int! {
  let t = template.html(r"{% for it in items %}<b>{{ it.name }}</b>={{ it.n }};{% end %}")?
  print(template.render(t, {"items": [Item { name: "a&b", n: 1 }, Item { name: "c", n: 2 }]})?)
  match template.render_text(r"{{ missing }}", {"x": 1}) {
    err(e) => print(template.message(e))
    ok(_) => print("rendered")
  }
  0
}
