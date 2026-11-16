# splash

Live pages in the style of Phoenix LiveView. The server renders a view to HTML, and the page keeps
itself current: new state, other visitors' actions and, under `duck run --live`, saved code all show
up in open tabs within a moment. Buttons, forms and inputs send events to the server, and its
answer updates the page at once. There's no reload and no flash, and the page is patched node by node, so
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
<input splash-input="search" placeholder="search…">          <!-- as you type, 250 ms after a pause -->
<input splash-input="q" splash-debounce="500">              <!-- …or after 500 ms -->
<select splash-change="sort"><option>new</option><option>old</option></select>
<input type="checkbox" splash-change="done" value="7">      <!-- "7" when checked, "" when not -->
```

```duck
fn handle(req: http.server.Req): http.Resp {
  match splash.event(req) {
    some(splash.Click("like", _)) => likes.send(Like)
    some(splash.Submit("sign", fields)) => book.send(Sign(fields.get("name") else ""))
    some(splash.Input("search", text)) => query.send(text)
    some(_) => {}
    none => if splash.is_visit(req) { count_a_visit() }
  }
  splash.reply(req, "my site", render())   // the new view goes straight back to the page
}
```

Add `http` to your own `[deps]` too, so you can name `http.server.Req`. A dependency's types aren't
visible to its users.

While an event is waiting on the server, the element that sent it (button, form, select) has the
class `splash-loading` and `aria-busy="true"`. Clicks and submits on a busy element are ignored, so
a double click counts once. `BASE_CSS` dims busy elements; style `.splash-loading` for a spinner.

**Security.** Other sites can't send events on a visitor's behalf. Every event must carry the
`x-splash` header: a cross-site form can't set it, and a cross-site `fetch` with it needs a CORS
preflight that this server never grants. `event` also rejects any `Origin` that isn't this host.
Still escape what users typed before showing it (`escape`).

## API
- `enum Event { Click(name, value), Submit(name, fields), Input(name, value), Change(name, value) }`: something the user did.
  - `Click`: a `splash-click="name"` element was clicked; `splash-value` gives `value`, else "".
  - `Submit`: a `splash-submit="name"` form was submitted, with its fields as `{str: str}`.
  - `Input`: the user typed in a `splash-input="name"` field. It's sent once typing pauses (250 ms, or `splash-debounce="ms"`), with the field's text.
  - `Change`: a `splash-change="name"` field changed. A select gives its value; a checkbox or radio gives its value when checked and "" when not.
- `event(req): Event?`: the event a request carries, if any. Events from another origin are `none`.
- `is_poll(req): bool`: is this an open page refreshing itself? `is_visit(req)` is neither a refresh nor an event. Do a visit's side effects only for visits.
- `reply(req, title, view): http.Resp`: the answer to any request for a live page. It sends the whole page, except for a refresh whose view hasn't changed, which gets a bare `204`.
- `serve(port: int, title: str, view: (http.server.Req) => str): ()!`: serves live pages on `port` forever with `reply`. Handle `event(req)` inside `view`. Run it under `sup` to restart it if it crashes.
- `struct Page { title, css, links, every }`, built with `titled(title)` (with `BASE_CSS`, no links, `EVERY` ms) and `.with_css(css)`, `.with_link(href)`, `.with_every(ms)`. `answer(req, page, view)` is the answer to any request for a live page. `render(page, view)` gives the whole HTML.
- `static(req, read: (str) => str?): http.Resp?` and `asset(name, text): str`: static text files under `STATIC` (`/static/`), with content-versioned URLs (see above).
- `page(title, view): str` and `page_every(title, view, every)`: a whole HTML page with `view` as its live part (`<main id="splash">`) and the client, refreshing every `every` ms (default `EVERY`, 500), styled with `BASE_CSS`. `respond(title, view)` wraps that page in a 200 response.
- `styled(title, css, view): str`, `styled_every(…, every)` and `reply_styled(req, title, css, view)`: the same with your own stylesheet, which goes in `<head>` as `<style id="splash-css">`. Build on the defaults with `splash.BASE_CSS + mine`, or pass `""` for no CSS.
- `BASE_CSS`: the default stylesheet. It gives readable system type, a centered column, plain buttons and inputs, works in light and dark mode, and shows a "reconnecting…" badge while the server is away.
- `script(every: int): str`: just the client, for a page you build yourself (its live element needs `id="splash"`).
- `sessions(): Sessions`, `run_sessions<S>(s, init: () => S, update: (S, Event) => S, view: (S) => str, max: int): ()!`, `ask(s, req): str` and `session_id(req): str?`: state per browser session (see above).
- `escape(s: str): str`: HTML-escapes `& < > " '`. Put anything a user typed through this.

## CSS

```duck
let CSS = splash.BASE_CSS + r"""
  body { background: #fdf6e3; }
  .like { font-size: 1.2em; }
  """

splash.reply_styled(req, "my site", CSS, view)
```

The stylesheet is live, like the view. Under `duck run --live`, change a color and save, and open
tabs restyle at their next refresh with no reload. A refresh only gets the page back when the view
*or* the CSS changed. Use a raw string (`r"""…"""`) for CSS, so its braces aren't read as
interpolation. A `<style>` inside the view works too, but it's sent with every changed view.

## Sessions: a task per browser

State that belongs to one visitor (a cart, a draft, "your clicks") lives in a task of that
visitor's own, LiveView's model. You write it as three functions: where a session starts, how an
event changes it, and how it looks.

```duck
struct Mine { clicks: int }

fn update(m: Mine, splash.Click("mine", _)): Mine = Mine { clicks: m.clicks + 1 }
fn update(m: Mine, _: splash.Event): Mine = m

fn view(m: Mine): str = "<button splash-click=\"mine\">clicked {m.clicks}</button>"

fn main(): int! uses net, time {
  let mine = splash.sessions()
  let kids = [
    sup.child("sessions", () => splash.run_sessions(mine, () => Mine { clicks: 0 }, update, view, 1000)),
    sup.child("web", () => web(mine)),        // its handler: splash.answer(req, look, splash.ask(mine, req))
  ]
  sup.run(kids, sup.one_for_one(10, 60_000))?
  0
}
```

- **Identity.** The page's script gives the browser a random session id in a cookie
  (`splash-sid`, from `crypto.randomUUID()`). A first visit, before the cookie exists, sees a fresh
  state, and the page asks for its own session's view right away.
- **`ask(sessions, req)`** sends the request's event to its session and returns that session's view.
  It waits at most `ASK_WAIT` (5 s); if the session is being restarted, it returns a short notice
  and the next refresh asks again.
- **`run_sessions(sessions, init, update, view, max)`** runs every session (run it under `sup`). Each
  session is a task with its own heap. A panic in `update` or `view` starts that one session over
  from `init()`, and other visitors don't notice. Past `max` sessions, the least recently used one
  stops.
- **With `duck run --live`**, changing the session state's shape (say, adding a field to `Mine`)
  restarts only the session tasks; everything else keeps running.

## Pages, linked stylesheets and static files

A `Page` is everything about a page apart from its view: its title, CSS, links and refresh interval.

```duck
fn read_static(name: str): str? uses fs = match fs.read("static/{name}") {
  ok(text) => some(text)
  err(_) => none
}

fn handle(req: http.server.Req): http.Resp uses fs {
  match splash.static(req, f => read_static(f)) {     // /static/… files
    some(r) => return r
    none => {}
  }
  let look = splash.titled("my site")
    .with_css(splash.BASE_CSS + MINE)
    .with_link(splash.asset("site.css", read_static("site.css") else ""))   // /static/site.css?v=…
    .with_link("https://cdn.example/lib.css")
  splash.answer(req, look, render())
}
```

- **`static(req, read)`** serves `/static/<name>` using your `read` function, so `splash` itself
  never touches the file system and needs no `fs` effect. Unsafe names (`..`, a leading `/`, an
  empty segment) get 403, missing files 404. Files are text only (CSS, JS, SVG, JSON, HTML), since
  `http` bodies are text.
- **`asset(name, text)`** is the file's URL with a content hash (`?v=…`). Versioned URLs are cached
  for good. Because you build the page on every request, an edited file gets a new URL, and open
  pages switch to it at their next refresh. That's live CSS from a plain `.css` file, without
  `duck run --live` even noticing.
- **Links are live too:** adding, dropping or re-versioning a link reaches open pages without a
  reload.

## Lists that reorder

When a view changes, the page is patched node by node. Children with a `splash-key` (or an `id`)
are matched by key wherever they moved; the rest are matched by position. Give list items keys:

```duck
"<ul>{items.map(i => "<li splash-key=\"{i.id}\">{splash.escape(i.name)}</li>").join("")}</ul>"
```

Then inserting at the top moves the existing rows instead of rewriting every one, so an input or
an open `<details>` inside a row stays with its row.

## How it works
- **Refreshes.** Every `every` ms the page fetches its own URL in the background, sending
  `x-splash: poll` and a fingerprint of the view it shows. If the view is the same, the server
  answers `204` with no body; otherwise it sends the page and the client patches `#splash` in
  place.
- **Events.** A click, submit, input or change is a form-encoded `POST` to the same URL with
  `x-splash: event`. The response is patched in the same way, without waiting for the next
  refresh.
- **Ordering.** Every request is numbered, and an answer older than the one already on the page is
  dropped, so a slow refresh can't undo a click that was answered after it.
- **Patching.** The client walks the old and new live element together, changing only the text,
  attributes and nodes that differ. An input being typed in is never replaced, so it keeps its
  focus, cursor and text.
- **Event fields show the server's state.** A field with `splash-change` or `splash-input` also
  gets its live state set (`selectedIndex`, `checked`, `value`), not just its attributes, unless
  it's the field being used. Browsers stop applying `selected` to an option once the user has
  picked it, so without this a dropdown could stay stuck on an old choice. Plain form fields, such
  as an unsent draft, are left alone.
- **Ordering.** Answers to requests sent before the latest event are dropped, so a refresh that
  raced your click can't briefly show the old state.
- **Hidden tabs** don't poll; they catch up as soon as they're visible again.
- **Server unreachable** (for example, while it restarts): `<html>` gets the class
  `splash-offline` and polling backs off up to 5 s. Style it to show "reconnecting…". The last
  view stays on screen.

That's polling, not push. The `http` server answers one connection at a time and closes each one,
so it can't hold a Server-Sent Events or WebSocket connection open yet. When it can, `splash`
should switch to push without changing this API.

See [`examples/live-site`](../../examples/live-site) for `splash` together with `sup` and
`duck run --live`.
