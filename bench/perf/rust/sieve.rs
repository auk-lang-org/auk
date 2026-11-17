fn main() {
    let n: usize = std::env::args().nth(1).and_then(|s| s.parse().ok()).unwrap_or(1000);
    let mut sieve: Vec<bool> = Vec::new();
    for _ in 0..=n { sieve.push(true); }
    let mut count = 0i64;
    for i in 2..=n {
        if sieve[i] {
            count += 1;
            let mut j = i * i;
            while j <= n { sieve[j] = false; j += i; }
        }
    }
    println!("{}", count);
}
