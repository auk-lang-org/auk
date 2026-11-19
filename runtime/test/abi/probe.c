/* The C side of the layout probe (run.sh): compares runtime/src/abi.auk and the platform's
 * runtime/src/cfacts.<os>-<arch>.auk, compiled by `auk build --lib`, with the C compiler's view
 * of runtime/c/auk_rt.h and the system headers. run.sh puts the generated tables
 * (tables.awk) in front of this file. Prints "ok <n> checks" or
 * what differs. */
#include <stdio.h>
#include <string.h>

/* chan.c's channel, as the C defined it before the port (runtime/src/chan.auk uses abi.Chan):
 * abi.auk's layout is still checked against C's. */
struct AukChan {
    AukHeader h;
    pthread_mutex_t lock;
    pthread_cond_t cv;
    const AukElemOps *ops;
    /* the queue: a ring of cap slots of size bytes, count of them from head */
    uint8_t *items;
    size_t size;
    int64_t cap;
    int64_t head;
    int64_t count;
    bool closed;
};

/* task.c's task, as the C defined it before the port (runtime/src/task.auk uses abi.Task). */
struct AukTask {
    AukHeader h;
    pthread_t th;
    pthread_mutex_t mu;
    AukThunk fn;
    void *args;
    void *result;
    size_t result_size;
    const AukElemOps *ops;
    bool joined;
    AukPanic *panic;
    bool observed;
    _Atomic bool cancel;
    _Atomic bool done;
    AukTask **kids;
    int64_t nkids;
    int64_t capkids;
    AukHeap *heap;
    void (*args_drop)(void *args);
    uintptr_t hint;
};

static int bad = 0;
static int nchecked = 0;
#define CHECK(c)                                                    \
    do {                                                            \
        nchecked++;                                                 \
        if (!(c)) {                                                 \
            printf("FAIL %s (probe.c:%d)\n", #c, __LINE__);         \
            bad = 1;                                                \
        }                                                           \
    } while (0)

int64_t auk_probe(int32_t k);
int64_t auk_probe_init(int32_t k, void *out);

static void check_value(int k, int64_t c, const char *what) {
    int64_t a = auk_probe(k);
    if (a != c) {
        printf("FAIL %s: C says %lld, Auk %lld\n", what, (long long)c, (long long)a);
        bad = 1;
    }
}

static void check_init(int k, const void *c, size_t n, const char *what) {
    unsigned char buf[256];
    memset(buf, 0xa5, sizeof buf);
    int64_t got = auk_probe_init(k, buf);
    nchecked++;
    if (got != (int64_t)n || memcmp(buf, c, n) != 0) {
        printf("FAIL %s: Auk's bytes differ from C's (%lld of %zu)\n", what, (long long)got, n);
        bad = 1;
    }
}

#include "tables.c"

bool auk_wifexited(int32_t);
int32_t auk_wexitstatus(int32_t);
bool auk_wifsignaled(int32_t);
int32_t auk_wtermsig(int32_t);
bool auk_s_isdir(uint32_t);
bool auk_s_isreg(uint32_t);
size_t auk_cmsg_len(size_t);
size_t auk_cmsg_space(size_t);
uint8_t *auk_cmsg_data(struct cmsghdr *);
struct cmsghdr *auk_cmsg_firsthdr(struct msghdr *);
uint64_t *auk_uc_pc(void *);
uint64_t *auk_uc_sp(void *);
void *auk_si_addr(void *);
int *auk_errno_ptr(void);
int32_t auk_errno(void);
void auk_set_errno(int32_t);
void *auk_stdout(void);
void *auk_stderr(void);
int64_t auk_stat_size(const char *);
bool auk_is_handle(uint32_t);
uint8_t *auk_map_key(AukMap *, int64_t);
uint8_t *auk_map_val(AukMap *, int64_t);
uint64_t auk_ops_hash(const AukElemOps *, const void *);
int64_t auk_value_i(AukValue);
AukValue auk_mk_value_f(double);
AukRes_int auk_mk_res_int(int64_t);
double auk_opt_float(AukOpt_float);
AukOpt_char auk_mk_opt_char(uint32_t);
AukObj *auk_closure_env(AukClosure);
int64_t auk_probe_str_len(AukStr *);
uint8_t auk_probe_str_byte(AukStr *, int64_t);
uintptr_t auk_task_hint(struct AukTask *);
bool auk_chan_closed(struct AukChan *);
int32_t auk_mutex_roundtrip(void);

static uint64_t hash_it(const void *p) { return *(const uint64_t *)p * 3; }

static void check_functions(const char *self) {
    /* the wait-status macros over every 16-bit status */
    for (int s = 0; s < 0x10000; s++) {
        if (auk_wifexited(s) != (bool)WIFEXITED(s) || auk_wifsignaled(s) != (bool)WIFSIGNALED(s) ||
            (WIFEXITED(s) && auk_wexitstatus(s) != WEXITSTATUS(s)) || (WIFSIGNALED(s) && auk_wtermsig(s) != WTERMSIG(s))) {
            printf("FAIL W* macros differ at status %#x\n", s);
            bad = 1;
            break;
        }
    }
    nchecked++;
    for (uint32_t m = 0; m < 0x10000; m += 0x1000) {
        CHECK(auk_s_isdir(m | 0644) == (bool)S_ISDIR(m | 0644));
        CHECK(auk_s_isreg(m | 0644) == (bool)S_ISREG(m | 0644));
    }
    /* control messages */
    for (size_t n = 0; n < 40; n++) {
        CHECK(auk_cmsg_len(n) == CMSG_LEN(n));
        CHECK(auk_cmsg_space(n) == CMSG_SPACE(n));
    }
    union {
        struct cmsghdr h;
        uint8_t b[CMSG_SPACE(sizeof(int))];
    } cbuf;
    struct msghdr msg;
    memset(&msg, 0, sizeof msg);
    msg.msg_control = cbuf.b;
    msg.msg_controllen = sizeof cbuf.b;
    CHECK(auk_cmsg_firsthdr(&msg) == CMSG_FIRSTHDR(&msg));
    CHECK(auk_cmsg_data(CMSG_FIRSTHDR(&msg)) == CMSG_DATA(CMSG_FIRSTHDR(&msg)));
    msg.msg_controllen = sizeof(struct cmsghdr) - 1;
    CHECK(auk_cmsg_firsthdr(&msg) == NULL);
    /* a signal handler's context: the PC and SP slots, read and written */
    ucontext_t uc;
    memset(&uc, 0, sizeof uc);
#if defined(__APPLE__)
    struct __darwin_mcontext64 mc;
    memset(&mc, 0, sizeof mc);
    uc.uc_mcontext = &mc;
#if defined(__aarch64__)
    uint64_t *pc = (uint64_t *)&mc.__ss.__pc, *sp = (uint64_t *)&mc.__ss.__sp;
#else
    uint64_t *pc = (uint64_t *)&mc.__ss.__rip, *sp = (uint64_t *)&mc.__ss.__rsp;
#endif
#elif defined(__aarch64__)
    uint64_t *pc = (uint64_t *)&uc.uc_mcontext.pc, *sp = (uint64_t *)&uc.uc_mcontext.sp;
#else
    uint64_t *pc = (uint64_t *)&uc.uc_mcontext.gregs[REG_RIP], *sp = (uint64_t *)&uc.uc_mcontext.gregs[REG_RSP];
#endif
    *pc = 0x1234;
    *sp = 0x5678;
    CHECK(auk_uc_pc(&uc) == pc && *auk_uc_pc(&uc) == 0x1234);
    CHECK(auk_uc_sp(&uc) == sp && *auk_uc_sp(&uc) == 0x5678);
    siginfo_t si;
    memset(&si, 0, sizeof si);
    si.si_addr = (void *)0x4242;
    CHECK(auk_si_addr(&si) == (void *)0x4242);
    /* errno, stdout, stderr */
    CHECK(auk_errno_ptr() == &errno);
    errno = EPIPE;
    CHECK(auk_errno() == EPIPE);
    auk_set_errno(EINTR);
    CHECK(errno == EINTR);
    CHECK(auk_stdout() == (void *)stdout && auk_stderr() == (void *)stderr);
    /* struct stat through the Auk layout */
    struct stat st;
    CHECK(stat(self, &st) == 0 && auk_stat_size(self) == (int64_t)st.st_size);
    /* abi */
    for (uint32_t k = 0; k < 16; k++) CHECK(auk_is_handle(k) == auk__is_handle(k));
    uint8_t entries[64];
    AukMap m;
    memset(&m, 0, sizeof m);
    m.entries = entries;
    m.stride = 16;
    m.voff = 8;
    CHECK(auk_map_key(&m, 2) == auk__map_key(&m, 2) && auk_map_val(&m, 3) == auk__map_val(&m, 3));
    AukElemOps ops;
    memset(&ops, 0, sizeof ops);
    ops.size = 8;
    ops.hash = hash_it;
    uint64_t x = 14;
    CHECK(auk_ops_hash(&ops, &x) == 42);
    AukValue v;
    memset(&v, 0, sizeof v);
    v.tag = AUK_V_INT;
    v.u.i = -77;
    CHECK(auk_value_i(v) == -77);
    v = auk_mk_value_f(2.5);
    CHECK(v.tag == AUK_V_FLOAT && v.u.f == 2.5);
    AukRes_int r = auk_mk_res_int(9);
    CHECK(r.ok && r.val == 9 && r.err == NULL);
    r = auk_mk_res_int(-3);
    CHECK(!r.ok && r.val == -3);
    CHECK(auk_opt_float((AukOpt_float){true, 1.25}) == 1.25 && auk_opt_float((AukOpt_float){false, 1.25}) == -1.0);
    AukOpt_char oc = auk_mk_opt_char(0x1F600);
    CHECK(oc.some && oc.val == 0x1F600);
    AukObj obj;
    CHECK(auk_closure_env((AukClosure){NULL, &obj}) == &obj);
    struct {
        AukStr s;
        uint8_t bytes[8];
    } str = {{{1, AUK_K_STR, 0}, 3, 3, true}, {0}};
    memcpy(str.s.data, "abc", 4);
    CHECK(auk_probe_str_len(&str.s) == 3 && auk_probe_str_byte(&str.s, 1) == 'b');
    struct AukTask task;
    memset(&task, 0, sizeof task);
    task.hint = 0xfeed;
    CHECK(auk_task_hint(&task) == 0xfeed);
    struct AukChan chan;
    memset(&chan, 0, sizeof chan);
    chan.closed = true;
    CHECK(auk_chan_closed(&chan));
    CHECK(auk_mutex_roundtrip() == 0);
}

int main(int argc, char **argv) {
    (void)argc;
    check_tables();
    check_functions(argv[0]);
    if (bad) return 1;
    printf("ok %d checks\n", nchecked);
    return 0;
}
