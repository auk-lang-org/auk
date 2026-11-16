/// Request routing with string-prefix and map patterns.

enum Resp { Ok(body: str), Created(id: int), NotFound, Bad(msg: str) }

struct Db { users: {int: str}, next: int }

fn route("GET /health", _: Value, _: var Db): Resp = Ok("up")
fn route("GET /users/" + id, _: Value, db: var Db): Resp {
  let n = int.parse(id) else return Bad("bad id")
  match db.users.get(n) { some(name) => Ok(name), none => NotFound }
}
fn route("POST /users", {"name": Str(name)}, db: var Db): Resp {
  db.next += 1
  db.users[db.next] = name
  Created(db.next)
}
fn route("POST /users", _: Value, _: var Db): Resp = Bad("expected {{\"name\": str}}")
fn route(_: str, _: Value, _: var Db): Resp = NotFound

fn status(Ok(_)): int = 200
fn status(Created(_)): int = 201
fn status(NotFound): int = 404
fn status(Bad(_)): int = 400

test "router" {
  var db = Db { users: {}, next: 0 }
  assert route("POST /users", json.parse(r"""{"name":"ann"}""")?, &db) == Created(1)
  assert route("GET /users/1", Null, &db) == Ok("ann")
  assert route("GET /users/9", Null, &db).status() == 404
  assert route("DELETE /", Null, &db) == NotFound
}
