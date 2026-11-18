/* The window process (gui.c explains why there is one). A program's first gui.open runs its own
 * executable again with AUK_GUI_HOST set. auk_main_wrapper (and the auk command) see that
 * variable and call auk__gui_host_main instead of running the program.
 *
 * The host's main thread runs AppKit. One thread per client reads its requests and hands them
 * to the main thread as jobs (a CFRunLoop source). All window state lives on the main thread,
 * and every reply and event is written from there, so the messages to a client stay in order.
 *
 * Each window maps the client's two shared frame buffers. Its view hosts a CALayer whose
 * contents are one of two IOSurfaces, which the compositor shows directly (no drawRect:). A
 * PRESENT copies the rectangle that changed (plus what the back surface missed since it was
 * last shown) from the buffer the client just wrote into the back surface, flips the layer to
 * it, and answers PRESENTED. The client then writes its other buffer.
 *
 * - AUK_GUI_HOST=fd:N: one client on fd N (a socket pair). Exit when it closes.
 * - AUK_GUI_HOST=listen:PATH (`auk run --live`): accept clients on a Unix socket. When a client
 *   goes away without BYE, its windows stay open as orphans. A later client's OPEN with the
 *   same title takes one over, and the next client to leave closes the rest. Exit when
 *   AUK_GUI_OWNER (the live parent's pid) is gone.
 *
 * AppKit, CoreFoundation, CoreGraphics and IOSurface are loaded with dlopen, and Objective-C is
 * driven through the runtime's C functions (objc_msgSend called through a pointer of each
 * method's exact type: on arm64 it isn't variadic). */
/* auk: own translation unit (its Point, Size, Rect...) */
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include "auk_rt.h"

#if defined(__APPLE__)

typedef void *Id;
typedef void *Sel;
typedef void *Class;

typedef struct HPoint {
    double x;
    double y;
} HPoint;

typedef struct HSize {
    double w;
    double h;
} HSize;

typedef struct HRect {
    HPoint o;
    HSize s;
} HRect;

static HRect hrect(double x, double y, double w, double h) {
    HRect r = {{x, y}, {w, h}};
    return r;
}

typedef struct SourceContext {
    intptr_t version;
    void *info;
    const void *retain;
    const void *release;
    const void *copy_description;
    const void *equal;
    const void *hash;
    const void *schedule;
    const void *cancel;
    void (*perform)(void *info);
} SourceContext;

/* The system functions, from dlopen'ed libraries. */
typedef struct Sys {
    Class (*get_class)(const char *name);
    Sel (*sel_register)(const char *name);
    void *msg_send;
    Class (*alloc_class_pair)(Class super, const char *name, size_t extra);
    bool (*add_method)(Class cls, Sel sel, const void *imp, const char *types);
    void (*register_class_pair)(Class cls);
    void *(*pool_push)(void);
    void (*pool_pop)(void *pool);
    void *(*run_loop_main)(void);
    void *(*source_create)(const void *alloc, intptr_t order, SourceContext *ctx);
    void (*add_source)(void *rl, void *source, const void *mode);
    void (*source_signal)(void *source);
    void (*wake_up)(void *rl);
    const void *common_modes;
    void *color_space;
    void (*cf_release)(const void *cf);
    const void *(*color_space_plist)(void *cs);
    void *(*surface_create)(Id props);
    int (*surface_lock)(void *s, uint32_t opts, uint32_t *seed);
    int (*surface_unlock)(void *s, uint32_t opts, uint32_t *seed);
    void *(*surface_base)(void *s);
    size_t (*surface_row_bytes)(void *s);
    bool (*surface_in_use)(void *s);
    void (*surface_set_value)(void *s, Id key, const void *value);
    /* for AUK_GUI_SNAP (tests): an image of one of this process's own windows (or NULL) */
    void *(*window_image)(HRect r, uint32_t list, uint32_t win, uint32_t opts);
    void *(*image_provider)(void *img);
    const void *(*provider_copy_data)(void *provider);
    size_t (*image_width)(void *img);
    size_t (*image_height)(void *img);
    size_t (*image_row_bytes)(void *img);
    const uint8_t *(*data_ptr)(const void *data);
} Sys;

static Sys sys;

static void *open_lib(const char *path, char **err) {
    void *h = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
    if (h == NULL && *err == NULL) {
        size_t n = strlen(path) + 256;
        *err = auk__xmalloc(n);
        snprintf(*err, n, "gui: cannot load %s: %s", path, dlerror());
    }
    return h;
}

static void *need(void *lib, const char *name, char **err) {
    void *p = lib == NULL ? NULL : dlsym(lib, name);
    if (p == NULL && *err == NULL) {
        size_t n = strlen(name) + 64;
        *err = auk__xmalloc(n);
        snprintf(*err, n, "gui: missing system function %s", name);
    }
    return p;
}

/* Load the system libraries: NULL, or why not (malloc'd). */
static char *load_sys(void) {
    char *err = NULL;
    void *objc = open_lib("/usr/lib/libobjc.A.dylib", &err);
    void *cf = open_lib("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", &err);
    void *cg = open_lib("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", &err);
    open_lib("/System/Library/Frameworks/AppKit.framework/AppKit", &err);
    void *ios = open_lib("/System/Library/Frameworks/IOSurface.framework/IOSurface", &err);
    if (err != NULL) {
        return err;
    }
    void *(*color_space_named)(const void *name) = need(cg, "CGColorSpaceCreateWithName", &err);
    const void *const *srgb = need(cg, "kCGColorSpaceSRGB", &err);
    sys.get_class = need(objc, "objc_getClass", &err);
    sys.sel_register = need(objc, "sel_registerName", &err);
    sys.msg_send = need(objc, "objc_msgSend", &err);
    sys.alloc_class_pair = need(objc, "objc_allocateClassPair", &err);
    sys.add_method = need(objc, "class_addMethod", &err);
    sys.register_class_pair = need(objc, "objc_registerClassPair", &err);
    sys.pool_push = need(objc, "objc_autoreleasePoolPush", &err);
    sys.pool_pop = need(objc, "objc_autoreleasePoolPop", &err);
    sys.run_loop_main = need(cf, "CFRunLoopGetMain", &err);
    sys.source_create = need(cf, "CFRunLoopSourceCreate", &err);
    sys.add_source = need(cf, "CFRunLoopAddSource", &err);
    sys.source_signal = need(cf, "CFRunLoopSourceSignal", &err);
    sys.wake_up = need(cf, "CFRunLoopWakeUp", &err);
    const void *const *modes = need(cf, "kCFRunLoopCommonModes", &err);
    sys.cf_release = need(cf, "CFRelease", &err);
    sys.color_space_plist = need(cg, "CGColorSpaceCopyPropertyList", &err);
    sys.surface_create = need(ios, "IOSurfaceCreate", &err);
    sys.surface_lock = need(ios, "IOSurfaceLock", &err);
    sys.surface_unlock = need(ios, "IOSurfaceUnlock", &err);
    sys.surface_base = need(ios, "IOSurfaceGetBaseAddress", &err);
    sys.surface_row_bytes = need(ios, "IOSurfaceGetBytesPerRow", &err);
    sys.surface_in_use = need(ios, "IOSurfaceIsInUse", &err);
    sys.surface_set_value = need(ios, "IOSurfaceSetValue", &err);
    sys.window_image = dlsym(cg, "CGWindowListCreateImage");
    sys.image_provider = need(cg, "CGImageGetDataProvider", &err);
    sys.provider_copy_data = need(cg, "CGDataProviderCopyData", &err);
    sys.image_width = need(cg, "CGImageGetWidth", &err);
    sys.image_height = need(cg, "CGImageGetHeight", &err);
    sys.image_row_bytes = need(cg, "CGImageGetBytesPerRow", &err);
    sys.data_ptr = need(cf, "CFDataGetBytePtr", &err);
    if (err != NULL) {
        return err;
    }
    sys.common_modes = *modes;
    sys.color_space = color_space_named(*srgb);
    return NULL;
}

static Sel sel(const char *name) {
    return sys.sel_register(name);
}

static Class cls(const char *name) {
    return sys.get_class(name);
}

/* objc_msgSend, typed: one function per method signature used here. */
static Id m_id(Id o, const char *s) {
    Id (*f)(Id, Sel) = sys.msg_send;
    return f(o, sel(s));
}

static void m_void(Id o, const char *s) {
    void (*f)(Id, Sel) = sys.msg_send;
    f(o, sel(s));
}

static void m_void_id(Id o, const char *s, Id a) {
    void (*f)(Id, Sel, Id) = sys.msg_send;
    f(o, sel(s), a);
}

static void m_void_id_id(Id o, const char *s, Id a, Id b) {
    void (*f)(Id, Sel, Id, Id) = sys.msg_send;
    f(o, sel(s), a, b);
}

static bool m_bool_id(Id o, const char *s, Id a) {
    bool (*f)(Id, Sel, Id) = sys.msg_send;
    return f(o, sel(s), a);
}

static void m_void_bool(Id o, const char *s, bool a) {
    void (*f)(Id, Sel, bool) = sys.msg_send;
    f(o, sel(s), a);
}

static bool m_bool_isize(Id o, const char *s, intptr_t a) {
    bool (*f)(Id, Sel, intptr_t) = sys.msg_send;
    return f(o, sel(s), a);
}

static bool m_bool(Id o, const char *s) {
    bool (*f)(Id, Sel) = sys.msg_send;
    return f(o, sel(s));
}

static void m_void_ptr(Id o, const char *s, void *a) {
    void (*f)(Id, Sel, void *) = sys.msg_send;
    f(o, sel(s), a);
}

static void *m_ptr(Id o, const char *s) {
    void *(*f)(Id, Sel) = sys.msg_send;
    return f(o, sel(s));
}

static void m_void_f64(Id o, const char *s, double a) {
    void (*f)(Id, Sel, double) = sys.msg_send;
    f(o, sel(s), a);
}

static double m_f64(Id o, const char *s) {
    double (*f)(Id, Sel) = sys.msg_send;
    return f(o, sel(s));
}

static intptr_t m_isize(Id o, const char *s) {
    intptr_t (*f)(Id, Sel) = sys.msg_send;
    return f(o, sel(s));
}

static uintptr_t m_usize(Id o, const char *s) {
    uintptr_t (*f)(Id, Sel) = sys.msg_send;
    return f(o, sel(s));
}

static uint16_t m_u16(Id o, const char *s) {
    uint16_t (*f)(Id, Sel) = sys.msg_send;
    return f(o, sel(s));
}

static const char *m_cstr(Id o, const char *s) {
    const char *(*f)(Id, Sel) = sys.msg_send;
    return f(o, sel(s));
}

static Id m_id_cstr(Id o, const char *s, const char *a) {
    Id (*f)(Id, Sel, const char *) = sys.msg_send;
    return f(o, sel(s), a);
}

static Id m_id_i64(Id o, const char *s, int64_t a) {
    Id (*f)(Id, Sel, int64_t) = sys.msg_send;
    return f(o, sel(s), a);
}

static Id m_id_rect(Id o, const char *s, HRect a) {
    Id (*f)(Id, Sel, HRect) = sys.msg_send;
    return f(o, sel(s), a);
}

static Id m_window_init(Id o, HRect r, uintptr_t style, uintptr_t backing, bool defer) {
    Id (*f)(Id, Sel, HRect, uintptr_t, uintptr_t, bool) = sys.msg_send;
    return f(o, sel("initWithContentRect:styleMask:backing:defer:"), r, style, backing, defer);
}

static Id m_menu_item_init(Id o, Id title, Sel action, Id key) {
    Id (*f)(Id, Sel, Id, Sel, Id) = sys.msg_send;
    return f(o, sel("initWithTitle:action:keyEquivalent:"), title, action, key);
}

static HRect m_rect(Id o, const char *s) {
    HRect (*f)(Id, Sel) = sys.msg_send;
    return f(o, sel(s));
}

static HPoint m_point(Id o, const char *s) {
    HPoint (*f)(Id, Sel) = sys.msg_send;
    return f(o, sel(s));
}

static HPoint m_point_convert(Id o, HPoint p, Id from) {
    HPoint (*f)(Id, Sel, HPoint, Id) = sys.msg_send;
    return f(o, sel("convertPoint:fromView:"), p, from);
}

/* An NSString of s[0..n) (embedded NULs dropped). */
static Id ns_string_n(const char *s, size_t n) {
    char *c = auk__xmalloc(n + 1);
    size_t k = 0;
    for (size_t i = 0; i < n; i++) {
        if (s[i] != 0) {
            c[k++] = s[i];
        }
    }
    c[k] = 0;
    Id r = m_id_cstr(cls("NSString"), "stringWithUTF8String:", c);
    free(c);
    return r;
}

static Id ns_string(const char *s) {
    return ns_string_n(s, strlen(s));
}

static Id app(void) {
    return m_id(cls("NSApplication"), "sharedApplication");
}

/* ---- AUK_GUI_TRACE=1: time copying into surfaces, waiting for the main thread, and handling
 * requests, and print the averages to stderr every half second ---------------------------- */

static bool trace_on;
static _Atomic uint64_t trace_s[9]; /* (count, total µs, max µs) for copy, wait, handle */
static pthread_mutex_t trace_lock = PTHREAD_MUTEX_INITIALIZER;
static int64_t trace_last;

static int64_t now_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}

static void trace_add(int kind, int64_t t0) {
    uint64_t us = (uint64_t)(now_us() - t0);
    atomic_fetch_add(&trace_s[kind * 3], 1);
    atomic_fetch_add(&trace_s[kind * 3 + 1], us);
    uint64_t m = atomic_load(&trace_s[kind * 3 + 2]);
    while (us > m && !atomic_compare_exchange_weak(&trace_s[kind * 3 + 2], &m, us)) {
    }
    pthread_mutex_lock(&trace_lock);
    int64_t now = now_us();
    if (trace_last == 0 || now - trace_last >= 500000) {
        trace_last = now;
        char line[512];
        int k = snprintf(line, sizeof line, "gui trace:");
        const char *names[3] = {"copy", "wait", "handle"};
        for (int i = 0; i < 3; i++) {
            uint64_t n = atomic_exchange(&trace_s[i * 3], 0);
            uint64_t tot = atomic_exchange(&trace_s[i * 3 + 1], 0);
            uint64_t max = atomic_exchange(&trace_s[i * 3 + 2], 0);
            if (n > 0 && k < (int)sizeof line) {
                k += snprintf(line + k, sizeof line - (size_t)k, " %s %llux avg %llu \xC2\xB5s max %llu \xC2\xB5s;", names[i],
                              (unsigned long long)n, (unsigned long long)(tot / n), (unsigned long long)max);
            }
        }
        fprintf(stderr, "%s\n", line);
    }
    pthread_mutex_unlock(&trace_lock);
}

/* ---- jobs: from the client threads to the main thread ------------------------------------ */

enum { JOB_ADD_CLIENT, JOB_HANDLE, JOB_GONE, JOB_RETRY };

typedef struct Job {
    int kind;
    uint64_t client;
    int fd;
    int64_t id;
    AukWireMsg msg;
    int64_t t0;
    struct Job *next;
} Job;

static pthread_mutex_t jobs_lock = PTHREAD_MUTEX_INITIALIZER;
static Job *jobs_head;
static Job *jobs_tail;
static void *wake_source;
static void *wake_loop;

static void submit(Job *j) {
    j->next = NULL;
    pthread_mutex_lock(&jobs_lock);
    if (jobs_tail == NULL) {
        jobs_head = j;
    } else {
        jobs_tail->next = j;
    }
    jobs_tail = j;
    pthread_mutex_unlock(&jobs_lock);
    if (wake_source != NULL) {
        sys.source_signal(wake_source);
        sys.wake_up(wake_loop);
    }
}

static Job *new_job(int kind) {
    Job *j = auk__xcalloc(1, sizeof(Job));
    j->kind = kind;
    j->fd = -1;
    return j;
}

/* ---- state (main thread only) ------------------------------------------------------------ */

/* A mapped shared frame buffer: fw×fh 0xffRRGGBB. */
typedef struct HBuf {
    uint32_t *ptr;
    size_t fw;
    size_t fh;
    int fd;
} HBuf;

/* An IOSurface of w×h BGRA pixels (0xffRRGGBB as little-endian u32s). */
typedef struct HSurf {
    void *s;
    size_t w;
    size_t h;
} HSurf;

typedef struct Area {
    size_t x0;
    size_t y0;
    size_t x1;
    size_t y1;
} Area;

typedef struct Areas {
    Area a[9];
    int n;
} Areas;

/* Add r to a list of areas, merging them all into one when the list gets long. */
static void add_area(Areas *v, Area r) {
    v->a[v->n++] = r;
    if (v->n > 8) {
        Area all = r;
        for (int i = 0; i < v->n; i++) {
            Area b = v->a[i];
            all.x0 = b.x0 < all.x0 ? b.x0 : all.x0;
            all.y0 = b.y0 < all.y0 ? b.y0 : all.y0;
            all.x1 = b.x1 > all.x1 ? b.x1 : all.x1;
            all.y1 = b.y1 > all.y1 ? b.y1 : all.y1;
        }
        v->a[0] = all;
        v->n = 1;
    }
}

typedef struct HWin {
    int64_t id;
    Id win;
    Id view;
    char *title;
    /* the client it belongs to, or (as an orphan) the generation of the one it did */
    bool orphan;
    uint64_t owner;
    /* the client's two shared frame buffers, and the one it last presented (-1: none) */
    HBuf bufs[2];
    bool has_buf[2];
    int front;
    /* the view's layer and its two IOSurfaces: the compositor shows one (shown) while a present
     * updates the other, then the layer flips to it */
    Id layer;
    HSurf surfs[2];
    bool has_surfs;
    int shown;
    /* areas the other surface got since this one was last updated: what it lacks */
    Areas stale[2];
    /* areas presented but not shown yet (the back surface was still in use), to copy from the
     * client's latest buffer; and whether a retry is scheduled */
    Areas pending;
    bool retry;
} HWin;

typedef struct HClient {
    uint64_t id;
    int fd;
} HClient;

static HWin *hwins;
static int64_t nhwins;
static int64_t caphwins;
static HClient *clients;
static int64_t nclients;
static int64_t capclients;
static int64_t next_win = 1;
/* one client at a time (fd mode): exit when it leaves */
static bool single_client;

static HWin *hwin(int64_t id) {
    for (int64_t i = 0; i < nhwins; i++) {
        if (hwins[i].id == id) {
            return &hwins[i];
        }
    }
    return NULL;
}

static int64_t view_id(Id view) {
    for (int64_t i = 0; i < nhwins; i++) {
        if (hwins[i].view == view) {
            return hwins[i].id;
        }
    }
    return 0;
}

static int client_fd(uint64_t client) {
    for (int64_t i = 0; i < nclients; i++) {
        if (clients[i].id == client) {
            return clients[i].fd;
        }
    }
    return -1;
}

static void send_to(uint64_t client, uint8_t op, AukWireBuf *b) {
    int fd = client_fd(client);
    if (fd >= 0) {
        auk__wire_send(fd, op, b->sb.buf == NULL ? b->sb.small : b->sb.buf, b->sb.len, -1);
    }
    auk_sb_free(&b->sb);
}

static void reply_err(uint64_t client, const char *msg) {
    AukWireBuf b = {0};
    auk__wire_put_i64(&b, 1);
    auk__wire_put_str(&b, msg, (int64_t)strlen(msg));
    send_to(client, AUK_WIRE_REPLY, &b);
}

static void close_win(int64_t id);

/* Send an event to the window's client (an orphan has none; its close button closes it). */
static void event(int64_t id, const int64_t *ev, int n) {
    HWin *w = hwin(id);
    if (w == NULL) {
        return;
    }
    if (!w->orphan) {
        AukWireBuf b = {0};
        auk__wire_put_i64(&b, id);
        for (int i = 0; i < n; i++) {
            auk__wire_put_i64(&b, ev[i]);
        }
        send_to(w->owner, AUK_WIRE_EVENT, &b);
    } else if (n == 1 && ev[0] == 1) {
        close_win(id);
    }
}

/* ---- surfaces and presenting ------------------------------------------------------------- */

static bool surf_new(size_t w, size_t h, HSurf *out) {
    Id d = m_id(cls("NSMutableDictionary"), "dictionary");
    const char *keys[4] = {"IOSurfaceWidth", "IOSurfaceHeight", "IOSurfaceBytesPerElement", "IOSurfacePixelFormat"};
    int64_t vals[4] = {(int64_t)w, (int64_t)h, 4, 0x42475241};
    for (int i = 0; i < 4; i++) {
        m_void_id_id(d, "setObject:forKey:", m_id_i64(cls("NSNumber"), "numberWithLongLong:", vals[i]), ns_string(keys[i]));
    }
    void *s = sys.surface_create(d);
    if (s == NULL) {
        return false;
    }
    /* the pixels are sRGB, so the compositor converts them for the display */
    const void *cs = sys.color_space_plist(sys.color_space);
    if (cs != NULL) {
        sys.surface_set_value(s, ns_string("IOSurfaceColorSpace"), cs);
        sys.cf_release(cs);
    }
    out->s = s;
    out->w = w;
    out->h = h;
    return true;
}

static void buf_free(HBuf *b) {
    munmap(b->ptr, b->fw * b->fh * 4);
    close(b->fd);
}

static double backing_scale(Id view) {
    Id win = m_id(view, "window");
    return win == NULL ? 1.0 : m_f64(win, "backingScaleFactor");
}

static bool area_inside(Area a, const Areas *v) {
    for (int i = 0; i < v->n; i++) {
        Area r = v->a[i];
        if (a.x0 >= r.x0 && a.y0 >= r.y0 && a.x1 <= r.x1 && a.y1 <= r.y1) {
            return true;
        }
    }
    return false;
}

/* Bring the back surface up to date from the client's latest buffer and flip the layer to it.
 * Returns true if something is still pending because the compositor still had that surface. */
static bool show(int64_t id) {
    int64_t t0 = now_us();
    bool again = false;
    HWin *win = hwin(id);
    if (win == NULL || win->front < 0 || !win->has_buf[win->front]) {
        goto done;
    }
    double scale = backing_scale(win->view);
    win = hwin(id); /* AppKit may have called back into the view */
    if (win == NULL) {
        goto done;
    }
    HBuf *src = &win->bufs[win->front];
    size_t fw = src->fw;
    size_t fh = src->fh;
    /* new surfaces for a new size; they lack everything */
    if (!win->has_surfs || win->surfs[0].w != fw || win->surfs[0].h != fh) {
        HSurf a;
        HSurf b;
        if (!surf_new(fw, fh, &a)) {
            fprintf(stderr, "gui.present: cannot make a %zux%zu surface\n", fw, fh);
            goto done;
        }
        if (!surf_new(fw, fh, &b)) {
            sys.cf_release(a.s);
            fprintf(stderr, "gui.present: cannot make a %zux%zu surface\n", fw, fh);
            goto done;
        }
        if (win->has_surfs) {
            sys.cf_release(win->surfs[0].s);
            sys.cf_release(win->surfs[1].s);
        }
        win->surfs[0] = a;
        win->surfs[1] = b;
        win->has_surfs = true;
        Area all = {0, 0, fw, fh};
        win->stale[0].n = 0;
        win->stale[1].n = 0;
        add_area(&win->stale[0], all);
        add_area(&win->stale[1], all);
        win->pending.n = 0;
        add_area(&win->pending, all);
    }
    if (win->pending.n == 0) {
        goto done;
    }
    int back = 1 - win->shown;
    HSurf *surf = &win->surfs[back];
    /* the compositor keeps the surface it showed last until the next refresh */
    if (sys.surface_in_use(surf->s)) {
        again = true;
        goto done;
    }
    sys.surface_lock(surf->s, 0, NULL);
    uint8_t *base = sys.surface_base(surf->s);
    size_t rb = sys.surface_row_bytes(surf->s);
    for (int i = 0; i < win->stale[back].n; i++) {
        Area a = win->stale[back].a[i];
        if (area_inside(a, &win->pending)) {
            continue;
        }
        for (size_t row = a.y0; row < a.y1; row++) {
            memcpy(base + row * rb + a.x0 * 4, src->ptr + row * fw + a.x0, (a.x1 - a.x0) * 4);
        }
    }
    for (int i = 0; i < win->pending.n; i++) {
        Area a = win->pending.a[i];
        for (size_t row = a.y0; row < a.y1; row++) {
            memcpy(base + row * rb + a.x0 * 4, src->ptr + row * fw + a.x0, (a.x1 - a.x0) * 4);
        }
    }
    sys.surface_unlock(surf->s, 0, NULL);
    win->stale[back].n = 0;
    for (int i = 0; i < win->pending.n; i++) {
        add_area(&win->stale[win->shown], win->pending.a[i]);
    }
    win->pending.n = 0;
    win->shown = back;
    Id layer = win->layer;
    void *contents = surf->s;
    m_void_f64(layer, "setContentsScale:", scale);
    m_void_ptr(layer, "setContents:", contents);
done:
    if (trace_on) {
        trace_add(0, t0);
    }
    return again;
}

static void *retry_thread(void *arg) {
    struct timespec ts = {0, 1000000};
    nanosleep(&ts, NULL);
    Job *j = new_job(JOB_RETRY);
    j->id = (int64_t)(intptr_t)arg;
    submit(j);
    return NULL;
}

/* Try show again shortly (once per window at a time). */
static void schedule_retry(int64_t id) {
    HWin *w = hwin(id);
    if (w == NULL || w->retry) {
        return;
    }
    w->retry = true;
    pthread_t th;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_create(&th, &attr, retry_thread, (void *)(intptr_t)id);
    pthread_attr_destroy(&attr);
}

/* Take a present: remember the area that changed and show it now if the back surface is free,
 * or as soon as it is. Either way the client may write its other buffer at once: from here on
 * this process reads only buffer buf, which the client leaves alone until its next present is
 * answered. NULL, or why not (malloc'd). */
static char *present(uint64_t client, int64_t id, int64_t fw64, int64_t fh64, int64_t buf, const int64_t *rects, int64_t n, int fd) {
    size_t fw = fw64 > 0 ? (size_t)fw64 : 0;
    size_t fh = fh64 > 0 ? (size_t)fh64 : 0;
    size_t len = 0;
    bool len_ok = fw > 0 && fh > 0 && !__builtin_mul_overflow(fw, fh, &len) && !__builtin_mul_overflow(len, (size_t)4, &len);
    if (!len_ok || buf < 0 || buf > 1) {
        if (fd >= 0) {
            close(fd);
        }
        char *e = auk__xmalloc(64);
        snprintf(e, 64, "gui.present: bad frame");
        return e;
    }
    int i = (int)buf;
    HWin *win = hwin(id);
    if (win == NULL || win->orphan || win->owner != client) {
        if (fd >= 0) {
            close(fd);
        }
        char *e = auk__xmalloc(96);
        snprintf(e, 96, "gui.present: window %lld is closed", (long long)id);
        return e;
    }
    if (fd >= 0) {
        void *p = mmap(NULL, len, PROT_READ, MAP_SHARED, fd, 0);
        if (p == MAP_FAILED) {
            int er = errno;
            close(fd);
            char *e = auk__xmalloc(256);
            snprintf(e, 256, "gui.present: cannot map the frame: %s", strerror(er));
            return e;
        }
        if (win->has_buf[i]) {
            buf_free(&win->bufs[i]);
        }
        win->bufs[i].ptr = p;
        win->bufs[i].fw = fw;
        win->bufs[i].fh = fh;
        win->bufs[i].fd = fd;
        win->has_buf[i] = true;
    }
    if (!win->has_buf[i] || win->bufs[i].fw != fw || win->bufs[i].fh != fh) {
        char *e = auk__xmalloc(64);
        snprintf(e, 64, "gui.present: no frame memory of that size");
        return e;
    }
    if (win->front >= 0 && win->has_buf[win->front] && (win->bufs[win->front].fw != fw || win->bufs[win->front].fh != fh)) {
        win->pending.n = 0; /* a new size: the new surfaces get everything anyway */
    }
    win->front = i;
    for (int64_t k = 0; k < n; k++) {
        int64_t x = rects[k * 4];
        int64_t y = rects[k * 4 + 1];
        int64_t w = rects[k * 4 + 2];
        int64_t h = rects[k * 4 + 3];
        int64_t xe = x + w > 0 ? x + w : 0;
        int64_t ye = y + h > 0 ? y + h : 0;
        Area a = {x > 0 ? (size_t)x : 0, y > 0 ? (size_t)y : 0, (size_t)xe < fw ? (size_t)xe : fw, (size_t)ye < fh ? (size_t)ye : fh};
        if (a.x0 < a.x1 && a.y0 < a.y1) {
            add_area(&win->pending, a);
        }
    }
    if (show(id)) {
        schedule_retry(id);
    }
    return NULL;
}

/* Save an image of win as it is on screen to path (a binary PPM), for tests. */
static void snapshot(Id win, const char *path) {
    if (sys.window_image == NULL) {
        fprintf(stderr, "gui: AUK_GUI_SNAP: no CGWindowListCreateImage on this system\n");
        return;
    }
    m_void(cls("CATransaction"), "flush");
    struct timespec ts = {0, 100 * 1000000};
    nanosleep(&ts, NULL);
    uint32_t num = (uint32_t)m_isize(win, "windowNumber");
    HRect null_rect = hrect(INFINITY, INFINITY, 0.0, 0.0);
    /* including only this window, its contents without the frame, at full resolution */
    void *img = sys.window_image(null_rect, 8, num, 1 | 8);
    if (img == NULL) {
        fprintf(stderr, "gui: AUK_GUI_SNAP: could not capture the window\n");
        return;
    }
    size_t w = sys.image_width(img);
    size_t h = sys.image_height(img);
    size_t rb = sys.image_row_bytes(img);
    const void *data = sys.provider_copy_data(sys.image_provider(img));
    if (data != NULL) {
        const uint8_t *p = sys.data_ptr(data);
        FILE *f = fopen(path, "wb");
        if (f != NULL) {
            fprintf(f, "P6\n%zu %zu\n255\n", w, h);
            for (size_t y = 0; y < h; y++) {
                for (size_t x = 0; x < w; x++) {
                    const uint8_t *px = p + y * rb + x * 4;
                    /* BGRA in memory */
                    uint8_t rgb[3] = {px[2], px[1], px[0]};
                    fwrite(rgb, 1, 3, f);
                }
            }
            fclose(f);
        }
        sys.cf_release(data);
    }
    sys.cf_release(img);
}

static void close_win(int64_t id) {
    HWin *w = hwin(id);
    if (w == NULL) {
        return;
    }
    const char *snap = getenv("AUK_GUI_SNAP");
    if (snap != NULL) {
        /* show what's pending first */
        for (int i = 0; i < 50; i++) {
            if (!show(id)) {
                break;
            }
            struct timespec ts = {0, 1000000};
            nanosleep(&ts, NULL);
        }
        w = hwin(id);
        if (w == NULL) {
            return;
        }
    }
    HWin c = *w;
    /* take it off the list before AppKit runs (it may call back into the view) */
    *w = hwins[nhwins - 1];
    nhwins--;
    if (snap != NULL) {
        snapshot(c.win, snap);
    }
    m_void_id(c.win, "setDelegate:", NULL);
    m_void(c.win, "close");
    m_void(c.win, "release");
    m_void(c.view, "release");
    m_void(c.layer, "release");
    for (int i = 0; i < 2; i++) {
        if (c.has_buf[i]) {
            buf_free(&c.bufs[i]);
        }
    }
    if (c.has_surfs) {
        sys.cf_release(c.surfs[0].s);
        sys.cf_release(c.surfs[1].s);
    }
    free(c.title);
}

/* ---- the view class: draws the window's buffer, reports input --------------------------- */

static Class view_class(void);

/* Shift, Control, Option, Command as bits 1, 2, 4, 8. */
static int64_t mods(Id ev) {
    uintptr_t f = m_usize(ev, "modifierFlags");
    int64_t m = 0;
    if ((f & (1u << 17)) != 0) {
        m |= 1;
    }
    if ((f & (1u << 18)) != 0) {
        m |= 2;
    }
    if ((f & (1u << 19)) != 0) {
        m |= 4;
    }
    if ((f & (1u << 20)) != 0) {
        m |= 8;
    }
    return m;
}

/* Content size in physical pixels, and the scale. */
static void metrics(Id view, int64_t *w, int64_t *h, double *scale) {
    if (view == NULL) {
        *w = 0;
        *h = 0;
        *scale = 1.0;
        return;
    }
    HRect r = m_rect(view, "bounds");
    *scale = backing_scale(view);
    *w = (int64_t)round(r.s.w * *scale);
    *h = (int64_t)round(r.s.h * *scale);
}

/* Where the mouse is, in physical pixels from the content's top-left. */
static void location(Id view, Id ev, int64_t *x, int64_t *y) {
    HPoint p = m_point(ev, "locationInWindow");
    p = m_point_convert(view, p, NULL);
    double scale = backing_scale(view);
    *x = (int64_t)floor(p.x * scale);
    *y = (int64_t)floor(p.y * scale);
}

static bool v_yes(Id self, Sel cmd) {
    (void)self;
    (void)cmd;
    return true;
}

static bool v_yes1(Id self, Sel cmd, Id a) {
    (void)self;
    (void)cmd;
    (void)a;
    return true;
}

static void v_mouse_down(Id self, Sel cmd, Id ev) {
    (void)cmd;
    int64_t id = view_id(self);
    if (id != 0) {
        int64_t x;
        int64_t y;
        location(self, ev, &x, &y);
        int64_t e[5] = {4, (int64_t)m_isize(ev, "buttonNumber"), x, y, mods(ev)};
        event(id, e, 5);
    }
}

static void v_mouse_up(Id self, Sel cmd, Id ev) {
    (void)cmd;
    int64_t id = view_id(self);
    if (id != 0) {
        int64_t x;
        int64_t y;
        location(self, ev, &x, &y);
        int64_t e[5] = {5, (int64_t)m_isize(ev, "buttonNumber"), x, y, mods(ev)};
        event(id, e, 5);
    }
}

static void v_mouse_moved(Id self, Sel cmd, Id ev) {
    (void)cmd;
    int64_t id = view_id(self);
    if (id != 0) {
        int64_t x;
        int64_t y;
        location(self, ev, &x, &y);
        int64_t e[3] = {3, x, y};
        event(id, e, 3);
    }
}

static void v_scroll(Id self, Sel cmd, Id ev) {
    (void)cmd;
    int64_t id = view_id(self);
    if (id != 0) {
        double dx = m_f64(ev, "scrollingDeltaX");
        double dy = m_f64(ev, "scrollingDeltaY");
        if (!m_bool(ev, "hasPreciseScrollingDeltas")) {
            /* a wheel's notches: about a line each */
            dx *= 16.0;
            dy *= 16.0;
        }
        double scale = backing_scale(self);
        int64_t e[3] = {6, (int64_t)(dx * scale * 100.0), (int64_t)(dy * scale * 100.0)};
        event(id, e, 3);
    }
}

/* Decode the UTF-8 char at s (valid text); *len gets its length. */
static uint32_t decode_char(const uint8_t *s, int *len) {
    if (s[0] < 0x80) {
        *len = 1;
        return s[0];
    }
    if (s[0] < 0xE0) {
        *len = 2;
        return ((uint32_t)(s[0] & 0x1F) << 6) | (s[1] & 0x3F);
    }
    if (s[0] < 0xF0) {
        *len = 3;
        return ((uint32_t)(s[0] & 0x0F) << 12) | ((uint32_t)(s[1] & 0x3F) << 6) | (s[2] & 0x3F);
    }
    *len = 4;
    return ((uint32_t)(s[0] & 0x07) << 18) | ((uint32_t)(s[1] & 0x3F) << 12) | ((uint32_t)(s[2] & 0x3F) << 6) | (s[3] & 0x3F);
}

static void v_key_down(Id self, Sel cmd, Id ev) {
    (void)cmd;
    int64_t id = view_id(self);
    if (id == 0) {
        return;
    }
    int64_t m = mods(ev);
    int64_t e[4] = {7, (int64_t)m_u16(ev, "keyCode"), m, m_bool(ev, "isARepeat") ? 1 : 0};
    event(id, e, 4);
    /* typed text: not with Control or Command, and not control characters or the function keys'
     * private-use characters (arrows, F1...) */
    if ((m & (2 | 8)) != 0) {
        return;
    }
    Id chars = m_id(ev, "characters");
    const uint8_t *s = chars == NULL ? NULL : (const uint8_t *)m_cstr(chars, "UTF8String");
    if (s == NULL) {
        return;
    }
    size_t n = strlen((const char *)s);
    int64_t *text = auk__xmalloc((n + 2) * sizeof(int64_t));
    int64_t k = 0;
    text[k++] = 9;
    for (size_t i = 0; i < n;) {
        int len;
        uint32_t c = decode_char(s + i, &len);
        if (c >= ' ' && c != 0x7f && !(c >= 0xf700 && c <= 0xf8ff)) {
            for (int b = 0; b < len; b++) {
                text[k++] = s[i + b];
            }
        }
        i += (size_t)len;
    }
    if (k > 1) {
        event(id, text, (int)k);
    }
    free(text);
}

static void v_key_up(Id self, Sel cmd, Id ev) {
    (void)cmd;
    int64_t id = view_id(self);
    if (id != 0) {
        int64_t e[3] = {8, (int64_t)m_u16(ev, "keyCode"), mods(ev)};
        event(id, e, 3);
    }
}

/* The close button asks; the program decides (by calling gui.close). */
static bool v_should_close(Id self, Sel cmd, Id sender) {
    (void)cmd;
    (void)sender;
    int64_t id = view_id(self);
    if (id != 0) {
        int64_t e[1] = {1};
        event(id, e, 1);
    }
    return false;
}

static void v_quit(Id self, Sel cmd, Id sender) {
    (void)self;
    (void)cmd;
    (void)sender;
    int64_t n = nhwins;
    int64_t *ids = auk__xmalloc((size_t)(n + 1) * sizeof(int64_t));
    for (int64_t i = 0; i < n; i++) {
        ids[i] = hwins[i].id;
    }
    for (int64_t i = 0; i < n; i++) {
        int64_t e[1] = {1};
        event(ids[i], e, 1);
    }
    free(ids);
}

static void v_did_resize(Id self, Sel cmd, Id note) {
    (void)cmd;
    (void)note;
    int64_t id = view_id(self);
    if (id == 0) {
        return;
    }
    int64_t w;
    int64_t h;
    double scale;
    metrics(self, &w, &h, &scale);
    HWin *win = hwin(id);
    if (win != NULL && !win->orphan) {
        AukWireBuf b = {0};
        auk__wire_put_i64(&b, id);
        auk__wire_put_i64(&b, w);
        auk__wire_put_i64(&b, h);
        auk__wire_put_f64(&b, scale);
        send_to(win->owner, AUK_WIRE_METRICS, &b);
        int64_t e[3] = {2, w, h};
        event(id, e, 3);
    }
}

static void v_did_become_key(Id self, Sel cmd, Id note) {
    (void)cmd;
    (void)note;
    int64_t id = view_id(self);
    if (id != 0) {
        int64_t e[2] = {10, 1};
        event(id, e, 2);
    }
}

static void v_did_resign_key(Id self, Sel cmd, Id note) {
    (void)cmd;
    (void)note;
    int64_t id = view_id(self);
    if (id != 0) {
        int64_t e[2] = {10, 0};
        event(id, e, 2);
    }
}

static Class the_view_class;

static Class view_class(void) {
    if (the_view_class != NULL) {
        return the_view_class;
    }
    Class c = sys.alloc_class_pair(cls("NSView"), "AukGuiView", 0);
    sys.add_method(c, sel("isFlipped"), (const void *)v_yes, "B@:");
    sys.add_method(c, sel("isOpaque"), (const void *)v_yes, "B@:");
    sys.add_method(c, sel("acceptsFirstResponder"), (const void *)v_yes, "B@:");
    sys.add_method(c, sel("acceptsFirstMouse:"), (const void *)v_yes1, "B@:@");
    const char *downs[3] = {"mouseDown:", "rightMouseDown:", "otherMouseDown:"};
    const char *ups[3] = {"mouseUp:", "rightMouseUp:", "otherMouseUp:"};
    for (int i = 0; i < 3; i++) {
        sys.add_method(c, sel(downs[i]), (const void *)v_mouse_down, "v@:@");
        sys.add_method(c, sel(ups[i]), (const void *)v_mouse_up, "v@:@");
    }
    const char *moves[4] = {"mouseMoved:", "mouseDragged:", "rightMouseDragged:", "otherMouseDragged:"};
    for (int i = 0; i < 4; i++) {
        sys.add_method(c, sel(moves[i]), (const void *)v_mouse_moved, "v@:@");
    }
    sys.add_method(c, sel("scrollWheel:"), (const void *)v_scroll, "v@:@");
    sys.add_method(c, sel("keyDown:"), (const void *)v_key_down, "v@:@");
    sys.add_method(c, sel("keyUp:"), (const void *)v_key_up, "v@:@");
    sys.add_method(c, sel("windowShouldClose:"), (const void *)v_should_close, "B@:@");
    sys.add_method(c, sel("windowDidResize:"), (const void *)v_did_resize, "v@:@");
    sys.add_method(c, sel("windowDidChangeBackingProperties:"), (const void *)v_did_resize, "v@:@");
    sys.add_method(c, sel("windowDidBecomeKey:"), (const void *)v_did_become_key, "v@:@");
    sys.add_method(c, sel("windowDidResignKey:"), (const void *)v_did_resign_key, "v@:@");
    sys.add_method(c, sel("aukQuit:"), (const void *)v_quit, "v@:@");
    sys.register_class_pair(c);
    the_view_class = c;
    return c;
}

/* ---- windows ----------------------------------------------------------------------------- */

/* A new window for client: its id, or 0 with *err (static text). */
static int64_t new_window(uint64_t client, const char *title, int64_t w, int64_t h, const char **err) {
    HRect r = hrect(0.0, 0.0, (double)w, (double)h);
    /* titled, closable, miniaturizable, resizable; buffered backing */
    Id win = m_window_init(m_id(cls("NSWindow"), "alloc"), r, 15, 2, false);
    if (win == NULL) {
        *err = "gui.open: AppKit could not create a window";
        return 0;
    }
    m_void_bool(win, "setReleasedWhenClosed:", false);
    Id view = m_id_rect(m_id(view_class(), "alloc"), "initWithFrame:", r);
    /* a layer-hosting view: AppKit leaves the layer's contents to us, and the compositor shows
     * an IOSurface straight from them */
    Id layer = m_id(m_id(cls("CALayer"), "alloc"), "init");
    m_void_id(layer, "setContentsGravity:", ns_string("topLeft"));
    m_void_bool(layer, "setOpaque:", true);
    Id white = m_id(cls("NSColor"), "whiteColor");
    m_void_ptr(layer, "setBackgroundColor:", m_ptr(white, "CGColor"));
    /* no fade when the contents change */
    Id none = m_id(cls("NSNull"), "null");
    Id actions = m_id(cls("NSMutableDictionary"), "dictionary");
    const char *keys[4] = {"contents", "contentsScale", "bounds", "position"};
    for (int i = 0; i < 4; i++) {
        m_void_id_id(actions, "setObject:forKey:", none, ns_string(keys[i]));
    }
    m_void_id(layer, "setActions:", actions);
    m_void_id(view, "setLayer:", layer);
    m_void_bool(view, "setWantsLayer:", true);
    if (nhwins == caphwins) {
        caphwins = caphwins == 0 ? 4 : caphwins * 2;
        hwins = auk__xrealloc(hwins, (size_t)caphwins * sizeof(HWin));
    }
    HWin *hw = &hwins[nhwins++];
    memset(hw, 0, sizeof *hw);
    int64_t id = next_win++;
    hw->id = id;
    hw->win = win;
    hw->view = view;
    size_t tn = strlen(title);
    hw->title = auk__xmalloc(tn + 1);
    memcpy(hw->title, title, tn + 1);
    hw->owner = client;
    hw->front = -1;
    hw->layer = layer;
    m_void_id(win, "setContentView:", view);
    m_void_id(win, "setDelegate:", view);
    m_void_bool(win, "setAcceptsMouseMovedEvents:", true);
    m_void_id(win, "setTitle:", ns_string(title));
    m_void(win, "center");
    m_void_id(win, "makeKeyAndOrderFront:", NULL);
    m_bool_id(win, "makeFirstResponder:", view);
    m_void_bool(app(), "activateIgnoringOtherApps:", true);
    return id;
}

static void open_win(uint64_t client, const char *title, int64_t w, int64_t h) {
    /* take over an orphan with this title (the program was restarted by `auk run --live`) */
    int64_t adopt = 0;
    for (int64_t i = 0; i < nhwins; i++) {
        if (hwins[i].orphan && strcmp(hwins[i].title, title) == 0 && (adopt == 0 || hwins[i].id < adopt)) {
            adopt = hwins[i].id;
        }
    }
    int64_t id = adopt;
    if (adopt != 0) {
        /* it keeps showing the old program's last frame until the new one presents */
        HWin *x = hwin(adopt);
        x->orphan = false;
        x->owner = client;
    } else {
        const char *err = NULL;
        id = new_window(client, title, w, h, &err);
        if (id == 0) {
            reply_err(client, err);
            return;
        }
    }
    HWin *x = hwin(id);
    Id view = x == NULL ? NULL : x->view;
    int64_t pw;
    int64_t ph;
    double scale;
    metrics(view, &pw, &ph, &scale);
    AukWireBuf b = {0};
    auk__wire_put_i64(&b, 0);
    auk__wire_put_i64(&b, id);
    auk__wire_put_i64(&b, pw);
    auk__wire_put_i64(&b, ph);
    auk__wire_put_f64(&b, scale);
    send_to(client, AUK_WIRE_REPLY, &b);
    if (adopt != 0 && view != NULL) {
        Id win = m_id(view, "window");
        m_void_id(win, "makeKeyAndOrderFront:", NULL);
    }
}

/* A client left: with bye, its windows close; without, they become orphans. Orphans of earlier
 * clients close either way: this client had its chance to take them over. */
static void gone(uint64_t client, bool bye) {
    int fd = client_fd(client);
    if (fd < 0) {
        return;
    }
    if (single_client) {
        _exit(0);
    }
    int64_t k = 0;
    for (int64_t i = 0; i < nclients; i++) {
        if (clients[i].id != client) {
            clients[k++] = clients[i];
        }
    }
    nclients = k;
    int64_t *close_ids = auk__xmalloc((size_t)(nhwins + 1) * sizeof(int64_t));
    int64_t nc = 0;
    for (int64_t i = 0; i < nhwins; i++) {
        HWin *w = &hwins[i];
        if (!w->orphan && w->owner == client) {
            if (bye) {
                close_ids[nc++] = w->id;
            } else {
                w->orphan = true;
            }
        } else if (w->orphan && w->owner < client) {
            close_ids[nc++] = w->id;
        }
    }
    shutdown(fd, SHUT_RDWR);
    close(fd);
    for (int64_t i = 0; i < nc; i++) {
        close_win(close_ids[i]);
    }
    free(close_ids);
}

static void handle(uint64_t client, AukWireMsg *m) {
    AukWireReader *r = &m->r;
    if (m->op == AUK_WIRE_OPEN) {
        int64_t w = auk__wire_i64(r);
        int64_t h = auk__wire_i64(r);
        int64_t n = r->i < r->n ? r->n - r->i : 0;
        char *title = auk__xmalloc((size_t)n + 1);
        memcpy(title, r->b + (r->i < r->n ? r->i : r->n), (size_t)n);
        title[n] = 0;
        /* invalid UTF-8 shown repaired, as the Rust host's lossy text did */
        AukStr *t = auk_str_from_bytes(title, n);
        open_win(client, auk_str_cstr(t), w, h);
        auk_release(t);
        free(title);
    } else if (m->op == AUK_WIRE_CLOSE) {
        int64_t id = auk__wire_i64(r);
        HWin *w = hwin(id);
        if (w != NULL && !w->orphan && w->owner == client) {
            close_win(id);
        }
    } else if (m->op == AUK_WIRE_PRESENT) {
        int64_t id = auk__wire_i64(r);
        int64_t fw = auk__wire_i64(r);
        int64_t fh = auk__wire_i64(r);
        int64_t buf = auk__wire_i64(r);
        int64_t seq = auk__wire_i64(r);
        int64_t n = auk__wire_i64(r);
        n = n < 0 ? 0 : (n > 4096 ? 4096 : n);
        int64_t *rects = auk__xmalloc((size_t)(n * 4 + 1) * sizeof(int64_t));
        for (int64_t k = 0; k < n * 4; k++) {
            rects[k] = auk__wire_i64(r);
        }
        char *err = present(client, id, fw, fh, buf, rects, n, m->fd);
        m->fd = -1; /* present took it */
        free(rects);
        AukWireBuf b = {0};
        auk__wire_put_i64(&b, id);
        auk__wire_put_i64(&b, seq);
        auk__wire_put_i64(&b, err == NULL ? 0 : 1);
        if (err != NULL) {
            auk__wire_put_str(&b, err, (int64_t)strlen(err));
            free(err);
        }
        send_to(client, AUK_WIRE_PRESENTED, &b);
    } else if (m->op == AUK_WIRE_BYE) {
        gone(client, true);
    }
    if (m->fd >= 0) {
        close(m->fd);
    }
}

static void run_jobs(void *info) {
    (void)info;
    for (;;) {
        pthread_mutex_lock(&jobs_lock);
        Job *j = jobs_head;
        if (j != NULL) {
            jobs_head = j->next;
            if (jobs_head == NULL) {
                jobs_tail = NULL;
            }
        }
        pthread_mutex_unlock(&jobs_lock);
        if (j == NULL) {
            return;
        }
        void *pool = sys.pool_push();
        if (j->kind == JOB_ADD_CLIENT) {
            if (nclients == capclients) {
                capclients = capclients == 0 ? 4 : capclients * 2;
                clients = auk__xrealloc(clients, (size_t)capclients * sizeof(HClient));
            }
            clients[nclients].id = j->client;
            clients[nclients].fd = j->fd;
            nclients++;
        } else if (j->kind == JOB_HANDLE) {
            if (trace_on) {
                trace_add(1, j->t0);
            }
            int64_t t1 = now_us();
            handle(j->client, &j->msg);
            free(j->msg.body);
            if (trace_on) {
                trace_add(2, t1);
            }
        } else if (j->kind == JOB_GONE) {
            gone(j->client, false);
        } else if (j->kind == JOB_RETRY) {
            HWin *w = hwin(j->id);
            if (w != NULL) {
                w->retry = false;
            }
            if (show(j->id)) {
                schedule_retry(j->id);
            }
        }
        sys.pool_pop(pool);
        free(j);
    }
}

/* ---- running ----------------------------------------------------------------------------- */

static _Atomic uint64_t next_client = 1;

/* A client's requests, read on a thread of its own and run on the main thread. */
static void *client_reader(void *arg) {
    Job *add = arg;
    int fd = add->fd;
    uint64_t id = add->client;
    submit(add);
    for (;;) {
        Job *j = new_job(JOB_HANDLE);
        if (auk__wire_recv(fd, &j->msg) <= 0) {
            free(j);
            break;
        }
        j->client = id;
        j->t0 = now_us();
        submit(j);
    }
    Job *g = new_job(JOB_GONE);
    g->client = id;
    submit(g);
    return NULL;
}

static void add_client(int fd) {
    auk__wire_no_sigpipe(fd);
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    Job *j = new_job(JOB_ADD_CLIENT);
    j->client = atomic_fetch_add(&next_client, 1);
    j->fd = fd;
    pthread_t th;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_create(&th, &attr, client_reader, j);
    pthread_attr_destroy(&attr);
}

static char *listen_path;
static int listen_owner;
static int listen_fd = -1;

static void *owner_watch(void *arg) {
    (void)arg;
    for (;;) {
        struct timespec ts = {0, 300 * 1000000};
        nanosleep(&ts, NULL);
        if (listen_owner <= 0 || kill(listen_owner, 0) != 0) {
            unlink(listen_path);
            _exit(0);
        }
    }
    return NULL;
}

static void *accept_loop(void *arg) {
    (void)arg;
    for (;;) {
        int c = accept(listen_fd, NULL, NULL);
        if (c >= 0) {
            add_client(c);
        }
    }
    return NULL;
}

static void spawn_detached(void *(*f)(void *)) {
    pthread_t th;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_create(&th, &attr, f, NULL);
    pthread_attr_destroy(&attr);
}

/* Accept clients on path; exit once the live parent (AUK_GUI_OWNER) is gone. NULL, or why not
 * (malloc'd). */
static char *listen_on(const char *path) {
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof addr);
    size_t n = strlen(path);
    if (n >= sizeof addr.sun_path) {
        char *e = auk__xmalloc(n + 64);
        snprintf(e, n + 64, "gui host: socket path too long: %s", path);
        return e;
    }
    addr.sun_family = AF_UNIX;
    memcpy(addr.sun_path, path, n);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    unlink(path);
    if (fd < 0 || bind(fd, (struct sockaddr *)&addr, sizeof addr) != 0 || listen(fd, 8) != 0) {
        char *e = auk__xmalloc(n + 256);
        snprintf(e, n + 256, "gui host: cannot listen on %s: %s", path, strerror(errno));
        return e;
    }
    listen_fd = fd;
    listen_path = auk__xmalloc(n + 1);
    memcpy(listen_path, path, n + 1);
    const char *o = getenv("AUK_GUI_OWNER");
    char *end = NULL;
    long v = o == NULL ? 0 : strtol(o, &end, 10);
    listen_owner = o != NULL && end != o && *end == 0 && v > 0 && v <= INT32_MAX ? (int)v : 0;
    spawn_detached(owner_watch);
    spawn_detached(accept_loop);
    return NULL;
}

/* A menu bar with the application menu's Quit (⌘Q). Quitting asks every window to close (a
 * Close event each) rather than ending anything: the program decides. */
static void menu(Id nsapp) {
    Id bar = m_id(m_id(cls("NSMenu"), "new"), "autorelease");
    Id item = m_id(m_id(cls("NSMenuItem"), "new"), "autorelease");
    m_void_id(bar, "addItem:", item);
    Id app_menu = m_id(m_id(cls("NSMenu"), "new"), "autorelease");
    Id quit = m_menu_item_init(m_id(cls("NSMenuItem"), "alloc"), ns_string("Quit"), sel("aukQuit:"), ns_string("q"));
    Id target = m_id(m_id(view_class(), "alloc"), "init");
    m_void_id(quit, "setTarget:", target);
    m_void_id(app_menu, "addItem:", m_id(quit, "autorelease"));
    m_void_id(item, "setSubmenu:", app_menu);
    m_void_id(nsapp, "setMainMenu:", bar);
}

static void start_app(void) {
    Id nsapp = app();
    m_bool_isize(nsapp, "setActivationPolicy:", 0); /* regular: a dock icon and a menu bar */
    menu(nsapp);
    SourceContext ctx;
    memset(&ctx, 0, sizeof ctx);
    ctx.perform = run_jobs;
    void *source = sys.source_create(NULL, 0, &ctx);
    void *loop = sys.run_loop_main();
    sys.add_source(loop, source, sys.common_modes);
    wake_loop = loop;
    wake_source = source;
}

static int host_run(const char *spec) {
    const char *t = getenv("AUK_GUI_TRACE");
    trace_on = t != NULL && strcmp(t, "1") == 0;
    char *err = load_sys();
    if (err != NULL) {
        fprintf(stderr, "%s\n", err);
        free(err);
        return 1;
    }
    start_app();
    if (strncmp(spec, "fd:", 3) == 0) {
        char *end = NULL;
        long fd = strtol(spec + 3, &end, 10);
        if (end == spec + 3 || *end != 0 || fd < 0 || fd > INT32_MAX) {
            fprintf(stderr, "gui host: bad AUK_GUI_HOST=%s\n", spec);
            return 1;
        }
        single_client = true;
        add_client((int)fd);
    } else if (strncmp(spec, "listen:", 7) == 0) {
        err = listen_on(spec + 7);
        if (err != NULL) {
            fprintf(stderr, "%s\n", err);
            free(err);
            return 1;
        }
    } else {
        fprintf(stderr, "gui host: bad AUK_GUI_HOST=%s\n", spec);
        return 1;
    }
    m_void(app(), "run");
    return 0;
}
#endif

/* Run the window process. Returns an exit code only if it can't start. */
int auk__gui_host_main(void) {
    const char *v = getenv("AUK_GUI_HOST");
    size_t n = v == NULL ? 0 : strlen(v);
    char *spec = auk__xmalloc(n + 1);
    if (n > 0) {
        memcpy(spec, v, n);
    }
    spec[n] = 0;
    unsetenv("AUK_GUI_HOST");
#if defined(__APPLE__)
    int r = host_run(spec);
#else
    fprintf(stderr, "gui: windows are only supported on macOS so far\n");
    int r = 1;
#endif
    free(spec);
    return r;
}
