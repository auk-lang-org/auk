fn main() {
    let n: usize = std::env::args().nth(1).and_then(|s| s.parse().ok()).unwrap_or(1000);
    let mut xs: Vec<i64> = Vec::new();
    let mut s: i64 = 42;
    for _ in 0..n {
        s = s.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        xs.push((s >> 33) % 1000000);
    }
    let mut ys = xs.clone(); ys.sort();
    let mut acc: i64 = 0;
    for i in 0..n { acc = acc.wrapping_mul(31).wrapping_add(ys[i]); }
    println!("{} {} {}", ys[0], ys[n - 1], acc);
}
