# live-site: hot reload, hands-on

A tiny website that counts its visitors. It's built to be edited while it runs, so you can watch what
`duck run --live` keeps and what it restarts.

```sh
cd examples/live-site
quack install                      # http, sup and splash
duck run --live src/main.duck      # PORT=9000 to pick another port
```

Open <http://localhost:8080> and click around: each page counts its own visitors. Keep the tab
open while you edit: **the page updates itself**, with no reload button.

## How it's built

```
main ── sup.run (one_for_one, 10 restarts a minute)
          ├── counter   owns the counts (struct Stats)
          └── web       serves pages; asks counter for each count over a Chan<Hit>
```

Tasks share nothing. The counts live only in the `counter` task, and `web` gets them by sending a
`Hit` (with a reply channel) for each request.

## How the page updates itself

Pages are [`splash`](../../packages/splash) pages. Each one carries a small script that re-fetches
the same URL every 500 ms and swaps in the live part (`view`) when it changed. There's no flash, and
the scroll position stays put. When `splash.is_poll(req)` says a request is one of those refreshes,
`web` sends a `Hit` with `visit: false`, and `counter` only reads the count. That one loop shows
both kinds of change:

- **Code changes:** you save, `duck run --live` swaps in the new code, and the next poll renders
  with it. The page changes about half a second after the save.
- **State changes:** a visit from another tab bumps the count, and the next poll in this tab shows
  it.

This is LiveView's behavior with polling instead of a push channel. The `http` server answers one
connection at a time and closes each one, so it can't hold a connection open for Server-Sent
Events or a WebSocket. That would be the next step.

## Things to try

Edit `src/main.duck` with the site open and save; watch the page (and the terminal).

| Edit | What happens | What survives |
|---|---|---|
| Change the text or colors in `view` | `[live] reloaded in … ms`; the open page shows it within half a second | everything: the counts, the open port |
| Change `record` (count by 10: `+ 10`) | reloaded; the next visit (another tab, or a click) uses the new rule | the counts so far |
| Make a type error (`fn view(…): str = 5`) | the error is printed and nothing is reloaded | everything: the old code keeps serving |
| Visit `/boom` | the request panics; `sup: web exited: …; restarting` | the counts (they live in `counter`); open tabs keep polling through the restart |
| Add a field to `Stats` (`since: int`, and `since: 0` in `counter`) | `` `Stats` changed shape: stopped … task(s) that use it ``; `sup` restarts them on the new code | `main`, the supervisor and the channel; the counts start over, since they were `Stats` |
| Add a field to `Hit` | `` `Hit` changed shape and `main`'s side of the program uses it: restarting the program `` | nothing: `main` made the `Chan<Hit>`, so the whole program starts again |
| Stop the program (or crash `main`) | `[live] the program exited …; waiting for a change` | the next save starts it again |

## Why each edit does what it does

- **Function bodies** are swapped in place. Every call to a user function goes through a table
  that a reload repoints, so the next call runs the new code. Data in memory is untouched.
- **A type's shape** can't change under data that already has the old shape. Each task has its
  own heap, so only the tasks that can hold the type have to go. `duck run --live` works out which
  ones those are from the compiled code, stops them, and lets their supervisor start them fresh.
  Both `counter` and `web` stop when `Stats` changes, even though only `counter` holds a `Stats`.
  The reason: both run through `sup`'s same task entry, and the analysis can't tell their start
  functions apart, so it errs on the safe side.
- **`main`'s own types** would mean changing data on the main thread, so the program restarts
  instead.
