/* Stacks: programs, tests and tasks run on threads with big stacks, and a stack overflow is a
 * panic "stack overflow" instead of a bare SIGSEGV.
 *
 * Every Auk thread (the program's main thread, a test's, each task's) calls
 * auk__stack_thread_begin first: it records the thread's stack bounds and gives it an
 * alternate signal stack. The SIGSEGV/SIGBUS handler runs there; a fault just below the
 * stack (in or past its guard pages) is an overflow:
 * - on a thread with a recovery point (`catch`, every task) it jumps back to it, like a panic
 *   (catch.c), with the message "stack overflow";
 * - otherwise it prints `panic: stack overflow` and exits 101, like any panic.
 * Any other fault goes on to the handler that was installed before (the tracer's, or the
 * compiler's own when the program runs in its process), or to the default action.
 *
 * The location is the function that overflowed, by name, when the executable's symbol table
 * has it (`auk build`); code compiled in memory has no symbols, so it is `<unknown>` there. The
 * handler allocates nothing and writes with write(2).
 *
 * auk: own translation unit (system ucontext headers) */
#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif
#include <dlfcn.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <sys/ucontext.h>
#else
#include <elf.h>
#include <fcntl.h>
#include <link.h>
#include <sys/auxv.h>
#include <ucontext.h>
#endif

#include "auk_rt.h"

/* Bytes below a thread's stack that count as an overflow when touched: the guard pages, and
 * a frame that jumped past them. */
#define STACK_SLACK ((uintptr_t)1 << 20)
/* The guard below the stacks this runtime starts (a big frame can skip a small one). */
#define STACK_GUARD ((size_t)256 << 10)
#define ALT_STACK_SIZE ((size_t)64 << 10)

static _Thread_local uintptr_t stack_lo;
static _Thread_local void *alt_stack;
/* The overflow's location for a recovery point to pick up (catch.c). */
static _Thread_local char overflow_loc[160];

static struct sigaction old_segv;
static struct sigaction old_bus;
static pthread_once_t install_once = PTHREAD_ONCE_INIT;

static void put(const char *s) {
    size_t n = strlen(s);
    while (n > 0) {
        ssize_t w = write(2, s, n);
        if (w <= 0) {
            return;
        }
        s += w;
        n -= (size_t)w;
    }
}

static uintptr_t fault_pc(void *uc) {
    if (uc == NULL) {
        return 0;
    }
    ucontext_t *u = uc;
#if defined(__APPLE__) && defined(__aarch64__)
    return (uintptr_t)u->uc_mcontext->__ss.__pc;
#elif defined(__APPLE__) && defined(__x86_64__)
    return (uintptr_t)u->uc_mcontext->__ss.__rip;
#elif defined(__linux__) && defined(__aarch64__)
    return (uintptr_t)u->uc_mcontext.pc;
#elif defined(__linux__) && defined(__x86_64__)
    return (uintptr_t)u->uc_mcontext.gregs[REG_RIP];
#else
    (void)u;
    return 0;
#endif
}

#if defined(__linux__)
/* The function symbol containing pc in the executable's own .symtab, into out: on Linux,
 * dladdr only sees the dynamic symbol table, which doesn't have Auk's local functions. Read
 * with pread (async-signal-safe), nothing allocated. 1 when found. */
static int elf_sym_name(uintptr_t pc, char *out, size_t cap) {
    int fd = auk__c_open("/proc/self/exe", O_RDONLY | O_CLOEXEC, 0);
    if (fd < 0) {
        return 0;
    }
    int found = 0;
    ElfW(Ehdr) eh;
    if (pread(fd, &eh, sizeof eh, 0) != (ssize_t)sizeof eh || memcmp(eh.e_ident, ELFMAG, SELFMAG) != 0 || eh.e_shentsize != sizeof(ElfW(Shdr))) {
        close(fd);
        return 0;
    }
    /* a PIE is loaded at its program headers' address less their file offset */
    uintptr_t addr = eh.e_type == ET_DYN ? pc - ((uintptr_t)getauxval(AT_PHDR) - (uintptr_t)eh.e_phoff) : pc;
    for (unsigned i = 0; i < eh.e_shnum && !found; i++) {
        ElfW(Shdr) sh, str;
        if (pread(fd, &sh, sizeof sh, (off_t)(eh.e_shoff + (uint64_t)i * sizeof sh)) != (ssize_t)sizeof sh || sh.sh_type != SHT_SYMTAB) {
            continue;
        }
        if (pread(fd, &str, sizeof str, (off_t)(eh.e_shoff + (uint64_t)sh.sh_link * sizeof str)) != (ssize_t)sizeof str) {
            break;
        }
        ElfW(Sym) syms[64];
        size_t n = sh.sh_size / sizeof syms[0];
        for (size_t k = 0; k < n && !found; k += 64) {
            size_t m = n - k < 64 ? n - k : 64;
            if (pread(fd, syms, m * sizeof syms[0], (off_t)(sh.sh_offset + k * sizeof syms[0])) != (ssize_t)(m * sizeof syms[0])) {
                break;
            }
            for (size_t j = 0; j < m; j++) {
                ElfW(Sym) *s = &syms[j];
                if ((s->st_info & 0xf) == STT_FUNC && addr >= s->st_value && addr < s->st_value + s->st_size) {
                    ssize_t r = pread(fd, out, cap - 1, (off_t)(str.sh_offset + s->st_name));
                    out[r > 0 ? r : 0] = 0;
                    found = r > 0;
                    break;
                }
            }
        }
    }
    close(fd);
    return found;
}
#endif

/* The Auk name of the function at pc ("dk_f12_parse" -> "parse"), into out; "<unknown>"
 * when there are no symbols. */
static void fn_name(uintptr_t pc, char *out, size_t cap) {
    const char *name = NULL;
    Dl_info info;
#if defined(__linux__)
    char sym[256];
    if (pc != 0 && elf_sym_name(pc, sym, sizeof sym)) {
        name = sym;
    } else
#endif
    if (pc != 0 && dladdr((void *)pc, &info) != 0 && info.dli_sname != NULL) {
        name = info.dli_sname;
    }
    if (name != NULL) {
        if (name[0] == '_') {
            name++;
        }
        if (strncmp(name, "dk_f", 4) == 0) {
            const char *p = name + 4;
            while (*p >= '0' && *p <= '9') {
                p++;
            }
            if (*p == '_') {
                name = p + 1;
            }
        }
    }
    if (name == NULL || name[0] == 0) {
        name = "<unknown>";
    }
    size_t n = strlen(name);
    if (n >= cap) {
        n = cap - 1;
    }
    memcpy(out, name, n);
    out[n] = 0;
}

static void pass_on(int sig, siginfo_t *si, void *uc) {
    struct sigaction *old = sig == SIGBUS ? &old_bus : &old_segv;
    if ((old->sa_flags & SA_SIGINFO) != 0 && old->sa_sigaction != NULL) {
        old->sa_sigaction(sig, si, uc);
        return;
    }
    if (old->sa_handler != SIG_DFL && old->sa_handler != SIG_IGN && old->sa_handler != NULL) {
        old->sa_handler(sig);
        return;
    }
    /* the default action: returning re-runs the faulting instruction, which faults again */
    signal(sig, SIG_DFL);
}

/* Runs on the overflowed thread's own stack after the handler returns: on to the recovery
 * point. */
static void overflow_resume(void) {
    auk__catch_throw_overflow();
}

/* Make the handler return into overflow_resume, on a little stack just above the overflow and
 * below the recovery point (the frames between are abandoned anyway). Jumping straight out of
 * the handler would leave the kernel thinking the thread is still on its alternate stack
 * (macOS), and the next overflow could not be reported. */
static bool redirect(void *uc) {
    uintptr_t sp = stack_lo + ((uintptr_t)32 << 10);
    uintptr_t rp = auk__catch_top_addr();
    if (rp != 0 && rp - 512 < sp) {
        sp = rp - 512;
    }
    sp &= ~(uintptr_t)15;
    if (uc == NULL || sp <= stack_lo) {
        return false;
    }
    ucontext_t *u = uc;
#if defined(__APPLE__) && defined(__aarch64__)
    u->uc_mcontext->__ss.__pc = (uint64_t)(uintptr_t)overflow_resume;
    u->uc_mcontext->__ss.__sp = (uint64_t)sp;
    return true;
#elif defined(__APPLE__) && defined(__x86_64__)
    u->uc_mcontext->__ss.__rip = (uint64_t)(uintptr_t)overflow_resume;
    u->uc_mcontext->__ss.__rsp = (uint64_t)(sp - 8);
    return true;
#elif defined(__linux__) && defined(__aarch64__)
    u->uc_mcontext.pc = (uint64_t)(uintptr_t)overflow_resume;
    u->uc_mcontext.sp = (uint64_t)sp;
    return true;
#elif defined(__linux__) && defined(__x86_64__)
    u->uc_mcontext.gregs[REG_RIP] = (greg_t)(uintptr_t)overflow_resume;
    u->uc_mcontext.gregs[REG_RSP] = (greg_t)(sp - 8);
    return true;
#else
    (void)u;
    return false;
#endif
}

static void flush_stdout(void) {
    /* what the program printed so far, unless the overflow hit inside stdio */
    if (ftrylockfile(stdout) == 0) {
        fflush(stdout);
        funlockfile(stdout);
    }
}

static void on_fault(int sig, siginfo_t *si, void *uc) {
    uintptr_t a = (uintptr_t)si->si_addr;
    bool overflow = stack_lo != 0 && a < stack_lo + 4096 && a + STACK_SLACK >= stack_lo;
    if (!overflow) {
        pass_on(sig, si, uc);
        return;
    }
    fn_name(fault_pc(uc), overflow_loc, sizeof overflow_loc);
    if (auk__catch_active()) {
        if (redirect(uc)) {
            return;
        }
        auk__catch_throw_overflow();
    }
    flush_stdout();
    auk__trace_on_overflow(overflow_loc);
    put("panic: stack overflow\n  at ");
    put(overflow_loc);
    put("\n");
    _exit(101);
}

static void install(void) {
    struct sigaction sa;
    /* already in front: keep the handler it passes other faults on to */
    if (sigaction(SIGSEGV, NULL, &sa) == 0 && (sa.sa_flags & SA_SIGINFO) != 0 && sa.sa_sigaction == on_fault) {
        return;
    }
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = on_fault;
    /* SA_NODEFER: a recovery point jumps out of the handler, which must leave SIGSEGV
     * unblocked for the next overflow */
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_NODEFER;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, &old_segv);
    sigaction(SIGBUS, &sa, &old_bus);
}

/* Put the overflow handler back in front of a crash handler installed after it (the tracer's),
 * which then gets the faults that aren't overflows. The first Auk thread installs it once, so
 * in a process whose runtime started before the program (the self-hosted compiler running the
 * program it compiled) the tracer's handler would otherwise come first, and an overflow would
 * end as a bare signal instead of a panic. */
void auk__stack_handlers_first(void) {
    install();
}

/* At the start of an Auk thread: record its stack and give it an alternate signal stack. */
void auk__stack_thread_begin(void) {
    pthread_once(&install_once, install);
    pthread_t self = pthread_self();
#if defined(__APPLE__)
    uintptr_t hi = (uintptr_t)pthread_get_stackaddr_np(self);
    stack_lo = hi - (uintptr_t)pthread_get_stacksize_np(self);
#else
    pthread_attr_t attr;
    if (pthread_getattr_np(self, &attr) == 0) {
        void *addr = NULL;
        size_t size = 0;
        pthread_attr_getstack(&attr, &addr, &size);
        stack_lo = (uintptr_t)addr;
        pthread_attr_destroy(&attr);
    }
#endif
    if (alt_stack == NULL) {
        alt_stack = malloc(ALT_STACK_SIZE);
        if (alt_stack != NULL) {
            stack_t ss;
            memset(&ss, 0, sizeof ss);
            ss.ss_sp = alt_stack;
            ss.ss_size = ALT_STACK_SIZE;
            sigaltstack(&ss, NULL);
        }
    }
}

/* At the end of an Auk thread started by the runtime. */
void auk__stack_thread_end(void) {
    stack_lo = 0;
    if (alt_stack != NULL) {
        stack_t ss;
        memset(&ss, 0, sizeof ss);
        ss.ss_flags = SS_DISABLE;
        sigaltstack(&ss, NULL);
        free(alt_stack);
        alt_stack = NULL;
    }
}

/* The location of the last overflow on this thread (for catch.c). */
const char *auk__stack_overflow_loc(void) {
    return overflow_loc;
}

/* Attributes for a thread with a stack of `size` bytes and a big guard. */
void auk__stack_attr(void *a, size_t size) {
    pthread_attr_t *attr = a;
    pthread_attr_init(attr);
    pthread_attr_setstacksize(attr, size);
    pthread_attr_setguardsize(attr, STACK_GUARD);
}

typedef struct BigRun {
    void (*f)(void *);
    void *arg;
    int64_t dbg_id;
} BigRun;

static void *big_entry(void *p) {
    BigRun *r = p;
    auk__dbg_thread_adopt(r->dbg_id);
    auk__stack_thread_begin();
    r->f(r->arg);
    auk__stack_thread_end();
    return NULL;
}

/* Run f(arg) on a new thread with a stack of AUK_MAIN_STACK bytes and wait for it (on this
 * thread, with overflow reporting, when no thread can be started). */
void auk__run_on_big_stack(void (*f)(void *), void *arg) {
    BigRun r = {f, arg, auk__dbg_thread_handoff()};
    pthread_attr_t attr;
    auk__stack_attr(&attr, AUK_MAIN_STACK);
    pthread_t th;
    int rc = pthread_create(&th, &attr, big_entry, &r);
    pthread_attr_destroy(&attr);
    if (rc != 0) {
        auk__dbg_thread_adopt(r.dbg_id);
        auk__stack_thread_begin();
        f(arg);
        return;
    }
    pthread_join(th, NULL);
}
