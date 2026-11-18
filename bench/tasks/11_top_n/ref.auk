fn top_n(items: [Item], n: int): [str]
  requires n >= 0
{
  items.filter(i => i.qty > 0).sort_by(i => (-(i.price * i.qty), i.name)).take(n).map(i => i.name)
}
