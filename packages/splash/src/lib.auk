/// Live pages, LiveView-style: the server renders a view to HTML, and the page keeps itself
/// current. Its script re-fetches the page in the background and patches the view in place when
/// it changed, so new state, other visitors' actions and (under `auk run --live`) saved code all
/// show up in open tabs within a moment: no reload, no flash, focus, typing and scroll intact.
/// Buttons, forms and inputs send events (`splash-click`, `splash-submit`, `splash-input`,
/// `splash-change`) that the server handles, and the answer patches the page at once; the element
/// has the class `splash-loading` until it does.
///
/// Events can't be forged by other sites: each one must carry the `x-splash` header, which a
/// cross-site form can't set and a cross-site `fetch` can't send without a CORS preflight this
/// server never grants; `event` also rejects any `Origin` that isn't this host.
///
/// Pages poll (`every` ms). With a `Hub` (`with_hub`, served by `http.server.serve_live`) they also
/// listen on a Server-Sent Events stream: every event, `changed(hub)` and `auk run --live`
/// reload tells all open pages to fetch at once, and polling slows to a fallback.

/// The header splash's own requests carry: `poll` (a refresh) or `event` (a click or submit).
pub let HEADER = "x-splash"

/// How often an open page asks for a fresh view, by default (ms).
pub let EVERY = 500

/// The default stylesheet of `page`, `reply` and `serve`: readable type, a centered column, plain
/// buttons and inputs, light and dark, and a "reconnecting…" badge while the server is away. Build
/// on it with `styled(title, splash.BASE_CSS + mine, view)`, or replace it.
pub let BASE_CSS = r"""
  :root { color-scheme: light dark; }
  body { margin: 0; font: 18px/1.5 system-ui, sans-serif; }
  #splash { max-width: 42rem; margin: 0 auto; padding: 2rem 1rem; }
  button, input, select, textarea { font: inherit; }
  button { padding: .3em .9em; border: 1px solid #8886; border-radius: .5em; background: #8881; cursor: pointer; }
  button:hover { background: #8883; }
  input, select, textarea { padding: .3em .5em; border: 1px solid #8886; border-radius: .5em; }
  a { color: inherit; }
  .splash-loading { opacity: .6; cursor: progress; }
  .splash-offline body::after { content: "reconnecting…"; position: fixed; right: 1rem; bottom: 1rem; padding: .3em .9em; border-radius: 1em; background: #333; color: #fff; font-size: .8em; }
  """

/// Something the user did on a page.
/// - `Click(name, value)`: an element with `splash-click="name"` (and `splash-value="..."`,
///   or "") was clicked.
/// - `Submit(name, fields)`: a form with `splash-submit="name"` was submitted, with its fields.
/// - `Input(name, value)`: the user typed in a field with `splash-input="name"`; sent once
///   typing pauses for 250 ms (`splash-debounce="ms"` to change it), with the field's text.
/// - `Change(name, value)`: a field with `splash-change="name"` changed (a select, a checkbox:
///   its value when checked, "" when not).
pub enum Event {
  Click(name: str, value: str),
  Submit(name: str, fields: {str: str}),
  Input(name: str, value: str),
  Change(name: str, value: str),
}

/// Is `req` an open page asking for a fresh view? Don't count it as a visit, and don't do a
/// visit's side effects for it.
pub fn is_poll(req: http.server.Req): bool = req.headers.get(HEADER) == some("poll")

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
    some("input") => Input(name, value)
    some("change") => Change(name, value)
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

/// Is `req` a visit: not a refresh, not an event?
pub fn is_visit(req: http.server.Req): bool = !is_poll(req) && event(req) is none

/// How a page looks, apart from its view: its title, its stylesheet (in `<head>`), the
/// stylesheets it links, and how often it refreshes. Build one with `titled` and the `with_*`
/// functions: `splash.titled("my site").with_css(CSS).with_link(splash.asset("site.css", text))`.
pub struct Page { title: str, css: str, links: [str], every: int, hub: Hub?, log: Log }

/// A page titled `title`, styled with `BASE_CSS`, linking nothing, refreshing every `EVERY` ms.
pub fn titled(title: str): Page =
  Page { title, css: BASE_CSS, links: [], every: EVERY, hub: none, log: Quiet }

/// The same page with the stylesheet `css` instead (`BASE_CSS + mine` to build on the defaults,
/// "" for none). It is live: change it, and open pages restyle at their next refresh.
pub fn with_css(p: Page, css: str): Page = Page { css, ..p }

/// The same page, also linking the stylesheet at `href` (`<link rel="stylesheet">`, after the
/// others). Links are live too: add, drop or re-version one, and open pages follow.
pub fn with_link(p: Page, href: str): Page = Page { links: p.links + [href], ..p }

/// The same page, refreshing every `every` ms.
pub fn with_every(p: Page, every: int): Page = Page { every, ..p }

/// The same page, pushed to by `hub`: open pages listen on its stream (answer it with `stream`),
/// and answering an event tells them all to fetch at once.
pub fn with_hub(p: Page, hub: Hub): Page = Page { hub: some(hub), ..p }

/// The same page, logging at `level`: on the server (stderr) every answer it makes, and in the
/// browser's console everything the page sends and receives (a visitor can raise their own
/// page's level with `splash.log("debug")` in the console).
pub fn with_log(p: Page, level: Log): Page = Page { log: level, ..p }

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

/// The answer to any request for a live page `p` showing `view`: the whole page for a visit or an
/// event, and for a refresh either the page or, when nothing on it changed since the page last
/// saw it, a bare 204 (an idle tab costs a few bytes per poll).
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
  let what = match ev {
    some(e) => "event {e}"
    none => if is_poll(req) { "refresh" } else { "visit" }
  }
  if is_poll(req) && had == h {
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
  http.Resp {
    status: 200,
    headers: {"content-type": "text/html; charset=utf-8", "x-splash-hash": h},
    body: render(p, view),
  }
}

/// The whole HTML of page `p` showing `view`.
pub fn render(p: Page, view: str): str {
  let links = p.links.map(
    l => "<link rel=\"stylesheet\" href=\"{escape(l)}\" data-splash>",
  ).join("")
  """
  <!doctype html>
  <html>
  <head>
  <meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>{escape(p.title)}</title>
  {links}<style id="splash-css">{p.css}</style>
  </head>
  <body>
  <main id="splash">{view}</main>
  {boot(p.every, fingerprint(p, view), p.hub is some(_), p.log)}
  </body>
  </html>
  """
}

/// `answer` for a page titled `title`, styled with `BASE_CSS`.
pub fn reply(req: http.server.Req, title: str, view: str): http.Resp =
  answer(req, titled(title), view)

/// `reply` with your own stylesheet `css`.
pub fn reply_styled(req: http.server.Req, title: str, css: str, view: str): http.Resp =
  answer(req, titled(title).with_css(css), view)

/// A 200 response with `page(title, view)`.
pub fn respond(title: str, view: str): http.Resp = answer(no_poll(), titled(title), view)

/// Serves live pages on `port` (every interface) forever: `view(req)` renders each one (its
/// HTML; handle `event(req)` in it), and `title` names them.
pub async fn serve(port: int, title: str, view: (http.server.Req) => str): ()! uses net {
  await http.server.serve("", port, req => reply(req, title, view(req)))
}

/// A whole HTML page showing `view` (HTML), titled `title`, that keeps itself current. Styled
/// with `BASE_CSS`.
pub fn page(title: str, view: str): str = render(titled(title), view)

/// `page`, asking for a fresh view every `every` ms.
pub fn page_every(title: str, view: str, every: int): str =
  render(titled(title).with_every(every), view)

/// `page` with the stylesheet `css` (in `<head>`, as `<style id="splash-css">`; "" for none).
pub fn styled(title: str, css: str, view: str): str = render(titled(title).with_css(css), view)

/// `styled`, asking for a fresh view every `every` ms.
pub fn styled_every(title: str, css: str, view: str, every: int): str =
  render(titled(title).with_css(css).with_every(every), view)

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

/// What a page reports to say what it shows (its view, stylesheet and links).
fn fingerprint(p: Page, view: str): str =
  "{short_hash(p.css + p.links.join("\n"))}-{short_hash(view)}"

/// A request that is not a refresh (for `respond`).
fn no_poll(): http.server.Req =
  http.server.Req { method: "GET", target: "/", path: "/", query: "", headers: {}, body: "" }

fn boot(every: int, h: str, push: bool, log: Log): str = "<script>const splashEvery = {every}, splashHash = \"{h}\", splashPush = {push}, splashLog = \"{name(log)}\";</script>" +
  CLIENT

/// The client. Polls with `setTimeout` (paused while the tab is hidden, backing off to 5 s while
/// the server is unreachable, when `<html>` gets the class `splash-offline`); sends clicks and
/// submits as form-encoded POSTs; patches `#splash` node by node (`morph`), so an input being
/// typed in keeps its focus, cursor and text.
let CLIENT = r"""
  <script>
  (() => {
    // ---- logging: `splash.log("debug" | "info" | "quiet")` in the console (remembered) ----
    const levels = { quiet: 0, info: 1, debug: 2 };
    const stored = () => { try { return localStorage.getItem("splash-log"); } catch (e) { return null; } };
    let level = levels[stored() || splashLog] ?? 0;
    const say = (min, ...args) => { if (level >= min) console.log("[splash]", ...args); };
    const warn = (...args) => console.warn("[splash]", ...args);
    self.splash = {
      log(l) {
        try { localStorage.setItem("splash-log", l); } catch (e) {}
        level = levels[l] ?? 0;
        console.info("[splash] log level:", l, "(levels: quiet, info, debug)");
      },
    };
    // a short readable path to an element, for logs: main#splash > ul > li[splash-key=3]
    const where = (n) => {
      const parts = [];
      for (let e = n.nodeType === 1 ? n : n.parentElement; e && e.id !== "splash"; e = e.parentElement) {
        const k = e.getAttribute("splash-key"), ev = ["splash-click", "splash-change", "splash-input", "splash-submit"].find((x) => e.hasAttribute(x));
        parts.unshift(e.tagName.toLowerCase() + (e.id ? "#" + e.id : "") + (k !== null ? `[splash-key=${k}]` : "") + (ev ? `[${ev}=${e.getAttribute(ev)}]` : ""));
      }
      return ["#splash", ...parts].join(" > ") + (n.nodeType === 3 ? " (text)" : "");
    };
    const decode = (body) => body ? Object.fromEntries(new URLSearchParams(body)) : undefined;

    // with push, polling is only a fallback (in case the stream is down)
    // (a browser without EventSource keeps polling at the normal rate)
    const push = splashPush && !!self.EventSource;
    const every = push ? Math.max(splashEvery, 5000) : splashEvery;
    let hash = splashHash, delay = every, timer, sent = 0, shown = 0, lastEvent = 0, offline = false;
    const root = document.documentElement;
    let changes = null;  // what the current patch changed (for logs)
    const note = (what) => { if (changes) changes.push(what); };
    const morph = (a, b) => {
      if (a.nodeType !== b.nodeType || a.nodeName !== b.nodeName) { note(`replaced ${where(a)}`); a.replaceWith(b.cloneNode(true)); return; }
      if (a.nodeType === 3 || a.nodeType === 8) {
        if (a.nodeValue !== b.nodeValue) { note(`text ${where(a)}: ${JSON.stringify(a.nodeValue)} -> ${JSON.stringify(b.nodeValue)}`); a.nodeValue = b.nodeValue; }
        return;
      }
      if (a.nodeType !== 1) return;
      for (const { name } of [...a.attributes]) if (!b.hasAttribute(name)) { note(`removed ${name} on ${where(a)}`); a.removeAttribute(name); }
      for (const { name, value } of [...b.attributes]) if (a.getAttribute(name) !== value) { note(`set ${name}=${JSON.stringify(value)} on ${where(a)}`); a.setAttribute(name, value); }
      // children: keyed ones (`splash-key`, or `id`) are matched by key, wherever they moved;
      // the rest by position
      const keyed = new Map();
      for (const c of a.childNodes) { const k = key(c); if (k !== null) keyed.set(k, c); }
      let i = 0;
      for (const n of [...b.childNodes]) {
        const cur = a.childNodes[i] || null, k = key(n);
        const match = k !== null ? keyed.get(k) : (cur && key(cur) === null ? cur : null);
        if (k !== null) keyed.delete(k);
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
    const key = (n) => n.nodeType === 1 ? n.getAttribute("splash-key") ?? (n.id || null) : null;
    // the first place two trees differ, for the self-check's warning
    const differ = (a, b) => {
      if (a.nodeType !== b.nodeType || a.nodeName !== b.nodeName) return `${where(a)}: <${a.nodeName}> where the server has <${b.nodeName}>`;
      if (a.nodeType === 3 && a.nodeValue !== b.nodeValue) return `${where(a)}: ${JSON.stringify(a.nodeValue)} where the server has ${JSON.stringify(b.nodeValue)}`;
      if (a.nodeType === 1) {
        for (const { name, value } of [...b.attributes]) if (a.getAttribute(name) !== value) return `${where(a)}: ${name}=${JSON.stringify(a.getAttribute(name))} where the server has ${JSON.stringify(value)}`;
        for (const { name } of [...a.attributes]) if (!b.hasAttribute(name)) return `${where(a)}: extra attribute ${name}`;
        if (a.childNodes.length !== b.childNodes.length) return `${where(a)}: ${a.childNodes.length} children where the server has ${b.childNodes.length}`;
        for (let i = 0; i < a.childNodes.length; i++) { const d = differ(a.childNodes[i], b.childNodes[i]); if (d) return d; }
      }
      return null;
    };

    // `el`: the element that sent an event, marked `splash-loading` until the answer is in
    const send = async (kind, body, el) => {
      const my = ++sent, t0 = performance.now();
      if (kind === "event") lastEvent = my;
      const headers = { "x-splash": kind, "x-splash-hash": hash, "x-splash-seq": String(my) };
      if (body) headers["content-type"] = "application/x-www-form-urlencoded";
      say(kind === "poll" ? 2 : 1, `#${my} -> ${kind}`, ...(body ? [decode(body)] : []), `(page shows ${hash || "nothing yet"})`);
      if (el) { el.classList.add("splash-loading"); el.setAttribute("aria-busy", "true"); }
      try {
        const r = await fetch(location.href, { method: body ? "POST" : "GET", headers, body });
        if (offline) { offline = false; say(1, "server reachable again"); }
        root.classList.remove("splash-offline");
        delay = every;
        const ms = Math.round(performance.now() - t0);
        // a later request's answer is already on the page, or this one was sent before the
        // latest event and shows the state from before it
        if (my < shown || my < lastEvent) {
          say(1, `#${my} <- ${r.status} in ${ms} ms: dropped, ` + (my < shown ? `a newer answer (#${shown}) is on the page` : `sent before event #${lastEvent}, so it shows the state from before it`));
          return;
        }
        shown = my;
        if (r.status === 204) { say(2, `#${my} <- 204 in ${ms} ms: unchanged`); return; }
        const doc = new DOMParser().parseFromString(await r.text(), "text/html");
        const now = document.getElementById("splash"), next = doc.getElementById("splash");
        const newHash = r.headers.get("x-splash-hash") || "";
        if (now && next) {
          changes = [];
          morph(now, next);
          const done = changes; changes = null;
          if (done.length) say(1, `#${my} <- ${r.status} in ${ms} ms: view ${newHash}, ${done.length} change(s)`, level >= 2 ? done : "");
          else say(2, `#${my} <- ${r.status} in ${ms} ms: view ${newHash}, nothing to change`);
          // self-check: the page must now match the server's view; if not, say where, and heal
          // by taking the server's version whole
          const live = document.getElementById("splash");
          if (!live.isEqualNode(next)) {
            warn(`#${my}: after patching, the page doesn't match the server's view: ${differ(live, next)}. Replacing it whole. (Please report this: it's a splash bug.)`);
            live.replaceWith(document.importNode(next, true));
          }
          hash = newHash;
        }
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
      } catch (e) {
        root.classList.add("splash-offline");
        delay = Math.min(delay * 2, 5000);
        if (!offline) { offline = true; say(1, `#${my}: server unreachable (${e.message || e}); retrying every ${delay / 1000} s or less`); }
        else say(2, `#${my}: still unreachable; next try in ${delay} ms`);
      } finally {
        if (el) { el.classList.remove("splash-loading"); el.removeAttribute("aria-busy"); }
      }
    };
    const params = (kind, name, value) => new URLSearchParams({ "splash-kind": kind, "splash-event": name, value }).toString();
    const busy = (el) => el.classList.contains("splash-loading");
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
    document.addEventListener("click", (e) => {
      const el = e.target.closest("[splash-click]");
      if (!el) return;
      e.preventDefault();
      if (busy(el)) { say(1, `click on ${where(el)} ignored: still waiting on the last one`); return; }
      send("event", params("click", el.getAttribute("splash-click"), el.getAttribute("splash-value") || ""), el);
    });
    document.addEventListener("submit", (e) => {
      const f = e.target.closest("[splash-submit]");
      if (!f) return;
      e.preventDefault();
      if (busy(f)) { say(1, `submit of ${where(f)} ignored: still waiting on the last one`); return; }
      const p = new URLSearchParams(new FormData(f));
      p.set("splash-kind", "submit");
      p.set("splash-event", f.getAttribute("splash-submit"));
      send("event", p.toString(), f);
      f.reset();
    });
    const typing = new WeakMap();
    document.addEventListener("input", (e) => {
      const el = e.target.closest("[splash-input]");
      if (!el) return;
      clearTimeout(typing.get(el));
      typing.set(el, setTimeout(() => send("event", params("input", el.getAttribute("splash-input"), el.value)),
        +(el.getAttribute("splash-debounce") || 250)));
    });
    document.addEventListener("change", (e) => {
      const el = e.target.closest("[splash-change]");
      if (!el) return;
      const v = el.type === "checkbox" || el.type === "radio" ? (el.checked ? el.value || "on" : "") : el.value;
      send("event", params("change", el.getAttribute("splash-change"), v), el);
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
  })();
  </script>
  """

// ---- tests ----

fn req(method: str, headers: {str: str}, body: str): http.server.Req =
  http.server.Req { method, target: "/", path: "/", query: "", headers, body }

fn get(headers: {str: str}): http.server.Req = req("GET", headers, "")

fn post(body: str): http.server.Req = req("POST", {"x-splash": "event"}, body)

test "a page wraps the view in the live element and runs the client" {
  let p = page("Home & away", "<p>hi</p>")
  assert p.contains("<main id=\"splash\"><p>hi</p></main>")
  assert p.contains("<title>Home &amp; away</title>")
  assert p.contains("const splashEvery = 500, splashHash = \"{fingerprint(titled("x"), "<p>hi</p>")}\", splashPush = false, splashLog = \"quiet\";")
  assert p.contains("<style id=\"splash-css\">{BASE_CSS}</style>")
  assert p.contains("[splash-click]") && p.contains("[splash-submit]")
}

test "page_every sets the interval" {
  assert page_every("t", "", 2000).contains("const splashEvery = 2000,")
}

test "is_poll, event and is_visit tell the requests apart" {
  assert is_poll(get({"x-splash": "poll"}))
  assert !is_poll(get({}))
  assert is_visit(get({}))
  assert !is_visit(get({"x-splash": "poll"}))
  assert !is_visit(post("splash-kind=click&splash-event=inc&value="))
}

test "a click" {
  assert event(post("splash-kind=click&splash-event=inc&value=5")) == some(Click("inc", "5"))
  assert event(post("splash-kind=click&splash-event=reset&value=")) == some(Click("reset", ""))
}

test "a submit, with its fields decoded" {
  let e = event(post("name=Ann+Lee&note=a%26b&splash-kind=submit&splash-event=sign"))
  assert e == some(Submit("sign", {"name": "Ann Lee", "note": "a&b"}))
}

test "typing and changes" {
  assert event(post("splash-kind=input&splash-event=search&value=du")) ==
    some(Input("search", "du"))
  assert event(post("splash-kind=change&splash-event=mood&value=")) == some(Change("mood", ""))
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

test "reply: the page, or 204 for a refresh that would show the same view" {
  let v = "<b>x</b>"
  let r = reply(get({}), "t", v)
  assert r.status == 200 && r.body.contains(v)
  let h = r.headers["x-splash-hash"]
  assert reply(get({"x-splash": "poll", "x-splash-hash": h}), "t", v).status == 204
  assert reply(get({"x-splash": "poll", "x-splash-hash": h}), "t", "<b>y</b>").status == 200
  assert reply(get({"x-splash": "poll", "x-splash-hash": ""}), "t", v).status == 200
}

test "styled: your CSS in the head, live; \"\" for none" {
  let p = styled("t", "h1 {{ color: red }}", "<h1>x</h1>")
  assert p.contains("<style id=\"splash-css\">h1 {{ color: red }}</style>")
  assert !p.contains("system-ui")
  assert styled("t", "", "x").contains("<style id=\"splash-css\"></style>")
}

test "reply: a CSS change alone is a change (no 204)" {
  let r = reply_styled(get({}), "t", "a {{}}", "<b>x</b>")
  let h = r.headers["x-splash-hash"]
  let poll = get({"x-splash": "poll", "x-splash-hash": h})
  assert reply_styled(poll, "t", "a {{}}", "<b>x</b>").status == 204
  assert reply_styled(poll, "t", "b {{}}", "<b>x</b>").status == 200
}

test "a Page: title, css, links, interval" {
  let p = titled("Shop")
    .with_css("b {{}}")
    .with_link("/static/a.css?v=1")
    .with_link("https://x/b.css")
    .with_every(900)
  let h = render(p, "<p>v</p>")
  assert h.contains("<link rel=\"stylesheet\" href=\"/static/a.css?v=1\" data-splash><link rel=\"stylesheet\" href=\"https://x/b.css\" data-splash>")
  assert h.contains("<style id=\"splash-css\">b {{}}</style>")
  assert h.contains("const splashEvery = 900,")
  assert h.contains("<title>Shop</title>")
}

test "a changed link is a change (no 204)" {
  let p = titled("t").with_link(asset("a.css", "one"))
  let h = answer(get({}), p, "v").headers["x-splash-hash"]
  let poll = get({"x-splash": "poll", "x-splash-hash": h})
  assert answer(poll, p, "v").status == 204
  assert answer(poll, titled("t").with_link(asset("a.css", "two")), "v").status == 200
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

test "respond is a 200 HTML page" {
  let r = respond("t", "<b>x</b>")
  assert r.status == 200
  assert r.headers["content-type"] == "text/html; charset=utf-8"
  assert r.body.contains("<b>x</b>")
}

test "escape" {
  assert escape("<a href=\"x\">Tom & Jerry's</a>") ==
    "&lt;a href=&quot;x&quot;&gt;Tom &amp; Jerry&#39;s&lt;/a&gt;"
  assert escape("plain") == "plain"
}
