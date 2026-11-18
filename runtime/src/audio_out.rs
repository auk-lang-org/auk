//! Sound output (`uses audio_out`): play interleaved float samples on the default output device.
//!
//! The system audio library is loaded with `dlopen` on first use, so programs that never play
//! sound don't link or load it: AudioToolbox's AudioQueue on macOS, PulseAudio's simple API
//! (`libpulse-simple.so.0`, also served by PipeWire) elsewhere. Playback blocks the calling task
//! until the sound has finished, waking every few milliseconds so a cancelled task stops at once.

use std::ffi::{CStr, c_char, c_void};

use crate::err::err_msg;
use crate::*;

/// Samples are handed to AudioQueue in buffers of this many frames.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
const CHUNK: usize = 4096;

unsafe fn float_slice<'a>(a: *const AukArr) -> &'a [f64] {
    if a.is_null() || unsafe { (*a).len } == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts((*a).data as *const f64, (*a).len as usize) }
    }
}

/// A symbol from a `dlopen`ed library, or None.
unsafe fn sym(lib: *mut c_void, name: &CStr) -> Option<*mut c_void> {
    let p = unsafe { libc::dlsym(lib, name.as_ptr()) };
    if p.is_null() { None } else { Some(p) }
}

fn sleep_ms(ms: i64) {
    let ts = libc::timespec { tv_sec: 0, tv_nsec: (ms * 1_000_000) as _ };
    unsafe { libc::nanosleep(&ts, std::ptr::null_mut()) };
}

/// Play `samples` (interleaved, `channels` per frame, nominally -1.0..1.0) at `rate` Hz and
/// return once they have been heard. An Err if the arguments are invalid or no output device can
/// be opened.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn auk_audio_out_play(samples: *const AukArr, channels: i64, rate: i64, loc: *const c_char) -> AukRes_unit {
    let xs = unsafe { float_slice(samples) };
    if !(1..=32).contains(&channels) {
        return AukRes::err(err_msg(&format!("audio_out.play: {channels} channels (expected 1 to 32)")));
    }
    if !(1..=768_000).contains(&rate) {
        return AukRes::err(err_msg(&format!("audio_out.play: sample rate {rate} (expected 1 to 768000)")));
    }
    if xs.len() % channels as usize != 0 {
        return AukRes::err(err_msg(&format!(
            "audio_out.play: {} samples is not a whole number of {channels}-channel frames",
            xs.len()
        )));
    }
    if xs.is_empty() {
        return AukRes::ok(0);
    }
    match unsafe { play(xs, channels as usize, rate as u32) } {
        Ok(()) => {
            crate::task::check_cancel(loc);
            AukRes::ok(0)
        }
        Err(e) => AukRes::err(err_msg(&format!("audio_out.play: {e}"))),
    }
}

fn to_f32(xs: &[f64]) -> Vec<f32> {
    xs.iter().map(|&x| x.clamp(-1.0, 1.0) as f32).collect()
}

// ---- macOS: AudioToolbox AudioQueue ---------------------------------------------------------

#[cfg(target_os = "macos")]
mod sys {
    use super::*;

    #[repr(C)]
    struct Asbd {
        sample_rate: f64,
        format_id: u32,
        format_flags: u32,
        bytes_per_packet: u32,
        frames_per_packet: u32,
        bytes_per_frame: u32,
        channels_per_frame: u32,
        bits_per_channel: u32,
        reserved: u32,
    }

    #[repr(C)]
    struct AqBuffer {
        capacity: u32,
        data: *mut c_void,
        size: u32,
        user: *mut c_void,
        desc_capacity: u32,
        descs: *mut c_void,
        desc_count: u32,
    }

    type Queue = *mut c_void;
    type Callback = extern "C" fn(*mut c_void, Queue, *mut AqBuffer);
    type NewOutput = unsafe extern "C" fn(*const Asbd, Callback, *mut c_void, *mut c_void, *mut c_void, u32, *mut Queue) -> i32;
    type Allocate = unsafe extern "C" fn(Queue, u32, *mut *mut AqBuffer) -> i32;
    type Enqueue = unsafe extern "C" fn(Queue, *mut AqBuffer, u32, *const c_void) -> i32;
    type Start = unsafe extern "C" fn(Queue, *const c_void) -> i32;
    type Stop = unsafe extern "C" fn(Queue, u8) -> i32;
    type GetProperty = unsafe extern "C" fn(Queue, u32, *mut c_void, *mut u32) -> i32;

    const LPCM: u32 = u32::from_be_bytes(*b"lpcm");
    const FLOAT_PACKED: u32 = 1 | 8; // kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
    const IS_RUNNING: u32 = u32::from_be_bytes(*b"aqrn");

    // Every buffer is enqueued up front, so nothing needs refilling when one finishes.
    extern "C" fn done(_: *mut c_void, _: Queue, _: *mut AqBuffer) {}

    struct Api {
        new_output: NewOutput,
        allocate: Allocate,
        enqueue: Enqueue,
        start: Start,
        stop: Stop,
        dispose: Stop,
        get_property: GetProperty,
    }

    fn api() -> Result<&'static Api, String> {
        static API: std::sync::OnceLock<Option<Api>> = std::sync::OnceLock::new();
        API.get_or_init(|| unsafe {
            let lib = libc::dlopen(c"/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox".as_ptr(), libc::RTLD_LAZY);
            if lib.is_null() {
                return None;
            }
            Some(Api {
                new_output: std::mem::transmute::<*mut c_void, NewOutput>(sym(lib, c"AudioQueueNewOutput")?),
                allocate: std::mem::transmute::<*mut c_void, Allocate>(sym(lib, c"AudioQueueAllocateBuffer")?),
                enqueue: std::mem::transmute::<*mut c_void, Enqueue>(sym(lib, c"AudioQueueEnqueueBuffer")?),
                start: std::mem::transmute::<*mut c_void, Start>(sym(lib, c"AudioQueueStart")?),
                stop: std::mem::transmute::<*mut c_void, Stop>(sym(lib, c"AudioQueueStop")?),
                dispose: std::mem::transmute::<*mut c_void, Stop>(sym(lib, c"AudioQueueDispose")?),
                get_property: std::mem::transmute::<*mut c_void, GetProperty>(sym(lib, c"AudioQueueGetProperty")?),
            })
        })
        .as_ref()
        .ok_or_else(|| "could not load AudioToolbox".to_string())
    }

    pub unsafe fn play(xs: &[f64], nch: usize, rate: u32) -> Result<(), String> {
        let a = api()?;
        let fmt = Asbd {
            sample_rate: rate as f64,
            format_id: LPCM,
            format_flags: FLOAT_PACKED,
            bytes_per_packet: 4 * nch as u32,
            frames_per_packet: 1,
            bytes_per_frame: 4 * nch as u32,
            channels_per_frame: nch as u32,
            bits_per_channel: 32,
            reserved: 0,
        };
        let mut q: Queue = std::ptr::null_mut();
        let st = unsafe { (a.new_output)(&fmt, done, std::ptr::null_mut(), std::ptr::null_mut(), std::ptr::null_mut(), 0, &mut q) };
        if st != 0 || q.is_null() {
            return Err(format!("no output device (AudioQueueNewOutput error {st})"));
        }
        let fail = |what: &str, st: i32| {
            unsafe { (a.dispose)(q, 1) };
            Err(format!("{what} error {st}"))
        };
        for chunk in xs.chunks(CHUNK * nch) {
            let bytes = (chunk.len() * 4) as u32;
            let mut b: *mut AqBuffer = std::ptr::null_mut();
            let st = unsafe { (a.allocate)(q, bytes, &mut b) };
            if st != 0 || b.is_null() {
                return fail("AudioQueueAllocateBuffer", st);
            }
            let f = to_f32(chunk);
            unsafe {
                std::ptr::copy_nonoverlapping(f.as_ptr() as *const u8, (*b).data as *mut u8, bytes as usize);
                (*b).size = bytes;
            }
            let st = unsafe { (a.enqueue)(q, b, 0, std::ptr::null()) };
            if st != 0 {
                return fail("AudioQueueEnqueueBuffer", st);
            }
        }
        let st = unsafe { (a.start)(q, std::ptr::null()) };
        if st != 0 {
            return fail("AudioQueueStart", st);
        }
        // Stop once the queued buffers have played; the queue reports it stopped running then.
        unsafe { (a.stop)(q, 0) };
        let frames = xs.len() / nch;
        let dur_ms = (frames as u64 * 1000 / rate as u64) as i64;
        let mut waited = 0i64;
        loop {
            if crate::task::cancelled() {
                break;
            }
            if waited >= dur_ms {
                let mut running: u32 = 0;
                let mut size = 4u32;
                let st = unsafe { (a.get_property)(q, IS_RUNNING, (&raw mut running).cast(), &mut size) };
                // a stuck queue shouldn't hang the program: give it two seconds past the end
                if st != 0 || running == 0 || waited >= dur_ms + 2000 {
                    break;
                }
            }
            sleep_ms(10);
            waited += 10;
        }
        unsafe { (a.dispose)(q, 1) };
        Ok(())
    }
}

// ---- elsewhere: PulseAudio's simple API -------------------------------------------------------

#[cfg(not(target_os = "macos"))]
mod sys {
    use super::*;
    use std::ffi::c_int;

    #[repr(C)]
    struct SampleSpec {
        format: c_int,
        rate: u32,
        channels: u8,
    }

    type Simple = *mut c_void;
    type New = unsafe extern "C" fn(
        *const c_char,
        *const c_char,
        c_int,
        *const c_char,
        *const c_char,
        *const SampleSpec,
        *const c_void,
        *const c_void,
        *mut c_int,
    ) -> Simple;
    type Write = unsafe extern "C" fn(Simple, *const c_void, usize, *mut c_int) -> c_int;
    type Drain = unsafe extern "C" fn(Simple, *mut c_int) -> c_int;
    type Free = unsafe extern "C" fn(Simple);
    type Strerror = unsafe extern "C" fn(c_int) -> *const c_char;

    const PLAYBACK: c_int = 1;
    #[cfg(target_endian = "little")]
    const FLOAT32: c_int = 5; // PA_SAMPLE_FLOAT32LE
    #[cfg(target_endian = "big")]
    const FLOAT32: c_int = 6; // PA_SAMPLE_FLOAT32BE

    struct Api {
        new: New,
        write: Write,
        drain: Drain,
        flush: Drain,
        free: Free,
        strerror: Strerror,
    }

    fn api() -> Result<&'static Api, String> {
        static API: std::sync::OnceLock<Option<Api>> = std::sync::OnceLock::new();
        API.get_or_init(|| unsafe {
            let lib = libc::dlopen(c"libpulse-simple.so.0".as_ptr(), libc::RTLD_LAZY);
            if lib.is_null() {
                return None;
            }
            let base = libc::dlopen(c"libpulse.so.0".as_ptr(), libc::RTLD_LAZY);
            let strerror = if base.is_null() { None } else { sym(base, c"pa_strerror") };
            Some(Api {
                new: std::mem::transmute::<*mut c_void, New>(sym(lib, c"pa_simple_new")?),
                write: std::mem::transmute::<*mut c_void, Write>(sym(lib, c"pa_simple_write")?),
                drain: std::mem::transmute::<*mut c_void, Drain>(sym(lib, c"pa_simple_drain")?),
                flush: std::mem::transmute::<*mut c_void, Drain>(sym(lib, c"pa_simple_flush")?),
                free: std::mem::transmute::<*mut c_void, Free>(sym(lib, c"pa_simple_free")?),
                strerror: std::mem::transmute::<*mut c_void, Strerror>(strerror?),
            })
        })
        .as_ref()
        .ok_or_else(|| "could not load libpulse-simple.so.0 (PulseAudio or PipeWire)".to_string())
    }

    pub unsafe fn play(xs: &[f64], nch: usize, rate: u32) -> Result<(), String> {
        let a = api()?;
        let text = |e: c_int| unsafe { crate::cstr((a.strerror)(e)).into_owned() };
        let spec = SampleSpec { format: FLOAT32, rate, channels: nch as u8 };
        let mut e: c_int = 0;
        let s = unsafe {
            (a.new)(std::ptr::null(), c"auk".as_ptr(), PLAYBACK, std::ptr::null(), c"audio_out".as_ptr(), &spec, std::ptr::null(), std::ptr::null(), &mut e)
        };
        if s.is_null() {
            return Err(format!("no output device ({})", text(e)));
        }
        // small chunks, so a cancelled task stops within a chunk
        for chunk in xs.chunks((rate as usize / 50).max(1) * nch) {
            if crate::task::cancelled() {
                unsafe { (a.flush)(s, &mut e) };
                unsafe { (a.free)(s) };
                return Ok(());
            }
            let f = to_f32(chunk);
            if unsafe { (a.write)(s, f.as_ptr().cast(), f.len() * 4, &mut e) } < 0 {
                unsafe { (a.free)(s) };
                return Err(text(e));
            }
        }
        let r = unsafe { (a.drain)(s, &mut e) };
        unsafe { (a.free)(s) };
        if r < 0 { Err(text(e)) } else { Ok(()) }
    }
}

use sys::play;
