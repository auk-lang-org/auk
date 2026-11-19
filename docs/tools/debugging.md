# Testing and debugging

Most bugs in an Auk program are caught before it runs, by the type checker, exhaustiveness
checking and contracts. For the rest, there are four tools, from lightest to heaviest:
`peek`, execution traces, the debugger, and native debug info.

## `peek`

`peek e` prints an expression with its value and location to stderr and evaluates to the
value, so it goes anywhere without restructuring the code:

```auk
fn main() {
  let xs = [1, 2, 3]
  let total = peek xs.map(x => x * x).sum()   // [main.auk:3] xs.map(x => x * x).sum() = 14
  print(total)
}
```

## Execution traces

`--trace` records what the program did: every call with its arguments, every return value,
every error and panic. Nothing in the source changes.

```console
$ auk run --trace=json fact.auk
{"ev":"call","fn":"fact.main","loc":"fact.auk:4:4","args":[],"depth":0}
{"ev":"call","fn":"fact.fact","loc":"fact.auk:6:27","args":["1"],"depth":1}
{"ev":"call","fn":"fact.fact","loc":"fact.auk:2:28","args":["0"],"depth":2}
{"ev":"ret","fn":"fact.fact","value":"1","depth":2}
{"ev":"ret","fn":"fact.fact","value":"1","depth":1}
...
```

`--trace=json` writes to stderr and `--trace=<file>` to a file. Each line is one JSON object:

| `ev` | fields |
|---|---|
| `call` | `fn`, `loc` (the call site), `args` (each shown as text), `depth` |
| `ret` | `fn`, `value`, `depth` |
| `err` | `fn`, `error`: a `T!` function returned an error |
| `peek` | `loc`, `expr`, `value` |
| `panic` | `msg`, `loc` |
| `test` | `name`, `result` (`ok` or `FAIL`) |
| `truncated` | the limit was reached |

Values are cut to 200 characters. Tracing stops after 10,000 events (`--trace-limit N`), and
core library functions are left out unless you pass `--trace-core`.

### Traces of failing tests

This is the most useful form. `auk test --trace=json` prints, under each failure, the last
things that test did:

```console
$ auk test --trace=json fact.auk
ok fact
FAIL bad
    panic: assertion failed: fact(3) == 7
      left: 6
      right: 7
      at fact.auk:12:21
    trace (last events, oldest first):
    {"ev":"call","fn":"fact.fact","loc":"fact.auk:12:21","args":["3"],"depth":0}
    {"ev":"call","fn":"fact.fact","loc":"fact.auk:2:28","args":["2"],"depth":1}
    ...
    {"ev":"ret","fn":"fact.fact","value":"6","depth":0}
    {"ev":"panic","msg":"assertion failed: fact(3) == 7\n  left: 6\n  right: 7","loc":"fact.auk:12:21","depth":0}
1 passed, 1 failed
```

`auk test --trace=<dir>` writes every test's whole trace to `<dir>/<test>.jsonl` instead.

A trace answers "what actually happened?" in one run and in a form that a script or an AI
agent can read, which is often faster than stepping through a debugger.

## `auk debug`

The debugger stops the program at breakpoints and panics and shows the local variables and
the call stack. It has two modes.

### Batch mode: a report in one command

With `--batch` or `--json` (or whenever stdin is not a terminal), `auk debug` runs the program
to each breakpoint and panic, records what it sees, and continues:

```console
$ auk debug --batch -b main.auk:6 main.auk
#1 breakpoint at main.auk:6 in main.main
  xs = [1, 2, 3]
#2 breakpoint at main.auk:6 in main.main.<fn:6>
  x = 1
  called from main.main (main.auk:6)
...
#5 panic: index 5 out of range for length 3 at main.auk:8 in main.main
  xs = [1, 2, 3]
  total = 9
stderr:
panic: index 5 out of range for length 3
  at main.auk:8:9
exit 101
```

With no breakpoints at all, you still get the locals and stack at the panic, which is often
all you need: `auk debug --batch main.auk`.

| option | |
|---|---|
| `-b, --break <place>` | stop at `file:line` or at a function's name; repeatable |
| `-b "<place> if <cond>"` | stop only when the Auk expression `cond` is true: `-b "main.auk:12 if n > 3"` |
| `-p, --print a,b,...` | show only these locals; an item may be an expression (`p.x`, `xs[0]`) |
| `-e, --eval <expr>` | also evaluate an Auk expression at each stop: `-e "xs.len()"` |
| `--catch all\|uncaught\|none` | which panics stop the program (default `uncaught`) |
| `--max-stops N` | end the program after `N` stops (default 20) |
| `--timeout S` | after `S` seconds, report where the program is and end it: finds hangs |
| `--json` | the report as JSON: `{stops: [{reason, fn, file, line, locals, stack}], exit_code, stdout, stderr}` |

### Interactive mode

On a terminal, `auk debug main.auk` opens a prompt:

```console
$ auk debug main.auk
auk debug: main.auk (`run` starts it, `help` lists commands)
(auk) break main.auk:6
(auk) run
```

| command | |
|---|---|
| `run`, `r` | start the program |
| `break`, `b <file:line\|fn>` | set a breakpoint; `break <place> if <cond>` for a condition |
| `delete`, `d [id]` | remove one breakpoint, or all |
| `continue`, `c` | resume |
| `next`, `n` / `step`, `s` / `finish`, `f` | step over / into / out |
| `print`, `p [names\|expr]` | the locals, or any Auk expression: `p xs.len()`, `p x = 5` |
| `bt`, `where` | the stack |
| `frame N`, `up`, `down` | select a frame |
| `threads`, `thread N` | list and select threads (one per task) |
| `catch all\|uncaught\|none` | stop on panics |
| `list`, `l` | source around the current line |
| `quit`, `q` | end the program |

An empty line repeats the last command, and Ctrl-C pauses a running program. Expressions are
real Auk, compiled on the spot in the stopped function's scope, so they can call your
functions.

Debug runs are slower than normal ones, roughly 4x on call-heavy code.

The same engine drives the debugger in [VS Code](editors.md), through `auk dap`.

## Native debuggers

`auk build -g` adds DWARF line tables, so `lldb` and `gdb` can set breakpoints by file and
line and print backtraces with Auk function names:

```console
$ auk build -g main.auk -o app
$ lldb ./app -o "b main.auk:6" -o run
```

The build stays optimized, so stepping can jump between lines, and variables are not
described. Use this for profilers and crashes in C code; use `auk debug` to look at Auk
values.

## Leak checking

Auk frees memory by reference counting, and a correct program leaks nothing.
`AUK_LEAK_CHECK=1 auk test` fails any program that ends with runtime objects still alive. It
is a check on the compiler and on C bindings more than on your code, and worth turning on in
CI for a package that uses `ffi`.
