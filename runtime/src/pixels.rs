//! Frames (`pixels.Frame`, pure): 32-bit pixels and the hot loops of filling, blending and
//! copying them, for `gui` programs and the `graphics` package.
//!
//! A frame holds `w`×`h` colors 0xTTRRGGBB, rows top to bottom. The top byte is transparency:
//! 0 is opaque (so a plain 0xRRGGBB is an opaque color) and 255 fully transparent; alpha is
//! `255 - T`, straight (not premultiplied). A frame is a handle shared by reference count and
//! copied before a write while shared, so it behaves like any Auk value. Rectangles are clipped
//! to the frame, so drawing partly (or wholly) outside it is fine.

use std::ffi::c_char;

use crate::rc::panic_msg;
use crate::*;

const MAX_PIXELS: i64 = 1 << 28;

unsafe fn alloc(w: i64, h: i64) -> *mut AukFrame {
    unsafe {
        let f = crate::rc::auk__alloc(size_of::<AukFrame>() + (w * h) as usize * 4, AUK_K_FRAME) as *mut AukFrame;
        (*f).w = w;
        (*f).hgt = h;
        f
    }
}

/// A frame's pixels.
pub unsafe fn pixels<'a>(f: *const AukFrame) -> &'a [u32] {
    unsafe { std::slice::from_raw_parts((*f).data.as_ptr(), ((*f).w * (*f).hgt) as usize) }
}

/// Copies of shared frames at least this big are reported under `AUK_GUI_TRACE=1`.
const REPORT_PIXELS: i64 = 256 * 1024;

/// Report (under `AUK_GUI_TRACE=1`) that a big shared frame was copied before a write: easy to
/// cause by accident (`let before = frame` kept alive across a draw loop) and costly at window
/// sizes. The first 20 are reported, then a count every 100.
fn report_copy(w: i64, h: i64, loc: *const c_char, what: &str) {
    use std::sync::atomic::{AtomicU64, Ordering::Relaxed};
    static ON: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    static N: AtomicU64 = AtomicU64::new(0);
    if w * h < REPORT_PIXELS || !*ON.get_or_init(|| std::env::var_os("AUK_GUI_TRACE").is_some_and(|v| v == "1")) {
        return;
    }
    let n = N.fetch_add(1, Relaxed) + 1;
    if n <= 20 {
        let at = if loc.is_null() { String::new() } else { format!(" at {}", unsafe { std::ffi::CStr::from_ptr(loc) }.to_string_lossy()) };
        eprintln!(
            "pixels.{what}{at}: copied a shared {w}x{h} frame ({} MB) to change it; something else still holds it \
             (keep one reference to a frame you draw into)",
            w * h * 4 / 1_000_000
        );
    } else if n % 100 == 0 {
        eprintln!("pixels: {n} copies of shared frames so far");
    }
}

/// The frame in `*pf`, writable: copied first if anything else holds it.
unsafe fn unique<'a>(pf: *mut *mut AukFrame, loc: *const c_char, what: &str) -> (&'a mut [u32], i64, i64) {
    unsafe {
        let f = *pf;
        let (w, h) = ((*f).w, (*f).hgt);
        if (*f).h.rc.load(std::sync::atomic::Ordering::Acquire) != 1 {
            report_copy(w, h, loc, what);
            let g = alloc(w, h);
            std::ptr::copy_nonoverlapping((*f).data.as_ptr(), (*g).data.as_mut_ptr(), (w * h) as usize);
            crate::rc::release(f);
            *pf = g;
        }
        (std::slice::from_raw_parts_mut((**pf).data.as_mut_ptr(), (w * h) as usize), w, h)
    }
}

/// Clip (x, y, w, h) to a `fw`×`fh` frame: (x0, y0, x1, y1), or None if nothing is left.
fn clip(x: i64, y: i64, w: i64, h: i64, fw: i64, fh: i64) -> Option<(i64, i64, i64, i64)> {
    let (x0, y0) = (x.max(0), y.max(0));
    let (x1, y1) = (x.saturating_add(w).min(fw), y.saturating_add(h).min(fh));
    (x0 < x1 && y0 < y1).then_some((x0, y0, x1, y1))
}

/// Run `f` on each row's part of rectangle `(x0, y0, x1, y1)` of a frame `stride` wide.
fn rows(px: &mut [u32], stride: i64, (x0, y0, x1, y1): (i64, i64, i64, i64), mut f: impl FnMut(&mut [u32])) {
    for row in y0..y1 {
        f(&mut px[(row * stride + x0) as usize..(row * stride + x1) as usize]);
    }
}

/// `t / 255` rounded to nearest (as `(t + 127) / 255`), for `t` in 0..=65025, without dividing.
#[inline]
fn div255(t: u32) -> u32 {
    let t = t + 128;
    (t + (t >> 8)) >> 8
}

/// An opaque `dst` with `1 - sa` of it kept (`ia = 255 - sa`) plus a color's premultiplied share
/// (`crb` = red and blue times `sa`, packed as 0x00RR00BB lanes of 16 bits; `cg` = green times
/// `sa`): red and blue are worked out together in one 32-bit multiply. Exact, the same as
/// `div255` per channel: each lane stays below 65536 (d·ia + c·sa ≤ 255·255).
#[inline]
fn mix_opaque(d: u32, ia: u32, crb: u32, cg: u32) -> u32 {
    let rb = (d & 0x00ff_00ff) * ia + crb + 0x0080_0080;
    let rb = ((rb + ((rb >> 8) & 0x00ff_00ff)) >> 8) & 0x00ff_00ff;
    rb | div255(((d >> 8) & 0xff) * ia + cg) << 8
}

/// `src` (0xTTRRGGBB) over `dst` with `src`'s alpha scaled by `cov` (0..=255).
#[inline]
fn over(dst: u32, src: u32, cov: u32) -> u32 {
    let sa = div255((255 - (src >> 24)) * cov);
    if sa == 0 {
        return dst;
    }
    if sa == 255 {
        return src & 0xff_ffff;
    }
    let da = 255 - (dst >> 24);
    if da == 255 {
        // an opaque destination, the usual case
        let ia = 255 - sa;
        let ch = |s: u32| div255(((dst >> s) & 0xff) * ia + ((src >> s) & 0xff) * sa) << s;
        return ch(16) | ch(8) | ch(0);
    }
    // straight alpha: oa = sa + da (1 - sa), c = (sc sa + dc da (1 - sa)) / oa
    let k = div255(da * (255 - sa));
    let oa = sa + k;
    if oa == 0 {
        return 0xff00_0000;
    }
    let ch = |s: u32| ((((src >> s) & 0xff) * sa + ((dst >> s) & 0xff) * k + oa / 2) / oa) << s;
    (255 - oa) << 24 | ch(16) | ch(8) | ch(0)
}

fn color(c: i64) -> u32 {
    c as u32
}

/// A `w`×`h` frame filled with `color`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_frame_new(w: i64, h: i64, c: i64, loc: *const c_char) -> *mut AukFrame {
    if w < 0 || h < 0 || w.checked_mul(h).is_none_or(|n| n > MAX_PIXELS) {
        panic_msg(loc, &format!("pixels.frame: size {w}x{h}"));
    }
    unsafe {
        let f = alloc(w, h);
        if c != 0 {
            std::slice::from_raw_parts_mut((*f).data.as_mut_ptr(), (w * h) as usize).fill(color(c));
        }
        f
    }
}

/// A `w`×`h` frame of the colors `px` (rows top to bottom).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_frame_from_list(w: i64, h: i64, px: *const AukArr, loc: *const c_char) -> *mut AukFrame {
    let n = if px.is_null() { 0 } else { unsafe { (*px).len } };
    if w < 0 || h < 0 || w.checked_mul(h) != Some(n) || n > MAX_PIXELS {
        panic_msg(loc, &format!("pixels.from_list: {n} colors is not {w}x{h}"));
    }
    unsafe {
        let f = alloc(w, h);
        let src = std::slice::from_raw_parts((*px).data as *const i64, n as usize);
        for (d, &s) in std::slice::from_raw_parts_mut((*f).data.as_mut_ptr(), n as usize).iter_mut().zip(src) {
            *d = color(s);
        }
        f
    }
}

/// The frame's colors as a list, rows top to bottom.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_frame_to_list(f: *const AukFrame) -> *mut AukArr {
    unsafe {
        let px = pixels(f);
        let mut out = crate::arr::auk_arr_new(&crate::rc::auk_ops_int, px.len() as i64);
        let d = crate::arr::auk_arr_make_unique(&mut out) as *mut i64;
        for (i, &p) in px.iter().enumerate() {
            *d.add(i) = p as i64;
        }
        (*out).len = px.len() as i64;
        out
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_frame_width(f: *const AukFrame) -> i64 {
    unsafe { (*f).w }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_frame_height(f: *const AukFrame) -> i64 {
    unsafe { (*f).hgt }
}

fn check(x: i64, y: i64, w: i64, h: i64, loc: *const c_char, what: &str) {
    if x < 0 || y < 0 || x >= w || y >= h {
        panic_msg(loc, &format!("pixels.{what}: ({x}, {y}) is outside the {w}x{h} frame"));
    }
}

/// The color at (`x`, `y`).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_frame_get(f: *const AukFrame, x: i64, y: i64, loc: *const c_char) -> i64 {
    unsafe {
        check(x, y, (*f).w, (*f).hgt, loc, "get");
        pixels(f)[(y * (*f).w + x) as usize] as i64
    }
}

/// Set the color at (`x`, `y`).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_frame_set(pf: *mut *mut AukFrame, x: i64, y: i64, c: i64, loc: *const c_char) {
    unsafe {
        check(x, y, (**pf).w, (**pf).hgt, loc, "set");
        let (px, w, _) = unique(pf, loc, "set");
        px[(y * w + x) as usize] = color(c);
    }
}

/// Set a rectangle to `c` (transparency included).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_frame_fill(pf: *mut *mut AukFrame, x: i64, y: i64, w: i64, h: i64, c: i64, loc: *const c_char) {
    unsafe {
        let Some(r) = clip(x, y, w, h, (**pf).w, (**pf).hgt) else { return };
        let (px, fw, _) = unique(pf, loc, "fill");
        rows(px, fw, r, |row| row.fill(color(c)));
    }
}

/// Paint `c` over a rectangle, as transparent as `c` is.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_frame_blend(pf: *mut *mut AukFrame, x: i64, y: i64, w: i64, h: i64, c: i64, loc: *const c_char) {
    let c = color(c);
    if c >> 24 == 255 {
        return;
    }
    unsafe {
        let Some(r) = clip(x, y, w, h, (**pf).w, (**pf).hgt) else { return };
        let (px, fw, _) = unique(pf, loc, "blend");
        let sa = 255 - (c >> 24);
        if sa == 255 {
            rows(px, fw, r, |row| row.fill(c));
            return;
        }
        // over an opaque pixel, with the color's share of each channel worked out once
        let ia = 255 - sa;
        let (crb, cg) = ((c & 0x00ff_00ff) * sa, ((c >> 8) & 0xff) * sa);
        rows(px, fw, r, |row| {
            if row.iter().all(|&d| d >> 24 == 0) {
                // all opaque, the usual case: a loop without branches
                for p in row {
                    *p = mix_opaque(*p, ia, crb, cg);
                }
            } else {
                for p in row {
                    *p = over(*p, c, 255);
                }
            }
        });
    }
}

/// The source and destination rectangles of a copy of `w`×`h` at (`sx`, `sy`) of a `sw`×`sh`
/// frame to (`x`, `y`) of a `dw`×`dh` one, clipped to both: (source x, source y, x0, y0, x1, y1).
#[allow(clippy::too_many_arguments)]
fn clip2(x: i64, y: i64, (sw, sh): (i64, i64), sx: i64, sy: i64, w: i64, h: i64, (dw, dh): (i64, i64)) -> Option<(i64, i64, i64, i64, i64, i64)> {
    let (sx0, sy0, sx1, sy1) = clip(sx, sy, w, h, sw, sh)?;
    let (dx, dy) = (x + (sx0 - sx), y + (sy0 - sy));
    let (x0, y0, x1, y1) = clip(dx, dy, sx1 - sx0, sy1 - sy0, dw, dh)?;
    Some((sx0 + (x0 - dx), sy0 + (y0 - dy), x0, y0, x1, y1))
}

/// Copy (or with `blend`, paint over) the `w`×`h` rectangle at (`sx`, `sy`) of `src` to (`x`, `y`).
#[allow(clippy::too_many_arguments)]
unsafe fn copy_rect(pf: *mut *mut AukFrame, x: i64, y: i64, src: *const AukFrame, sx: i64, sy: i64, w: i64, h: i64, blend: bool, loc: *const c_char) {
    unsafe {
        let ssize = ((*src).w, (*src).hgt);
        let Some((ox, oy, x0, y0, x1, y1)) = clip2(x, y, ssize, sx, sy, w, h, ((**pf).w, (**pf).hgt)) else { return };
        let len = (x1 - x0) as usize;
        let sw = ssize.0;
        // the source may be this very frame: take the rectangle out first, as it may overlap
        let same = std::ptr::eq(src, *pf);
        let tmp: Vec<u32> = if same {
            let s = pixels(src);
            (0..y1 - y0).flat_map(|r| s[((oy + r) * sw + ox) as usize..][..len].iter().copied()).collect()
        } else {
            Vec::new()
        };
        let (px, fw, _) = unique(pf, loc, if blend { "composite" } else { "blit" });
        let s = if same { &tmp[..] } else { pixels(src) };
        for r in 0..y1 - y0 {
            let from = if same { &s[r as usize * len..][..len] } else { &s[((oy + r) * sw + ox) as usize..][..len] };
            let to = &mut px[((y0 + r) * fw + x0) as usize..][..len];
            if blend {
                for (d, &c) in to.iter_mut().zip(from) {
                    *d = over(*d, c, 255);
                }
            } else {
                to.copy_from_slice(from);
            }
        }
    }
}

/// Copy the `w`×`h` rectangle at (`sx`, `sy`) of `src` to (`x`, `y`).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_frame_blit(pf: *mut *mut AukFrame, x: i64, y: i64, src: *const AukFrame, sx: i64, sy: i64, w: i64, h: i64, loc: *const c_char) {
    unsafe { copy_rect(pf, x, y, src, sx, sy, w, h, false, loc) }
}

/// Paint the `w`×`h` rectangle at (`sx`, `sy`) of `src` over (`x`, `y`), by its transparency.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_frame_composite(pf: *mut *mut AukFrame, x: i64, y: i64, src: *const AukFrame, sx: i64, sy: i64, w: i64, h: i64, loc: *const c_char) {
    unsafe { copy_rect(pf, x, y, src, sx, sy, w, h, true, loc) }
}

/// Paint `c` through `mask` (coverage 0..255, `mw` per row) placed at (`x`, `y`): how text
/// glyphs are drawn.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_frame_blit_mask(pf: *mut *mut AukFrame, x: i64, y: i64, mask: *const AukArr, mw: i64, c: i64, loc: *const c_char) {
    if mw < 1 {
        panic_msg(loc, &format!("pixels.blit_mask: mask width {mw} (expected at least 1)"));
    }
    let mn = if mask.is_null() { 0 } else { unsafe { (*mask).len } };
    if mn == 0 {
        return;
    }
    let c = color(c);
    if c >> 24 == 255 {
        return;
    }
    unsafe {
        let m: &[i64] = std::slice::from_raw_parts((*mask).data as *const i64, mn as usize);
        let mh = mn / mw;
        let Some((x0, y0, x1, y1)) = clip(x, y, mw, mh, (**pf).w, (**pf).hgt) else { return };
        let (px, fw, _) = unique(pf, loc, "blit_mask");
        let opaque = c >> 24 == 0;
        let len = (x1 - x0) as usize;
        let (crb, cg) = (c & 0x00ff_00ff, (c >> 8) & 0xff);
        for row in y0..y1 {
            let mrow = &m[((row - y) * mw + (x0 - x)) as usize..][..len];
            let prow = &mut px[(row * fw + x0) as usize..][..len];
            if opaque && prow.iter().all(|&d| d >> 24 == 0) {
                // the usual case for text: no branches, so it vectorizes. Exact for every
                // coverage: 0 leaves the pixel as it was and 255 gives the color.
                for (p, &a) in prow.iter_mut().zip(mrow) {
                    let a = a.clamp(0, 255) as u32;
                    *p = mix_opaque(*p, 255 - a, crb * a, cg * a);
                }
                continue;
            }
            for (p, &a) in prow.iter_mut().zip(mrow) {
                if a <= 0 {
                    continue;
                }
                let a = a.min(255) as u32;
                let d = *p;
                if !opaque || d >> 24 != 0 {
                    *p = over(d, c, a);
                } else if a == 255 {
                    *p = c;
                } else {
                    // an opaque color over an opaque pixel
                    *p = mix_opaque(d, 255 - a, (c & 0x00ff_00ff) * a, ((c >> 8) & 0xff) * a);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{div255, mix_opaque, over};

    #[test]
    fn mix_opaque_is_exact() {
        let mut seed = 12345u32;
        let mut next = || {
            seed ^= seed << 13;
            seed ^= seed >> 17;
            seed ^= seed << 5;
            seed
        };
        for _ in 0..200_000 {
            let (d, c, sa) = (next() & 0xff_ffff, next() & 0xff_ffff, next() % 256);
            let ia = 255 - sa;
            let want = |s: u32| div255(((d >> s) & 0xff) * ia + ((c >> s) & 0xff) * sa) << s;
            assert_eq!(mix_opaque(d, ia, (c & 0x00ff_00ff) * sa, ((c >> 8) & 0xff) * sa), want(16) | want(8) | want(0), "{d:x} {c:x} {sa}");
        }
    }

    #[test]
    fn over_matches_straight_alpha() {
        // opaque over anything replaces; transparent leaves it
        assert_eq!(over(0x123456, 0xabcdef, 255), 0xabcdef);
        assert_eq!(over(0x123456, 0xff_abcdef, 255), 0x123456);
        // half white over opaque black: mid grey, opaque
        assert_eq!(over(0x000000, 0x7f_ffffff, 255), 0x808080);
        // half white over transparent: half white
        assert_eq!(over(0xff_000000, 0x7f_ffffff, 255), 0x7f_ffffff);
        // half over half: alpha 0.75, color weighted 2:1 toward the top
        assert_eq!(over(0x7f_0000ff, 0x7f_ff0000, 255), 0x3f_aa0055);
    }
}

#[cfg(test)]
mod bench {
    use super::*;
    #[test]
    #[ignore]
    fn bench_frame_ops() {
        unsafe {
            let (w, h) = (2940i64, 1612i64);
            let mut f = auk_frame_new(w, h, 0xffffff, std::ptr::null());
            let t = std::time::Instant::now();
            for i in 0..50 {
                auk_frame_fill(&mut f, 0, 0, w, h, 0x101010 * (i % 16), std::ptr::null());
            }
            eprintln!("fill {} µs", t.elapsed().as_micros() / 50);
            let t = std::time::Instant::now();
            for _ in 0..20 {
                auk_frame_blend(&mut f, 0, 0, w, h, 0x80336699, std::ptr::null());
            }
            eprintln!("blend {} µs", t.elapsed().as_micros() / 20);
            let t = std::time::Instant::now();
            let px = std::slice::from_raw_parts_mut((*f).data.as_mut_ptr(), (w * h) as usize);
            for i in 0..50 {
                px.fill(i);
            }
            eprintln!("plain slice fill {} µs", t.elapsed().as_micros() / 50);
        }
    }
}
