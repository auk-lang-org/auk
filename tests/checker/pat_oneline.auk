enum C { R, G, B, K }

fn f(c: C): int = match c { R => 1, G => 2 }

fn g(c: C): int = match c { R => 1 }

fn h(x: bool): int = match x {
  true => 1 }

fn i(c: C): int {
	match c {
		R => 1
	}
}

fn main() { print(f(C.R) + g(C.G) + h(true) + i(C.K)) }
