/* Core library: print, fs, net, time, rand, env (with stdin), proc. */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <pthread.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#if defined(__linux__)
#include <sys/random.h>
#endif

#include "auk_rt.h"

extern char **environ;

/* ---- small helpers ----------------------------------------------------------------------- */

/* An Err with the builder's text (consumed) and code. */
static AukErr *err_code_sb(AukStrBuf *b, int code) {
    AukErr *e = auk__err_sb(b);
    e->code = code;
    return e;
}

static AukRes_str str_err(AukErr *e) {
    AukRes_str r = {0};
    r.err = e;
    return r;
}

/* A growable byte buffer. */
typedef struct Bytes {
    uint8_t *p;
    int64_t n;
    int64_t cap;
} Bytes;

static void bytes_add(Bytes *b, const uint8_t *p, int64_t n) {
    if (b->n + n > b->cap) {
        int64_t cap = b->cap == 0 ? 65536 : b->cap;
        while (cap < b->n + n) {
            cap *= 2;
        }
        b->p = auk__xrealloc(b->p, (size_t)cap);
        b->cap = cap;
    }
    memcpy(b->p + b->n, p, (size_t)n);
    b->n += n;
}

/* Read all of f into b; returns 0 or an errno. */
static int slurp(FILE *f, Bytes *b) {
    uint8_t *buf = auk__xmalloc(65536);
    for (;;) {
        size_t n = fread(buf, 1, 65536, f);
        if (n == 0) {
            break;
        }
        bytes_add(b, buf, (int64_t)n);
    }
    free(buf);
    if (ferror(f)) {
        return errno != 0 ? errno : EIO;
    }
    return 0;
}

/* print: runtime/src/core_env.auk */

/* fs: runtime/src/core_fs.auk; auk__bytes_to_arr: core_util.auk */

/* net: runtime/src/core_net.auk */

/* time, rand: runtime/src/core_time.auk */

/* env: runtime/src/core_env.auk */

/* ---- proc -------------------------------------------------------------------------------- */

AUK_API AukRes_str auk_proc_run(const AukStr *cmd, const AukArr *args_in) {
    int64_t n = auk_arr_len(args_in);
    char **argv = auk__xmalloc((size_t)(n + 2) * sizeof(char *));
    argv[0] = (char *)auk_str_cstr(cmd);
    for (int64_t i = 0; i < n; i++) {
        argv[i + 1] = (char *)auk_str_cstr(((AukStr *const *)args_in->data)[i]);
    }
    argv[n + 1] = NULL;
    int fds[2];
    if (pipe(fds) < 0) {
        free(argv);
        return str_err(auk__err_errno("proc.run", cmd, errno));
    }
    auk__c_fcntl(fds[0], F_SETFD, FD_CLOEXEC);
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, fds[1], 1);
    posix_spawn_file_actions_addclose(&fa, fds[1]);
    pid_t pid = 0;
    fflush(stdout);
    int rc = posix_spawnp(&pid, auk_str_cstr(cmd), &fa, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    free(argv);
    close(fds[1]);
    if (rc != 0) {
        close(fds[0]);
        return str_err(auk__err_errno("proc.run", cmd, rc));
    }
    Bytes b = {0};
    uint8_t *buf = auk__xmalloc(65536);
    for (;;) {
        auk__wait_fd(fds[0], false);
        ssize_t r = read(fds[0], buf, 65536);
        if (r < 0 && errno == EINTR) {
            continue;
        }
        if (r <= 0) {
            break;
        }
        bytes_add(&b, buf, r);
    }
    free(buf);
    close(fds[0]);
    int status = 0;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) {
            status = -1;
            break;
        }
    }
    AukStr *out = auk_str_from_bytes((const char *)b.p, b.n);
    free(b.p);
    if (status == -1 || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        AukStrBuf m = {0};
        auk__sb_put_cstr(&m, "proc.run ");
        auk__sb_put_cstr(&m, auk_str_cstr(cmd));
        AukErr *e;
        if (status != -1 && WIFEXITED(status)) {
            int st = WEXITSTATUS(status);
            auk__sb_put_cstr(&m, ": exited with status ");
            auk_sb_int(&m, st);
            e = err_code_sb(&m, st);
        } else if (status != -1 && WIFSIGNALED(status)) {
            int sig = WTERMSIG(status);
            auk__sb_put_cstr(&m, ": killed by signal ");
            auk_sb_int(&m, sig);
            e = err_code_sb(&m, 128 + sig);
        } else {
            auk__sb_put_cstr(&m, ": could not wait for the process");
            e = auk__err_sb(&m);
        }
        auk_release(out);
        return str_err(e);
    }
    AukRes_str r = {0};
    r.ok = true;
    r.val = out;
    return r;
}

AUK_API _Noreturn void auk_proc_exit(int64_t code, const char *loc) {
    if (code < 0 || code > 255) {
        AukStrBuf m = {0};
        auk__sb_put_cstr(&m, "proc.exit(");
        auk_sb_int(&m, code);
        auk__sb_put_cstr(&m, "): code out of range 0..255");
        auk__panic_sb(loc, &m);
    }
    fflush(stdout);
    fflush(stderr);
    auk__trace_flush();
    if (auk_leak_check() != 0) {
        _exit(102);
    }
    /* _exit, like a panic: async tasks may still be running on other threads */
    _exit((int)code);
}
