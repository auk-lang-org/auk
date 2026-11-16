/// A JSON-backed todo list: `todo add buy milk`, `todo done 2`, `todo ls`.

struct Todo { id: int, text: str, done: bool }

fn main(args: [str]): int! uses fs {
  var todos: [Todo] = json.decode(fs.read("todos.json") else "[]")?
  run(args.skip(1), &todos)?
  fs.write("todos.json", json.encode(todos))?
  0
}

fn run(["add", ..words]: [str], todos: var [Todo]): ()! {
  todos.push(Todo { id: todos.len() + 1, text: words.join(" "), done: false })
}
fn run(["done", id]: [str], todos: var [Todo]): ()! {
  let n = int.parse(id) else fail("not a number: {id}")
  let i = todos.find_index(t => t.id == n) else fail("no todo #{n}")
  todos[i].done = true
}
fn run(["ls"]: [str], todos: var [Todo]): ()! {
  for t in todos {
    let mark = if t.done { "x" } else { " " }
    print("{mark} {t.id}. {t.text}")
  }
}
fn run(_: [str], _: var [Todo]): ()! = fail("usage: todo add|done|ls")
