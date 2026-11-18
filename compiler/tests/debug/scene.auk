struct Point { x: int, y: int }
enum Shape { Circle(c: Point, r: float), Square(Point, float), Empty }
struct Scene { name: str, shapes: [Shape], tags: {str: int}, best: Point?, pair: (int, str) }

fn main() {
    let s = Scene { name: "demo", shapes: [Circle(Point { x: 1, y: 2 }, 3.0), Square(Point { x: 0, y: 0 }, 1.5), Empty], tags: {"a": 1, "b": 2}, best: Point { x: 9, y: 9 }, pair: (7, "seven") }
    let big = 0..1500
    print(s.name)
}
