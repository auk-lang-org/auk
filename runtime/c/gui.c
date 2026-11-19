/* Windows (`uses gui`): open native windows, show pixels drawn by Auk code, and read input.
 * (Drawing into a frame natively is the pure pixels module, pixels.c.)
 *
 * A separate window process. The program never loads a window system itself. The first
 * gui.open starts a host: this same executable run again (posix_spawn, a fresh exec) with
 * AUK_GUI_HOST set, which owns every native window (gui_host). The two talk over a Unix socket
 * (the wire protocol below), and pixels go through shared memory. This keeps Apple's frameworks
 * out of processes that were forked without exec, as `auk run --live` children are (they don't
 * support that), and leaves the program's main thread alone.
 *
 * - Normally the host is the program's own child, on a socket pair, and it exits (closing the
 *   windows) when the program ends.
 * - Under `auk run --live`, the parent sets AUK_GUI_SESSION to a socket path. The first child
 *   starts a host listening there, and later children (after a restart) connect to the same
 *   host. A child that ends without saying goodbye (killed for a restart, or crashed) leaves its
 *   windows open, and the next child's gui.open with the same title takes over the window. A
 *   child that returns normally says goodbye (auk_gui_shutdown) and its windows close.
 *
 * A window is an int id (the host's), so it can be copied between tasks. A reader thread queues
 * each window's events, which next_event takes.
 *
 * Wire protocol: a message is a u32 length (of what follows), an op byte, then fields: i64/f64
 * little-endian and a string as the rest of the message. A file descriptor can ride along
 * (SCM_RIGHTS) with the first bytes of a message. The ops are in auk_rt.h (AUK_WIRE_*). */
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <mach-o/dyld.h>
#endif

#include "auk_rt.h"

extern char **environ;

/* ---- the wire protocol ------------------------------------------------------------------- */

void auk__wire_put_i64(AukWireBuf *b, int64_t v) {
    uint8_t le[8];
    for (int i = 0; i < 8; i++) {
        le[i] = (uint8_t)((uint64_t)v >> (8 * i));
    }
    auk__sb_put(&b->sb, le, 8);
}

void auk__wire_put_f64(AukWireBuf *b, double v) {
    auk__wire_put_i64(b, auk_fbits(v));
}

void auk__wire_put_str(AukWireBuf *b, const char *s, int64_t n) {
    auk__sb_put(&b->sb, s, n);
}

/* The next i64 of a message (0 past the end). */
int64_t auk__wire_i64(AukWireReader *r) {
    int64_t v = 0;
    if (r->i + 8 <= r->n) {
        uint64_t u = 0;
        for (int k = 0; k < 8; k++) {
            u |= (uint64_t)r->b[r->i + k] << (8 * k);
        }
        v = (int64_t)u;
    }
    r->i += 8;
    return v;
}

double auk__wire_f64(AukWireReader *r) {
    return auk_ffrom_bits(auk__wire_i64(r));
}

/* Don't die of SIGPIPE when the other side has gone; get EPIPE instead. */
void auk__wire_no_sigpipe(int fd) {
#if defined(SO_NOSIGPIPE)
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#else
    (void)fd;
#endif
}

/* Send one message, with pass (an fd, or -1) attached to its first bytes; 0 or an errno. */
int auk__wire_send(int fd, uint8_t op, const uint8_t *body, int64_t n, int pass) {
    size_t total = (size_t)n + 5;
    uint8_t *buf = auk__xmalloc(total);
    uint32_t len = (uint32_t)(n + 1);
    for (int i = 0; i < 4; i++) {
        buf[i] = (uint8_t)(len >> (8 * i));
    }
    buf[4] = op;
    if (n > 0) {
        memcpy(buf + 5, body, (size_t)n);
    }
    size_t off = 0;
    int err = 0;
    while (off < total) {
        struct iovec iov = {buf + off, total - off};
        struct msghdr msg;
        memset(&msg, 0, sizeof msg);
        msg.msg_iov = &iov;
        msg.msg_iovlen = 1;
        union {
            struct cmsghdr h;
            uint8_t b[CMSG_SPACE(sizeof(int))];
        } cbuf;
        if (pass >= 0) {
            memset(&cbuf, 0, sizeof cbuf);
            msg.msg_control = cbuf.b;
            msg.msg_controllen = CMSG_SPACE(sizeof(int));
            struct cmsghdr *c = CMSG_FIRSTHDR(&msg);
            c->cmsg_level = SOL_SOCKET;
            c->cmsg_type = SCM_RIGHTS;
            c->cmsg_len = CMSG_LEN(sizeof(int));
            memcpy(CMSG_DATA(c), &pass, sizeof(int));
        }
        ssize_t w = sendmsg(fd, &msg, 0);
        if (w < 0) {
            if (errno == EINTR) {
                continue;
            }
            err = errno;
            break;
        }
        pass = -1;
        off += (size_t)w;
    }
    free(buf);
    return err;
}

/* Read exactly n bytes, picking up an fd if one comes (into *got_fd, closing an earlier one):
 * 1, 0 on EOF at the very start, or -1 (errno set). */
static int read_full(int fd, uint8_t *buf, size_t n, int *got_fd) {
    size_t off = 0;
    while (off < n) {
        struct iovec iov = {buf + off, n - off};
        struct msghdr msg;
        memset(&msg, 0, sizeof msg);
        msg.msg_iov = &iov;
        msg.msg_iovlen = 1;
        union {
            struct cmsghdr h;
            uint8_t b[64];
        } cbuf;
        msg.msg_control = cbuf.b;
        msg.msg_controllen = sizeof cbuf.b;
        ssize_t r = recvmsg(fd, &msg, 0);
        if (r > 0 && msg.msg_controllen >= sizeof(struct cmsghdr)) {
            struct cmsghdr *c = CMSG_FIRSTHDR(&msg);
            if (c != NULL && c->cmsg_level == SOL_SOCKET && c->cmsg_type == SCM_RIGHTS) {
                int p;
                memcpy(&p, CMSG_DATA(c), sizeof(int));
                if (*got_fd >= 0) {
                    close(*got_fd);
                }
                *got_fd = p;
            }
        }
        if (r == 0) {
            if (off == 0) {
                return 0;
            }
            errno = EPIPE;
            return -1;
        }
        if (r < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        off += (size_t)r;
    }
    return 1;
}

/* The next message into *m (its body malloc'd): 1, 0 at EOF, or -1. */
int auk__wire_recv(int fd, AukWireMsg *m) {
    m->fd = -1;
    uint8_t len[4];
    int r = read_full(fd, len, 4, &m->fd);
    if (r <= 0) {
        return r;
    }
    uint32_t n = (uint32_t)len[0] | (uint32_t)len[1] << 8 | (uint32_t)len[2] << 16 | (uint32_t)len[3] << 24;
    if (n == 0 || n > (64u << 20)) {
        errno = EINVAL;
        return -1;
    }
    uint8_t *body = auk__xmalloc(n);
    r = read_full(fd, body, n, &m->fd);
    if (r <= 0) {
        free(body);
        return -1;
    }
    m->op = body[0];
    m->body = body;
    m->n = n;
    /* the fields start after the op byte */
    m->r.b = body + 1;
    m->r.n = (int64_t)n - 1;
    m->r.i = 0;
    return 1;
}

/* ---- windows and their events (the client side) ------------------------------------------ */

typedef struct Event {
    int64_t *v;
    int64_t n;
} Event;

typedef struct Win {
    int64_t id;
    /* a ring of queued events */
    Event *events;
    int64_t head;
    int64_t len;
    int64_t cap;
    /* content size in physical pixels */
    int64_t w;
    int64_t h;
    double scale;
} Win;

static pthread_mutex_t wins_lock = PTHREAD_MUTEX_INITIALIZER;
/* signalled whenever an event is queued or a window closes */
static pthread_cond_t ev_cv = PTHREAD_COND_INITIALIZER;
static Win *wins;
static int64_t nwins;
static int64_t capwins;
/* closed by this program: the host's late events for them are dropped */
static int64_t *closed_ids;
static int64_t nclosed;
static int64_t capclosed;

static Win *win_find(int64_t id) {
    for (int64_t i = 0; i < nwins; i++) {
        if (wins[i].id == id) {
            return &wins[i];
        }
    }
    return NULL;
}

static bool is_closed(int64_t id) {
    for (int64_t i = 0; i < nclosed; i++) {
        if (closed_ids[i] == id) {
            return true;
        }
    }
    return false;
}

static void closed_add(int64_t id) {
    if (is_closed(id)) {
        return;
    }
    if (nclosed == capclosed) {
        capclosed = capclosed == 0 ? 8 : capclosed * 2;
        closed_ids = auk__xrealloc(closed_ids, (size_t)capclosed * sizeof(int64_t));
    }
    closed_ids[nclosed++] = id;
}

/* (gui_reader, closed_remove, bufs_find: macOS only; gui.open fails elsewhere) */
static __attribute__((unused)) void closed_remove(int64_t id) {
    int64_t k = 0;
    for (int64_t i = 0; i < nclosed; i++) {
        if (closed_ids[i] != id) {
            closed_ids[k++] = closed_ids[i];
        }
    }
    nclosed = k;
}

static void win_free_events(Win *w) {
    for (int64_t i = 0; i < w->len; i++) {
        free(w->events[(w->head + i) % w->cap].v);
    }
    free(w->events);
}

static void win_remove(int64_t id) {
    int64_t k = 0;
    for (int64_t i = 0; i < nwins; i++) {
        if (wins[i].id == id) {
            win_free_events(&wins[i]);
        } else {
            wins[k++] = wins[i];
        }
    }
    nwins = k;
}

/* The window's entry, made if it is new (NULL for a window this program closed; wins_lock
 * held). */
static Win *win_entry(int64_t id) {
    if (is_closed(id)) {
        return NULL;
    }
    Win *w = win_find(id);
    if (w != NULL) {
        return w;
    }
    if (nwins == capwins) {
        capwins = capwins == 0 ? 4 : capwins * 2;
        wins = auk__xrealloc(wins, (size_t)capwins * sizeof(Win));
    }
    w = &wins[nwins++];
    memset(w, 0, sizeof *w);
    w->id = id;
    w->scale = 1.0;
    return w;
}

/* Queue an event (from the host; v is taken). A burst of motion or resizing only keeps its
 * latest. */
static void push_event(int64_t id, int64_t *v, int64_t n) {
    pthread_mutex_lock(&wins_lock);
    Win *w = win_entry(id);
    if (w == NULL) {
        free(v);
    } else {
        if (n > 0 && (v[0] == 2 || v[0] == 3) && w->len > 0) {
            Event *last = &w->events[(w->head + w->len - 1) % w->cap];
            if (last->n > 0 && last->v[0] == v[0]) {
                free(last->v);
                w->len--;
            }
        }
        if (w->len == w->cap) {
            int64_t cap = w->cap == 0 ? 16 : w->cap * 2;
            Event *evs = auk__xmalloc((size_t)cap * sizeof(Event));
            for (int64_t i = 0; i < w->len; i++) {
                evs[i] = w->events[(w->head + i) % w->cap];
            }
            free(w->events);
            w->events = evs;
            w->cap = cap;
            w->head = 0;
        }
        w->events[(w->head + w->len) % w->cap].v = v;
        w->events[(w->head + w->len) % w->cap].n = n;
        w->len++;
    }
    pthread_mutex_unlock(&wins_lock);
    pthread_cond_broadcast(&ev_cv);
}

/* ---- the connection to the host ---------------------------------------------------------- */

static pthread_mutex_t conn_lock = PTHREAD_MUTEX_INITIALIZER;
/* the host connection's fd, once connected (-1 before) */
static int conn_fd = -1;
/* the host has gone (EOF): every call fails from now on */
static _Atomic bool host_dead;
/* one request at a time waits for its reply */
static pthread_mutex_t req_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t reply_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t reply_cv = PTHREAD_COND_INITIALIZER;
static uint8_t *reply_body;
static int64_t reply_n;
static bool reply_ready;

/* Per window: the last PRESENT the host finished, and an error it reported since. */
typedef struct Ack {
    int64_t win;
    int64_t seq;
    char *err;
} Ack;

static pthread_mutex_t acks_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t ack_cv = PTHREAD_COND_INITIALIZER;
static Ack *acks;
static int64_t nacks;
static int64_t capacks;

static Ack *ack_find(int64_t win) {
    for (int64_t i = 0; i < nacks; i++) {
        if (acks[i].win == win) {
            return &acks[i];
        }
    }
    return NULL;
}

static void ack_remove(int64_t win) {
    int64_t k = 0;
    for (int64_t i = 0; i < nacks; i++) {
        if (acks[i].win == win) {
            free(acks[i].err);
        } else {
            acks[k++] = acks[i];
        }
    }
    nacks = k;
}

static void broadcast_locked(pthread_mutex_t *m, pthread_cond_t *cv) {
    pthread_mutex_lock(m);
    pthread_cond_broadcast(cv);
    pthread_mutex_unlock(m);
}

/* The rest of a message as a malloc'd string. */
static char *rest_str(AukWireReader *r) {
    int64_t n = r->i < r->n ? r->n - r->i : 0;
    char *s = auk__xmalloc((size_t)n + 1);
    if (n > 0) {
        memcpy(s, r->b + r->i, (size_t)n);
    }
    s[n] = 0;
    r->i = r->n;
    return s;
}

/* The connection's reader: replies go to the waiting request, events to their window's
 * queue. */
static __attribute__((unused)) void *gui_reader(void *arg) {
    int fd = (int)(intptr_t)arg;
    for (;;) {
        AukWireMsg m;
        if (auk__wire_recv(fd, &m) <= 0) {
            break;
        }
        if (m.fd >= 0) {
            close(m.fd);
        }
        AukWireReader *r = &m.r;
        if (m.op == AUK_WIRE_REPLY) {
            pthread_mutex_lock(&reply_lock);
            free(reply_body);
            reply_body = auk__xmalloc((size_t)r->n + 1);
            memcpy(reply_body, r->b, (size_t)r->n);
            reply_n = r->n;
            reply_ready = true;
            pthread_cond_broadcast(&reply_cv);
            pthread_mutex_unlock(&reply_lock);
        } else if (m.op == AUK_WIRE_PRESENTED) {
            int64_t id = auk__wire_i64(r);
            int64_t seq = auk__wire_i64(r);
            int64_t status = auk__wire_i64(r);
            char *e = status != 0 ? rest_str(r) : NULL;
            pthread_mutex_lock(&acks_lock);
            Ack *a = ack_find(id);
            if (a != NULL) {
                if (seq > a->seq) {
                    a->seq = seq;
                }
                if (e != NULL) {
                    free(a->err);
                    a->err = e;
                    e = NULL;
                }
            }
            pthread_cond_broadcast(&ack_cv);
            pthread_mutex_unlock(&acks_lock);
            free(e);
        } else if (m.op == AUK_WIRE_EVENT) {
            int64_t id = auk__wire_i64(r);
            int64_t n = (r->n - r->i) / 8;
            int64_t *v = auk__xmalloc((size_t)(n + 1) * sizeof(int64_t));
            for (int64_t i = 0; i < n; i++) {
                v[i] = auk__wire_i64(r);
            }
            push_event(id, v, n);
        } else if (m.op == AUK_WIRE_METRICS) {
            int64_t id = auk__wire_i64(r);
            int64_t w = auk__wire_i64(r);
            int64_t h = auk__wire_i64(r);
            double scale = auk__wire_f64(r);
            pthread_mutex_lock(&wins_lock);
            Win *win = win_entry(id);
            if (win != NULL) {
                win->w = w;
                win->h = h;
                win->scale = scale;
            }
            pthread_mutex_unlock(&wins_lock);
        }
        free(m.body);
    }
    /* the host is gone, and so are its windows */
    atomic_store(&host_dead, true);
    broadcast_locked(&acks_lock, &ack_cv);
    pthread_mutex_lock(&wins_lock);
    for (int64_t i = 0; i < nwins; i++) {
        closed_add(wins[i].id);
        win_free_events(&wins[i]);
    }
    nwins = 0;
    pthread_mutex_unlock(&wins_lock);
    pthread_mutex_lock(&conn_lock);
    conn_fd = -1;
    pthread_mutex_unlock(&conn_lock);
    broadcast_locked(&wins_lock, &ev_cv);
    broadcast_locked(&reply_lock, &reply_cv);
    return NULL;
}

/* A malloc'd message "<a><b>". */
static char *msg2(const char *a, const char *b) {
    size_t na = strlen(a);
    size_t nb = strlen(b);
    char *s = auk__xmalloc(na + nb + 1);
    memcpy(s, a, na);
    memcpy(s + na, b, nb + 1);
    return s;
}

/* Wait (lock held) on cv for up to ms milliseconds. */
static void gui_wait_ms(pthread_cond_t *cv, pthread_mutex_t *m, int64_t ms) {
    struct timeval now;
    gettimeofday(&now, NULL);
    int64_t ns = (int64_t)now.tv_usec * 1000 + ms * 1000000;
    struct timespec until = {now.tv_sec + (time_t)(ns / 1000000000), (long)(ns % 1000000000)};
    pthread_cond_timedwait(cv, m, &until);
}

#if defined(__APPLE__)
int posix_spawn_file_actions_addinherit_np(posix_spawn_file_actions_t *actions, int fd);

/* Start the host: this executable again, with AUK_GUI_HOST=spec, inheriting only the standard
 * streams (and child_fd as fd 3, unless -1), so it holds none of the program's sockets or
 * files. Under --live, AUK_GUI_OWNER is the live parent (the host outlives this child). NULL,
 * or why it failed (malloc'd). */
static char *spawn_host(const char *spec, int child_fd) {
    char exe[4096];
    uint32_t size = sizeof exe;
    if (_NSGetExecutablePath(exe, &size) != 0) {
        return msg2("gui: cannot find this program's executable", "");
    }
    int64_t nenv = 0;
    while (environ[nenv] != NULL) {
        nenv++;
    }
    char **envp = auk__xmalloc((size_t)(nenv + 3) * sizeof(char *));
    int64_t k = 0;
    for (int64_t i = 0; i < nenv; i++) {
        if (strncmp(environ[i], "AUK_GUI_HOST=", 13) != 0 && strncmp(environ[i], "AUK_GUI_OWNER=", 14) != 0) {
            envp[k++] = environ[i];
        }
    }
    char *host = msg2("AUK_GUI_HOST=", spec);
    envp[k++] = host;
    char owner[64];
    if (child_fd < 0) {
        memcpy(owner, "AUK_GUI_OWNER=", 14);
        auk__fmt_i64(owner + 14, getppid());
        envp[k++] = owner;
    }
    envp[k] = NULL;
    char *argv[2] = {exe, NULL};
    posix_spawnattr_t attr;
    posix_spawn_file_actions_t acts;
    posix_spawnattr_init(&attr);
    posix_spawn_file_actions_init(&acts);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_CLOEXEC_DEFAULT);
    for (int fd = 0; fd < 3; fd++) {
        posix_spawn_file_actions_addinherit_np(&acts, fd);
    }
    if (child_fd >= 0) {
        posix_spawn_file_actions_adddup2(&acts, child_fd, 3);
    }
    pid_t pid = 0;
    int rc = posix_spawn(&pid, exe, &acts, &attr, argv, envp);
    posix_spawn_file_actions_destroy(&acts);
    posix_spawnattr_destroy(&attr);
    free(host);
    free(envp);
    if (rc != 0) {
        return msg2("gui: cannot start the window process: ", strerror(rc));
    }
    return NULL;
}

/* A sockaddr_un for path; false if it is too long. */
static bool unix_addr(const char *path, struct sockaddr_un *addr) {
    memset(addr, 0, sizeof *addr);
    size_t n = strlen(path);
    if (n >= sizeof addr->sun_path) {
        return false;
    }
    addr->sun_family = AF_UNIX;
    memcpy(addr->sun_path, path, n);
    return true;
}

static int try_connect(const char *path) {
    struct sockaddr_un addr;
    if (!unix_addr(path, &addr)) {
        return -1;
    }
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }
    if (connect(fd, (struct sockaddr *)&addr, sizeof addr) == 0) {
        return fd;
    }
    close(fd);
    return -1;
}

/* Connect to the `auk run --live` session's host at path, starting it first if no one is
 * listening there yet: the fd, or -1 with *err. */
static int connect_session(const char *path, char **err) {
    int fd = try_connect(path);
    if (fd >= 0) {
        return fd;
    }
    char *spec = msg2("listen:", path);
    *err = spawn_host(spec, -1);
    free(spec);
    if (*err != NULL) {
        return -1;
    }
    for (int i = 0; i < 200; i++) {
        struct timespec ts = {0, 15 * 1000000};
        nanosleep(&ts, NULL);
        fd = try_connect(path);
        if (fd >= 0) {
            return fd;
        }
    }
    *err = msg2("gui: the window process didn't start listening on ", path);
    return -1;
}

/* The host connection (connecting first): the fd, or -1 with *err (malloc'd). */
static int gui_connect(char **err) {
    pthread_mutex_lock(&conn_lock);
    if (conn_fd >= 0) {
        int fd = conn_fd;
        pthread_mutex_unlock(&conn_lock);
        return fd;
    }
    if (atomic_load(&host_dead)) {
        pthread_mutex_unlock(&conn_lock);
        *err = msg2("gui: the window process has stopped", "");
        return -1;
    }
    int fd;
    const char *session = getenv("AUK_GUI_SESSION");
    if (session != NULL && session[0] != 0) {
        fd = connect_session(session, err);
        if (fd < 0) {
            pthread_mutex_unlock(&conn_lock);
            return -1;
        }
    } else {
        int sv[2];
        if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) {
            *err = msg2("gui: socketpair failed: ", strerror(errno));
            pthread_mutex_unlock(&conn_lock);
            return -1;
        }
        *err = spawn_host("fd:3", sv[1]);
        close(sv[1]);
        if (*err != NULL) {
            close(sv[0]);
            pthread_mutex_unlock(&conn_lock);
            return -1;
        }
        fd = sv[0];
    }
    auk__c_fcntl(fd, F_SETFD, FD_CLOEXEC);
    auk__wire_no_sigpipe(fd);
    pthread_t th;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    int rc = pthread_create(&th, &attr, gui_reader, (void *)(intptr_t)fd);
    pthread_attr_destroy(&attr);
    if (rc != 0) {
        *err = msg2("gui: cannot start the event thread: ", strerror(rc));
        pthread_mutex_unlock(&conn_lock);
        return -1;
    }
    conn_fd = fd;
    pthread_mutex_unlock(&conn_lock);
    return fd;
}

/* Send a request and wait for its reply's result (after the status): true with *out (malloc'd,
 * *n bytes), or false with *err (malloc'd). */
static bool request(uint8_t op, AukWireBuf *body, uint8_t **out, int64_t *n, char **err) {
    pthread_mutex_lock(&req_lock);
    int fd = gui_connect(err);
    if (fd < 0) {
        pthread_mutex_unlock(&req_lock);
        return false;
    }
    pthread_mutex_lock(&reply_lock);
    reply_ready = false;
    pthread_mutex_unlock(&reply_lock);
    int e = auk__wire_send(fd, op, body->sb.buf == NULL ? body->sb.small : body->sb.buf, body->sb.len, -1);
    if (e != 0) {
        pthread_mutex_unlock(&req_lock);
        char *x = msg2("gui: the window process has stopped (", strerror(e));
        *err = msg2(x, ")");
        free(x);
        return false;
    }
    pthread_mutex_lock(&reply_lock);
    bool ok = false;
    for (;;) {
        if (reply_ready) {
            reply_ready = false;
            AukWireReader r = {reply_body, reply_n, 0};
            if (auk__wire_i64(&r) == 0) {
                int64_t len = reply_n > 8 ? reply_n - 8 : 0;
                *out = auk__xmalloc((size_t)len + 1);
                memcpy(*out, reply_body + (reply_n > 8 ? 8 : reply_n), (size_t)len);
                *n = len;
                ok = true;
            } else {
                *err = rest_str(&r);
            }
            break;
        }
        if (atomic_load(&host_dead)) {
            *err = msg2("gui: the window process has stopped", "");
            break;
        }
        gui_wait_ms(&reply_cv, &reply_lock, 200);
    }
    pthread_mutex_unlock(&reply_lock);
    pthread_mutex_unlock(&req_lock);
    return ok;
}
#endif

/* Send a message that has no reply (if connected at all). */
static void tell(uint8_t op, AukWireBuf *body) {
    pthread_mutex_lock(&req_lock);
    pthread_mutex_lock(&conn_lock);
    int fd = conn_fd;
    pthread_mutex_unlock(&conn_lock);
    if (fd >= 0) {
        auk__wire_send(fd, op, body->sb.buf == NULL ? body->sb.small : body->sb.buf, body->sb.len, -1);
    }
    pthread_mutex_unlock(&req_lock);
}

/* Close this program's windows: it is ending normally (`auk run --live` calls this when the
 * program returns, so its windows don't wait to be taken over by the next run). */
void auk_gui_shutdown(void) {
    AukWireBuf b = {0};
    tell(AUK_WIRE_BYE, &b);
}

/* ---- the Auk-facing calls ---------------------------------------------------------------- */

static AukRes_int int_err_sb(AukStrBuf *m) {
    AukRes_int r = {0};
    r.err = auk__err_sb(m);
    return r;
}

/* Open a window with a w×h (logical points) content area; returns its id. */
AUK_API AukRes_int auk_gui_open(const AukStr *title, int64_t w, int64_t h) {
    AukRes_int res = {0};
    if (w < 1 || w > 16384 || h < 1 || h > 16384) {
        AukStrBuf m = {0};
        auk__sb_put_cstr(&m, "gui.open: size ");
        auk_sb_int(&m, w);
        auk__sb_put_cstr(&m, "x");
        auk_sb_int(&m, h);
        auk__sb_put_cstr(&m, " (expected 1 to 16384 each)");
        return int_err_sb(&m);
    }
#if defined(__APPLE__)
    AukWireBuf body = {0};
    auk__wire_put_i64(&body, w);
    auk__wire_put_i64(&body, h);
    auk__wire_put_str(&body, auk_str_cstr(title), auk_str_byte_len(title));
    uint8_t *out = NULL;
    int64_t n = 0;
    char *err = NULL;
    bool ok = request(AUK_WIRE_OPEN, &body, &out, &n, &err);
    auk_sb_free(&body.sb);
    if (!ok) {
        res.err = auk_err_new_cstr(err);
        free(err);
        return res;
    }
    AukWireReader r = {out, n, 0};
    int64_t id = auk__wire_i64(&r);
    int64_t pw = auk__wire_i64(&r);
    int64_t ph = auk__wire_i64(&r);
    double scale = auk__wire_f64(&r);
    free(out);
    pthread_mutex_lock(&wins_lock);
    closed_remove(id);
    Win *win = win_entry(id);
    if (win != NULL) {
        win->w = pw;
        win->h = ph;
        win->scale = scale;
    }
    pthread_mutex_unlock(&wins_lock);
    res.ok = true;
    res.val = id;
    return res;
#else
    (void)title;
    res.err = auk_err_new_cstr("gui: windows are only supported on macOS so far");
    return res;
#endif
}

/* ---- presenting frames ------------------------------------------------------------------- */

/* A window's frame in shared memory (0xffRRGGBB u32s), mapped here and in the host. */
typedef struct Shm {
    int fd;
    uint32_t *ptr;
    int64_t w;
    int64_t h;
} Shm;

/* A rectangle [x0, x1) × [y0, y1). */
typedef struct GuiRect {
    int64_t x0;
    int64_t y0;
    int64_t x1;
    int64_t y1;
} GuiRect;

/* Areas written into the other buffer since this one was last written: what it lacks. */
typedef struct Stale {
    GuiRect r[9];
    int n;
} Stale;

/* A window's two shared frame buffers. The host reads only the one last presented, so present
 * writes the other; it returns without waiting, and waits for the host to take the last
 * present (PRESENTED) only before writing the buffer that present used. */
typedef struct Bufs {
    int64_t win;
    int64_t w;
    int64_t h;
    Shm b[2];
    /* whether the host has the buffer's fd yet */
    bool sent[2];
    /* whether the buffer has never been written */
    bool blank[2];
    Stale stale[2];
    /* the buffer to write next */
    int next;
    /* the last PRESENT's sequence number */
    int64_t seq;
} Bufs;

static pthread_mutex_t shms_lock = PTHREAD_MUTEX_INITIALIZER;
static Bufs *shms;
static int64_t nshms;
static int64_t capshms;

static void shm_free(Shm *s) {
    munmap(s->ptr, (size_t)(s->w * s->h * 4));
    close(s->fd);
}

static void bufs_free(Bufs *b) {
    shm_free(&b->b[0]);
    shm_free(&b->b[1]);
}

static __attribute__((unused)) Bufs *bufs_find(int64_t win) {
    for (int64_t i = 0; i < nshms; i++) {
        if (shms[i].win == win) {
            return &shms[i];
        }
    }
    return NULL;
}

static void bufs_remove(int64_t win) {
    int64_t k = 0;
    for (int64_t i = 0; i < nshms; i++) {
        if (shms[i].win == win) {
            bufs_free(&shms[i]);
        } else {
            shms[k++] = shms[i];
        }
    }
    nshms = k;
}

/* Close a window (a no-op for one that is already closed). */
AUK_API void auk_gui_close(int64_t win) {
    pthread_mutex_lock(&wins_lock);
    closed_add(win);
    bool was_open = win_find(win) != NULL;
    win_remove(win);
    pthread_cond_broadcast(&ev_cv);
    pthread_mutex_unlock(&wins_lock);
    pthread_mutex_lock(&shms_lock);
    bufs_remove(win);
    pthread_mutex_unlock(&shms_lock);
    pthread_mutex_lock(&acks_lock);
    ack_remove(win);
    pthread_mutex_unlock(&acks_lock);
    if (was_open) {
        AukWireBuf b = {0};
        auk__wire_put_i64(&b, win);
        tell(AUK_WIRE_CLOSE, &b);
        auk_sb_free(&b.sb);
    }
}

/* The window's content width in physical pixels (0 once it is closed). */
AUK_API int64_t auk_gui_width(int64_t win) {
    pthread_mutex_lock(&wins_lock);
    Win *w = win_find(win);
    int64_t v = w == NULL ? 0 : w->w;
    pthread_mutex_unlock(&wins_lock);
    return v;
}

/* The window's content height in physical pixels (0 once it is closed). */
AUK_API int64_t auk_gui_height(int64_t win) {
    pthread_mutex_lock(&wins_lock);
    Win *w = win_find(win);
    int64_t v = w == NULL ? 0 : w->h;
    pthread_mutex_unlock(&wins_lock);
    return v;
}

/* Physical pixels per logical point (2.0 on a Retina display). */
AUK_API double auk_gui_scale(int64_t win) {
    pthread_mutex_lock(&wins_lock);
    Win *w = win_find(win);
    double v = w == NULL ? 1.0 : w->scale;
    pthread_mutex_unlock(&wins_lock);
    return v;
}

#if defined(__APPLE__)
static _Atomic int64_t shm_counter;

/* A new w×h shared buffer; false with *err (malloc'd). */
static bool shm_new(int64_t w, int64_t h, Shm *s, char **err) {
    size_t len = (size_t)(w * h * 4);
    char name[64];
    AukStrBuf nb = {0};
    auk__sb_put_cstr(&nb, "/aukgui.");
    auk_sb_int(&nb, getpid());
    auk__sb_put_cstr(&nb, ".");
    auk_sb_int(&nb, atomic_fetch_add(&shm_counter, 1));
    auk__sb_take_into(&nb, name, sizeof name);
    int fd = auk__c_shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0600);
    if (fd < 0) {
        *err = msg2("gui.present: shared memory: ", strerror(errno));
        return false;
    }
    shm_unlink(name);
    auk__c_fcntl(fd, F_SETFD, FD_CLOEXEC);
    if (ftruncate(fd, (off_t)len) != 0) {
        int e = errno;
        close(fd);
        *err = msg2("gui.present: shared memory: ", strerror(e));
        return false;
    }
    void *p = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (p == MAP_FAILED) {
        int e = errno;
        close(fd);
        *err = msg2("gui.present: shared memory: ", strerror(e));
        return false;
    }
    s->fd = fd;
    s->ptr = p;
    s->w = w;
    s->h = h;
    return true;
}

/* Wait until the host has finished PRESENT seq of win; the error of any present since the last
 * wait (malloc'd), or NULL. */
static char *wait_presented(int64_t win, int64_t seq) {
    pthread_mutex_lock(&acks_lock);
    char *err = NULL;
    for (;;) {
        Ack *a = ack_find(win);
        if (a == NULL) {
            break;
        }
        if (a->seq >= seq) {
            err = a->err;
            a->err = NULL;
            break;
        }
        if (atomic_load(&host_dead)) {
            err = msg2("gui: the window process has stopped", "");
            break;
        }
        gui_wait_ms(&ack_cv, &acks_lock, 200);
    }
    pthread_mutex_unlock(&acks_lock);
    return err;
}

/* Copy rectangle r of the frame src (w per row) into dst as 0xffRRGGBB: windows show frames
 * opaque, whatever their transparency. */
static void convert(uint32_t *dst, const uint32_t *src, int64_t w, GuiRect r) {
    for (int64_t row = r.y0; row < r.y1; row++) {
        for (int64_t i = row * w + r.x0; i < row * w + r.x1; i++) {
            dst[i] = src[i] | 0xff000000u;
        }
    }
}

/* Add r to a list of areas, merging them all into one when the list gets long. */
static void add_rect(Stale *s, GuiRect r) {
    s->r[s->n++] = r;
    if (s->n > 8) {
        GuiRect all = r;
        for (int i = 0; i < s->n; i++) {
            GuiRect b = s->r[i];
            all.x0 = b.x0 < all.x0 ? b.x0 : all.x0;
            all.y0 = b.y0 < all.y0 ? b.y0 : all.y0;
            all.x1 = b.x1 > all.x1 ? b.x1 : all.x1;
            all.y1 = b.y1 > all.y1 ? b.y1 : all.y1;
        }
        s->r[0] = all;
        s->n = 1;
    }
}

/* Present rs (n of them, clipped) of src (w×h) in win: NULL, or why not (malloc'd). */
static char *present(int64_t win, const uint32_t *src, int64_t w, int64_t h, GuiRect *rs, int64_t n) {
    pthread_mutex_lock(&shms_lock);
    Bufs *bf = bufs_find(win);
    char *err = NULL;
    if (bf == NULL || bf->w != w || bf->h != h) {
        /* a new size: new buffers (the host maps them as their fds arrive) */
        Bufs fresh;
        memset(&fresh, 0, sizeof fresh);
        fresh.win = win;
        fresh.w = w;
        fresh.h = h;
        if (!shm_new(w, h, &fresh.b[0], &err)) {
            pthread_mutex_unlock(&shms_lock);
            return err;
        }
        if (!shm_new(w, h, &fresh.b[1], &err)) {
            shm_free(&fresh.b[0]);
            pthread_mutex_unlock(&shms_lock);
            return err;
        }
        fresh.blank[0] = true;
        fresh.blank[1] = true;
        if (bf != NULL) {
            fresh.seq = bf->seq;
            bufs_free(bf);
            *bf = fresh;
        } else {
            if (nshms == capshms) {
                capshms = capshms == 0 ? 4 : capshms * 2;
                shms = auk__xrealloc(shms, (size_t)capshms * sizeof(Bufs));
            }
            shms[nshms++] = fresh;
            bf = &shms[nshms - 1];
        }
        pthread_mutex_lock(&acks_lock);
        if (ack_find(win) == NULL) {
            if (nacks == capacks) {
                capacks = capacks == 0 ? 4 : capacks * 2;
                acks = auk__xrealloc(acks, (size_t)capacks * sizeof(Ack));
            }
            acks[nacks].win = win;
            acks[nacks].seq = bf->seq;
            acks[nacks].err = NULL;
            nacks++;
        }
        pthread_mutex_unlock(&acks_lock);
    }
    if (n == 0) {
        pthread_mutex_unlock(&shms_lock);
        return NULL;
    }
    /* until the host has taken the last present (the other buffer), it may still read this
     * one */
    err = wait_presented(win, bf->seq);
    if (err != NULL) {
        pthread_mutex_unlock(&shms_lock);
        return err;
    }
    int i = bf->next;
    int o = 1 - bf->next;
    uint32_t *dst = bf->b[i].ptr;
    const uint32_t *other = bf->b[o].ptr;
    GuiRect whole = {0, 0, w, h};
    if (bf->blank[i] && bf->blank[o]) {
        rs = &whole;
        n = 1;
    }
    if (bf->blank[i] && !bf->blank[o]) {
        memcpy(dst, other, (size_t)(w * h) * 4);
    } else if (!bf->blank[i]) {
        /* catch up with what the other buffer got since this one was written (apart from what
         * this present writes anyway) */
        for (int k = 0; k < bf->stale[i].n; k++) {
            GuiRect s = bf->stale[i].r[k];
            bool covered = false;
            for (int64_t j = 0; j < n && !covered; j++) {
                covered = s.x0 >= rs[j].x0 && s.y0 >= rs[j].y0 && s.x1 <= rs[j].x1 && s.y1 <= rs[j].y1;
            }
            if (covered) {
                continue;
            }
            for (int64_t row = s.y0; row < s.y1; row++) {
                memcpy(dst + row * w + s.x0, other + row * w + s.x0, (size_t)(s.x1 - s.x0) * 4);
            }
        }
    }
    bf->stale[i].n = 0;
    bf->blank[i] = false;
    for (int64_t j = 0; j < n; j++) {
        convert(dst, src, w, rs[j]);
        add_rect(&bf->stale[o], rs[j]);
    }
    bf->seq++;
    bf->next = o;
    int pass = bf->sent[i] ? -1 : bf->b[i].fd;
    bf->sent[i] = true;
    AukWireBuf body = {0};
    auk__wire_put_i64(&body, win);
    auk__wire_put_i64(&body, w);
    auk__wire_put_i64(&body, h);
    auk__wire_put_i64(&body, i);
    auk__wire_put_i64(&body, bf->seq);
    auk__wire_put_i64(&body, n);
    for (int64_t j = 0; j < n; j++) {
        auk__wire_put_i64(&body, rs[j].x0);
        auk__wire_put_i64(&body, rs[j].y0);
        auk__wire_put_i64(&body, rs[j].x1 - rs[j].x0);
        auk__wire_put_i64(&body, rs[j].y1 - rs[j].y0);
    }
    pthread_mutex_unlock(&shms_lock);
    pthread_mutex_lock(&req_lock);
    int fd = gui_connect(&err);
    if (fd >= 0) {
        int e = auk__wire_send(fd, AUK_WIRE_PRESENT, body.sb.buf == NULL ? body.sb.small : body.sb.buf, body.sb.len, pass);
        if (e != 0) {
            char *x = msg2("gui: the window process has stopped (", strerror(e));
            err = msg2(x, ")");
            free(x);
        }
    }
    pthread_mutex_unlock(&req_lock);
    auk_sb_free(&body.sb);
    return err;
}
#else
static char *present(int64_t win, const uint32_t *src, int64_t w, int64_t h, void *rs, int64_t n) {
    (void)win;
    (void)src;
    (void)w;
    (void)h;
    (void)rs;
    (void)n;
    return msg2("gui: windows are only supported on macOS so far", "");
}
#endif

static AukRes_unit unit_err_sb(AukStrBuf *m) {
    AukRes_unit r = {0};
    r.err = auk__err_sb(m);
    return r;
}

static int64_t clamp_add(int64_t a, int64_t b, int64_t hi) {
    int64_t s;
    if (__builtin_add_overflow(a, b, &s)) {
        s = b > 0 ? INT64_MAX : INT64_MIN;
    }
    return s < hi ? s : hi;
}

/* Show the rectangles rects (flattened x, y, w, h quads) of the frame f in the window; the rest
 * of what it shows stays. Only those rectangles are copied, and they go to the window process
 * together, in one message. */
AUK_API AukRes_unit auk_gui_present_rects(int64_t win, const AukFrame *f, const AukArr *rects) {
    int64_t w = f->w;
    int64_t h = f->hgt;
    AukStrBuf m = {0};
    if (w < 1 || h < 1) {
        auk__sb_put_cstr(&m, "gui.present: an empty ");
        auk_sb_int(&m, w);
        auk__sb_put_cstr(&m, "x");
        auk_sb_int(&m, h);
        auk__sb_put_cstr(&m, " frame");
        return unit_err_sb(&m);
    }
    int64_t n = auk_arr_len(rects);
    if (n % 4 != 0) {
        auk__sb_put_cstr(&m, "gui.present_rects: ");
        auk_sb_int(&m, n);
        auk__sb_put_cstr(&m, " ints is not a list of x, y, w, h quads");
        return unit_err_sb(&m);
    }
    pthread_mutex_lock(&wins_lock);
    bool open = win_find(win) != NULL;
    pthread_mutex_unlock(&wins_lock);
    if (!open) {
        auk__sb_put_cstr(&m, "gui.present: window ");
        auk_sb_int(&m, win);
        auk__sb_put_cstr(&m, " is closed");
        return unit_err_sb(&m);
    }
    const int64_t *q = n > 0 ? (const int64_t *)rects->data : NULL;
    GuiRect *rs = auk__xmalloc((size_t)(n / 4 + 1) * sizeof(GuiRect));
    int64_t k = 0;
    for (int64_t i = 0; i + 3 < n; i += 4) {
        GuiRect r = {q[i] > 0 ? q[i] : 0, q[i + 1] > 0 ? q[i + 1] : 0, clamp_add(q[i], q[i + 2], w), clamp_add(q[i + 1], q[i + 3], h)};
        if (r.x0 < r.x1 && r.y0 < r.y1) {
            rs[k++] = r;
        }
    }
    char *err = present(win, f->data, w, h, rs, k);
    free(rs);
    AukRes_unit res = {0};
    if (err != NULL) {
        res.err = auk_err_new_cstr(err);
        free(err);
        return res;
    }
    res.ok = true;
    return res;
}

/* The next event of win as [int] (the kind, then its fields), waiting at most ms milliseconds
 * (0: don't wait, negative: until there is one). Empty if none came. A closed or unknown window
 * reports Close, so a loop over its events ends. A task waiting here can be cancelled. */
AUK_API AukArr *auk_gui_next_event(int64_t win, int64_t ms, const char *loc) {
    static const int64_t close_ev[1] = {1};
    struct timespec t0;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    int64_t start = (int64_t)t0.tv_sec * 1000 + t0.tv_nsec / 1000000;
    const int64_t *v = NULL;
    int64_t *owned = NULL; /* a queued event's ints, freed here */
    int64_t n = 0;
    pthread_mutex_lock(&wins_lock);
    for (;;) {
        Win *w = win_find(win);
        if (w == NULL) {
            v = close_ev;
            n = 1;
            break;
        }
        if (w->len > 0) {
            Event e = w->events[w->head];
            w->head = (w->head + 1) % w->cap;
            w->len--;
            owned = e.v;
            v = e.v;
            n = e.n;
            break;
        }
        int64_t slice = 50;
        if (ms >= 0) {
            struct timespec t;
            clock_gettime(CLOCK_MONOTONIC, &t);
            int64_t left = ms - ((int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000 - start);
            if (left <= 0) {
                break;
            }
            slice = left < 50 ? left : 50;
        }
        gui_wait_ms(&ev_cv, &wins_lock, slice);
        if (auk__task_cancelled()) {
            pthread_mutex_unlock(&wins_lock);
            auk__check_cancel(loc);
            pthread_mutex_lock(&wins_lock);
        }
    }
    pthread_mutex_unlock(&wins_lock);
    AukArr *out = auk_arr_new(&auk_ops_int, n);
    if (n > 0) {
        int64_t *d = auk_arr_make_unique(&out);
        memcpy(d, v, (size_t)n * sizeof(int64_t));
        out->len = n;
    }
    free(owned);
    return out;
}
