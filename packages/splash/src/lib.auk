/// Live pages, LiveView-style: the server renders a view to HTML, and the page keeps itself
/// current. Its script re-fetches the view in the background and patches it in place when it
/// changed, so new state, other visitors' actions and (under `auk run --live`) saved code all
/// show up in open tabs within a moment: no reload, no flash, focus, typing and scroll intact.
/// Buttons, forms and inputs send events (`splash-click`, `splash-submit`, `splash-input`,
/// `splash-change`, `splash-validate`, `splash-blur`, `splash-keydown`) that the server handles,
/// and the answer patches the page at once; the element has the class `splash-loading` until it
/// does. `splash-nav` links move between pages without a reload; `splash-part` scopes events to a
/// component; `splash-hook` attaches your own script to an element.
///
/// Events can't be forged by other sites: each one must carry the `x-splash` header, which a
/// cross-site form can't set and a cross-site `fetch` can't send without a CORS preflight this
/// server never grants; `event` also rejects any `Origin` that isn't this host.
///
/// Pages poll (`every` ms). With a `Hub` (`with_hub`, served by `http.server.serve_live`) they also
/// listen on a Server-Sent Events stream: every event, `changed(hub)` and `auk run --live`
/// reload tells all open pages to fetch at once, and polling slows to a fallback.

/// The header splash's own requests carry: `poll` (a refresh), `event` or `nav` (a move to
/// another page).
pub let HEADER = "x-splash"

/// How often an open page asks for a fresh view, by default (ms).
pub let EVERY = 500

/// The default stylesheet of `titled`: readable type, a centered column, plain buttons and
/// inputs, light and dark, field errors, flash messages, and a "reconnecting…" badge while the
/// server is away. Build on it with `.with_css(splash.BASE_CSS + mine)`, or replace it.
pub let BASE_CSS = r"""
  :root { color-scheme: light dark; }
  body { margin: 0; font: 18px/1.5 system-ui, sans-serif; }
  #splash { max-width: 42rem; margin: 0 auto; padding: 2rem 1rem; }
  button, input, select, textarea { font: inherit; }
  button { padding: .3em .9em; border: 1px solid #8886; border-radius: .5em; background: #8881; cursor: pointer; }
  button:hover { background: #8883; }
  input, select, textarea { padding: .3em .5em; border: 1px solid #8886; border-radius: .5em; }
  a { color: inherit; }
  [aria-invalid="true"] { border-color: #d33; }
  .splash-error { color: #d33; font-size: .85em; margin: .2em 0; }
  .splash-loading { opacity: .6; cursor: progress; }
  .splash-flash { position: fixed; left: 50%; top: 1rem; transform: translateX(-50%); padding: .4em 1em; border-radius: .6em; background: #333; color: #fff; box-shadow: 0 2px 8px #0004; }
  .splash-offline body::after { content: "reconnecting…"; position: fixed; right: 1rem; bottom: 1rem; padding: .3em .9em; border-radius: 1em; background: #333; color: #fff; font-size: .8em; }
  """

/// Something the user did on a page. Inside an element with `splash-part="id"`, `name` is
/// `"id/name"` (parts nest: `"list/7/like"`); `split`, `within` and `route` take it apart.
/// - `Click(name, value)`: an element with `splash-click="name"` (and `splash-value="..."`,
///   or "") was clicked.
/// - `Submit(name, fields)`: a form with `splash-submit="name"` was submitted, with its fields
///   (and its files: `upload`).
/// - `Input(name, value)`: the user typed in a field with `splash-input="name"`; sent once
///   typing pauses for 250 ms (`splash-debounce="ms"` to change it), with the field's text.
/// - `Change(name, value)`: a field with `splash-change="name"` changed (a select, a checkbox:
///   its value when checked, "" when not).
/// - `Validate(name, fields)`: the user is filling in a form with `splash-validate="name"`; sent
///   as typing pauses, with its fields, so the view can show errors before the form is sent.
/// - `Blur(name, value)`: a field with `splash-blur="name"` lost focus, with its value.
/// - `Key(name, key, value)`: a key went down in an element with `splash-keydown="name"`
///   (only the keys in `splash-keys="Enter Escape"`, if it has one), with the key's name and
///   the field's value.
/// - `Js(name, value)`: your own script sent it, with `splash.send(el, name, value)`.
pub enum Event {
  Click(name: str, value: str),
  Submit(name: str, fields: {str: str}),
  Input(name: str, value: str),
  Change(name: str, value: str),
  Validate(name: str, fields: {str: str}),
  Blur(name: str, value: str),
  Key(name: str, key: str, value: str),
  Js(name: str, value: str),
}

/// Is `req` an open page asking for a fresh view? Don't count it as a visit, and don't do a
/// visit's side effects for it.
pub fn is_poll(req: http.server.Req): bool = req.headers.get(HEADER) == some("poll")

/// Is `req` a page moving to this URL without a reload (a `splash-nav` link, back or forward, a
/// `redirect`)? It's a visit too.
pub fn is_nav(req: http.server.Req): bool = req.headers.get(HEADER) == some("nav")

/// The event `req` carries, if it is one (handle it, then answer with the new view).
pub fn event(req: http.server.Req): Event? {
  if req.method != "POST" || req.headers.get(HEADER) != some("event") || !same_origin(req) {
    return none
  }
  var fields: {str: str} = {}
  for (k, v) in url.parse_query(req.body) { fields[k] = v }
  let name = fields.remove("splash-event") else return none
  let value = fields.get("value") else ""
  match fields.remove("splash-kind") {
    some("submit") => Submit(name, fields)
    some("validate") => Validate(name, fields)
    some("input") => Input(name, value)
    some("change") => Change(name, value)
    some("blur") => Blur(name, value)
    some("key") => Key(name, fields.get("key") else "", value)
    some("js") => Js(name, value)
    _ => Click(name, value)
  }
}

/// Did `req` come from a page of this site? Browsers send `Origin` on every POST; a request
/// without one (not from a browser) has no page to have been tricked.
fn same_origin(req: http.server.Req): bool {
  let o = req.headers.get("origin") else return true
  let host = req.headers.get("host") else return false
  o == "http://{host}" || o == "https://{host}"
}

/// Is `req` a visit: not a refresh, not an event? (Moving here with `splash-nav` is a visit.)
pub fn is_visit(req: http.server.Req): bool = !is_poll(req) && event(req) is none

/// The name an event carries (`"cart/add"` inside `splash-part="cart"`).
pub fn event_name(e: Event): str = match e {
  Click(n, _) => n
  Submit(n, _) => n
  Input(n, _) => n
  Change(n, _) => n
  Validate(n, _) => n
  Blur(n, _) => n
  Key(n, _, _) => n
  Js(n, _) => n
}

/// The same event, named `n`.
fn renamed(e: Event, n: str): Event = match e {
  Click(_, v) => Click(n, v)
  Submit(_, fs) => Submit(n, fs)
  Input(_, v) => Input(n, v)
  Change(_, v) => Change(n, v)
  Validate(_, fs) => Validate(n, fs)
  Blur(_, v) => Blur(n, v)
  Key(_, k, v) => Key(n, k, v)
  Js(_, v) => Js(n, v)
}

// ---- parts: components with their own state, update and view ----

/// `html` as part `id` of the page: events from inside it are named `"id/name"`. (Any element
/// can be a part: give it `splash-part="id"` yourself, say on an `<li>`.) Ids can't hold `/`.
pub fn part(id: str, html: str): str = "<div splash-part=\"{escape(id)}\">{html}</div>"

/// Part `id` showing state `s` with `view`. If `view` panics, the part shows the error and the
/// rest of the page is unharmed.
pub fn part<S>(id: str, s: S, view: (S) => str): str = part(id, catch view(s) else e => problem(e))

/// The part an event came from, and the event as that part sees it (its name without the
/// part's id): `Click("cart/add", "3")` is `some(("cart", Click("add", "3")))`. None outside any
/// part. For a list of parts, the id says which one: `"todo-7"`.
pub fn split(e: Event): (str, Event)? {
  let n = event_name(e)
  let i = n.find("/")?
  some((n[0..i], renamed(e, n[i + 1..n.len()])))
}

/// The event as part `id` sees it, if it came from inside that part.
pub fn within(e: Event, id: str): Event? {
  let (p, inner) = split(e)?
  if p == id { some(inner) } else { none }
}

/// Part `id`'s next state: `update(s, inner)` if `e` came from inside it, else `s` as it is. If
/// `update` panics, the part keeps `s` (with a line on stderr) and the rest of the page goes on.
pub fn route<S>(e: Event, id: str, s: S, update: (S, Event) => S): S {
  let inner = within(e, id) else return s
  catch update(s, inner) else x => {
    eprint("splash: part {id}'s update panicked ({x}); it keeps its state")
    s
  }
}

// ---- pages ----

/// How a page looks, apart from its view: its title, its stylesheet (in `<head>`), the
/// stylesheets and scripts it links, and how often it refreshes. Build one with `titled` and the
/// `with_*` functions: `splash.titled("my site").with_css(CSS).with_link(splash.asset("site.css", text))`.
pub struct Page {
  title: str,
  css: str,
  links: [str],
  scripts: [str],
  every: int,
  hub: Hub?,
  log: Log,
}

/// A page titled `title`, styled with `BASE_CSS`, linking nothing, refreshing every `EVERY` ms.
pub fn titled(title: str): Page =
  Page { title, css: BASE_CSS, links: [], scripts: [], every: EVERY, hub: none, log: Quiet }

/// The same page with the stylesheet `css` instead (`BASE_CSS + mine` to build on the defaults,
/// "" for none). It is live: change it, and open pages restyle at their next refresh.
pub fn with_css(p: Page, css: str): Page = Page { css, ..p }

/// The same page, also linking the stylesheet at `href` (`<link rel="stylesheet">`, after the
/// others). Links are live too: add, drop or re-version one, and open pages follow.
pub fn with_link(p: Page, href: str): Page = Page { links: p.links + [href], ..p }

/// The same page, also loading the script at `src` (`<script defer>`): where your hooks live
/// (`splash.hooks.chart = {...}`). Scripts load once, with the page; a changed list reaches
/// open pages at their next reload, not live.
pub fn with_script(p: Page, src: str): Page = Page { scripts: p.scripts + [src], ..p }

/// The same page, refreshing every `every` ms.
pub fn with_every(p: Page, every: int): Page = Page { every, ..p }

/// The same page, pushed to by `hub`: open pages listen on its stream (answer it with `stream`),
/// and answering an event tells them all to fetch at once.
pub fn with_hub(p: Page, hub: Hub): Page = Page { hub: some(hub), ..p }

/// The same page, logging at `level`: on the server (stderr) every answer it makes, and in the
/// browser's console everything the page sends and receives (a visitor can raise their own
/// page's level with `splash.log("debug")` in the console).
pub fn with_log(p: Page, level: Log): Page = Page { log: level, ..p }

/// The answer to any request for a live page `p` showing `view`. A visit gets the whole page.
/// splash's own requests (refreshes, events, moves) get only what the page needs to patch
/// itself: the title and the view, plus the stylesheets if they changed. A refresh whose page
/// already shows all that gets a bare 204 (an idle tab costs a few bytes per poll).
pub fn answer(req: http.server.Req, p: Page, view: str): http.Resp {
  let ev = event(req)
  if ev is some(_) {
    match p.hub {
      some(hub) => changed(hub)
      none => {}
    }
  }
  let h = fingerprint(p, view)
  let had = req.headers.get("x-splash-hash") else ""
  let kind = req.headers.get(HEADER) else ""
  let what = match ev {
    some(e) => "event {e}"
    none => match kind {
      "poll" => "refresh"
      "nav" => "move"
      _ => "visit"
    }
  }
  if kind == "poll" && had == h {
    say(p.log, Debug, "{seq(req)} {req.method} {req.path} {what} -> 204 unchanged ({h})")
    return http.Resp { status: 204, headers: {"x-splash-hash": h}, body: "" }
  }
  let changed = if had == "" {
    ""
  } else if had == h {
    ", same as the page has"
  } else {
    ", page had {had}"
  }
  say(p.log, Info, "{seq(req)} {req.method} {req.path} {what} -> 200 view {h}{changed}")
  var headers = {"content-type": "text/html; charset=utf-8", "x-splash-hash": h}
  let body = if kind == "" {
    render(p, view)
  } else {
    let head = head_of(had) != head_of(h)
    if !head { headers["x-splash-head"] = "same" }
    fragment(p, view, head)
  }
  http.Resp { status: 200, headers, body }
}

/// The whole HTML of page `p` showing `view`.
pub fn render(p: Page, view: str): str {
  let scripts = p.scripts.map(s => "<script src=\"{escape(s)}\" defer></script>").join("")
  """
  <!doctype html>
  <html>
  <head>
  <meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>{escape(p.title)}</title>
  {links(p)}<style id="splash-css">{p.css}</style>{scripts}
  </head>
  <body>
  <main id="splash">{view}</main>
  {boot(p.every, fingerprint(p, view), p.hub is some(_), p.log)}
  </body>
  </html>
  """
}

/// What one of splash's own requests gets: the title, the stylesheets (when `head`) and the view.
fn fragment(p: Page, view: str, head: bool): str {
  let styles = if head { "{links(p)}<style id=\"splash-css\">{p.css}</style>" } else { "" }
  "<title>{escape(p.title)}</title>{styles}<main id=\"splash\">{view}</main>"
}

fn links(p: Page): str =
  p.links.map(l => "<link rel=\"stylesheet\" href=\"{escape(l)}\" data-splash>").join("")

/// Serves the live page `p` on `port` (every interface) forever: `view(req)` renders each one
/// (its HTML; handle `event(req)` in it).
pub async fn serve(port: int, p: Page, view: (http.server.Req) => str): ()! uses net {
  await http.server.serve("", port, req => answer(req, p, view(req)))
}

/// Send the page to `to` (a path on this site): after an event, the page moves there without a
/// reload, as a `splash-nav` link would (and Back returns). A plain request gets a 303 redirect.
pub fn redirect(req: http.server.Req, to: str): http.Resp = if req.headers.get(HEADER) is some(_) {
  http.Resp { status: 200, headers: {"x-splash-goto": to}, body: "" }
} else {
  http.Resp { status: 303, headers: {"location": to}, body: "" }
}

/// The same response, also showing `msg` to the user for a few seconds (a toast, styled by
/// `.splash-flash`): "Saved ✓" after an event. Shown once, by the page the response reaches.
pub fn flash(r: http.Resp, msg: str): http.Resp {
  var headers = r.headers
  headers["x-splash-flash"] = encoding.percent_encode(msg)
  http.Resp { headers, ..r }
}

// ---- form errors ----

/// The error message for `field` from `errors` (field name to message), as a
/// `<p class="splash-error">`, or "" if it has none. Put it after the field.
pub fn error_for(errors: {str: str}, field: str): str = match errors.get(field) {
  some(m) => "<p class=\"splash-error\" id=\"{escape(field)}-error\">{escape(m)}</p>"
  none => ""
}

/// The attributes marking `field` invalid if `errors` has a message for it (else ""): put them
/// in the field's tag, `<input name="email"{splash.invalid(errs, "email")}>`. A submitted form
/// that comes back with an invalid field keeps what was typed; otherwise it is cleared.
pub fn invalid(errors: {str: str}, field: str): str = if errors.contains(field) {
  " aria-invalid=\"true\" aria-describedby=\"{escape(field)}-error\""
} else {
  ""
}

// ---- uploads ----

/// A file sent with a form (`<input type="file" name="photo">` in a `splash-submit` form): its
/// name, its media type ("" if the browser didn't know), and its bytes.
pub struct Upload { name: str, mime: str, bytes: [int] }

/// The files a submitted form sent in `field` (several with `multiple`). The field itself holds
/// their names (joined with ", "). Files travel base64-encoded in the request, so a request's
/// limit (`http.wire.MAX_BODY`, 16 MB) allows about 12 MB of files.
pub fn uploads(fields: {str: str}, field: str): [Upload] {
  let prefix = "{FILE}{field}:"
  var out: [Upload] = []
  for k, v in fields {
    if k.starts_with(prefix) {
      match decode_upload(v) {
        some(u) => out.push(u)
        none => {}
      }
    }
  }
  out
}

/// The first file a submitted form sent in `field`, if any.
pub fn upload(fields: {str: str}, field: str): Upload? = uploads(fields, field).first()

/// `fields` with `files` in `field`, as a page sends them (for tests: `Submit("photo",
/// splash.attach({}, "photo", [up]))`).
pub fn attach(fields: {str: str}, field: str, files: [Upload]): {str: str} {
  var out = fields
  out[field] = files.map(f => f.name).join(", ")
  for i, f in files {
    out["{FILE}{field}:{i}"] = "{f.name}\n{f.mime}\n{encoding.base64(f.bytes)}"
  }
  out
}

let FILE = "splash-file:"

fn decode_upload(v: str): Upload? {
  let i = v.find("\n")?
  let rest = v[i + 1..v.len()]
  let j = rest.find("\n")?
  let bytes = encoding.from_base64(rest[j + 1..rest.len()]) else return none
  some(Upload { name: v[0..i], mime: rest[0..j], bytes })
}

// ---- logging ----

/// How much splash reports. `Info`: one line per event, per change shown, per page joining or
/// leaving, per session started or stopped. `Debug`: every message too (each refresh, each push).
/// Lines carry the browser's request number (`#13`), the same on both sides.
pub enum Log { Quiet, Info, Debug }

/// A level from its name: "debug", "info", anything else `Quiet` (`env.get("SPLASH_LOG")`).
pub fn log_level(s: str): Log = match s.trim().lower() {
  "debug" => Debug
  "info" => Info
  _ => Quiet
}

fn rank(Quiet): int = 0
fn rank(Info): int = 1
fn rank(Debug): int = 2

fn name(Quiet): str = "quiet"
fn name(Info): str = "info"
fn name(Debug): str = "debug"

/// Write `msg` (on stderr) if `level` is at least `min`.
fn say(level: Log, min: Log, msg: str) {
  if rank(level) >= rank(min) {
    eprint("splash {msg}")
  }
}

/// Which browser and which of its requests ("b20fe175#13", as in that browser's console), for logs.
fn seq(req: http.server.Req): str =
  short_id(session_id(req) else "") + "#" + (req.headers.get("x-splash-seq") else "-")

/// A session id, shortened for logs.
fn short_id(sid: str): str = if sid.len() > 8 { sid[0..8] } else { sid }

// ---- push: a hub that tells open pages to fetch now ----

/// The way to a site's hub: make one with `hub()`, run it with `run_hub` (as a `sup` child), answer
/// pages' streams with `stream`, and attach it to pages with `with_hub`.
pub struct Hub { ch: Chan<Tell>, log: Log }

enum Tell { Join(out: Chan<str>), Changed }

pub fn hub(): Hub = Hub { ch: chan(), log: Quiet }

/// The same hub, logging at `level` (pages joining and leaving, pushes, reloads).
pub fn with_log(h: Hub, level: Log): Hub = Hub { log: level, ..h }

/// Something changed that no event caused (a timer, a background job): tell open pages to fetch.
pub fn changed(h: Hub) = h.ch.send(Changed)

/// Runs the hub forever (run it as a `sup` child). It tells every open page to fetch when told
/// (`changed`, or an answered event) and after each `auk run --live` reload, and keeps idle
/// streams alive (a comment every 15 s), dropping those whose page has gone.
pub fn run_hub(h: Hub): ()! {
  var pages: [Chan<str>] = []
  var seen = reloads()
  var idle = 0
  loop {
    match h.ch.recv_for(250) {
      some(Join(out)) => {
        pages.push(out)
        say(h.log, Info, "hub: a page joined ({pages.len()} open)")
      }
      some(Changed) => pages = tell(h.log, pages, "change")
      none => {
        idle += 1
        if reloads() != seen {
          seen = reloads()
          say(h.log, Info, "hub: code reloaded")
          pages = tell(h.log, pages, "reload")
        } else if idle >= 60 {
          idle = 0
          pages = tell(h.log, pages, "")
        }
      }
    }
  }
}

/// Send `what` to every page ("": a keepalive); the ones whose stream has closed (the page went
/// away) drop out.
fn tell(log: Log, pages: [Chan<str>], what: str): [Chan<str>] {
  let msg = if what == "" { ": still here\n\n" } else { "data: {what}\n\n" }
  let left = pages.filter(p => catch p.send(msg) is ok(_))
  if what != "" {
    say(log, Debug, "hub: pushed \"{what}\" to {left.len()} page(s)")
  }
  if left.len() < pages.len() {
    say(log, Info, "hub: {pages.len() - left.len()} page(s) left ({left.len()} open)")
  }
  left
}

/// The answer to a page's push stream (`?splash=events`), or none for any other request.
pub fn stream(req: http.server.Req, h: Hub): http.server.Reply? {
  if !req.query.split("&").contains("splash=events") { return none }
  let out: Chan<str> = chan()
  h.ch.send(Join(out))
  some(
    http.server.Stream(
      200,
      {"content-type": "text/event-stream", "cache-control": "no-cache"},
      out,
    ),
  )
}

// ---- sessions: a task per browser ----

/// The cookie naming a browser's session: a random UUID the page's script sets on its first
/// load (secure randomness from the browser, so splash needs no `rand` effect).
pub let SESSION_COOKIE = "splash-sid"

/// How long `ask` waits for a session's answer (ms).
pub let ASK_WAIT = 5000

/// A request on its way to its session: its event (none: just show), and where to answer.
struct Route { sid: str, event: Event?, reply: Chan<str> }

/// The way to a site's sessions: make one with `sessions()`, run them with `run_sessions` (as a
/// `sup` child) and ask them with `ask` (in the web handler).
pub struct Sessions { ch: Chan<Route>, log: Log }

pub fn sessions(): Sessions = Sessions { ch: chan(), log: Quiet }

/// The same sessions, logging at `level` (sessions started and stopped, each event per session).
pub fn with_log(s: Sessions, level: Log): Sessions = Sessions { log: level, ..s }

/// This request's session id, from its cookie (none on a first visit, or if it looks wrong).
pub fn session_id(req: http.server.Req): str? {
  let cookies = req.headers.get("cookie") else return none
  for part in cookies.split(";") {
    let kv = part.trim()
    if kv.starts_with(SESSION_COOKIE + "=") {
      let id = kv[SESSION_COOKIE.len() + 1..kv.len()]
      let ok = id.len() >= 8 &&
        id.len() <= 64 &&
        id.chars().all(c => c.is_alpha() || c.is_digit() || c == '-')
      return if ok { some(id) } else { none }
    }
  }
  none
}

/// The view (HTML) of this request's session, after applying its event if it has one. A first
/// visit (no session yet) gets the view of a fresh state; its page starts a session right away.
/// If the session doesn't answer within `ASK_WAIT` ms (its task is being restarted), a short
/// notice instead: the page's next refresh asks again.
pub fn ask(s: Sessions, req: http.server.Req): str {
  let reply: Chan<str> = chan()
  let sid = session_id(req) else ""
  let ev = event(req)
  match ev {
    some(e) => say(s.log, Info, "{seq(req)} session: event {e}")
    none => say(s.log, Debug, "{seq(req)} session: view")
  }
  s.ch.send(Route { sid, event: ev, reply })
  reply.recv_for(ASK_WAIT) else {
    say(s.log, Info, "{seq(req)} session: no answer in {ASK_WAIT} ms")
    "<p class=\"splash-error\">One moment…</p>"
  }
}

/// Runs a site's sessions until `s` is closed (run it as a `sup` child). Each browser session
/// gets a task of its own, holding a state that starts as `init()`; each event of that session is
/// applied with `update`, and `view` renders it. Sessions share nothing: a panic in `update` or
/// `view` starts that one session over from `init()` (with a line on stderr), and the others
/// don't notice. At most `max` sessions live at once: past that, the least recently used stops.
pub fn run_sessions<S>(
  s: Sessions,
  init: () => S,
  update: (S, Event) => S,
  view: (S) => str,
  max: int,
): ()! {
  var chans: {str: Chan<Route>} = {}
  var tasks: {str: Task<()>} = {}
  var recent: [str] = []
  for r in s.ch {
    if r.sid == "" {
      r.reply.send(catch view(init()) else e => problem(e))
      continue
    }
    if !chans.contains(r.sid) {
      while recent.len() > 0 && recent.len() >= max {
        let old = recent.remove(0)
        stop(&chans, &tasks, old)
        say(
          s.log,
          Info,
          "sessions: stopped {short_id(old)}, the least recently used ({chans.len()} live)",
        )
      }
      let c: Chan<Route> = chan()
      chans[r.sid] = c
      tasks[r.sid] = session(c, init, update, view)
      say(s.log, Info, "sessions: started {short_id(r.sid)} ({chans.len()} live)")
    }
    recent = recent.filter(x => x != r.sid) + [r.sid]
    chans[r.sid].send(r)
  }
  for id in recent {
    stop(&chans, &tasks, id)
  }
}

/// Close session `id`'s channel and wait for its task to finish.
fn stop(chans: var {str: Chan<Route>}, tasks: var {str: Task<()>}, id: str) {
  match chans.remove(id) {
    some(c) => c.close()
    none => {}
  }
  match tasks.remove(id) {
    some(t) => {
      let _ = await any [t]
    }
    none => {}
  }
}

async fn session<S>(asks: Chan<Route>, init: () => S, update: (S, Event) => S, view: (S) => str) {
  var state = init()
  for a in asks {
    match a.event {
      some(e) => match catch update(state, e) {
        ok(next) => state = next
        err(x) => {
          eprint("splash: a session's update panicked ({x}); it starts over")
          state = init()
        }
      }
      none => {}
    }
    a.reply.send(catch view(state) else e => problem(e))
  }
}

fn problem(e: Err): str = "<p class=\"splash-error\">{escape("{e}")}</p>"

// ---- static files ----

/// Where `static` serves files, and `asset` links them.
pub let STATIC = "/static/"

/// The answer to a request for a static file (`/static/<name>`), or none for any other request:
/// `read(name)` gives the file's text (none: 404). splash reads nothing itself (it has no `fs`
/// effect), so you pass the reading in: `splash.static(req, f => read_static(f))`, with
/// `fn read_static(name: str): str? uses fs` reading `static/{name}` (none if it can't).
/// Names with `..`, a leading `/`, a `\\` or an empty segment are refused (403). Text files
/// only (`http` bodies are text): CSS, JS, SVG, JSON, HTML, plain text. A request with `?v=`
/// (from `asset`) may be cached for good; any other must be checked again each time.
pub fn static(req: http.server.Req, read: (str) => str?): http.Resp? {
  if !req.path.starts_with(STATIC) { return none }
  let name = req.path[STATIC.len()..req.path.len()]
  if !safe_name(name) {
    return some(http.Resp {
      status: 403,
      headers: {"content-type": "text/plain"},
      body: "forbidden",
    })
  }
  let text = read(name) else return some(http.Resp {
    status: 404,
    headers: {"content-type": "text/plain"},
    body: "not found",
  })
  let cache = if req.query.contains("v=") {
    "public, max-age=31536000, immutable"
  } else {
    "no-cache"
  }
  some(http.Resp {
    status: 200,
    headers: {"content-type": content_type(name), "cache-control": cache},
    body: text,
  })
}

/// The URL of static file `name` whose text is `text`, versioned by its content
/// (`/static/site.css?v=…`): link it on every render, and an edited file gets a new URL, so
/// open pages fetch it again (live), while an unchanged one stays cached.
pub fn asset(name: str, text: str): str = "{STATIC}{name}?v={short_hash(text)}"

fn safe_name(name: str): bool = name != "" &&
  !name.starts_with("/") &&
  !name.contains("\\") &&
  !name.split("/").any(s => s == "" || s == "." || s == "..")

fn content_type(name: str): str {
  let ext = (name.split(".").last() else "").lower()
  match ext {
    "css" => "text/css; charset=utf-8"
    "js" => "text/javascript; charset=utf-8"
    "mjs" => "text/javascript; charset=utf-8"
    "json" => "application/json"
    "svg" => "image/svg+xml"
    "html" => "text/html; charset=utf-8"
    "txt" => "text/plain; charset=utf-8"
    _ => "application/octet-stream"
  }
}

fn short_hash(s: str): str = "{hash.fnv1a64(s.bytes()) & 0xffffffff}"

// ---- testing without a browser ----

/// A pretend browser for tests: it sends `handler` the requests a real page would (with a
/// session cookie, the page's fingerprint and splash's headers) and keeps what the page would
/// show. `let b = splash.browser(handle)`, then `b.open("/")`, `b.send(Click("like", ""))`,
/// `b.go("/about")`, `b.refresh()`; each returns the view, and `b.view`, `b.title`, `b.url`,
/// `b.flash` and `b.status` tell the rest. A `redirect` is followed.
pub struct Browser {
  handler: (http.server.Req) => http.Resp,
  url: str,
  sid: str,
  hash: str,
  view: str,
  title: str,
  flash: str,
  status: int,
}

/// A browser on `handler`, with a session of its own (`with_session` for another one).
pub fn browser(handler: (http.server.Req) => http.Resp): Browser = Browser {
  handler,
  url: "/",
  sid: "test-browser-1",
  hash: "",
  view: "",
  title: "",
  flash: "",
  status: 0,
}

/// The same browser, as session `sid` (8 to 64 letters, digits or `-`): two browsers with
/// different sessions are two visitors.
pub fn with_session(b: Browser, sid: str): Browser = Browser { sid, ..b }

/// Visit `url` (typed in, or reloaded): the whole page. Returns the view.
pub fn open(b: var Browser, url: str): str {
  b.url = url
  b.hash = ""
  fetch(&b, "GET", "", "")
}

/// Move to `url` as a `splash-nav` link does. Returns the view.
pub fn go(b: var Browser, url: str): str {
  b.url = url
  fetch(&b, "GET", "nav", "")
}

/// Refresh as an open page does every `every` ms. Returns the view (the same one after a 204).
pub fn refresh(b: var Browser): str = fetch(&b, "GET", "poll", "")

/// Send event `e`, as clicking, typing or submitting would. Returns the new view.
pub fn send(b: var Browser, e: Event): str = fetch(&b, "POST", "event", form(e))

fn fetch(b: var Browser, method: str, kind: str, body: str): str {
  var headers = {"host": "localhost", "cookie": "{SESSION_COOKIE}={b.sid}"}
  if kind != "" {
    headers[HEADER] = kind
    headers["x-splash-hash"] = b.hash
  }
  if body != "" { headers["content-type"] = "application/x-www-form-urlencoded" }
  let handler = b.handler
  let r = handler(http.server.request(method, b.url, headers, body))
  b.status = r.status
  b.flash = match r.headers.get("x-splash-flash") {
    some(f) => encoding.percent_decode(f) else f
    none => ""
  }
  match r.headers.get("x-splash-goto") {
    some(to) => return go(&b, to)
    none => {}
  }
  match r.headers.get("location") {
    some(to) => return open(&b, to)
    none => {}
  }
  if r.status == 204 { return b.view }
  b.hash = r.headers.get("x-splash-hash") else ""
  b.view = live_part(r.body)
  b.title = between(r.body, "<title>", "</title>") else b.title
  b.view
}

/// The live part (`#splash`) of a page or a fragment.
fn live_part(html: str): str {
  let open = "<main id=\"splash\">"
  let i = html.find(open) else return html
  let rest = html[i + open.len()..html.len()]
  let pieces = rest.split("</main>")
  pieces.take(pieces.len() - 1).join("</main>")
}

fn between(s: str, a: str, b: str): str? {
  let i = s.find(a)?
  let rest = s[i + a.len()..s.len()]
  let j = rest.find(b)?
  some(rest[0..j])
}

/// The body a page sends for event `e` (form-encoded): `event` reads it back.
pub fn form(e: Event): str = url.build_query(pairs(e))

fn pairs(e: Event): [(str, str)] = match e {
  Click(n, v) => kind("click", n) + [("value", v)]
  Submit(n, fs) => fs.entries() + kind("submit", n)
  Input(n, v) => kind("input", n) + [("value", v)]
  Change(n, v) => kind("change", n) + [("value", v)]
  Validate(n, fs) => fs.entries() + kind("validate", n)
  Blur(n, v) => kind("blur", n) + [("value", v)]
  Key(n, k, v) => kind("key", n) + [("key", k), ("value", v)]
  Js(n, v) => kind("js", n) + [("value", v)]
}

fn kind(k: str, n: str): [(str, str)] = [("splash-kind", k), ("splash-event", n)]

/// The view after `events`, starting from `init()`: a session's three functions tested without
/// a server. `play(init, update, view, [Click("add", ""), Click("add", "")])`.
pub fn play<S>(init: () => S, update: (S, Event) => S, view: (S) => str, events: [Event]): str =
  view(events.reduce(init(), (s, e) => update(s, e)))

// ---- the client ----

/// The page's script on its own, for a page built by hand: the live part must be the element
/// with `id="splash"`.
pub fn script(every: int): str = boot(every, "", false, Quiet)

/// `s` as HTML text: `&`, `<`, `>`, `"` and `'` escaped. Put anything a user typed through this.
pub fn escape(s: str): str = s
  .replace("&", "&amp;")
  .replace("<", "&lt;")
  .replace(">", "&gt;")
  .replace("\"", "&quot;")
  .replace("'", "&#39;")

/// What a page reports to say what it shows: its head (title, stylesheet, links), then its view.
fn fingerprint(p: Page, view: str): str =
  "{short_hash(p.title + "\n" + p.css + "\n" + p.links.join("\n"))}-{short_hash(view)}"

/// The head half of a fingerprint.
fn head_of(h: str): str = h.split("-").first() else ""

fn boot(every: int, h: str, push: bool, log: Log): str = "<script>const splashEvery = {every}, splashHash = \"{h}\", splashPush = {push}, splashLog = \"{name(log)}\";</script>" +
  CLIENT

/// The client. Polls with `setTimeout` (paused while the tab is hidden, backing off to 5 s while
/// the server is unreachable, when `<html>` gets the class `splash-offline`); sends events as
/// form-encoded POSTs; moves between pages with `history.pushState`; patches `#splash` node by
/// node (`morph`), so an input being typed in keeps its focus, cursor and text; runs hooks.
let CLIENT = r"""
  <script>
  (() => {
    // ---- logging: `splash.log("debug" | "info" | "quiet")` in the console (remembered) ----
    const levels = { quiet: 0, info: 1, debug: 2 };
    const stored = () => { try { return localStorage.getItem("splash-log"); } catch (e) { return null; } };
    let level = levels[stored() || splashLog] ?? 0;
    const say = (min, ...args) => { if (level >= min) console.log("[splash]", ...args); };
    const warn = (...args) => console.warn("[splash]", ...args);
    // hooks may be defined before this script runs (a script in <head>) or after (`with_script`)
    const hooks = (self.splash && self.splash.hooks) || {};
    self.splash = {
      hooks,
      log(l) {
        try { localStorage.setItem("splash-log", l); } catch (e) {}
        level = levels[l] ?? 0;
        console.info("[splash] log level:", l, "(levels: quiet, info, debug)");
      },
      // an event from your own script: Js(name, value) on the server, scoped to el's parts
      send(el, name, value) { send("event", params("js", scoped(el, name), value == null ? "" : String(value))); },
      // move to another page of this site without a reload
      go(url) { go(url); },
    };
    const ATTRS = ["splash-click", "splash-change", "splash-input", "splash-submit", "splash-validate", "splash-blur", "splash-keydown", "splash-hook"];
    // a short readable path to an element, for logs: #splash > ul > li[splash-key=3]
    const where = (n) => {
      const parts = [];
      for (let e = n.nodeType === 1 ? n : n.parentElement; e && e.id !== "splash"; e = e.parentElement) {
        const k = e.getAttribute("splash-key"), p = e.getAttribute("splash-part"), ev = ATTRS.find((x) => e.hasAttribute(x));
        parts.unshift(e.tagName.toLowerCase() + (e.id ? "#" + e.id : "") + (p !== null ? `[splash-part=${p}]` : "") + (k !== null ? `[splash-key=${k}]` : "") + (ev ? `[${ev}=${e.getAttribute(ev)}]` : ""));
      }
      return ["#splash", ...parts].join(" > ") + (n.nodeType === 3 ? " (text)" : "");
    };
    const decode = (body) => body ? Object.fromEntries(new URLSearchParams(body)) : undefined;
    // an event's name inside parts: "cart/add" for splash-click="add" inside splash-part="cart"
    const scoped = (el, name) => {
      const ids = [];
      for (let p = el && el.closest("[splash-part]"); p; p = p.parentElement && p.parentElement.closest("[splash-part]")) ids.unshift(p.getAttribute("splash-part"));
      return [...ids, name].join("/");
    };

    // with push, polling is only a fallback (in case the stream is down)
    // (a browser without EventSource keeps polling at the normal rate)
    const push = splashPush && !!self.EventSource;
    const every = push ? Math.max(splashEvery, 5000) : splashEvery;
    let hash = splashHash, delay = every, timer, sent = 0, shown = 0, lastEvent = 0, offline = false;
    const root = document.documentElement;
    let changes = null;  // what the current patch changed (for logs)
    const note = (what) => { if (changes) changes.push(what); };
    const same = (x, y) => x.nodeType === y.nodeType && x.nodeName === y.nodeName;
    const key = (n) => n.nodeType === 1 ? n.getAttribute("splash-key") ?? (n.id || null) : null;
    const morph = (a, b) => {
      if (!same(a, b)) { note(`replaced ${where(a)}`); a.replaceWith(b.cloneNode(true)); return; }
      if (a.nodeType === 3 || a.nodeType === 8) {
        if (a.nodeValue !== b.nodeValue) { note(`text ${where(a)}: ${JSON.stringify(a.nodeValue)} -> ${JSON.stringify(b.nodeValue)}`); a.nodeValue = b.nodeValue; }
        return;
      }
      if (a.nodeType !== 1) return;
      for (const { name } of [...a.attributes]) if (!b.hasAttribute(name)) { note(`removed ${name} on ${where(a)}`); a.removeAttribute(name); }
      for (const { name, value } of [...b.attributes]) if (a.getAttribute(name) !== value) { note(`set ${name}=${JSON.stringify(value)} on ${where(a)}`); a.setAttribute(name, value); }
      // what's inside belongs to a script (a chart, an editor): leave it alone
      if (a.hasAttribute("splash-ignore")) return;
      // children: keyed ones (`splash-key`, or `id`) are matched by key, wherever they moved;
      // the rest by position, looking a few nodes ahead for one inserted or removed, so the
      // nodes after it (a field being typed in) stay themselves
      const keyed = new Map();
      for (const c of a.childNodes) { const k = key(c); if (k !== null) keyed.set(k, c); }
      const news = [...b.childNodes];
      let i = 0;
      for (let j = 0; j < news.length; j++) {
        const n = news[j], k = key(n);
        let cur = a.childNodes[i] || null, match = null;
        if (k !== null) { match = keyed.get(k) || null; keyed.delete(k); }
        else if (cur && key(cur) === null) {
          if (same(cur, n)) match = cur;
          else if (!news.slice(j + 1, j + 4).some((x) => key(x) === null && same(x, cur))) {
            // not an insertion: were nodes removed before one like n?
            const gone = [cur];
            for (let s = cur.nextSibling, t = 0; s && t < 3; s = s.nextSibling, t++) {
              if (key(s) === null && same(s, n)) { match = s; break; }
              gone.push(s);
            }
            if (match) { for (const g of gone) { note(`removed ${where(g)}`); g.remove(); } cur = match; }
            else match = cur;  // morph replaces it
          }
        }
        if (match) { if (match !== cur) { note(`moved ${where(match)}`); a.insertBefore(match, cur); } morph(match, n); }
        else { const c = n.cloneNode(true); a.insertBefore(c, cur); note(`added ${where(c)}`); }
        i++;
      }
      while (a.childNodes.length > i) { note(`removed ${where(a.lastChild)}`); a.lastChild.remove(); }
      // a field the server owns (an event field) shows the server's state: browsers display a
      // field's current state, which stops following its attributes once touched (an option the
      // user picked ignores `selected` from then on). Spared: only a text field being typed in
      // (focused, in a focused window). A choice (select, checkbox, radio) was sent the moment it
      // was made, and keeps focus long after, so it always follows the server.
      const choice = a.tagName === "SELECT" || a.type === "checkbox" || a.type === "radio";
      const typing = !choice && a === document.activeElement && document.hasFocus();
      if ((a.hasAttribute("splash-change") || a.hasAttribute("splash-input")) && !typing) {
        if (a.tagName === "SELECT") {
          if (a.selectedIndex !== b.selectedIndex) { note(`synced ${where(a)}: option ${a.selectedIndex} -> ${b.selectedIndex}`); a.selectedIndex = b.selectedIndex; }
        } else if (a.type === "checkbox" || a.type === "radio") {
          if (a.checked !== b.hasAttribute("checked")) { note(`synced ${where(a)}: checked ${a.checked} -> ${!a.checked}`); a.checked = b.hasAttribute("checked"); }
        } else if (a.tagName === "TEXTAREA") {
          if (a.value !== b.textContent) { note(`synced ${where(a)}: value`); a.value = b.textContent; }
        } else if ("value" in a) {
          const v = b.getAttribute("value") ?? "";
          if (a.value !== v) { note(`synced ${where(a)}: ${JSON.stringify(a.value)} -> ${JSON.stringify(v)}`); a.value = v; }
        }
      } else if (a.hasAttribute("splash-change") || a.hasAttribute("splash-input")) {
        say(2, `kept ${where(a)} as is: it's being typed in`);
      }
    };
    // the first place two trees differ (null: none), for the self-check
    const differ = (a, b) => {
      if (!same(a, b)) return `${where(a)}: <${a.nodeName}> where the server has <${b.nodeName}>`;
      if ((a.nodeType === 3 || a.nodeType === 8) && a.nodeValue !== b.nodeValue) return `${where(a)}: ${JSON.stringify(a.nodeValue)} where the server has ${JSON.stringify(b.nodeValue)}`;
      if (a.nodeType === 1) {
        for (const { name, value } of [...b.attributes]) if (a.getAttribute(name) !== value) return `${where(a)}: ${name}=${JSON.stringify(a.getAttribute(name))} where the server has ${JSON.stringify(value)}`;
        for (const { name } of [...a.attributes]) if (!b.hasAttribute(name)) return `${where(a)}: extra attribute ${name}`;
        if (a.hasAttribute("splash-ignore")) return null;
        if (a.childNodes.length !== b.childNodes.length) return `${where(a)}: ${a.childNodes.length} children where the server has ${b.childNodes.length}`;
        for (let i = 0; i < a.childNodes.length; i++) { const d = differ(a.childNodes[i], b.childNodes[i]); if (d) return d; }
      }
      return null;
    };

    // ---- hooks: splash.hooks.name = { mounted() {}, updated() {}, destroyed() {} } ----
    // `this.el` is the element, `this.send(name, value)` sends Js(name, value). `updated` runs
    // when the server changed the element's attributes (pass data in data-* attributes).
    const live = new Map();
    const attrs = (el) => [...el.attributes].map((x) => x.name + "=" + x.value).join("\n");
    const call = (h, fn) => { try { if (typeof h.ctx[fn] === "function") h.ctx[fn](); } catch (e) { warn(`hook ${h.name}: ${fn} failed:`, e); } };
    const runHooks = () => {
      const top = document.getElementById("splash");
      const els = top ? [...top.querySelectorAll("[splash-hook]")] : [];
      const now = new Set(els);
      for (const [el, h] of live) if (!now.has(el) || el.getAttribute("splash-hook") !== h.name) { live.delete(el); say(1, `hook ${h.name}: destroyed`); call(h, "destroyed"); }
      for (const el of els) {
        const name = el.getAttribute("splash-hook"), h = live.get(el);
        if (!h) {
          const def = hooks[name];
          if (!def) { warn(`no hook named ${JSON.stringify(name)} (define splash.hooks[${JSON.stringify(name)}] = { mounted() {...} })`); continue; }
          const ctx = Object.assign(Object.create(def), { el, send: (n, v) => self.splash.send(el, n, v) });
          const fresh = { ctx, name, attrs: attrs(el) };
          live.set(el, fresh);
          say(1, `hook ${name}: mounted on ${where(el)}`);
          call(fresh, "mounted");
        } else if (h.attrs !== attrs(el)) {
          h.attrs = attrs(el);
          say(2, `hook ${name}: updated`);
          call(h, "updated");
        }
      }
    };

    // ---- flash: a message the server sent with an answer ----
    const toast = (msg) => {
      say(1, "flash:", msg);
      const t = document.createElement("div");
      t.className = "splash-flash";
      t.setAttribute("role", "status");
      t.textContent = msg;
      document.body.appendChild(t);
      setTimeout(() => t.remove(), 4000);
    };

    // `el`: the element that sent an event, marked `splash-loading` until the answer is in;
    // `after(ok)`: runs once the answer is in (and patched), or the request failed
    const send = async (kind, body, el, after) => {
      const my = ++sent, t0 = performance.now();
      if (kind !== "poll") lastEvent = my;
      const headers = { "x-splash": kind, "x-splash-hash": hash, "x-splash-seq": String(my) };
      if (body) headers["content-type"] = "application/x-www-form-urlencoded";
      say(kind === "poll" ? 2 : 1, `#${my} -> ${kind} ${kind === "nav" ? location.pathname + location.search : ""}`, ...(body ? [decode(body)] : []), `(page shows ${hash || "nothing yet"})`);
      if (el) { el.classList.add("splash-loading"); el.setAttribute("aria-busy", "true"); }
      let ok = false;
      try {
        const r = await fetch(location.href, { method: body ? "POST" : "GET", headers, body });
        ok = r.ok;
        if (offline) { offline = false; say(1, "server reachable again"); }
        root.classList.remove("splash-offline");
        delay = every;
        const ms = Math.round(performance.now() - t0);
        const flash = r.headers.get("x-splash-flash");
        if (flash) toast(decodeURIComponent(flash));
        const to = r.headers.get("x-splash-goto");
        if (to) { say(1, `#${my} <- ${r.status} in ${ms} ms: go to ${to}`); go(to); return; }
        // a later request's answer is already on the page, or this one was sent before the
        // latest event and shows the state from before it
        if (my < shown || my < lastEvent) {
          say(1, `#${my} <- ${r.status} in ${ms} ms: dropped, ` + (my < shown ? `a newer answer (#${shown}) is on the page` : `sent before event #${lastEvent}, so it shows the state from before it`));
          return;
        }
        shown = my;
        if (r.status === 204) { say(2, `#${my} <- 204 in ${ms} ms: unchanged`); return; }
        const text = await r.text();
        const doc = new DOMParser().parseFromString(text, "text/html");
        if (doc.title && doc.title !== document.title) document.title = doc.title;
        const now = document.getElementById("splash"), next = doc.getElementById("splash");
        const newHash = r.headers.get("x-splash-hash") || "";
        if (now && next) {
          changes = [];
          morph(now, next);
          const done = changes; changes = null;
          if (done.length) say(1, `#${my} <- ${r.status} in ${ms} ms (${text.length} bytes): view ${newHash}, ${done.length} change(s)`, level >= 2 ? done : "");
          else say(2, `#${my} <- ${r.status} in ${ms} ms: view ${newHash}, nothing to change`);
          // self-check: the page must now match the server's view; if not, say where, and heal
          // by taking the server's version whole
          const live = document.getElementById("splash"), d = differ(live, next);
          if (d) {
            warn(`#${my}: after patching, the page doesn't match the server's view: ${d}. Replacing it whole. (Please report this: it's a splash bug.)`);
            live.replaceWith(document.importNode(next, true));
          }
          hash = newHash;
          runHooks();
        }
        // the head: sent only when it changed
        if (r.headers.get("x-splash-head") !== "same") {
          // linked stylesheets: follow the new page's list (an edited asset has a new ?v=)
          const hrefs = (d) => [...d.querySelectorAll("link[data-splash]")].map((l) => l.getAttribute("href"));
          if (hrefs(document).join("\n") !== hrefs(doc).join("\n")) {
            say(1, "stylesheets now:", hrefs(doc));
            const css = document.getElementById("splash-css");
            for (const l of document.querySelectorAll("link[data-splash]")) l.remove();
            for (const l of doc.querySelectorAll("link[data-splash]")) document.head.insertBefore(l.cloneNode(true), css);
          }
          const cs = document.getElementById("splash-css"), ns = doc.getElementById("splash-css");
          if (ns && !cs) document.head.appendChild(ns.cloneNode(true));
          else if (cs && !ns) cs.remove();
          else if (cs && ns && cs.textContent !== ns.textContent) { say(1, "stylesheet (CSS) changed"); cs.textContent = ns.textContent; }
        }
      } catch (e) {
        root.classList.add("splash-offline");
        delay = Math.min(delay * 2, 5000);
        if (!offline) { offline = true; say(1, `#${my}: server unreachable (${e.message || e}); retrying every ${delay / 1000} s or less`); }
        else say(2, `#${my}: still unreachable; next try in ${delay} ms`);
      } finally {
        if (el) { el.classList.remove("splash-loading"); el.removeAttribute("aria-busy"); }
        if (after) after(ok);
      }
    };
    const params = (kind, name, value, more) => new URLSearchParams({ "splash-kind": kind, "splash-event": name, value, ...more }).toString();
    const busy = (el) => el.classList.contains("splash-loading");
    // a form's fields; with `files`, its files too, base64 (field "splash-file:<name>:<i>")
    const b64 = async (file) => {
      const u8 = new Uint8Array(await file.arrayBuffer());
      let s = "";
      for (let i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode.apply(null, u8.subarray(i, i + 0x8000));
      return btoa(s);
    };
    const fields = async (f, kind, name, files) => {
      const p = new URLSearchParams(), names = {};
      for (const [k, v] of new FormData(f)) {
        if (typeof v === "string") { p.append(k, v); continue; }
        if (!v.name && !v.size) continue;  // a file field left empty
        const list = names[k] = names[k] || [];
        if (files) p.append(`splash-file:${k}:${list.length}`, `${v.name}\n${v.type}\n${await b64(v)}`);
        list.push(v.name);
      }
      for (const k in names) p.set(k, names[k].join(", "));
      p.set("splash-kind", kind);
      p.set("splash-event", name);
      return p.toString();
    };
    const poll = async () => {
      if (!document.hidden) await send("poll");
      timer = setTimeout(poll, delay);
    };
    const now = () => { clearTimeout(timer); poll(); };
    document.addEventListener("visibilitychange", () => { if (!document.hidden) { say(2, "tab visible again: refreshing"); now(); } });
    // push: the server says something changed; fetch now (EventSource reconnects by itself)
    if (push) {
      const es = new EventSource(location.pathname + "?splash=events");
      es.onopen = () => say(2, "push stream open");
      es.onerror = () => say(2, "push stream interrupted (the browser reconnects by itself)");
      es.onmessage = (e) => { say(1, `push <- ${e.data}`); if (!document.hidden) now(); };
    }

    // ---- moving between pages: splash-nav links, back and forward, the server's redirects ----
    const go = (url, back) => {
      const u = new URL(url, location.href);
      if (u.origin !== location.origin) { location.assign(u.href); return; }
      if (!back) history.pushState(null, "", u.href);
      send("nav").then(() => {
        if (back) return;
        const target = u.hash && document.getElementById(decodeURIComponent(u.hash.slice(1)));
        if (target) target.scrollIntoView(); else scrollTo(0, 0);
      });
    };
    addEventListener("popstate", () => { say(1, "back/forward to", location.pathname + location.search); go(location.href, true); });

    document.addEventListener("click", (e) => {
      const el = e.target.closest("[splash-click]");
      if (el) {
        e.preventDefault();
        if (busy(el)) { say(1, `click on ${where(el)} ignored: still waiting on the last one`); return; }
        send("event", params("click", scoped(el, el.getAttribute("splash-click")), el.getAttribute("splash-value") || ""), el);
        return;
      }
      // a link inside (or with) splash-nav, to this site, opened plainly, moves without a reload
      const a = e.target.closest("a[href]"), scope = a && a.closest("[splash-nav]");
      if (!scope || scope.getAttribute("splash-nav") === "off") return;
      if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
      if ((a.target && a.target !== "_self") || a.hasAttribute("download")) return;
      const u = new URL(a.href, location.href);
      if (u.origin !== location.origin) return;
      if (u.pathname === location.pathname && u.search === location.search && u.hash) return;  // an anchor on this page
      e.preventDefault();
      go(u.href);
    });
    document.addEventListener("submit", async (e) => {
      const f = e.target.closest("[splash-submit]");
      if (!f) return;
      e.preventDefault();
      if (busy(f)) { say(1, `submit of ${where(f)} ignored: still waiting on the last one`); return; }
      clearTimeout(typing.get(f));  // a validation still waiting is moot
      f.classList.add("splash-loading");  // busy while its files are read, too
      let body;
      try { body = await fields(f, "submit", scoped(f, f.getAttribute("splash-submit")), true); }
      catch (err) { f.classList.remove("splash-loading"); warn(`submit of ${where(f)}: couldn't read its files:`, err); return; }
      // cleared once the server took it: an answer marking a field invalid keeps what was typed
      send("event", body, f, (ok) => { if (ok && !f.querySelector('[aria-invalid="true"]')) f.reset(); });
    });
    const typing = new WeakMap();
    const later = (el, fn) => {
      clearTimeout(typing.get(el));
      typing.set(el, setTimeout(fn, +(el.getAttribute("splash-debounce") || 250)));
    };
    document.addEventListener("input", (e) => {
      const el = e.target.closest("[splash-input]");
      if (el) later(el, () => send("event", params("input", scoped(el, el.getAttribute("splash-input")), el.value)));
      const f = e.target.closest("form[splash-validate]");
      if (f) later(f, async () => send("event", await fields(f, "validate", scoped(f, f.getAttribute("splash-validate")), false)));
    });
    document.addEventListener("change", (e) => {
      const el = e.target.closest("[splash-change]");
      if (!el) return;
      const v = el.type === "checkbox" || el.type === "radio" ? (el.checked ? el.value || "on" : "") : el.value;
      send("event", params("change", scoped(el, el.getAttribute("splash-change")), v), el);
    });
    document.addEventListener("focusout", (e) => {
      const el = e.target.closest && e.target.closest("[splash-blur]");
      if (el && el.contains(e.target) && (el === e.target || !el.contains(e.relatedTarget))) {
        send("event", params("blur", scoped(el, el.getAttribute("splash-blur")), e.target.value ?? ""));
      }
    });
    document.addEventListener("keydown", (e) => {
      const el = e.target.closest && e.target.closest("[splash-keydown]");
      if (!el) return;
      const only = el.getAttribute("splash-keys");
      if (only && !only.split(/\s+/).includes(e.key)) return;
      if (only && e.key === "Enter") e.preventDefault();  // it's handled: don't also submit a form
      send("event", params("key", scoped(el, el.getAttribute("splash-keydown")), e.target.value ?? "", { key: e.key }));
    });

    // a session of its own: a random id in a cookie; without one yet, ask for this session's
    // view right away (the page shows a fresh one)
    let first = delay;
    if (!/(^|;\s*)splash-sid=/.test(document.cookie)) {
      const id = self.crypto && crypto.randomUUID ? crypto.randomUUID()
        : Array.from({ length: 4 }, () => Math.random().toString(36).slice(2)).join("-");
      document.cookie = "splash-sid=" + id + "; path=/; SameSite=Lax";
      say(1, "new session", id.slice(0, 8));
      hash = "";
      first = 0;
    }
    const sid = (document.cookie.match(/(?:^|;\s*)splash-sid=([^;]*)/) || [])[1] || "";
    say(1, `started: session ${sid.slice(0, 8)} (server logs say ${sid.slice(0, 8)}#n for this tab's request #n), log level ${Object.keys(levels)[level]}, ${push ? "push + polling every " + every / 1000 + " s" : "polling every " + every + " ms"}, view ${splashHash}`);
    timer = setTimeout(poll, first);
    // hooks mount once the page's own scripts (`with_script`, deferred) have run
    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", runHooks);
    else runHooks();
  })();
  </script>
  """

// ---- tests ----

fn req(method: str, headers: {str: str}, body: str): http.server.Req =
  http.server.Req { method, target: "/", path: "/", query: "", headers, body }

fn get(headers: {str: str}): http.server.Req = req("GET", headers, "")

fn post(body: str): http.server.Req = req("POST", {"x-splash": "event"}, body)

test "a page wraps the view in the live element and runs the client" {
  let p = render(titled("Home & away"), "<p>hi</p>")
  assert p.contains("<main id=\"splash\"><p>hi</p></main>")
  assert p.contains("<title>Home &amp; away</title>")
  assert p.contains("const splashEvery = 500, splashHash = \"{fingerprint(titled("Home & away"), "<p>hi</p>")}\", splashPush = false, splashLog = \"quiet\";")
  assert p.contains("<style id=\"splash-css\">{BASE_CSS}</style>")
  assert p.contains("[splash-click]") && p.contains("[splash-submit]")
}

test "with_every sets the interval" {
  assert render(titled("t").with_every(2000), "").contains("const splashEvery = 2000,")
}

test "is_poll, is_nav, event and is_visit tell the requests apart" {
  assert is_poll(get({"x-splash": "poll"}))
  assert !is_poll(get({}))
  assert is_visit(get({}))
  assert !is_visit(get({"x-splash": "poll"}))
  assert !is_visit(post("splash-kind=click&splash-event=inc&value="))
  assert is_nav(get({"x-splash": "nav"})) && is_visit(get({"x-splash": "nav"}))
  assert !is_nav(get({}))
}

test "a click" {
  assert event(post("splash-kind=click&splash-event=inc&value=5")) == some(Click("inc", "5"))
  assert event(post("splash-kind=click&splash-event=reset&value=")) == some(Click("reset", ""))
}

test "a submit, with its fields decoded" {
  let e = event(post("name=Ann+Lee&note=a%26b&splash-kind=submit&splash-event=sign"))
  assert e == some(Submit("sign", {"name": "Ann Lee", "note": "a&b"}))
}

test "typing, changes, validation, blur, keys and script events" {
  assert event(post("splash-kind=input&splash-event=search&value=du")) ==
    some(Input("search", "du"))
  assert event(post("splash-kind=change&splash-event=mood&value=")) == some(Change("mood", ""))
  assert event(post("email=a%40b&splash-kind=validate&splash-event=join")) ==
    some(Validate("join", {"email": "a@b"}))
  assert event(post("splash-kind=blur&splash-event=email&value=x")) == some(Blur("email", "x"))
  assert event(post("splash-kind=key&splash-event=todo&value=milk&key=Enter")) ==
    some(Key("todo", "Enter", "milk"))
  assert event(post("splash-kind=js&splash-event=zoom&value=3")) == some(Js("zoom", "3"))
}

test "form is what event reads back, for every kind of event" {
  for e in [
    Click("a b", "x&y"),
    Submit("sign", {"name": "Ann", "value": "v"}),
    Input("q", "ü"),
    Change("c", ""),
    Validate("v", {"email": "a@b"}),
    Blur("b", "1"),
    Key("k", "Escape", "t"),
    Js("j", "{{\"x\": 1}}"),
  ] {
    assert event(post(form(e))) == some(e)
  }
}

test "events from another site are rejected" {
  let body = "splash-kind=click&splash-event=like&value="
  let from = (origin: str) => req(
    "POST",
    {"x-splash": "event", "host": "localhost:8080", "origin": origin},
    body,
  )
  assert event(from("http://localhost:8080")) == some(Click("like", ""))
  assert event(from("https://localhost:8080")) == some(Click("like", ""))
  assert event(from("http://evil.example")) is none
  assert event(from("http://localhost:8080.evil.example")) is none
  assert event(from("null")) is none
  // and a cross-site form can't set the header at all
  assert event(
    req("POST", {"host": "localhost:8080", "origin": "http://localhost:8080"}, body),
  ) is none
}

test "no event: a GET, a plain POST, a POST without a name" {
  assert event(get({"x-splash": "event"})) is none
  assert event(req("POST", {}, "splash-kind=click&splash-event=inc")) is none
  assert event(post("splash-kind=click")) is none
}

test "answer: the page, or 204 for a refresh that would show the same view" {
  let v = "<b>x</b>"
  let p = titled("t")
  let r = answer(get({}), p, v)
  assert r.status == 200 && r.body.contains(v)
  let h = r.headers["x-splash-hash"]
  assert answer(get({"x-splash": "poll", "x-splash-hash": h}), p, v).status == 204
  assert answer(get({"x-splash": "poll", "x-splash-hash": h}), p, "<b>y</b>").status == 200
  assert answer(get({"x-splash": "poll", "x-splash-hash": ""}), p, v).status == 200
  // a move is never a 204, even to a page that looks the same
  assert answer(get({"x-splash": "nav", "x-splash-hash": h}), p, v).status == 200
}

test "splash's own requests get only the title and the view, plus the head when it changed" {
  let p = titled("Shop").with_css("b {{}}").with_link("/a.css")
  let visit = answer(get({}), p, "<b>x</b>")
  assert visit.body.contains("splashEvery") && visit.headers.get("x-splash-head") is none
  let h = visit.headers["x-splash-hash"]
  let ev = answer(
    req("POST", {"x-splash": "event", "x-splash-hash": h}, form(Click("go", ""))),
    p,
    "<b>y</b>",
  )
  assert ev.body == "<title>Shop</title><main id=\"splash\"><b>y</b></main>"
  assert ev.headers["x-splash-head"] == "same"
  let restyled = answer(
    get({"x-splash": "poll", "x-splash-hash": h}),
    p.with_css("i {{}}"),
    "<b>x</b>",
  )
  assert restyled.status == 200 && restyled.headers.get("x-splash-head") is none
  assert restyled.body ==
    "<title>Shop</title><link rel=\"stylesheet\" href=\"/a.css\" data-splash><style id=\"splash-css\">i {{}}</style><main id=\"splash\"><b>x</b></main>"
  assert visit.body.len() > 5 * ev.body.len() + 5000
}

test "a new title alone is a change (no 204)" {
  let h = answer(get({}), titled("one"), "v").headers["x-splash-hash"]
  let poll = get({"x-splash": "poll", "x-splash-hash": h})
  assert answer(poll, titled("one"), "v").status == 204
  let r = answer(poll, titled("two"), "v")
  assert r.status == 200 && r.body.starts_with("<title>two</title>")
}

test "with_css: your CSS in the head, live; \"\" for none" {
  let p = render(titled("t").with_css("h1 {{ color: red }}"), "<h1>x</h1>")
  assert p.contains("<style id=\"splash-css\">h1 {{ color: red }}</style>")
  assert !p.contains("system-ui")
  assert render(titled("t").with_css(""), "x").contains("<style id=\"splash-css\"></style>")
}

test "a CSS change alone is a change (no 204)" {
  let p = titled("t").with_css("a {{}}")
  let h = answer(get({}), p, "<b>x</b>").headers["x-splash-hash"]
  let poll = get({"x-splash": "poll", "x-splash-hash": h})
  assert answer(poll, p, "<b>x</b>").status == 204
  assert answer(poll, p.with_css("b {{}}"), "<b>x</b>").status == 200
}

test "a Page: title, css, links, scripts, interval" {
  let p = titled("Shop")
    .with_css("b {{}}")
    .with_link("/static/a.css?v=1")
    .with_link("https://x/b.css")
    .with_script("/static/hooks.js")
    .with_every(900)
  let h = render(p, "<p>v</p>")
  assert h.contains("<link rel=\"stylesheet\" href=\"/static/a.css?v=1\" data-splash><link rel=\"stylesheet\" href=\"https://x/b.css\" data-splash>")
  assert h.contains("<style id=\"splash-css\">b {{}}</style><script src=\"/static/hooks.js\" defer></script>")
  assert h.contains("const splashEvery = 900,")
  assert h.contains("<title>Shop</title>")
  // scripts aren't live: adding one isn't a change to the page
  assert fingerprint(p, "v") == fingerprint(p.with_script("/more.js"), "v")
}

test "a changed link is a change (no 204)" {
  let p = titled("t").with_link(asset("a.css", "one"))
  let h = answer(get({}), p, "v").headers["x-splash-hash"]
  let poll = get({"x-splash": "poll", "x-splash-hash": h})
  assert answer(poll, p, "v").status == 204
  assert answer(poll, titled("t").with_link(asset("a.css", "two")), "v").status == 200
}

test "redirect: the page moves for splash's requests, a 303 for others" {
  let r = redirect(post(form(Click("save", ""))), "/items/7")
  assert r.status == 200 && r.headers["x-splash-goto"] == "/items/7"
  let plain = redirect(get({}), "/items/7")
  assert plain.status == 303 && plain.headers["location"] == "/items/7"
}

test "flash rides along with any response" {
  let r = answer(post(form(Click("save", ""))), titled("t"), "v").flash("Saved ✓ & done")
  assert r.headers["x-splash-flash"] == "Saved%20%E2%9C%93%20%26%20done"
  assert r.status == 200 && r.headers.contains("x-splash-hash")
}

test "parts: events named by where they came from" {
  let e = Click("cart/add", "3")
  assert split(e) == some(("cart", Click("add", "3")))
  assert split(Click("add", "")) is none
  assert within(e, "cart") == some(Click("add", "3"))
  assert within(e, "search") is none
  assert within(Submit("list/7/edit", {"t": "x"}), "list") == some(Submit("7/edit", {"t": "x"}))
  assert event_name(Key("a/b", "Enter", "")) == "a/b"
  assert part("cart", "<b>2</b>") == "<div splash-part=\"cart\"><b>2</b></div>"
}

fn bump(n: int, Click("add", v)): int = n + (int.parse(v) else 1)
fn bump(_: int, Click("boom", _)): int {
  let xs: [int] = []
  xs[1]
}
fn bump(n: int, _: Event): int = n

fn boom_view(_: int): str {
  let xs: [str] = []
  xs[3]
}

struct Two { a: int, b: int }

test "parts: route updates only its own state, and a panic keeps it" {
  let up = (s: Two, e: Event) => Two { a: route(e, "a", s.a, bump), b: route(e, "b", s.b, bump) }
  let s = [Click("a/add", "2"), Click("b/add", ""), Click("a/add", "5"), Click("add", "9")]
    .reduce(Two { a: 0, b: 0 }, up)
  assert (s.a, s.b) == (7, 1)
  assert part("a", 4, n => "n={n}") == "<div splash-part=\"a\">n=4</div>"
  // (panics caught in a task of their own: its memory goes with it)
  let t = panicky_parts()
  assert await t
}

async fn panicky_parts(): bool =
  route(Click("a/boom", ""), "a", 4, bump) == 4 && part("a", 4, boom_view).contains("splash-error")

test "form errors" {
  let errs = {"email": "That's not an email <address>"}
  assert error_for(errs, "email") ==
    "<p class=\"splash-error\" id=\"email-error\">That&#39;s not an email &lt;address&gt;</p>"
  assert error_for(errs, "name") == ""
  assert invalid(errs, "email") == " aria-invalid=\"true\" aria-describedby=\"email-error\""
  assert invalid(errs, "name") == ""
}

test "uploads: a form's files, decoded" {
  let a = Upload { name: "a.png", mime: "image/png", bytes: [137, 80, 78, 71, 0, 255] }
  let b = Upload { name: "notes, v2.txt", mime: "", bytes: [] }
  let fields = attach({"title": "pics"}, "photo", [a, b])
  assert fields["photo"] == "a.png, notes, v2.txt"
  // through a real request body and back
  let got = event(post(form(Submit("up", fields)))) else return fail("no event")
  match got {
    Submit("up", fs) => {
      assert uploads(fs, "photo") == [a, b]
      assert upload(fs, "photo") == some(a)
      assert upload(fs, "other") is none
      assert fs["title"] == "pics"
    }
    _ => fail("not a submit")
  }
  assert uploads({"splash-file:photo:0": "x.png\nimage/png\n***"}, "photo") == []
  assert uploads({"splash-file:photo:0": "no newline"}, "photo") == []
}

fn files(name: str): str? = match name {
  "site.css" => some("body {{}}")
  "js/app.js" => some("go()")
  _ => none
}

fn at(path: str, query: str): http.server.Req =
  http.server.Req { method: "GET", target: path, path, query, headers: {}, body: "" }

test "static files: served, typed, cached when versioned" {
  let r = static(at("/static/site.css", "v=12"), files) else return fail("not served")
  assert r.status == 200 && r.body == "body {{}}"
  assert r.headers["content-type"] == "text/css; charset=utf-8"
  assert r.headers["cache-control"].contains("immutable")
  let j = static(at("/static/js/app.js", ""), files) else return fail("not served")
  assert j.headers["content-type"] == "text/javascript; charset=utf-8"
  assert j.headers["cache-control"] == "no-cache"
}

test "static files: 404, 403, and other paths are not static" {
  assert static(at("/static/nope.css", ""), files)?.status == some(404)
  for bad in [
    "/static/../secret",
    "/static//etc/passwd",
    "/static/a/../../x",
    "/static/",
    "/static/a\\b",
  ] {
    assert static(at(bad, ""), files)?.status == some(403)
  }
  assert static(at("/", ""), files) is none
  assert static(at("/staticfile", ""), files) is none
}

test "asset URLs change with the content" {
  assert asset("a.css", "x").starts_with("/static/a.css?v=")
  assert asset("a.css", "x") == asset("a.css", "x")
  assert asset("a.css", "x") != asset("a.css", "y")
}

test "session ids come from the cookie, and must look like one" {
  let with = (c: str) => req("GET", {"cookie": c}, "")
  assert session_id(with("a=1; splash-sid=0b1e5d2c-77aa-4f0e-9d1c-3f6a2b8e9c10; b=2")) ==
    some("0b1e5d2c-77aa-4f0e-9d1c-3f6a2b8e9c10")
  assert session_id(with("splash-sid=short")) is none
  assert session_id(with("splash-sid=<script>alert(1)</script>")) is none
  assert session_id(with("other=1")) is none
  assert session_id(get({})) is none
}

/// A counter per session, for the session tests.
fn tally_update(n: int, Click("add", _)): int = n + 1
fn tally_update(_: int, Click("boom", _)): int {
  let xs: [int] = []
  xs[1]
}
fn tally_update(n: int, _: Event): int = n

fn tally_view(n: int): str = "n={n}"

async fn tally_sessions(s: Sessions, max: int): ()! =
  run_sessions(s, () => 0, tally_update, tally_view, max)

fn as_session(sid: str, body: str): http.server.Req {
  let headers = if body == "" {
    {"cookie": "splash-sid={sid}"}
  } else {
    {"cookie": "splash-sid={sid}", "x-splash": "event"}
  }
  req(if body == "" { "GET" } else { "POST" }, headers, body)
}

let ADD = "splash-kind=click&splash-event=add&value="

test "each session has its own state; a panic resets only that one" {
  let s = sessions()
  let t = tally_sessions(s, 10)
  let (a, b) = ("aaaaaaaa-1", "bbbbbbbb-2")
  assert ask(s, as_session(a, ADD)) == "n=1"
  assert ask(s, as_session(a, ADD)) == "n=2"
  assert ask(s, as_session(b, ADD)) == "n=1"
  assert ask(s, as_session(a, "")) == "n=2"
  assert ask(s, get({})) == "n=0"
  assert ask(s, as_session(b, "splash-kind=click&splash-event=boom&value=")) == "n=0"
  assert ask(s, as_session(a, "")) == "n=2"
  s.ch.close()
  await t?
}

test "past max sessions, the least recently used one stops" {
  let s = sessions()
  let t = tally_sessions(s, 2)
  assert ask(s, as_session("first-111", ADD)) == "n=1"
  assert ask(s, as_session("second-22", ADD)) == "n=1"
  assert ask(s, as_session("first-111", ADD)) == "n=2"
  assert ask(s, as_session("third-333", ADD)) == "n=1"
  assert ask(s, as_session("first-111", "")) == "n=2"
  assert ask(s, as_session("second-22", "")) == "n=0"
  s.ch.close()
  await t?
}

test "play: a session's functions without a server" {
  assert play(() => 0, tally_update, tally_view, []) == "n=0"
  assert play(() => 0, tally_update, tally_view, [
    Click("add", ""),
    Click("x", ""),
    Click("add", ""),
  ]) ==
    "n=2"
}

/// A little site for the browser tests: a counter per session, a page per path, a redirect and
/// a flash.
fn site(s: Sessions, req: http.server.Req): http.Resp {
  match event(req) {
    some(Click("leave", _)) => return redirect(req, "/bye").flash("See you")
    _ => {}
  }
  let r = answer(req, titled("at {req.path}"), "<p>{req.path}</p>{ask(s, req)}")
  if event(req) == some(Click("add", "")) { r.flash("Added") } else { r }
}

test "a pretend browser: visits, events, refreshes, moves, redirects, flashes" {
  let s = sessions()
  let t = tally_sessions(s, 10)
  var b = browser(r => site(s, r))
  assert b.open("/") == "<p>/</p>n=0"
  assert b.title == "at /" && b.status == 200
  assert b.send(Click("add", "")) == "<p>/</p>n=1"
  assert b.flash == "Added"
  assert b.refresh() == "<p>/</p>n=1" && b.status == 204 && b.flash == ""
  assert b.go("/pond") == "<p>/pond</p>n=1"
  assert b.title == "at /pond" && b.url == "/pond"
  // another visitor has a session of their own
  var other = browser(r => site(s, r)).with_session("someone-else")
  assert other.open("/") == "<p>/</p>n=0"
  assert b.send(Click("leave", "")) == "<p>/bye</p>n=1"
  assert b.url == "/bye" && b.flash == ""
  s.ch.close()
  await t?
}

test "push: a hub's stream, and pages that know to listen" {
  let h = hub()
  let r = stream(get({}), h)
  assert r is none
  let s = stream(
    http.server.Req {
      method: "GET",
      target: "/?splash=events",
      path: "/",
      query: "splash=events",
      headers: {},
      body: "",
    },
    h,
  )
  match s {
    some(http.server.Stream(200, headers, _)) =>
      assert headers["content-type"] == "text/event-stream"
    _ => fail("no stream")
  }
  assert render(titled("t").with_hub(h), "v").contains("splashPush = true,")
  assert render(titled("t"), "v").contains("splashPush = false,")
}

async fn hub_task(h: Hub): ()! = run_hub(h)

test "the hub tells joined pages, and drops the ones that left" {
  let h = hub()
  let t = hub_task(h)
  let (a, b): (Chan<str>, Chan<str>) = (chan(), chan())
  h.ch.send(Join(a))
  h.ch.send(Join(b))
  changed(h)
  assert a.recv_for(2000) == some("data: change\n\n")
  assert b.recv_for(2000) == some("data: change\n\n")
  b.close()
  changed(h)
  assert a.recv_for(2000) == some("data: change\n\n")
  // an event answered on a page with the hub tells it too
  let _ = answer(post("splash-kind=click&splash-event=x&value="), titled("t").with_hub(h), "v")
  assert a.recv_for(2000) == some("data: change\n\n")
  t.cancel()
  let _ = await any [t]
}

test "log levels: by name, and handed to the page's script" {
  assert log_level("debug") == Debug
  assert log_level(" Info ") == Info
  assert log_level("") == Quiet
  assert log_level("loud") == Quiet
  assert render(titled("t").with_log(Debug), "v").contains("splashLog = \"debug\";")
  assert render(titled("t"), "v").contains("splashLog = \"quiet\";")
  assert hub().with_log(Info).log == Info
  assert sessions().with_log(Debug).log == Debug
}

test "escape" {
  assert escape("<a href=\"x\">Tom & Jerry's</a>") ==
    "&lt;a href=&quot;x&quot;&gt;Tom &amp; Jerry&#39;s&lt;/a&gt;"
  assert escape("plain") == "plain"
}
