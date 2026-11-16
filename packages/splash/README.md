# splash

Live pages in the style of Phoenix LiveView. The server renders a view to HTML, and the page keeps
itself current: new state, other visitors' actions and, under `duck run --live`, saved code all show
up in open tabs within a moment. Buttons and forms send events to the server, and its answer
updates the page at once. There's no reload and no flash, and the page is patched node by node, so
focus, half-typed input and the scroll position all survive updates.

**Effects:** `net` (for `serve`). Depends on `http`, `url` and `hash`.

```duck
fn view(): str uses time = "<h1>It is {time.now()} ms</h1>"

fn main(): int! uses net, time {
  await splash.serve(8080, "clock", _ => view())?   // open tabs tick along by themselves
  0
}
```

## Events

Mark elements in your view, and handle what comes back:

```html
<button splash-click="like">❤ 3</button>
<button splash-click="delete" splash-value="42">delete</button>
<form splash-submit="sign"><input name="name"><button>sign</button></form>
```

```duck
fn handle(req: http.server.Req): http.Resp {
  match splash.event(req) {
    some(splash.Click("like", _)) => likes.send(Like)
    some(splash.Submit("sign", fields)) => book.send(Sign(fields.get("name") else ""))
    some(_) => {}
    none => if splash.is_visit(req) { count_a_visit() }
  }
  splash.reply(req, "my site", render())   // the new view goes straight back to the page
}
```

Add `http` to your own `[deps]` too, so you can name `http.server.Req`. A dependency's types aren't
visible to its users.

## API
- `enum Event { Click(name: str, value: str), Submit(name: str, fields: {str: str}) }`: something the user did. A `splash-click="name"` element was clicked (`splash-value` gives `value`, else ""), or a `splash-submit="name"` form was submitted with its fields.
- `event(req): Event?`: the event a request carries, if any.
- `is_poll(req): bool`: is this an open page refreshing itself? `is_visit(req)` is neither a refresh nor an event. Do a visit's side effects only for visits.
- `reply(req, title, view): http.Resp`: the answer to any request for a live page. It sends the whole page, except for a refresh whose view hasn't changed, which gets a bare `204`.
- `serve(port: int, title: str, view: (http.server.Req) => str): ()!`: serves live pages on `port` forever with `reply`. Handle `event(req)` inside `view`. Run it under `sup` to restart it if it crashes.
- `page(title, view): str` and `page_every(title, view, every)`: a whole HTML page with `view` as its live part (`<main id="splash">`) and the client, refreshing every `every` ms (default `EVERY`, 500). `respond(title, view)` wraps that page in a 200 response.
- `script(every: int): str`: just the client, for a page you build yourself (its live element needs `id="splash"`).
- `escape(s: str): str`: HTML-escapes `& < > " '`. Put anything a user typed through this.

## How it works
- **Refreshes.** Every `every` ms the page fetches its own URL in the background, sending
  `x-splash: poll` and a fingerprint of the view it shows. If the view is the same, the server
  answers `204` with no body; otherwise it sends the page and the client patches `#splash` in
  place.
- **Events.** A click or submit is a form-encoded `POST` to the same URL with `x-splash: event`.
  The response is patched in the same way, without waiting for the next refresh.
- **Patching.** The client walks the old and new live element together, changing only the text,
  attributes and nodes that differ. An input being typed in is never replaced, so it keeps its
  focus, cursor and text.
- **Hidden tabs** don't poll; they catch up as soon as they're visible again.
- **Server unreachable** (for example, while it restarts): `<html>` gets the class
  `splash-offline` and polling backs off up to 5 s. Style it to show "reconnecting…". The last
  view stays on screen.

That's polling, not push. The `http` server answers one connection at a time and closes each one,
so it can't hold a Server-Sent Events or WebSocket connection open yet. When it can, `splash`
should switch to push without changing this API.

See [`examples/live-site`](../../examples/live-site) for `splash` together with `sup` and
`duck run --live`.
