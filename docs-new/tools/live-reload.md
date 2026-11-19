# Live reload

`auk run --live` runs a program and swaps in new code every time you save, **without
restarting it**. Variables, tasks, open sockets and connected clients all survive. You edit a
running server and the next request runs the new code.

```console
$ auk run --live src/main.auk
[live] reloaded in 41 ms
```

## What happens on a save

| your edit | what happens | what survives |
|---|---|---|
| A function body changes | the new code is swapped in; the next call to that function runs it | everything |
| The program has a type error | the error is printed, nothing is swapped, the old code keeps running | everything |
| A struct or enum changes layout (a field or variant added, removed or retyped), and only tasks use it | just the tasks that can hold that type are stopped; their supervisors restart them on the new code | every other task, and `main` |
| A struct or enum changes layout, and `main` itself can hold it | the program restarts | nothing |
| The program exits or `main` crashes | `--live` waits; the next save starts it again | |

The reasoning is simple. New code can always replace old code, but data already in memory
keeps the layout it was built with. So when a layout changes, whoever might be holding data of
that type has to start over, and nobody else does. Tasks [share nothing](../language/concurrency.md#tasks-share-nothing),
which is what makes it safe to stop some of them and keep the rest.

## Writing a program that reloads well

1. **Put long-lived state in a task of its own**, and let other tasks reach it through a
   channel. Changing how requests are handled then never touches the state.
2. **Run tasks under a supervisor** (the [`sup` package](../language/concurrency.md#supervisors)),
   so a task stopped by a layout change is started again automatically.
3. **Keep `main` small.** If `main` only starts the supervisor, almost no edit can force a
   whole-program restart.

A function that is already running finishes with its old code; the swap applies to calls made
after the reload. A long-running loop therefore picks up changes to the functions it calls,
not to its own body. `reloads()` returns how many swaps have happened so far, for code that
wants to notice one.

## Try it

`examples/live-site` is a small website built to be edited while it runs: a visitor counter, a
guestbook and a shared note, with a table of edits to try and what each one does.

```console
$ cd examples/live-site
$ raft install
$ auk run --live src/main.auk
```

Open <http://localhost:8080> in two tabs, then change the text in `view` and save. The open
pages update themselves in about half a second, counts intact.

`--live` is a development tool. Deploy the program you get from `auk build`.
