use std::collections::HashMap;
fn main() {
    let n: i64 = std::env::args().nth(1).and_then(|s| s.parse().ok()).unwrap_or(1000);
    let mut parts: Vec<String> = Vec::new();
    for i in 0..n { parts.push(format!("w{}", i % 1000)); }
    let text = parts.join(" ");
    let mut counts: HashMap<&str, i64> = HashMap::new();
    for w in text.split(' ') { *counts.entry(w).or_insert(0) += 1; }
    let mut total = 0;
    for c in text.chars() { if c == 'w' { total += 1; } }
    println!("{} {} {}", text.chars().count(), counts.len(), total);
}
