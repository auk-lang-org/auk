# live-site: hot reload, hands-on

A tiny website: it counts each page's visitors, and everyone shares a ❤ button, a guestbook, a
note anyone can edit as they type, and a "duck of the day" picker.
It's built to be edited while it runs, so you can watch what `duck run --live` keeps and what it
restarts.

```sh
cd examples/live-site
quack install                      # http, sup and splash
duck run --live src/main.duck      # PORT=9000 to pick another port
```

Open <http://localhost:8080> in two tabs and click around: ❤ in one tab, sign the guestbook in the
other, type in the note, pick a duck. Each tab shows the other's changes within half a second. Keep a tab open while you edit:
**the page updates itself**, with no reload button.

## How it's built

```
main ── sup.run (one_for_one: up to 10 restarts in 6 s)
          ├── counter   owns the state everyone shares (struct Stats): visits, likes, guestbook, note
          ├── sessions  a task per browser (splash.run_sessions), each holding a Mine: "your clicks"
          ├── hub       pushes to open pages (Server-Sent Events): after any click or edit, and after each reload
          └── web       serves pages, a task per connection; asks counter (over a Chan<Hit>) and the visitor's session for their parts
```

Tasks share nothing. The state lives only in the `counter` task. For each request, `web` sends a
`Hit` saying what it did (an `Act`: a `Visit`, a `Look` from a page refreshing itself, a `Like`, a
`Sign` with a name, a `Note` being typed, or a `Pick` of a duck) plus a reply channel. `counter` applies it and answers with what the page should
show.

## How the page updates itself

Pages are [`splash`](../../packages/splash) pages. Each one carries a small script that re-fetches
the same URL every 500 ms and patches the live part (`view`) in place when it changed. There's no
flash; focus, half-typed input and the scroll position all stay. The ❤ button
(`splash-click="like"`), the guestbook form (`splash-submit="sign"`), the note
(`splash-input="note"`) and the duck picker (`splash-change="duck"`) send events that `act` turns
into an `Act`, and the answer updates the page at once. A refresh is a `Look`, so it doesn't
count as a visit. That one loop shows both kinds of change:

- **Code changes:** you save, `duck run --live` swaps in the new code, the hub notices the reload,
  and every open tab fetches at once. The page changes about 0.3 s after the reload finishes.
- **State changes:** a ❤, guestbook entry or note from another tab changes the state, and the hub
  tells every tab to fetch. Other tabs update within about 50 ms.

Pages hold a Server-Sent Events stream open to the hub (`http.server.serve_live` gives each
connection a task of its own, so held streams don't block anyone). Polling is only a 5 s fallback.

## Things to try

Edit `src/main.duck` with the site open and save; watch the page (and the terminal).

| Edit | What happens | What survives |
|---|---|---|
| Change the text in `view` | `[live] reloaded in … ms`; the open page shows it within half a second | everything: the counts, the open port |
| Change a color in `CSS` | reloaded; the open page restyles within half a second, without a reload | everything, including whatever you were typing |
| Edit `static/site.css` (the linked stylesheet) | no Duck reload at all: the page links `site.css?v=<content hash>`, the next refresh sees a new hash, and the open page swaps the link | everything |
| Change `record` (count by 10: `+ 10`) | reloaded; the next visit (another tab, or a click) uses the new rule | the counts so far |
| Make ❤ worth 10 (`s.likes += 10` in `apply`) | reloaded; the next click adds 10 | the likes so far, and the guestbook |
| Edit `view` while half-way through typing a name | the page updates around the input | what you typed, and the focus |
| Make a type error (`fn view(…): str = 5`) | the error is printed and nothing is reloaded | everything: the old code keeps serving |
| Visit `/boom` | the request panics; only its own connection drops (each connection is a task) | everything; nothing restarts |
| Add a field to `Mine` (`since: int`, and `since: 0` where one is made) | `` `Mine` changed shape: stopped … task(s) that use it ``: only the sessions restart | everything shared: visits, ❤, guestbook, note; only "your clicks" start over |
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
