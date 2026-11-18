fn h(env: {str: str}, k: str): int uses env = env.len() + (core.env.get(k) else "").len()
fn main() {}
