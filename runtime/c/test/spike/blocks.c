/* Phase 7b spike: Network.framework TLS without -fblocks.
 *
 * NOT part of the runtime build or the unit tests. It answers one question for
 * docs/lowlevel.md ("Blocks without -fblocks"): can every block runtime/c/tls.c hands to
 * Network.framework, Security.framework and libdispatch be built by hand, as plain C structs and
 * function pointers laid out per Clang's Block ABI, so that a dialect with `raw struct`s and C
 * function pointers (but no `^{}` syntax) can drive Network.framework?
 *
 * This file is compiled WITHOUT -fblocks (it #errors if __BLOCKS__ is defined), so the SDK
 * headers hide every block-taking declaration and this file re-declares them with `void *` block
 * parameters: what an Auk `extern fn` would do. Run it with runtime/c/test/spike/blocks.sh, which
 * makes a self-signed certificate, starts `openssl s_server -rev` on 127.0.0.1 and builds this
 * with ASan + UBSan, then checks it with leaks(1) and without block signatures. It lives in a
 * subdirectory so runtime/c/test/run.sh (which links every .c in test/) doesn't pick it up.
 *
 *   blocks <port> <cert.der>
 *
 * The blocks tls.c creates, and the hand-made equivalent of each here:
 *
 *   tls.c block                               captures       kind here
 *   nw_parameters_create_secure_tcp tls cfg   t, fallback    stack literal (framework copies)
 *   sec_protocol_options_set_verify_block     t              stack literal (framework copies)
 *   nw_parameters_create_secure_tcp tcp cfg   -              global literal
 *   nw_connection_set_state_changed_handler   t              stack literal + copy/dispose
 *   dispatch_sync (read the outcome)          t, out         stack literal (never copied)
 *   nw_connection_receive completion          op             stack literal + copy/dispose
 *   dispatch_data_apply applier (returns bool) op            stack literal (never copied)
 *   nw_connection_send completion             op             stack literal + copy/dispose
 *   (the verify block's `complete` argument: a framework-made block this code invokes)
 */
#ifdef __BLOCKS__
#error "blocks.c must be compiled without -fblocks"
#endif

#include <Network/Network.h>
#include <Security/Security.h>
#include <dispatch/dispatch.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---------------------------------------------------------------------------------------------
 * The Block ABI (https://clang.llvm.org/docs/Block-ABI-Apple.html), as Clang emits it today
 * (checked against `clang -fblocks -S -emit-llvm`): a stack literal has flags BLOCK_HAS_SIGNATURE,
 * a global one BLOCK_IS_GLOBAL | BLOCK_HAS_SIGNATURE, and the descriptor is
 * {reserved, size, [copy, dispose,] signature, layout}.
 * ------------------------------------------------------------------------------------------- */

extern void *_NSConcreteStackBlock[32];
extern void *_NSConcreteGlobalBlock[32];
extern void *_Block_copy(const void *block);
extern void _Block_release(const void *block);

enum {
    BLOCK_DEALLOCATING = 0x0001,
    BLOCK_REFCOUNT_MASK = 0xfffe, /* runtime-owned: zero in a literal */
    BLOCK_NEEDS_FREE = 1 << 24,   /* runtime-owned: set on heap copies */
    BLOCK_HAS_COPY_DISPOSE = 1 << 25,
    BLOCK_IS_GLOBAL = 1 << 28,
    BLOCK_HAS_SIGNATURE = 1 << 30,
};

/* Every block starts with this. */
typedef struct BlockHdr {
    void *isa;
    int32_t flags;
    int32_t reserved;
    void *invoke; /* first argument: the block itself */
    const void *descriptor;
} BlockHdr;

/* Descriptor without helpers (flags lack BLOCK_HAS_COPY_DISPOSE). */
typedef struct BlockDesc {
    uintptr_t reserved;
    uintptr_t size; /* sizeof the whole literal: _Block_copy memmoves this many bytes */
    const char *signature;
    const char *layout;
} BlockDesc;

/* Descriptor with helpers (flags have BLOCK_HAS_COPY_DISPOSE). */
typedef struct BlockDescCD {
    uintptr_t reserved;
    uintptr_t size;
    void (*copy)(void *dst, const void *src); /* after the memmove: dst is the new heap block */
    void (*dispose)(const void *blk);         /* before the heap block is freed */
    const char *signature;
    const char *layout;
} BlockDescCD;

/* -DSPIKE_NO_SIGNATURE: literals without BLOCK_HAS_SIGNATURE (the descriptors keep the field; it
 * is ignored), to check that no API here needs the signature string. */
#ifdef SPIKE_NO_SIGNATURE
#define SIG_FLAG 0
#else
#define SIG_FLAG BLOCK_HAS_SIGNATURE
#endif

static void block_init(BlockHdr *h, void *invoke, const void *desc, bool helpers) {
    h->isa = _NSConcreteStackBlock;
    h->flags = SIG_FLAG | (helpers ? BLOCK_HAS_COPY_DISPOSE : 0);
    h->reserved = 0;
    h->invoke = invoke;
    h->descriptor = desc;
}

/* Invoke a block someone else made (sec_protocol_verify_complete_t: void (^)(bool)). */
static void call_bool_block(void *blk, bool v) {
    void (*inv)(void *, bool) = (void (*)(void *, bool))((BlockHdr *)blk)->invoke;
    inv(blk, v);
}

/* Live heap copies of the helper-carrying blocks: copy helper +1, dispose helper -1. Must be 0
 * at exit, which proves the framework releases every copy it makes. */
static _Atomic int live_copies;
static _Atomic int total_copies;
/* invocations on a block whose address differs from the literal's: the framework copied it */
static _Atomic int ran_on_copy;

/* ---------------------------------------------------------------------------------------------
 * The block-taking API, re-declared with `void *` blocks (hidden by the headers without
 * __BLOCKS__).
 * ------------------------------------------------------------------------------------------- */

extern nw_parameters_t nw_parameters_create_secure_tcp(void *configure_tls, void *configure_tcp);
extern void nw_connection_set_state_changed_handler(nw_connection_t c, void *handler);
extern void nw_connection_receive(nw_connection_t c, uint32_t min, uint32_t max, void *completion);
extern void nw_connection_send(nw_connection_t c, dispatch_data_t content, nw_content_context_t ctx,
                               bool is_complete, void *completion);
extern void sec_protocol_options_set_verify_block(sec_protocol_options_t o, void *verify, dispatch_queue_t q);
extern bool dispatch_data_apply(dispatch_data_t data, void *applier);
extern void dispatch_sync(dispatch_queue_t q, void *block);
extern void dispatch_async(dispatch_queue_t q, void *block);
/* destructor NULL (DISPATCH_DATA_DESTRUCTOR_DEFAULT): copy the buffer */
extern dispatch_data_t dispatch_data_create(const void *buf, size_t size, dispatch_queue_t q, void *destructor);
/* NW_CONNECTION_DEFAULT_STREAM_CONTEXT */
extern nw_content_context_t _nw_content_context_default_stream;

/* ---------------------------------------------------------------------------------------------
 * The connection, as tls.c's NwTls.
 * ------------------------------------------------------------------------------------------- */

enum { VERIFY_SYSTEM, VERIFY_ANCHOR };

typedef struct Conn {
    nw_connection_t conn;
    dispatch_queue_t q;
    dispatch_semaphore_t ready;
    dispatch_semaphore_t gone;
    int verify_mode;
    SecCertificateRef anchor;
    const char *host;
    /* written on q only */
    bool reported;
    bool ok;
    bool saw_cert;
    int domain;
    int code;
    char why[256];
} Conn;

typedef struct Outcome {
    bool ok;
    bool saw_cert;
    int domain;
    int code;
    char why[256];
} Outcome;

static void post(dispatch_semaphore_t s) {
    dispatch_retain(s);
    dispatch_semaphore_signal(s);
    dispatch_release(s);
}

/* --- verify block: void (^)(sec_protocol_metadata_t, sec_trust_t, sec_protocol_verify_complete_t)
 * captures t */
typedef struct VerifyBlock {
    BlockHdr h;
    Conn *t;
} VerifyBlock;

static void verify_invoke(VerifyBlock *b, sec_protocol_metadata_t md, sec_trust_t trust_ref, void *complete) {
    (void)md;
    Conn *t = b->t;
    t->saw_cert = true;
    SecTrustRef trust = sec_trust_copy_ref(trust_ref);
    CFStringRef name = CFStringCreateWithCString(NULL, t->host, kCFStringEncodingUTF8);
    SecPolicyRef policy = SecPolicyCreateSSL(true, name);
    bool ok = SecTrustSetPolicies(trust, policy) == errSecSuccess;
    if (ok && t->verify_mode == VERIFY_ANCHOR) {
        /* trust exactly the test certificate */
        const void *certs[1] = {t->anchor};
        CFArrayRef anchors = CFArrayCreate(NULL, certs, 1, &kCFTypeArrayCallBacks);
        ok = SecTrustSetAnchorCertificates(trust, anchors) == errSecSuccess &&
             SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess;
        CFRelease(anchors);
    }
    CFErrorRef err = NULL;
    ok = ok && SecTrustEvaluateWithError(trust, &err);
    if (!ok) {
        snprintf(t->why, sizeof t->why, "trust evaluation failed");
        CFStringRef d = err != NULL ? CFErrorCopyDescription(err) : NULL;
        if (d != NULL) {
            CFStringGetCString(d, t->why, sizeof t->why, kCFStringEncodingUTF8);
            CFRelease(d);
        }
    }
    if (err != NULL) {
        CFRelease(err);
    }
    CFRelease(policy);
    CFRelease(name);
    CFRelease(trust);
    call_bool_block(complete, ok);
}

static const BlockDesc verify_desc = {0, sizeof(VerifyBlock), "v32@?0^{sec_protocol_metadata=}8^{sec_trust=}16@?<v@?B>24", NULL};

/* --- TLS configure block: void (^)(nw_protocol_options_t), captures t, fallback */
typedef struct TlsCfgBlock {
    BlockHdr h;
    Conn *t;
    bool fallback;
} TlsCfgBlock;

static void tls_cfg_invoke(TlsCfgBlock *b, nw_protocol_options_t tls) {
    sec_protocol_options_t sec = nw_tls_copy_sec_protocol_options(tls);
    sec_protocol_options_set_min_tls_protocol_version(sec, tls_protocol_version_TLSv12);
    if (b->fallback) {
        sec_protocol_options_set_max_tls_protocol_version(sec, tls_protocol_version_TLSv12);
        sec_protocol_options_set_tls_is_fallback_attempt(sec, true);
    }
    /* a literal in this frame: the framework copies it, so it may die when we return */
    VerifyBlock vb;
    block_init(&vb.h, (void *)verify_invoke, &verify_desc, false);
    vb.t = b->t;
    sec_protocol_options_set_verify_block(sec, &vb, b->t->q);
    nw_release(sec);
}

static const BlockDesc cfg_desc = {0, sizeof(TlsCfgBlock), "v16@?0^{nw_protocol_options=}8", NULL};

/* --- TCP configure block: no captures, so a global literal (never copied, never freed) */
static void tcp_cfg_invoke(void *b, nw_protocol_options_t tcp) {
    (void)b;
    nw_tcp_options_set_connection_timeout(tcp, 30);
}

static const BlockDesc tcp_cfg_desc = {0, sizeof(BlockHdr), "v16@?0^{nw_protocol_options=}8", NULL};
static BlockHdr tcp_cfg_block = {_NSConcreteGlobalBlock, BLOCK_IS_GLOBAL | SIG_FLAG, 0, (void *)tcp_cfg_invoke,
                                 &tcp_cfg_desc};

/* --- state handler: void (^)(nw_connection_state_t, nw_error_t), captures t; carries
 * copy/dispose helpers that only count copies (t's lifetime is the caller's, as in tls.c) */
typedef struct StateBlock {
    BlockHdr h;
    Conn *t;
    void *literal; /* the stack literal's address: a call on another address ran on a copy */
} StateBlock;

static void count_copy(void *dst, const void *src) {
    (void)dst;
    (void)src;
    atomic_fetch_add(&live_copies, 1);
    atomic_fetch_add(&total_copies, 1);
}

static void count_dispose(const void *blk) {
    (void)blk;
    atomic_fetch_sub(&live_copies, 1);
}

static void state_invoke(StateBlock *b, nw_connection_state_t st, nw_error_t err) {
    Conn *t = b->t;
    if ((void *)b != b->literal) {
        atomic_fetch_add(&ran_on_copy, 1);
    }
    if (st == nw_connection_state_cancelled) {
        post(t->gone);
        return;
    }
    bool done = st == nw_connection_state_ready || st == nw_connection_state_waiting || st == nw_connection_state_failed;
    if (!done || t->reported) {
        return;
    }
    t->reported = true;
    t->ok = st == nw_connection_state_ready;
    if (err != NULL) {
        t->domain = (int)nw_error_get_error_domain(err);
        t->code = nw_error_get_error_code(err);
    }
    post(t->ready);
}

static const BlockDescCD state_desc = {0, sizeof(StateBlock), count_copy, count_dispose,
                                       "v20@?0i8^{nw_error=}12", NULL};

/* --- dispatch_sync block: void (^)(void), captures t, out */
typedef struct ReadOutBlock {
    BlockHdr h;
    Conn *t;
    Outcome *out;
} ReadOutBlock;

static void read_out_invoke(ReadOutBlock *b) {
    memcpy(b->out->why, b->t->why, sizeof b->t->why);
    b->out->ok = b->t->ok;
    b->out->saw_cert = b->t->saw_cert;
    b->out->domain = b->t->domain;
    b->out->code = b->t->code;
}

static const BlockDesc read_out_desc = {0, sizeof(ReadOutBlock), "v8@?0", NULL};

static void conn_free(Conn *t) {
    nw_connection_cancel(t->conn);
    dispatch_semaphore_wait(t->gone, DISPATCH_TIME_FOREVER);
    nw_release(t->conn);
    dispatch_release(t->q);
    dispatch_release(t->ready);
    dispatch_release(t->gone);
    free(t);
}

static Conn *connect_tls(const char *host, const char *port, int mode, SecCertificateRef anchor, bool fallback,
                         Outcome *out) {
    Conn *t = calloc(1, sizeof(Conn));
    t->q = dispatch_queue_create("spike.tls", DISPATCH_QUEUE_SERIAL);
    t->ready = dispatch_semaphore_create(0);
    t->gone = dispatch_semaphore_create(0);
    t->verify_mode = mode;
    t->anchor = anchor;
    t->host = host;
    nw_endpoint_t ep = nw_endpoint_create_host(host, port);

    /* The TLS configure literal is in malloc'd memory scribbled over and freed straight after
     * the call: if the framework kept our pointer instead of copying, invoking it would crash. */
    TlsCfgBlock *cfg = malloc(sizeof *cfg);
    block_init(&cfg->h, (void *)tls_cfg_invoke, &cfg_desc, false);
    cfg->t = t;
    cfg->fallback = fallback;
    nw_parameters_t params = nw_parameters_create_secure_tcp(cfg, &tcp_cfg_block);
    memset(cfg, 0xA5, sizeof *cfg);
    free(cfg);

    t->conn = nw_connection_create(ep, params);
    nw_release(ep);
    nw_release(params);
    nw_connection_set_queue(t->conn, t->q);

    StateBlock *sb = malloc(sizeof *sb);
    block_init(&sb->h, (void *)state_invoke, &state_desc, true);
    sb->t = t;
    sb->literal = sb;
    nw_connection_set_state_changed_handler(t->conn, sb);
    memset(sb, 0xA5, sizeof *sb);
    free(sb);

    nw_connection_start(t->conn);
    dispatch_semaphore_wait(t->ready, DISPATCH_TIME_FOREVER);

    ReadOutBlock rb; /* dispatch_sync never copies: a stack literal is enough */
    block_init(&rb.h, (void *)read_out_invoke, &read_out_desc, false);
    rb.t = t;
    rb.out = out;
    dispatch_sync(t->q, &rb);
    return t;
}

/* ---------------------------------------------------------------------------------------------
 * One receive / send in flight. The op's reference count is owned by the block copies: the
 * copy helper retains, the dispose helper releases, so the op lives exactly as long as the
 * framework holds the completion (even one that's dropped uncalled), plus the caller's own ref.
 * ------------------------------------------------------------------------------------------- */

typedef struct Op {
    _Atomic int refs;
    dispatch_semaphore_t done;
    uint8_t *buf;
    size_t n;
    bool fin;
    bool failed;
    int domain;
    int code;
} Op;

static Op *op_new(void) {
    Op *op = calloc(1, sizeof(Op));
    atomic_store(&op->refs, 1); /* the caller's */
    op->done = dispatch_semaphore_create(0);
    return op;
}

static void op_drop(Op *op) {
    if (atomic_fetch_sub(&op->refs, 1) == 1) {
        dispatch_release(op->done);
        free(op->buf);
        free(op);
    }
}

typedef struct OpBlock {
    BlockHdr h;
    Op *op;
    void *literal;
} OpBlock;

static void op_copy(void *dst, const void *src) {
    (void)src;
    atomic_fetch_add(&((OpBlock *)dst)->op->refs, 1);
    count_copy(dst, src);
}

static void op_dispose(const void *blk) {
    op_drop(((const OpBlock *)blk)->op);
    count_dispose(blk);
}

/* dispatch_data_apply applier: bool (^)(dispatch_data_t, size_t, const void *, size_t) */
static bool apply_invoke(OpBlock *b, dispatch_data_t region, size_t off, const void *bytes, size_t len) {
    (void)region;
    memcpy(b->op->buf + off, bytes, len);
    return true;
}

static const BlockDesc apply_desc = {0, sizeof(OpBlock), "B40@?0^{dispatch_data_s=}8Q16r^v24Q32", NULL};

/* receive completion: void (^)(dispatch_data_t, nw_content_context_t, bool, nw_error_t) */
static void recv_invoke(OpBlock *b, dispatch_data_t content, nw_content_context_t ctx, bool complete, nw_error_t err) {
    (void)ctx;
    Op *op = b->op;
    if ((void *)b != b->literal) {
        atomic_fetch_add(&ran_on_copy, 1);
    }
    if (content != NULL) {
        op->n = dispatch_data_get_size(content);
        op->buf = malloc(op->n != 0 ? op->n : 1);
        OpBlock ab;
        block_init(&ab.h, (void *)apply_invoke, &apply_desc, false);
        ab.op = op;
        ab.literal = &ab;
        dispatch_data_apply(content, &ab);
    }
    op->fin = complete;
    if (err != NULL) {
        op->failed = true;
        op->domain = (int)nw_error_get_error_domain(err);
        op->code = nw_error_get_error_code(err);
    }
    post(op->done);
}

static const BlockDescCD recv_desc = {
    0,    sizeof(OpBlock),
    op_copy, op_dispose,
    "v36@?0^{dispatch_data_s=}8^{nw_content_context=}16B24^{nw_error=}28",
    NULL};

/* send completion: void (^)(nw_error_t) */
static void send_invoke(OpBlock *b, nw_error_t err) {
    Op *op = b->op;
    if ((void *)b != b->literal) {
        atomic_fetch_add(&ran_on_copy, 1);
    }
    if (err != NULL) {
        op->failed = true;
        op->domain = (int)nw_error_get_error_domain(err);
        op->code = nw_error_get_error_code(err);
    }
    post(op->done);
}

static const BlockDescCD send_desc = {0, sizeof(OpBlock), op_copy, op_dispose, "v16@?0^{nw_error=}8", NULL};

static bool tls_send(Conn *t, const char *s) {
    dispatch_data_t data = dispatch_data_create(s, strlen(s), NULL, NULL);
    Op *op = op_new();
    OpBlock *b = malloc(sizeof *b);
    block_init(&b->h, (void *)send_invoke, &send_desc, true);
    b->op = op; /* the literal holds no reference: only its copies do */
    b->literal = b;
    nw_connection_send(t->conn, data, _nw_content_context_default_stream, false, b);
    memset(b, 0xA5, sizeof *b);
    free(b);
    dispatch_release(data);
    dispatch_semaphore_wait(op->done, DISPATCH_TIME_FOREVER);
    bool ok = !op->failed;
    op_drop(op);
    return ok;
}

/* Receive until `want` bytes arrived (or EOF / error); returns a malloc'd NUL-terminated string. */
static char *tls_recv(Conn *t, size_t want) {
    char *acc = calloc(1, want + 1);
    size_t have = 0;
    while (have < want) {
        Op *op = op_new();
        OpBlock *b = malloc(sizeof *b);
        block_init(&b->h, (void *)recv_invoke, &recv_desc, true);
        b->op = op;
        b->literal = b;
        nw_connection_receive(t->conn, 1, (uint32_t)(want - have), b);
        memset(b, 0xA5, sizeof *b);
        free(b);
        dispatch_semaphore_wait(op->done, DISPATCH_TIME_FOREVER);
        memcpy(acc + have, op->buf, op->n);
        have += op->n;
        bool stop = op->failed || op->fin || op->n == 0;
        op_drop(op);
        if (stop) {
            break;
        }
    }
    return acc;
}

/* ---------------------------------------------------------------------------------------------
 * dispatch_async / dispatch_sync with each kind of hand-made block.
 * ------------------------------------------------------------------------------------------- */

static _Atomic int bumps;

static void bump_global_invoke(void *b) {
    (void)b;
    atomic_fetch_add(&bumps, 1);
}

static const BlockDesc void_desc = {0, sizeof(BlockHdr), "v8@?0", NULL};
static BlockHdr bump_global = {_NSConcreteGlobalBlock, BLOCK_IS_GLOBAL | SIG_FLAG, 0, (void *)bump_global_invoke,
                               &void_desc};

/* captures a counter and an amount; plain (no helpers) */
typedef struct AddBlock {
    BlockHdr h;
    _Atomic int *ctr;
    int by;
} AddBlock;

static void add_invoke(AddBlock *b) {
    atomic_fetch_add(b->ctr, b->by);
}

static const BlockDesc add_desc = {0, sizeof(AddBlock), "v8@?0", NULL};

/* captures an Op (refcounted by copy/dispose) and posts its semaphore */
static void post_invoke(OpBlock *b) {
    atomic_fetch_add(&bumps, 100);
    if ((void *)b != b->literal) {
        atomic_fetch_add(&ran_on_copy, 1);
    }
    post(b->op->done);
}

static const BlockDescCD post_desc = {0, sizeof(OpBlock), op_copy, op_dispose, "v8@?0", NULL};

static int dispatch_checks(void) {
    int fails = 0;
    dispatch_queue_t q = dispatch_queue_create("spike.dispatch", DISPATCH_QUEUE_SERIAL);
    atomic_store(&bumps, 0);

    /* global: sync and async */
    dispatch_sync(q, &bump_global);
    dispatch_async(q, &bump_global);

    /* plain captured: sync from the stack, async from a scribbled-and-freed literal */
    AddBlock a;
    block_init(&a.h, (void *)add_invoke, &add_desc, false);
    a.ctr = &bumps;
    a.by = 10;
    dispatch_sync(q, &a);
    AddBlock *ah = malloc(sizeof *ah);
    *ah = a;
    dispatch_async(q, ah);
    memset(ah, 0xA5, sizeof *ah);
    free(ah);

    /* copy/dispose: async (copied, the copy holds an op ref), then sync */
    Op *op = op_new();
    OpBlock *pb = malloc(sizeof *pb);
    block_init(&pb->h, (void *)post_invoke, &post_desc, true);
    pb->op = op;
    pb->literal = pb;
    dispatch_async(q, pb);
    memset(pb, 0xA5, sizeof *pb);
    free(pb);
    dispatch_semaphore_wait(op->done, DISPATCH_TIME_FOREVER);
    OpBlock sb;
    block_init(&sb.h, (void *)post_invoke, &post_desc, true);
    sb.op = op;
    sb.literal = &sb;
    dispatch_sync(q, &sb);
    dispatch_semaphore_wait(op->done, DISPATCH_TIME_FOREVER);
    op_drop(op);

    /* our own _Block_copy / _Block_release of each kind */
    void *g = _Block_copy(&bump_global);
    if (g != &bump_global) {
        printf("FAIL _Block_copy of a global block returned a new block\n");
        fails++;
    }
    _Block_release(g);
    AddBlock *c1 = _Block_copy(&a);
    AddBlock *c2 = _Block_copy(c1); /* a heap block: same pointer, refcount + 1 */
    if (c1 == &a || c2 != c1 || !(c1->h.flags & BLOCK_NEEDS_FREE)) {
        printf("FAIL _Block_copy of a stack block: c1=%p c2=%p flags=%#x\n", (void *)c1, (void *)c2, c1->h.flags);
        fails++;
    }
    dispatch_sync(q, c1);
    _Block_release(c2);
    _Block_release(c1);

    dispatch_sync(q, &bump_global); /* drain */
    /* 1 + 1 (global) + 10 + 10 (add) + 100 + 100 (post) + 10 (copied add) + 1 (drain) */
    int want = 1 + 1 + 10 + 10 + 100 + 100 + 10 + 1;
    if (atomic_load(&bumps) != want) {
        printf("FAIL dispatch: bumps %d, want %d\n", atomic_load(&bumps), want);
        fails++;
    } else {
        printf("ok   dispatch_sync/dispatch_async with global, plain and copy/dispose blocks\n");
    }
    dispatch_release(q);
    return fails;
}

/* ---------------------------------------------------------------------------------------------
 * main
 * ------------------------------------------------------------------------------------------- */

static SecCertificateRef load_der(const char *path) {
    FILE *f = fopen(path, "rb");
    if (f == NULL) {
        perror(path);
        exit(2);
    }
    uint8_t buf[16384];
    size_t n = fread(buf, 1, sizeof buf, f);
    fclose(f);
    CFDataRef d = CFDataCreate(NULL, buf, (CFIndex)n);
    SecCertificateRef c = SecCertificateCreateWithData(NULL, d);
    CFRelease(d);
    if (c == NULL) {
        fprintf(stderr, "%s: not a DER certificate\n", path);
        exit(2);
    }
    return c;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: blocks <port> <cert.der>\n");
        return 2;
    }
    const char *host = "127.0.0.1";
    const char *port = argv[1];
    SecCertificateRef anchor = load_der(argv[2]);
    int fails = 0;
    Outcome o;

    /* 1. the system trust store refuses the self-signed certificate */
    memset(&o, 0, sizeof o);
    Conn *t = connect_tls(host, port, VERIFY_SYSTEM, anchor, false, &o);
    if (o.ok || !o.saw_cert) {
        printf("FAIL refuse: ok=%d saw_cert=%d\n", o.ok, o.saw_cert);
        fails++;
    } else {
        printf("ok   refused by the system trust store: domain %d code %d: %s\n", o.domain, o.code, o.why);
    }
    conn_free(t);

    /* 2. the verify block trusts the test certificate: handshake, send, receive, close */
    memset(&o, 0, sizeof o);
    t = connect_tls(host, port, VERIFY_ANCHOR, anchor, false, &o);
    if (!o.ok || !o.saw_cert) {
        printf("FAIL accept: ok=%d saw_cert=%d domain %d code %d why %s\n", o.ok, o.saw_cert, o.domain, o.code, o.why);
        fails++;
    } else {
        printf("ok   accepted with the test certificate as the only anchor\n");
        const char *msg = "hello, auk\n";
        if (!tls_send(t, msg)) {
            printf("FAIL send\n");
            fails++;
        }
        char *got = tls_recv(t, strlen(msg));
        /* s_server -rev sends each line back reversed */
        if (strcmp(got, "kua ,olleh\n") != 0) {
            printf("FAIL recv: got \"%s\"\n", got);
            fails++;
        } else {
            printf("ok   sent \"hello, auk\" and received \"%.*s\"\n", (int)strlen(got) - 1, got);
        }
        free(got);
    }
    conn_free(t);

    /* 3. the fallback configure (captured bool): TLS 1.2 max + TLS_FALLBACK_SCSV to a TLS 1.3
     * server is refused by the server (inappropriate_fallback), proving the capture took */
    memset(&o, 0, sizeof o);
    t = connect_tls(host, port, VERIFY_ANCHOR, anchor, true, &o);
    if (o.ok) {
        printf("FAIL fallback attempt was accepted by a TLS 1.3 server\n");
        fails++;
    } else {
        printf("ok   fallback attempt refused by the server: domain %d code %d\n", o.domain, o.code);
    }
    conn_free(t);

    fails += dispatch_checks();

    CFRelease(anchor);
    /* the framework releases handler copies asynchronously after cancel: give it a moment */
    for (int i = 0; i < 100 && atomic_load(&live_copies) != 0; i++) {
        dispatch_sync(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), &bump_global);
        struct timespec ts = {0, 10 * 1000 * 1000};
        nanosleep(&ts, NULL);
    }
    printf("%s block copies made by the framework/dispatch: %d, still live: %d, invocations on a copy: %d\n",
           atomic_load(&live_copies) == 0 ? "ok  " : "FAIL", atomic_load(&total_copies), atomic_load(&live_copies),
           atomic_load(&ran_on_copy));
    if (atomic_load(&live_copies) != 0) {
        fails++;
    }
    printf("%s\n", fails == 0 ? "PASS" : "FAILED");
    return fails == 0 ? 0 : 1;
}
