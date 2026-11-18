/* Sound output (`uses audio_out`): play interleaved float samples on the default output device.
 *
 * The system audio library is loaded with dlopen on first use, so programs that never play
 * sound don't load it: AudioToolbox's AudioQueue on macOS, PulseAudio's simple API
 * (libpulse-simple.so.0, also served by PipeWire) elsewhere. Playback blocks the calling task
 * until the sound has finished, waking every few milliseconds so a cancelled task stops at
 * once. */
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "auk_rt.h"

/* x clamped to -1..1 as a float (NaN stays NaN). */
static float to_f32(double x) {
    if (x < -1.0) {
        return -1.0f;
    }
    if (x > 1.0) {
        return 1.0f;
    }
    return (float)x;
}

static void audio_sleep_ms(int64_t ms) {
    struct timespec ts = {0, (long)(ms * 1000000)};
    nanosleep(&ts, NULL);
}

/* The reason playback failed (static or in buf). */
typedef struct AudioFail {
    char buf[256];
} AudioFail;

#if defined(__APPLE__)
/* ---- macOS: AudioToolbox AudioQueue ------------------------------------------------------ */

/* Samples are handed to AudioQueue in buffers of this many frames. */
enum { CHUNK = 4096 };

typedef struct Asbd {
    double sample_rate;
    uint32_t format_id;
    uint32_t format_flags;
    uint32_t bytes_per_packet;
    uint32_t frames_per_packet;
    uint32_t bytes_per_frame;
    uint32_t channels_per_frame;
    uint32_t bits_per_channel;
    uint32_t reserved;
} Asbd;

typedef struct AqBuffer {
    uint32_t capacity;
    void *data;
    uint32_t size;
    void *user;
    uint32_t desc_capacity;
    void *descs;
    uint32_t desc_count;
} AqBuffer;

typedef void *AqQueue;
typedef void (*AqCallback)(void *user, AqQueue q, AqBuffer *b);

typedef struct AqApi {
    int32_t (*new_output)(const Asbd *fmt, AqCallback cb, void *user, void *run_loop, void *mode, uint32_t flags, AqQueue *out);
    int32_t (*allocate)(AqQueue q, uint32_t bytes, AqBuffer **out);
    int32_t (*enqueue)(AqQueue q, AqBuffer *b, uint32_t n, const void *descs);
    int32_t (*start)(AqQueue q, const void *when);
    int32_t (*stop)(AqQueue q, uint8_t immediate);
    int32_t (*dispose)(AqQueue q, uint8_t immediate);
    int32_t (*get_property)(AqQueue q, uint32_t id, void *data, uint32_t *size);
} AqApi;

static const uint32_t LPCM = 0x6c70636d;       /* 'lpcm' */
static const uint32_t FLOAT_PACKED = 1 | 8;    /* kAudioFormatFlagIsFloat | IsPacked */
static const uint32_t IS_RUNNING = 0x6171726e; /* 'aqrn' */

/* Every buffer is enqueued up front, so nothing needs refilling when one finishes. */
static void aq_done(void *user, AqQueue q, AqBuffer *b) {
    (void)user;
    (void)q;
    (void)b;
}

static AqApi aq;
static bool aq_ok;
static pthread_once_t aq_once = PTHREAD_ONCE_INIT;

static void aq_load(void) {
    void *lib = dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox", RTLD_LAZY);
    if (lib == NULL) {
        return;
    }
    aq.new_output = dlsym(lib, "AudioQueueNewOutput");
    aq.allocate = dlsym(lib, "AudioQueueAllocateBuffer");
    aq.enqueue = dlsym(lib, "AudioQueueEnqueueBuffer");
    aq.start = dlsym(lib, "AudioQueueStart");
    aq.stop = dlsym(lib, "AudioQueueStop");
    aq.dispose = dlsym(lib, "AudioQueueDispose");
    aq.get_property = dlsym(lib, "AudioQueueGetProperty");
    aq_ok = aq.new_output != NULL && aq.allocate != NULL && aq.enqueue != NULL && aq.start != NULL && aq.stop != NULL &&
            aq.dispose != NULL && aq.get_property != NULL;
}

static bool aq_fail(AudioFail *f, AqQueue q, const char *what, int32_t st) {
    aq.dispose(q, 1);
    snprintf(f->buf, sizeof f->buf, "%s error %d", what, (int)st);
    return false;
}

static bool play(const double *xs, int64_t n, int64_t nch, int64_t rate, AudioFail *f) {
    pthread_once(&aq_once, aq_load);
    if (!aq_ok) {
        snprintf(f->buf, sizeof f->buf, "could not load AudioToolbox");
        return false;
    }
    Asbd fmt = {(double)rate, LPCM, FLOAT_PACKED, (uint32_t)(4 * nch), 1, (uint32_t)(4 * nch), (uint32_t)nch, 32, 0};
    AqQueue q = NULL;
    int32_t st = aq.new_output(&fmt, aq_done, NULL, NULL, NULL, 0, &q);
    if (st != 0 || q == NULL) {
        snprintf(f->buf, sizeof f->buf, "no output device (AudioQueueNewOutput error %d)", (int)st);
        return false;
    }
    int64_t per = CHUNK * nch;
    for (int64_t off = 0; off < n; off += per) {
        int64_t len = n - off < per ? n - off : per;
        uint32_t bytes = (uint32_t)(len * 4);
        AqBuffer *b = NULL;
        st = aq.allocate(q, bytes, &b);
        if (st != 0 || b == NULL) {
            return aq_fail(f, q, "AudioQueueAllocateBuffer", st);
        }
        float *d = b->data;
        for (int64_t i = 0; i < len; i++) {
            d[i] = to_f32(xs[off + i]);
        }
        b->size = bytes;
        st = aq.enqueue(q, b, 0, NULL);
        if (st != 0) {
            return aq_fail(f, q, "AudioQueueEnqueueBuffer", st);
        }
    }
    st = aq.start(q, NULL);
    if (st != 0) {
        return aq_fail(f, q, "AudioQueueStart", st);
    }
    /* Stop once the queued buffers have played; the queue reports it stopped running then. */
    aq.stop(q, 0);
    int64_t frames = n / nch;
    int64_t dur_ms = (int64_t)((uint64_t)frames * 1000 / (uint64_t)rate);
    int64_t waited = 0;
    for (;;) {
        if (auk__task_cancelled()) {
            break;
        }
        if (waited >= dur_ms) {
            uint32_t running = 0;
            uint32_t size = 4;
            st = aq.get_property(q, IS_RUNNING, &running, &size);
            /* a stuck queue shouldn't hang the program: give it two seconds past the end */
            if (st != 0 || running == 0 || waited >= dur_ms + 2000) {
                break;
            }
        }
        audio_sleep_ms(10);
        waited += 10;
    }
    aq.dispose(q, 1);
    return true;
}

#else
/* ---- elsewhere: PulseAudio's simple API -------------------------------------------------- */

typedef struct PaSpec {
    int format;
    uint32_t rate;
    uint8_t channels;
} PaSpec;

typedef void *PaSimple;

typedef struct PaApi {
    PaSimple (*new_)(const char *server, const char *name, int dir, const char *dev, const char *stream, const PaSpec *ss,
                     const void *map, const void *attr, int *error);
    int (*write)(PaSimple s, const void *data, size_t bytes, int *error);
    int (*drain)(PaSimple s, int *error);
    int (*flush)(PaSimple s, int *error);
    void (*free_)(PaSimple s);
    const char *(*strerror_)(int error);
} PaApi;

enum { PA_PLAYBACK = 1 };
#if __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
enum { PA_FLOAT32 = 6 }; /* PA_SAMPLE_FLOAT32BE */
#else
enum { PA_FLOAT32 = 5 }; /* PA_SAMPLE_FLOAT32LE */
#endif

static PaApi pa;
static bool pa_ok;
static pthread_once_t pa_once = PTHREAD_ONCE_INIT;

static void pa_load(void) {
    void *lib = dlopen("libpulse-simple.so.0", RTLD_LAZY);
    void *base = dlopen("libpulse.so.0", RTLD_LAZY);
    if (lib == NULL || base == NULL) {
        return;
    }
    pa.new_ = dlsym(lib, "pa_simple_new");
    pa.write = dlsym(lib, "pa_simple_write");
    pa.drain = dlsym(lib, "pa_simple_drain");
    pa.flush = dlsym(lib, "pa_simple_flush");
    pa.free_ = dlsym(lib, "pa_simple_free");
    pa.strerror_ = dlsym(base, "pa_strerror");
    pa_ok = pa.new_ != NULL && pa.write != NULL && pa.drain != NULL && pa.flush != NULL && pa.free_ != NULL && pa.strerror_ != NULL;
}

static bool play(const double *xs, int64_t n, int64_t nch, int64_t rate, AudioFail *f) {
    pthread_once(&pa_once, pa_load);
    if (!pa_ok) {
        snprintf(f->buf, sizeof f->buf, "could not load libpulse-simple.so.0 (PulseAudio or PipeWire)");
        return false;
    }
    PaSpec spec = {PA_FLOAT32, (uint32_t)rate, (uint8_t)nch};
    int e = 0;
    PaSimple s = pa.new_(NULL, "auk", PA_PLAYBACK, NULL, "audio_out", &spec, NULL, NULL, &e);
    if (s == NULL) {
        snprintf(f->buf, sizeof f->buf, "no output device (%s)", pa.strerror_(e));
        return false;
    }
    /* small chunks, so a cancelled task stops within a chunk */
    int64_t per = (rate / 50 > 1 ? rate / 50 : 1) * nch;
    float *buf = auk__xmalloc((size_t)per * sizeof(float));
    for (int64_t off = 0; off < n; off += per) {
        if (auk__task_cancelled()) {
            pa.flush(s, &e);
            pa.free_(s);
            free(buf);
            return true;
        }
        int64_t len = n - off < per ? n - off : per;
        for (int64_t i = 0; i < len; i++) {
            buf[i] = to_f32(xs[off + i]);
        }
        if (pa.write(s, buf, (size_t)len * 4, &e) < 0) {
            pa.free_(s);
            free(buf);
            snprintf(f->buf, sizeof f->buf, "%s", pa.strerror_(e));
            return false;
        }
    }
    free(buf);
    int r = pa.drain(s, &e);
    pa.free_(s);
    if (r < 0) {
        snprintf(f->buf, sizeof f->buf, "%s", pa.strerror_(e));
        return false;
    }
    return true;
}
#endif

static AukRes_unit audio_err(AukStrBuf *m) {
    AukRes_unit r = {0};
    r.err = auk__err_sb(m);
    return r;
}

/* Play samples (interleaved, channels per frame, nominally -1.0..1.0) at rate Hz and return
 * once they have been heard. An Err if the arguments are invalid or no output device can be
 * opened. */
AUK_API AukRes_unit auk_audio_out_play(const AukArr *samples, int64_t channels, int64_t rate, const char *loc) {
    int64_t n = auk_arr_len(samples);
    AukStrBuf m = {0};
    auk__sb_put_cstr(&m, "audio_out.play: ");
    if (channels < 1 || channels > 32) {
        auk_sb_int(&m, channels);
        auk__sb_put_cstr(&m, " channels (expected 1 to 32)");
        return audio_err(&m);
    }
    if (rate < 1 || rate > 768000) {
        auk__sb_put_cstr(&m, "sample rate ");
        auk_sb_int(&m, rate);
        auk__sb_put_cstr(&m, " (expected 1 to 768000)");
        return audio_err(&m);
    }
    if (n % channels != 0) {
        auk_sb_int(&m, n);
        auk__sb_put_cstr(&m, " samples is not a whole number of ");
        auk_sb_int(&m, channels);
        auk__sb_put_cstr(&m, "-channel frames");
        return audio_err(&m);
    }
    AukRes_unit r = {0};
    if (n == 0) {
        auk_sb_free(&m);
        r.ok = true;
        return r;
    }
    AudioFail f = {{0}};
    if (play((const double *)samples->data, n, channels, rate, &f)) {
        auk_sb_free(&m);
        auk__check_cancel(loc);
        r.ok = true;
        return r;
    }
    auk__sb_put_cstr(&m, f.buf);
    return audio_err(&m);
}
