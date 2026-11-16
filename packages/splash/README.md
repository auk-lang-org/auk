# splash

Live pages in the style of Phoenix LiveView. The server renders a view to HTML, and the page keeps
itself current: new state, other visitors' actions and, under `duck run --live`, saved code all show
up in open tabs within a moment. There's no reload, no flash, and the scroll position stays put.

**Effects:** `net` (for `serve`). Depends on `http`.

```duck
fn view(): str uses time = "<h1>It is {time.now()} ms</h1>"

fn main(): int! uses net, time {
  await splash.serve(8080, "clock", _ => view())?   // open tabs tick along by themselves
  0
}
```

Or, inside your own `http` handler (add `http` to your `[deps]` too, to name its types):

```duck
fn handle(req: http.server.Req): http.Resp {
  if !splash.is_poll(req) { count_a_visit() }   // an open page refreshing itself isn't a visit
  splash.respond("my site", render())
}
```

## API
- `page(title: str, view: str): str`: a whole HTML page with `view` (HTML) as its live part (`<main id="splash">`) and the refresh script. `page_every(title, view, every)` sets the interval in ms (default `EVERY`, 500).
- `respond(title: str, view: str): http.Resp`: a 200 `text/html` response with that page.
- `serve(port: int, title: str, view: (http.server.Req) => str): ()!`: serves live pages on `port` forever. Run it under `sup` to restart it if it crashes.
- `is_poll(req): bool`: is this an open page asking for a fresh view (the `x-splash` header, `POLL_HEADER`) rather than a visit? Skip a visit's side effects for polls.
- `script(every: int): str`: just the script, for a page you build yourself (its live element needs `id="splash"`).
- `escape(s: str): str`: HTML-escapes `& < > " '`. Put anything a user typed through this.

## How it works
Every `every` ms, the page fetches its own URL in the background with the `x-splash: 1` header. It
parses the response and replaces `#splash` if it changed. Anything else on the page stays as it
was, and a failed fetch (the server is restarting) is retried on the next tick.

That's polling, not push. The `http` server answers one connection at a time and closes each one,
so it can't hold a Server-Sent Events or WebSocket connection open yet. When it can, `splash`
should switch to push without changing this API. Each open tab costs one request per interval.

See [`examples/live-site`](../../examples/live-site) for `splash` together with `sup` and
`duck run --live`.
