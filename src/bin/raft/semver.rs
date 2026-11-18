//! Semantic versions (`MAJOR.MINOR.PATCH`) and requirements (`^1.2`, `~1.2.3`, `=1.2.3`, `*`).

use std::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct Version {
    pub major: u64,
    pub minor: u64,
    pub patch: u64,
}

impl Version {
    /// Parse exactly `MAJOR.MINOR.PATCH` (no pre-release or build suffix).
    pub fn parse(s: &str) -> Option<Version> {
        match parts(s)?.as_slice() {
            &[major, minor, patch] => Some(Version { major, minor, patch }),
            _ => None,
        }
    }
}

impl fmt::Display for Version {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "{}.{}.{}", self.major, self.minor, self.patch)
    }
}

/// 1 to 3 dot-separated numbers without leading zeros.
fn parts(s: &str) -> Option<Vec<u64>> {
    let ps: Vec<u64> = s
        .split('.')
        .map(|p| {
            let ok = !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit()) && (p == "0" || !p.starts_with('0'));
            if ok { p.parse().ok() } else { None }
        })
        .collect::<Option<_>>()?;
    (1..=3).contains(&ps.len()).then_some(ps)
}

/// A version requirement: the half-open range `lo <= v < hi` (no `hi` = unbounded).
#[derive(Debug, Clone, PartialEq)]
pub struct Req {
    text: String,
    lo: Version,
    hi: Option<Version>,
}

impl Req {
    /// Parse `^X[.Y[.Z]]`, `~X[.Y[.Z]]`, `=X.Y.Z` or `*`. A bare `X.Y` means `^X.Y`.
    pub fn parse(s: &str) -> Option<Req> {
        let s = s.trim();
        let text = s.to_string();
        if s == "*" {
            return Some(Req { text, lo: Version { major: 0, minor: 0, patch: 0 }, hi: None });
        }
        let (op, rest) = match s.chars().next()? {
            c @ ('^' | '~' | '=') => (c, s[1..].trim_start()),
            _ => ('^', s),
        };
        let ps = parts(rest)?;
        let n = ps.len();
        let (x, y, z) = (ps[0], ps.get(1).copied().unwrap_or(0), ps.get(2).copied().unwrap_or(0));
        let v = |major, minor, patch| Version { major, minor, patch };
        let hi = match op {
            '=' if n == 3 => v(x, y, z + 1),
            '=' => return None,
            '~' if n == 1 => v(x + 1, 0, 0),
            '~' => v(x, y + 1, 0),
            // Caret: the leftmost non-zero component given may not change.
            _ if x > 0 || n == 1 => v(x + 1, 0, 0),
            _ if y > 0 || n == 2 => v(0, y + 1, 0),
            _ => v(0, 0, z + 1),
        };
        Some(Req { text, lo: v(x, y, z), hi: Some(hi) })
    }

    pub fn matches(&self, v: Version) -> bool {
        v >= self.lo && self.hi.is_none_or(|hi| v < hi)
    }
}

impl fmt::Display for Req {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.write_str(&self.text)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn m(req: &str, v: &str) -> bool {
        Req::parse(req).unwrap().matches(Version::parse(v).unwrap())
    }

    #[test]
    fn versions() {
        assert_eq!(Version::parse("1.20.3"), Some(Version { major: 1, minor: 20, patch: 3 }));
        for bad in ["1.2", "1.2.3.4", "01.2.3", "1.2.x", "", "1.2.3-beta"] {
            assert_eq!(Version::parse(bad), None, "{bad}");
        }
        assert!(Version::parse("1.10.0") > Version::parse("1.9.9"));
    }

    #[test]
    fn caret() {
        assert!(m("^1.2", "1.2.0") && m("^1.2", "1.9.7") && !m("^1.2", "2.0.0") && !m("^1.2", "1.1.9"));
        assert!(m("^1.2.3", "1.2.3") && !m("^1.2.3", "1.2.2"));
        assert!(m("^1", "1.0.0") && !m("^1", "2.0.0"));
        // 0.x: the minor version is the breaking one.
        assert!(m("^0.3", "0.3.0") && m("^0.3", "0.3.9") && !m("^0.3", "0.4.0") && !m("^0.3", "0.2.9"));
        assert!(m("^0.0.3", "0.0.3") && !m("^0.0.3", "0.0.4"));
        assert!(m("^0", "0.9.0") && !m("^0", "1.0.0"));
        assert!(m("1.2", "1.5.0") && !m("1.2", "2.0.0"));
    }

    #[test]
    fn tilde_exact_star() {
        assert!(m("~1.2.3", "1.2.3") && m("~1.2.3", "1.2.9") && !m("~1.2.3", "1.3.0") && !m("~1.2.3", "1.2.2"));
        assert!(m("~1", "1.9.0") && !m("~1", "2.0.0"));
        assert!(m("=1.2.3", "1.2.3") && !m("=1.2.3", "1.2.4"));
        assert!(m("*", "0.0.1") && m("*", "99.0.0"));
        for bad in ["=1.2", "^", "^1.x", ">1.0", "^1.2.3.4"] {
            assert_eq!(Req::parse(bad), None, "{bad}");
        }
    }
}
