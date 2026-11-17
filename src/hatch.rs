//! `duck hatch <file> [--hole N] [--tries 3] [--dry-run]`: fill `??` holes with an AI model.
//!
//! For each hole (see holes.rs for discovery and numbering), in order:
//! 1. build a prompt: the language reference (`duck spec`), the file the hole is in, the hole's
//!    brief (`duck holes`), and the instruction to reply with only the code that replaces `??`
//!    in a fenced block;
//! 2. run the model command, `DUCK_HATCH_CMD` (default `claude -p`, run by `sh -c`), with the
//!    prompt on stdin, and take the code from the first ```` ```duck ```` (or plain ```` ``` ````)
//!    fence of its stdout, or the whole reply;
//! 3. splice it in place of the hole (a `{ ?? }` block becomes a multi-line block) and type-check
//!    the program in memory (`resolve::with_sources`); on errors, ask again with the answer and the
//!    diagnostics as `duck check --json` JSON;
//! 4. when it checks, build the test binary (contracts on: `ensures` is checked in test builds;
//!    execution tracing on) and run the tests that call the function; on failures, ask again with
//!    their output and the last `TRACE_TAIL` events of each failing test's execution trace (the
//!    calls with their arguments and results, errors, peeks and the panic: see build.rs);
//! 5. up to `--tries` answers per hole. A filled hole stays filled while the next holes are found
//!    again (positions shift); a hole that couldn't be filled is left as it was.
//!
//! At the end every changed file is formatted (`duck fmt`) and written, or with `--dry-run`
//! printed as a unified diff. A summary line per hole says whether it was filled.

use std::collections::{BTreeMap, HashMap};
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;
use std::{env, fs, thread};

use super::diag::FileDiag;
use super::holes::{self, Hole};
use super::resolve::with_sources;

/// The model command when `DUCK_HATCH_CMD` is unset.
const DEFAULT_CMD: &str = "claude -p";

/// How long one test run may take before it is killed (an answer may loop forever).
const TEST_TIMEOUT: Duration = Duration::from_secs(60);

/// How many trailing trace events of a failing test go into the retry prompt.
const TRACE_TAIL: &str = "12";

struct Opts {
    file: String,
    hole: Option<usize>,
    tries: usize,
    dry_run: bool,
}

fn parse_args(args: &[String]) -> Result<Opts, String> {
    let mut o = Opts { file: String::new(), hole: None, tries: 3, dry_run: false };
    let mut it = args.iter();
    while let Some(a) = it.next() {
        let mut num = |what: &str| -> Result<usize, String> {
            it.next().and_then(|v| v.parse::<usize>().ok()).filter(|&n| n > 0).ok_or_else(|| format!("{what} needs a positive number"))
        };
        match a.as_str() {
            "--hole" => o.hole = Some(num("--hole")?),
            "--tries" => o.tries = num("--tries")?,
            "--dry-run" => o.dry_run = true,
            f if !f.starts_with("--") && o.file.is_empty() => o.file = f.to_string(),
            _ => return Err(format!("unexpected argument `{a}`")),
        }
    }
    if o.file.is_empty() {
        return Err("missing <file>".into());
    }
    Ok(o)
}

/// `duck hatch`. Returns the exit code: 0 when every hole it worked on was filled.
pub fn run(args: &[String]) -> i32 {
    let o = match parse_args(args) {
        Ok(o) => o,
        Err(e) => {
            eprintln!("error: {e}\nusage: duck hatch <file> [--hole N] [--tries 3] [--dry-run]");
            return 2;
        }
    };
    let root = PathBuf::from(&o.file);
    // the current text of every file changed so far (on top of the files on disk)
    let mut srcs: HashMap<String, String> = HashMap::new();
    let holes = match analyze(&root, &srcs) {
        Ok(h) => h,
        Err(()) => return 1,
    };
    if holes.is_empty() {
        println!("no holes in {}", o.file);
        return 0;
    }
    if let Some(n) = o.hole
        && n > holes.len()
    {
        eprintln!("error: there is no hole {n} ({} has {} hole(s); see `duck holes {}`)", o.file, holes.len(), o.file);
        return 2;
    }
    let originals: BTreeMap<String, String> =
        holes.iter().map(|h| h.file.clone()).map(|f| (f.clone(), fs::read_to_string(&f).unwrap_or_default())).collect();
    let cmd = env::var("DUCK_HATCH_CMD").ok().filter(|c| !c.trim().is_empty()).unwrap_or_else(|| DEFAULT_CMD.to_string());
    let total = holes.len();
    // the original numbers of the holes still to do; unfilled holes stay in the list, so the
    // next one to do is at index `skip` after a fresh discovery
    let todo: Vec<usize> = match o.hole {
        Some(n) => vec![n],
        None => (1..=total).collect(),
    };
    let mut skip = o.hole.map_or(0, |n| n - 1);
    let mut summary = Vec::new();
    let mut all_ok = true;
    for number in todo {
        let holes = match analyze(&root, &srcs) {
            Ok(h) => h,
            Err(()) => return 1,
        };
        let Some(h) = holes.get(skip) else { break };
        let label = format!("hole {number} ({}, {}:{})", h.context, h.file, h.span.line);
        eprintln!("hatching {label}");
        let r = fill(&root, h, &mut srcs, &cmd, o.tries);
        match r {
            Ok(n) => summary.push(format!("{label}: filled after {n} {}", if n == 1 { "try" } else { "tries" })),
            Err(last) => {
                all_ok = false;
                skip += 1;
                let last = last.trim_end().replace('\n', "\n    ");
                summary.push(format!("{label}: failed after {} {}\n  last error:\n    {last}", o.tries, if o.tries == 1 { "try" } else { "tries" }));
            }
        }
    }
    // format and write (or show) every changed file
    for (file, before) in &originals {
        let Some(after) = srcs.get(file) else { continue };
        let after = super::fmt::format(after).unwrap_or_else(|_| after.clone());
        if o.dry_run {
            print!("{}", diff(file, before, &after));
        } else if let Err(e) = fs::write(file, &after) {
            eprintln!("error: cannot write {file}: {e}");
            all_ok = false;
        }
    }
    for s in &summary {
        println!("{s}");
    }
    if o.dry_run && !srcs.is_empty() {
        println!("(dry run: no files were changed)");
    }
    i32::from(!all_ok)
}

/// Discover the holes of the program as it is now. Errors (the program doesn't type-check even
/// with its holes) are printed.
fn analyze(root: &Path, srcs: &HashMap<String, String>) -> Result<Vec<Hole>, ()> {
    match with_sources(srcs, || holes::analyze(root)) {
        Ok((hs, diags)) if diags.iter().all(|d| d.diag.is_warning()) => Ok(hs),
        Ok((_, diags)) | Err(diags) => {
            eprintln!("error: the program must type-check (holes are allowed) before hatching:");
            with_sources(srcs, || holes::print_diags(&diags));
            Err(())
        }
    }
}

/// Fill one hole: ask, splice, check, test, retry. On success `srcs` has the filled file and
/// the number of tries is returned; otherwise the last error.
fn fill(root: &Path, h: &Hole, srcs: &mut HashMap<String, String>, cmd: &str, tries: usize) -> Result<usize, String> {
    let current = match srcs.get(&h.file) {
        Some(s) => s.clone(),
        None => fs::read_to_string(&h.file).map_err(|e| format!("cannot read {}: {e}", h.file))?,
    };
    let base = prompt(h, &current);
    let mut feedback = String::new();
    let mut last = String::from("no answer");
    for attempt in 1..=tries {
        eprintln!("  try {attempt}/{tries}");
        let reply = match ask(cmd, &format!("{base}{feedback}")) {
            Ok(r) => r,
            Err(e) => {
                last = e;
                continue;
            }
        };
        let code = extract_code(&reply);
        if code.trim().is_empty() {
            last = "the model's answer had no code".into();
            feedback = retry_note(&code, "was empty. Reply with the Duck code that replaces `??`.");
            continue;
        }
        let new_src = splice(&current, h, &code);
        let mut cand = srcs.clone();
        cand.insert(h.file.clone(), new_src);
        // 1. it type-checks, and the hole is gone
        let diags: Vec<FileDiag> = with_sources(&cand, || match super::resolve::load(root) {
            Ok(p) => super::check::check_all(p).1,
            Err(ds) => ds,
        });
        let errors: Vec<FileDiag> = diags.into_iter().filter(|d| !d.diag.is_warning()).collect();
        if !errors.is_empty() {
            let json = super::diag::json_report_files(&h.file, &errors);
            last = with_sources(&cand, || {
                errors.iter().map(|d| d.diag.render(&d.file, &super::resolve::source_of(&d.file).unwrap_or_default())).collect::<String>()
            });
            feedback = retry_note(
                &code,
                &format!(
                    "did not type-check. Fix these errors (`duck check --json` diagnostics; positions are in the file with your answer spliced in):\n{json}"
                ),
            );
            continue;
        }
        if code.contains("??") {
            last = "the answer still contains a `??` hole".into();
            feedback = retry_note(&code, "still contains a `??` hole. Write the complete code, without holes.");
            continue;
        }
        // 2. the tests that call the function pass (with contracts checked)
        if !h.tests.is_empty() {
            let names: Vec<&str> = h.tests.iter().map(|t| t.name.as_str()).collect();
            if let Err(out) = with_sources(&cand, || run_tests(root, &names)) {
                last = out.clone();
                feedback = retry_note(
                    &code,
                    &format!(
                        "type-checks, but these tests failed. Each failure shows the test's output, then its execution trace: \
                         the last events before it ended, oldest first, as JSON lines (`call` with the arguments, `ret` with the \
                         value or `err` with the error, `peek`, `panic`; `depth` is the call nesting). Use the trace to see what \
                         your code actually did, then fix it:\n{out}"
                    ),
                );
                continue;
            }
        }
        *srcs = cand;
        return Ok(attempt);
    }
    Err(last)
}

fn retry_note(code: &str, what: &str) -> String {
    format!("\n\n## Your previous answer\n```duck\n{code}\n```\nIt {what}\n\nReply again with ONLY the corrected Duck code that replaces `??`, in one ```duck fenced block.\n")
}

/// The prompt for one hole (feedback from earlier tries is appended to it).
pub fn prompt(h: &Hole, file_src: &str) -> String {
    let what = if h.body.is_some() {
        "the statements of the block body `{ ?? }` (without the surrounding braces; the last expression is the value)"
    } else {
        "a single expression"
    };
    format!(
        "You are filling a hole (`??`) in a program written in Duck, a statically typed language compiled to native code.\n\n\
         # The Duck language reference\n\n{spec}\n\n\
         # The file `{file}`\n\n```duck\n{file_src}```\n\n\
         # The hole to fill\n\n{brief}\n\
         # Your task\n\n\
         Write the Duck code that replaces the `??` at {file}:{line}:{col} ({context}): {what}, of type `{ty}`. \
         It must type-check, satisfy the function's contracts and make the tests above pass. \
         Use only what the reference and the file provide. Do not repeat the signature, do not change other code, and do not leave any `??`.\n\n\
         Reply with ONLY the code, in one fenced block:\n```duck\n<code that replaces ??>\n```\n",
        spec = super::SPEC.trim_end(),
        file = h.file,
        brief = holes::brief_text(h),
        line = h.span.line,
        col = h.span.col,
        context = h.context,
        ty = h.expected,
    )
}

/// Run the model command with the prompt on stdin; its stdout is the reply.
fn ask(cmd: &str, prompt: &str) -> Result<String, String> {
    let mut child = Command::new("sh")
        .arg("-c")
        .arg(cmd)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("cannot run the model command `{cmd}`: {e}"))?;
    let mut stdin = child.stdin.take().expect("piped stdin");
    let text = prompt.to_string();
    // write from a thread: the command may start answering before it has read everything
    let writer = thread::spawn(move || {
        let _ = stdin.write_all(text.as_bytes());
    });
    let out = child.wait_with_output().map_err(|e| format!("the model command `{cmd}` failed: {e}"))?;
    let _ = writer.join();
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr);
        return Err(format!("the model command `{cmd}` failed ({}): {}", out.status, err.trim()));
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// The code in the first ```duck (or plain ```) fence of a reply, or the whole reply.
pub fn extract_code(reply: &str) -> String {
    let lines: Vec<&str> = reply.lines().collect();
    let fence_at = |pred: &dyn Fn(&str) -> bool| lines.iter().position(|l| pred(l.trim()));
    let open = fence_at(&|l| l.starts_with("```duck")).or_else(|| fence_at(&|l| l.starts_with("```")));
    let body: Vec<&str> = match open {
        Some(i) => {
            let rest = &lines[i + 1..];
            let close = rest.iter().position(|l| l.trim().starts_with("```")).unwrap_or(rest.len());
            rest[..close].to_vec()
        }
        None => lines,
    };
    dedent(&body.join("\n")).trim_matches('\n').trim_end().to_string()
}

/// Remove the common leading indentation of the non-blank lines.
fn dedent(s: &str) -> String {
    let ind = s.lines().filter(|l| !l.trim().is_empty()).map(|l| l.len() - l.trim_start().len()).min().unwrap_or(0);
    s.lines().map(|l| if l.len() >= ind { &l[ind..] } else { l.trim_start() }).collect::<Vec<_>>().join("\n")
}

/// Replace the hole with `code`. A `{ ?? }` block becomes a block with the code on its own
/// indented lines; elsewhere, continuation lines get the hole line's indentation.
pub fn splice(src: &str, h: &Hole, code: &str) -> String {
    let line_indent = |line: u32| -> String {
        let start = holes::offset(src, line, 1);
        src[start..].chars().take_while(|c| *c == ' ' || *c == '\t').collect()
    };
    let code = code.trim_matches('\n');
    if let Some(b) = h.body {
        let base = line_indent(b.line);
        let inner: Vec<String> = code.lines().map(|l| if l.trim().is_empty() { String::new() } else { format!("{base}  {l}") }).collect();
        let (a, z) = (holes::offset(src, b.line, b.col), holes::offset(src, b.end_line, b.end_col));
        return format!("{}{{\n{}\n{base}}}{}", &src[..a], inner.join("\n"), &src[z..]);
    }
    let base = line_indent(h.span.line);
    let text: Vec<String> = code.lines().enumerate().map(|(i, l)| if i == 0 || l.trim().is_empty() { l.to_string() } else { format!("{base}{l}") }).collect();
    let (a, z) = (holes::offset(src, h.span.line, h.span.col), holes::offset(src, h.span.end_line, h.span.end_col));
    format!("{}{}{}", &src[..a], text.join("\n"), &src[z..])
}

static RUN_N: AtomicUsize = AtomicUsize::new(0);

/// Build the program's tests (holes allowed, contracts on, traced) and run them. Only the tests
/// named in `names` count; one that fails only by reaching another unfilled hole is ignored.
/// Returns their failure output.
fn run_tests(root: &Path, names: &[&str]) -> Result<(), String> {
    // compiled here (the candidate is an in-memory source), run in a forked child in its own
    // process group, killed after TEST_TIMEOUT
    let tp = super::build::check(root)?;
    let g = super::build::generate(&tp, super::mir::progen::Mode::Test, super::mir::progen::Trace { on: true, core: false, debug: false, lines: false })?;
    let info = super::mir::types::TyInfo::new(&tp);
    let j = super::mir::clif::jit(&g.prog, &info, false)?;
    let n = RUN_N.fetch_add(1, Ordering::Relaxed);
    let file = env::temp_dir().join(format!("duck-hatch-{}-{n}.out", std::process::id()));
    // SAFETY: hatch is single-threaded here
    unsafe {
        env::set_var("DUCK_TRACE", "-");
        env::set_var("DUCK_TRACE_TAIL", TRACE_TAIL);
    }
    let r = super::mir::clif::Redirect { merged: Some(&file), stdin_null: true, ..Default::default() };
    let w = j.spawn(&[root.display().to_string()], r, true).and_then(|pid| super::mir::clif::wait_child(pid, Some(TEST_TIMEOUT)));
    unsafe {
        env::remove_var("DUCK_TRACE");
        env::remove_var("DUCK_TRACE_TAIL");
    }
    let out = fs::read(&file).map(|b| String::from_utf8_lossy(&b).into_owned()).unwrap_or_default();
    let _ = fs::remove_file(&file);
    if w?.is_none() {
        return Err(format!("the tests did not finish within {}s (an infinite loop?)", TEST_TIMEOUT.as_secs()));
    }
    // "ok NAME" / "FAIL NAME" lines, each failure followed by its indented output
    let mut failures = String::new();
    let mut seen = 0;
    let mut cur: Option<(String, String)> = None;
    let flush = |cur: &mut Option<(String, String)>, failures: &mut String| {
        if let Some((name, body)) = cur.take() {
            let other_hole = body.contains("unfilled hole");
            if !other_hole {
                *failures += &format!("FAIL {name}\n{body}");
            }
        }
    };
    for l in out.lines() {
        if let Some(name) = l.strip_prefix("ok ") {
            flush(&mut cur, &mut failures);
            seen += usize::from(names.contains(&name));
        } else if let Some(name) = l.strip_prefix("FAIL ") {
            flush(&mut cur, &mut failures);
            if names.contains(&name) {
                seen += 1;
                cur = Some((name.to_string(), String::new()));
            }
        } else if l.starts_with("    ") {
            if let Some((_, body)) = &mut cur {
                *body += l;
                body.push('\n');
            }
        } else {
            flush(&mut cur, &mut failures);
        }
    }
    flush(&mut cur, &mut failures);
    if !failures.is_empty() {
        return Err(failures);
    }
    if seen < names.len() {
        return Err(format!("the tests did not run to completion:\n{out}"));
    }
    Ok(())
}

/// A unified diff of `a` -> `b` with 3 lines of context.
pub fn diff(file: &str, a: &str, b: &str) -> String {
    let (x, y): (Vec<&str>, Vec<&str>) = (a.lines().collect(), b.lines().collect());
    if x == y {
        return String::new();
    }
    // common prefix and suffix, then an LCS of the middle
    let pre = x.iter().zip(&y).take_while(|(p, q)| p == q).count();
    let suf = x[pre..].iter().rev().zip(y[pre..].iter().rev()).take_while(|(p, q)| p == q).count();
    let (xm, ym) = (&x[pre..x.len() - suf], &y[pre..y.len() - suf]);
    let mut lcs = vec![vec![0u32; ym.len() + 1]; xm.len() + 1];
    for i in (0..xm.len()).rev() {
        for j in (0..ym.len()).rev() {
            lcs[i][j] = if xm[i] == ym[j] { lcs[i + 1][j + 1] + 1 } else { lcs[i + 1][j].max(lcs[i][j + 1]) };
        }
    }
    // edit script over the whole files: (' ' | '-' | '+', line)
    let mut ops: Vec<(char, &str)> = x[..pre].iter().map(|l| (' ', *l)).collect();
    let (mut i, mut j) = (0, 0);
    while i < xm.len() || j < ym.len() {
        if i < xm.len() && j < ym.len() && xm[i] == ym[j] {
            ops.push((' ', xm[i]));
            i += 1;
            j += 1;
        } else if i < xm.len() && (j == ym.len() || lcs[i + 1][j] >= lcs[i][j + 1]) {
            ops.push(('-', xm[i]));
            i += 1;
        } else {
            ops.push(('+', ym[j]));
            j += 1;
        }
    }
    ops.extend(x[x.len() - suf..].iter().map(|l| (' ', *l)));
    // group into hunks
    let mut out = format!("--- a/{file}\n+++ b/{file}\n");
    let changed: Vec<usize> = ops.iter().enumerate().filter(|(_, (k, _))| *k != ' ').map(|(i, _)| i).collect();
    let mut k = 0;
    while k < changed.len() {
        let start = changed[k].saturating_sub(3);
        let mut end = changed[k];
        while k < changed.len() && changed[k] <= end + 7 {
            end = changed[k];
            k += 1;
        }
        let end = (end + 4).min(ops.len());
        let (a_start, b_start) = ops[..start].iter().fold((1, 1), |(a, b), (op, _)| match op {
            ' ' => (a + 1, b + 1),
            '-' => (a + 1, b),
            _ => (a, b + 1),
        });
        let a_len = ops[start..end].iter().filter(|(op, _)| *op != '+').count();
        let b_len = ops[start..end].iter().filter(|(op, _)| *op != '-').count();
        out += &format!("@@ -{a_start},{a_len} +{b_start},{b_len} @@\n");
        for (op, l) in &ops[start..end] {
            out += &format!("{op}{l}\n");
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_fenced_code() {
        assert_eq!(extract_code("Here:\n```duck\n  let a = 1\n  a + 1\n```\nbye"), "let a = 1\na + 1");
        assert_eq!(extract_code("```\nxs.len()\n```"), "xs.len()");
        assert_eq!(extract_code("  xs.len()  \n"), "xs.len()");
    }

    #[test]
    fn diffs_lines() {
        let d = diff("f.duck", "a\nb\nc\n", "a\nB\nc\n");
        assert_eq!(d, "--- a/f.duck\n+++ b/f.duck\n@@ -1,3 +1,3 @@\n a\n-b\n+B\n c\n");
        assert_eq!(diff("f", "x\n", "x\n"), "");
    }
}
