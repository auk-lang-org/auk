//! `duck explain`: the error catalogue. Every diagnostic code in `diag::CODES` has a page in
//! docs/errors/<code>.md (what went wrong, a wrong and a fixed example, common causes), embedded
//! in the binary and rendered as plain text for a terminal.

use super::diag::CODES;

macro_rules! pages {
    ($($code:literal)*) => {
        /// (code, markdown page) for every registered code, in `CODES` order.
        pub const PAGES: &[(&str, &str)] = &[$(($code, include_str!(concat!("../docs/errors/", $code, ".md")))),*];
    };
}

pages! {
    "E0001" "E0002" "E0003" "E0004" "E0005" "E0006" "E0007" "E0008" "E0009" "E0010" "E0011" "E0012"
    "E0013" "E0020" "E0021" "E0022" "E0023" "E0024" "E0025" "E0026" "E0027" "E0028" "E0029" "E0030"
    "E0031" "E0032" "E0033" "E0034" "E0035" "E0036" "E0037" "E0038" "E0039" "E0100" "E0101" "E0102" "E0103" "E0104" "E0105"
    "E0106" "E0107" "E0108" "E0109" "E0110" "E0111" "E0112" "E0113" "E0114" "E0115" "E0116" "E0120" "E0121"
    "E0200" "E0201" "E0202" "E0203" "E0204" "E0205" "E0207" "E0210" "E0221" "E0222" "E0223" "E0224"
    "E0225" "E0240" "E0241" "E0242" "E0243" "E0244" "E0245" "E0246" "E0247" "E0248" "E0249" "E0250"
    "E0251" "E0252" "E0253" "E0254" "E0255" "E0260" "E0261" "E0262" "E0263" "E0264" "E0265" "E0266"
    "E0270" "E0280" "E0281" "E0282" "E0290" "E0291" "E0292" "E0293" "E0300" "E0301" "E0302" "E0310" "E0311" "E0320" "E0322" "E0323"
    "E0331" "E0332" "E0333" "E0334" "E0335" "E0350" "E0360" "E0370" "E0400" "E0401" "E0402" "E0403" "E0410"
    "E0411" "E0412" "E0413" "E0414" "E0415" "E0420"
}

/// The markdown page for `code`.
pub fn page(code: &str) -> Option<&'static str> {
    PAGES.iter().find(|(c, _)| *c == code).map(|(_, p)| *p)
}

/// `duck explain [code]`. Returns the exit code.
pub fn run(args: &[String]) -> i32 {
    match args {
        [] => {
            print!("{}", list());
            0
        }
        [arg] => match normalize(arg).and_then(|c| page(&c)) {
            Some(p) => {
                print!("{}", render(p));
                0
            }
            None => {
                eprint!("{}", unknown(arg));
                1
            }
        },
        _ => {
            eprintln!("usage: duck explain [E0xxx]");
            2
        }
    }
}

/// Every code with its title, one per line.
pub fn list() -> String {
    let mut out = String::from("Duck error codes (run `duck explain E0xxx` for details):\n\n");
    for (c, t) in CODES {
        out += &format!("  {c}  {t}\n");
    }
    out
}

/// `E0400`, `e0400`, `0400` and `400` all mean E0400.
fn normalize(arg: &str) -> Option<String> {
    let digits = arg.strip_prefix(['E', 'e']).unwrap_or(arg);
    let n: u32 = digits.parse().ok().filter(|_| !digits.is_empty() && digits.len() <= 4)?;
    Some(format!("E{n:04}"))
}

/// The error for an unregistered code: the closest codes (by number), or codes whose title
/// mentions the word given.
fn unknown(arg: &str) -> String {
    let shown = normalize(arg).unwrap_or_else(|| arg.to_string());
    let mut out = format!("error: `{shown}` is not a Duck error code\n");
    let near: Vec<&(&str, &str)> = match normalize(arg) {
        Some(c) => {
            let n: i64 = c[1..].parse().unwrap_or(0);
            let mut by_dist: Vec<&(&str, &str)> = CODES.iter().collect();
            by_dist.sort_by_key(|(c, _)| (c[1..].parse::<i64>().unwrap_or(0) - n).abs());
            by_dist.into_iter().take(3).collect()
        }
        None => {
            let w = arg.to_lowercase();
            CODES.iter().filter(|(_, t)| t.to_lowercase().contains(&w)).take(5).collect()
        }
    };
    if !near.is_empty() {
        out += "  closest codes:\n";
        for (c, t) in near {
            out += &format!("    {c}  {t}\n");
        }
    }
    out += "  help: run `duck explain` to list every code\n";
    out
}

/// Markdown -> plain text: headings underlined, code blocks indented four spaces (a block for
/// another file of a project is headed by its path), everything else as written.
pub fn render(md: &str) -> String {
    let mut out = String::new();
    let mut in_code = false;
    for line in md.lines() {
        if let Some(info) = line.strip_prefix("```") {
            if !in_code {
                let mut parts = info.split_whitespace();
                let lang = parts.next().unwrap_or("");
                if let Some(path) = parts.next() {
                    let comment = if lang == "duck" { "//" } else { "#" };
                    out += &format!("    {comment} {path}\n");
                }
            }
            in_code = !in_code;
        } else if in_code {
            out += &if line.is_empty() { String::new() } else { format!("    {line}") };
            out.push('\n');
        } else if let Some(h) = line.strip_prefix("# ") {
            out += &format!("{h}\n{}\n", "=".repeat(h.chars().count()));
        } else if let Some(h) = line.strip_prefix("## ") {
            out += &format!("{h}\n{}\n", "-".repeat(h.chars().count()));
        } else {
            out += line;
            out.push('\n');
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_code_has_a_page_with_its_title() {
        assert_eq!(PAGES.len(), CODES.len());
        for ((c, t), (pc, p)) in CODES.iter().zip(PAGES) {
            assert_eq!(c, pc);
            assert!(p.starts_with(&format!("# {c}: {t}\n")), "{c}: the page must start with `# {c}: {t}`");
        }
    }

    #[test]
    fn codes_normalize() {
        for a in ["E0400", "e0400", "0400", "400"] {
            assert_eq!(normalize(a).as_deref(), Some("E0400"));
        }
        assert_eq!(normalize("E"), None);
        assert_eq!(normalize("semicolon"), None);
        assert_eq!(normalize("E12345"), None);
    }

    #[test]
    fn unknown_codes_suggest_neighbours() {
        let u = unknown("E0206");
        assert!(u.contains("E0205") && u.contains("E0207"), "{u}");
        let u = unknown("semicolon");
        assert!(u.contains("E0011"), "{u}");
    }

    #[test]
    fn render_markdown() {
        let md = "# E1: t\n\ntext `x`\n\n## Wrong\n\n```duck\nfn f() {\n\n}\n```\n\n```toml quack.toml\n[package]\n```\n";
        assert_eq!(
            render(md),
            "E1: t\n=====\n\ntext `x`\n\nWrong\n-----\n\n    fn f() {\n\n    }\n\n    # quack.toml\n    [package]\n"
        );
    }
}
