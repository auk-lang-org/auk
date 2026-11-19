use std::collections::HashMap;
fn main() {
    let n: i64 = std::env::args().nth(1).and_then(|s| s.parse().ok()).unwrap_or(1000);
    let mut m: HashMap<i64, i64> = HashMap::new();
    for i in 0..n { let k = (i * 7919) % (n / 2); *m.entry(k).or_insert(0) += 1; }
    let mut hits = 0;
    for i in 0..n { if m.get(&i).is_some() { hits += 1; } }
    println!("{} {}", m.len(), hits);
}
