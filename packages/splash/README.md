# splash

Live pages in the style of Phoenix LiveView. The server renders a view to HTML, and the page keeps
itself current: new state, other visitors' actions and, under `auk run --live`, saved code all show
up in open tabs within a moment. Buttons, forms, inputs and keys send events to the server, and its
answer updates the page at once. Links move between pages without a reload. There's no flash of a
reloading page, and the page is patched node by node, so focus, half-typed input and the scroll
position all survive updates.

**Effects:** `net` (for `serve`). Depends on `http`, `url`, `hash` and `encoding`.

```auk
fn view(): str uses time = "<h1>It is {time.now()} ms</h1>"

fn main(): int! uses net, time {
  await splash.serve(8080, splash.titled("clock"), _ => view())?   // open tabs tick along by themselves
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
<input splash-blur="nick">                                  <!-- when it loses focus -->
<input splash-keydown="todo" splash-keys="Enter Escape">    <!-- only these keys (all, without splash-keys) -->
```

```auk
fn handle(req: http.server.Req): http.Resp {
  match splash.event(req) {
    some(splash.Click("like", _)) => likes.send(Like)
    some(splash.Submit("sign", fields)) => book.send(Sign(fields.get("name") else ""))
    some(splash.Input("search", text)) => query.send(text)
    some(splash.Key("todo", "Enter", text)) => todos.send(Add(text))
    some(_) => {}
    none => if splash.is_visit(req) { count_a_visit() }
  }
  splash.answer(req, splash.titled("my site"), render())   // the new view goes straight back to the page
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

## Pages

A `Page` is everything about a page apart from its view: its title, CSS, links, scripts and refresh
interval. `answer(req, page, view)` is the answer to every request for a live page.

```auk
let CSS = splash.BASE_CSS + r"""
  body { background: #fdf6e3; }
  .like { font-size: 1.2em; }
  """

let look = splash.titled("my site").with_css(CSS)
splash.answer(req, look, view)
```

The stylesheet is live, like the view. Under `auk run --live`, change a color and save, and open
tabs restyle at their next refresh with no reload. Use a raw string (`r"""…"""`) for CSS, so its
braces aren't read as interpolation. `BASE_CSS` gives readable system type, a centered column,
plain buttons and inputs, field errors, flash messages, light and dark mode, and a "reconnecting…"
badge while the server is away. Pass `""` for no CSS at all.

**What goes over the wire.** A visit gets the whole page, client script included (about 20 KB). The
page's own requests get only what it needs to patch itself: the title and the view (`<title>…</title><main id="splash">…</main>`),
plus the stylesheet and links when they changed. A refresh whose page already shows all that gets a
bare `204`. So a click on a small page costs a few hundred bytes, and an idle tab almost nothing.

## Moving between pages

Links inside an element with `splash-nav` (or with it themselves) move to their page without a
reload, like LiveView's `live_patch`: the page fetches the new URL's view, patches it in, updates
the title and pushes a history entry, so Back and Forward work too, also without reloads.

```html
<nav splash-nav>
  <a href="/">home</a> <a href="/items?sort=new">new items</a>
  <a href="/logout" splash-nav="off">log out</a>              <!-- a plain link -->
</nav>
```

Links to other sites, links opened in a new tab (a modifier key, `target`, `download`) and anchors
on the same page work as usual. On the server, a move is a visit to the new URL (`is_visit` is true,
and `is_nav` tells it apart), so route on `req.path` and `req.query` as you would anyway. Session
state comes along.

After an event, send the page somewhere else with `redirect`:

```auk
some(splash.Submit("new", fields)) => return splash.redirect(req, "/items/{save(fields)}")
```

The page moves there as if a link had been followed. A plain request (no script) gets a `303`.

## Forms: validation and errors

`splash-validate="name"` on a form sends `Validate(name, fields)` as the user types (250 ms after a
pause, or `splash-debounce`), so the view can show errors before the form is sent. `invalid` and
`error_for` render them:

```auk
fn errors(fs: {str: str}): {str: str} =
  if (fs.get("email") else "").contains("@") { {} } else { {"email": "That's not an email"} }

fn form(errs: {str: str}): str = """
  <form splash-submit="join" splash-validate="join">
    <input name="email"{splash.invalid(errs, "email")}>
    {splash.error_for(errs, "email")}
    <button>join</button>
  </form>
  """
```

`invalid` adds `aria-invalid="true"` (red border in `BASE_CSS`) and points `aria-describedby` at
the message; `error_for` is a `<p class="splash-error">`. Fields being typed in aren't touched by
the patch, so errors come and go around them.

A submitted form is cleared once the server answers, unless the new view marks one of its fields
invalid: then what was typed stays, to be fixed. If the server can't be reached, it stays too.

**Flash messages.** `flash(resp, msg)` shows a short message (a toast, `.splash-flash`) on the page
the response reaches, once:

```auk
let resp = splash.answer(req, look, view)
match splash.event(req) {
  some(splash.Submit("save", _)) => splash.flash(resp, "Saved ✓")
  _ => resp
}
```

It works on a `redirect` too: the message shows on the page moved to.

## Uploads

A file field in a `splash-submit` form sends its files with the form. `upload` and `uploads` give
them back with their name, media type and bytes:

```html
<form splash-submit="photo"><input type="file" name="pic" accept="image/*"><button>send</button></form>
```

```auk
some(splash.Submit("photo", fields)) => match splash.upload(fields, "pic") {
  some(f) => photos.send(Save(f.name, f.mime, f.bytes))
  none => {}
}
```

With `multiple`, `uploads(fields, "pic")` gives all of them. The field itself holds the files'
names. Files travel base64-encoded (`http` bodies are text), and a request may have at most 16 MB,
so the files of one form can total about 12 MB. The form is busy while its files are read and sent.

## Parts: components with their own state

A part is a piece of the page with its own state, `update` and `view`. Mark it `splash-part="id"`
(or wrap it with `splash.part(id, html)`), and every event from inside it is named `"id/name"`:
a `splash-click="add"` inside part `cart` arrives as `Click("cart/add", …)`. Parts nest
(`"list/7/like"`).

```auk
struct Shop { cart: Cart, search: Search }

fn update(s: Shop, e: splash.Event): Shop = Shop {
  cart: e.route("cart", s.cart, cart_update),          // cart_update sees Click("add", …)
  search: e.route("search", s.search, search_update),
}

fn view(s: Shop): str =
  splash.part("cart", s.cart, cart_view) + splash.part("search", s.search, search_view)
```

- `route(e, id, s, update)` applies `update` only to events from inside part `id`, with the
  part's id taken off the name. If `update` panics, the part keeps its state and the rest of the
  page goes on.
- `part(id, s, view)` renders a part. If `view` panics, the part shows the error in its place.
- For a list of parts, the id says which: `split(e)` gives `("todo-7", Click("done", ""))`, and
  `within(e, id)` gives the event as part `id` sees it.

## Hooks: your own script on an element

For things the server can't render (a chart, a map, an editor), attach a script to an element with
`splash-hook="name"`, and tell splash to leave its insides alone with `splash-ignore`:

```html
<div splash-hook="chart" splash-ignore data-points="3,1,4,1,5"></div>
```

```js
// static/hooks.js, loaded with  .with_script(splash.asset("hooks.js", text))
splash.hooks.chart = {
  mounted() { this.chart = drawChart(this.el, this.el.dataset.points); },
  updated() { this.chart.update(this.el.dataset.points); },   // the server changed its attributes
  destroyed() { this.chart.dispose(); },
  // this.send("zoom", 3) sends Js("zoom", "3") to the server (named by its parts, like any event)
};
```

- `mounted` runs when an element with the hook appears (at load, or when a patch adds it),
  `updated` when the server changes its attributes, and `destroyed` when it goes away. Pass data
  in `data-*` attributes.
- `splash-ignore` keeps the patch out of the element's children (its attributes still follow the
  server). Without it, the patch puts back what the server sent.
- From any script, `splash.send(el, name, value)` sends `Js(name, value)`, and `splash.go(url)`
  moves to another page.
- `Page.with_script(src)` loads a script (`defer`) on the page. Unlike stylesheets, scripts
  aren't live: a changed script reaches open pages at their next reload.

## Push

With a hub, open pages don't wait for their next poll. A Server-Sent Events stream tells them to
fetch the moment something changes: after any event, after `splash.changed(hub)` (for changes no
event caused, such as timers or background jobs), and after each `auk run --live` reload.
Polling drops to a 5 s fallback.

```auk
let hub = splash.hub()
// kids: sup.child("hub", () => splash.run_hub(hub)), and a web child serving with serve_live:
fn handle(req: http.server.Req, hub: splash.Hub): http.server.Reply {
  match splash.stream(req, hub) {                 // the pages' push streams
    some(r) => return r
    none => {}
  }
  http.server.Whole(splash.answer(req, splash.titled("my site").with_hub(hub), render()))
}
// await http.server.serve_live("", 8080, req => handle(req, hub))
```

Streams need `http.server.serve_live`, which gives each connection a task of its own. The plain
`serve` answers one connection at a time, so a held-open stream would block everyone else. The hub
keeps idle streams alive with a comment every 15 s, and drops a page's stream once its connection
is gone.

## Sessions: a task per browser

State that belongs to one visitor (a cart, a draft, "your clicks") lives in a task of that
visitor's own, LiveView's model. You write it as three functions: where a session starts, how an
event changes it, and how it looks.

```auk
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
- **With `auk run --live`**, changing the session state's shape (say, adding a field to `Mine`)
  restarts only the session tasks; everything else keeps running.

## Linked stylesheets and static files

```auk
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
  `auk run --live` even noticing.
- **Links are live too:** adding, dropping or re-versioning a link reaches open pages without a
  reload.

## Lists that reorder

When a view changes, the page is patched node by node. Children with a `splash-key` (or an `id`)
are matched by key wherever they moved; the rest are matched by position, looking a few nodes ahead
for one that was inserted or removed. Give list items keys:

```auk
"<ul>{items.map(i => "<li splash-key=\"{i.id}\">{splash.escape(i.name)}</li>").join("")}</ul>"
```

Then inserting at the top moves the existing rows instead of rewriting every one, so an input or
an open `<details>` inside a row stays with its row.

## Testing

Test a site without a browser or a server. `browser(handler)` sends your handler the requests a
real page would (with a session cookie, the page's fingerprint and splash's headers) and keeps what
the page would show:

```auk
test "liking" {
  var b = splash.browser(req => handle(req))
  assert b.open("/").contains("❤ 0")
  assert b.send(splash.Click("like", "")).contains("❤ 1")
  assert b.flash == "Thanks!"
  assert b.go("/about").contains("<h1>About")      // as a splash-nav link would
  assert b.title == "About"
  let _ = b.refresh()
  assert b.status == 204                           // nothing changed
}
```

`open`, `go`, `send` and `refresh` each return the view (the inside of `#splash`); `b.view`,
`b.title`, `b.url`, `b.flash` and `b.status` tell the rest. Redirects are followed.
`with_session(sid)` gives another visitor. A handler for `serve_live` returns a `Reply`, so test
the function that makes its `http.Resp`.

For a session's three functions, `play(init, update, view, events)` is the view after `events`:

```auk
assert splash.play(() => Mine { clicks: 0 }, update, view, [splash.Click("mine", ""), splash.Click("mine", "")]) ==
  "<button splash-click=\"mine\">clicked 2</button>"
```

`form(e)` is the body a page sends for event `e` (for building requests by hand), and
`attach(fields, field, files)` puts `Upload`s into a `Submit`'s fields.

## Logging

When a page and the server disagree, turn on logging and watch both sides:

```auk
let log = splash.log_level(env.get("SPLASH_LOG") else "")    // "info" or "debug"
let hub = splash.hub().with_log(log)
let mine = splash.sessions().with_log(log)
let look = splash.titled("my site").with_hub(hub).with_log(log)
```

- **Server (stderr):** at `Info`, every visit, move, event and change shown, as in
  `75bbccf2#4 POST / event Submit("sign", {"name": "Ann"}) -> 200 view 1318231027-3710048048`, plus
  pages joining and leaving the hub and sessions starting and stopping. At `Debug`, also every
  refresh (including the empty `204` answers) and every push.
- **Browser (console):** the page logs at the same level. A visitor can change their own page's
  level with `splash.log("debug")` in the console, and it's remembered for that browser. You see
  every request with its number (`#4 -> event {...}`), every answer and what it did (`#4 <- 200 in
  5 ms (412 bytes): view …, 3 change(s)`, or `dropped: a newer answer is on the page`), each push,
  hooks mounting and leaving, and at `Debug` the list of changes the patch made, such as
  `text #splash > p > button[splash-click=like]: "❤ 0" -> "❤ 1"`.
- **Matching the two:** the console's "started" line names the session (`75bbccf2`); that tab's
  request `#4` is `75bbccf2#4` in the server log.

**Self-check.** After every patch, the page compares itself with the server's view (skipping the
insides of `splash-ignore` elements). If they differ, which would be a bug in the patcher, it logs a
warning naming the first difference (always, at any level) and replaces the live element with the
server's version, so the page doesn't stay wrong.

## How it works
- **Refreshes.** Every `every` ms the page fetches its own URL in the background, sending
  `x-splash: poll` and a fingerprint of what it shows (its head and its view). If nothing changed,
  the server answers `204` with no body; otherwise it sends the title and view (and the head, if
  that changed), and the client patches `#splash` in place.
- **Events.** A click, submit, input, change, blur, key or script event is a form-encoded `POST` to
  the same URL with `x-splash: event`. The response is patched in the same way, without waiting for
  the next refresh.
- **Moves.** A `splash-nav` link pushes the new URL onto the history and fetches it with
  `x-splash: nav`; Back and Forward do the same without pushing. A `redirect` answers an event with
  `x-splash-goto`, and the page moves there.
- **Ordering.** Every request is numbered. An answer older than the one already on the page is
  dropped, and so is one to a request sent before the latest event or move, so a slow refresh can't
  undo a click or briefly show the old state.
- **Patching.** The client walks the old and new live element together, changing only the text,
  attributes and nodes that differ. An input being typed in is never replaced, so it keeps its
  focus, cursor and text.
- **Event fields show the server's state.** A field with `splash-change` or `splash-input` also
  gets its live state set (`selectedIndex`, `checked`, `value`), not just its attributes.
  Browsers stop applying `selected` to an option once the user has picked it, so without this a
  dropdown could stay stuck on an old choice. A dropdown, checkbox or radio always follows the
  server: its choice was sent the moment it was made, and it keeps focus long after. A text field
  is spared only while it's being typed in (focused, in a focused window). Plain form fields, such
  as an unsent draft, are left alone.
- **Hidden tabs** don't poll; they catch up as soon as they're visible again.
- **Server unreachable** (for example, while it restarts): `<html>` gets the class
  `splash-offline` and polling backs off up to 5 s. `BASE_CSS` shows "reconnecting…". The last
  view stays on screen.

Without a hub that's all polling. With one (see Push), pages also listen on a stream and fetch the
moment the hub says so.

## API
- **Events.** `enum Event { Click(name, value), Submit(name, fields), Input(name, value), Change(name, value), Validate(name, fields), Blur(name, value), Key(name, key, value), Js(name, value) }`: something the user did (see Events, Forms, Hooks).
  - `event(req): Event?`: the event a request carries, if any. Events from another origin are `none`.
  - `is_poll(req)`: an open page refreshing itself. `is_nav(req)`: a page moving here. `is_visit(req)`: not a refresh, not an event (a move is a visit). Do a visit's side effects only for visits.
  - `event_name(e)`: the name an event carries.
- **Pages.** `struct Page`, built with `titled(title)` (`BASE_CSS`, no links or scripts, `EVERY` ms) and `.with_css(css)`, `.with_link(href)`, `.with_script(src)`, `.with_every(ms)`, `.with_hub(h)`, `.with_log(level)`.
  - `answer(req, page, view): http.Resp`: the answer to any request for a live page.
  - `render(page, view): str`: the whole HTML page.
  - `serve(port, page, view: (http.server.Req) => str): ()!`: serves live pages on `port` forever with `answer`. Handle `event(req)` inside `view`. Run it under `sup` to restart it if it crashes.
  - `script(every): str`: just the client, for a page you build yourself (its live element needs `id="splash"`).
  - `BASE_CSS`, `EVERY` (500 ms), `HEADER` (`x-splash`).
- **Moving and messages.** `redirect(req, to): http.Resp` and `flash(resp, msg): http.Resp` (see Moving between pages, Forms).
- **Forms.** `invalid(errors, field): str`, `error_for(errors, field): str`. Uploads: `struct Upload { name, mime, bytes }`, `upload(fields, field): Upload?`, `uploads(fields, field): [Upload]`.
- **Parts.** `part(id, html)`, `part(id, s, view)`, `route(e, id, s, update)`, `within(e, id): Event?`, `split(e): (str, Event)?`.
- **Push.** `struct Hub`, `hub()`, `run_hub(h): ()!`, `changed(h)`, `stream(req, h): http.server.Reply?`.
- **Sessions.** `sessions(): Sessions`, `run_sessions<S>(s, init, update, view, max): ()!`, `ask(s, req): str`, `session_id(req): str?`, `SESSION_COOKIE`, `ASK_WAIT`.
- **Static files.** `static(req, read: (str) => str?): http.Resp?`, `asset(name, text): str`, `STATIC` (`/static/`).
- **Testing.** `struct Browser`, `browser(handler)`, `.with_session(sid)`, `.open(url)`, `.go(url)`, `.send(e)`, `.refresh()`; `play(init, update, view, events)`; `form(e): str`; `attach(fields, field, files)`.
- **Logging.** `enum Log { Quiet, Info, Debug }`, `log_level(name): Log`, and `with_log(level)` on a `Page`, a `Hub` and `Sessions`.
- `escape(s: str): str`: HTML-escapes `& < > " '`. Put anything a user typed through this.

**From 0.6:** `page`, `page_every`, `styled`, `styled_every`, `reply`, `reply_styled` and `respond`
are gone. Use `titled(title)` with `.with_css`/`.with_every`, and `answer`/`render`. `serve` takes a
`Page` instead of a title.

See [`examples/live-site`](../../examples/live-site) for `splash` together with `sup`,
`splash-nav`, a flash and `auk run --live`.
