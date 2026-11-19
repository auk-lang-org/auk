/* Prints, as Auk source of the runtime's `raw` dialect, the C library facts the runtime uses on
 * this platform: constants, struct layouts, opaque type sizes, the pthread static initializers,
 * the ucontext register slots, and the C macros over functions (W*, S_ISDIR, CMSG_*, errno,
 * stdout/stderr) as small raw functions. Run by runtime/gen/cfacts.sh, which writes the output
 * to runtime/src/cfacts.<os>-<arch>.auk (docs/lowlevel.md, section 11).
 *
 * Output conventions (runtime/test/abi/run.sh parses them to check the checked-in file against
 * the headers again): every struct is preceded by `/// C: <C type>[; <auk>=<c> ...]` (field
 * renames) or `/// C: <C type>; opaque`, has one field per line, and padding fields named
 * `_pad<n>`; every constant that is a C expression ends with `// C: <expr>`. */
#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <netdb.h>
#include <netinet/in.h>
#include <poll.h>
#include <setjmp.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <dispatch/dispatch.h>
#include <sys/ucontext.h>
#else
#include <elf.h>
#include <link.h>
#include <sys/auxv.h>
#include <ucontext.h>
#endif

#if __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#error "cfacts: initializers are written as little-endian words"
#endif
#if defined(__APPLE__)
static const char *OS = "macos";
#elif defined(__linux__)
static const char *OS = "linux";
#else
#error "cfacts: unsupported OS"
#endif
#if defined(__aarch64__)
static const char *ARCH = "arm64";
#elif defined(__x86_64__)
static const char *ARCH = "x86_64";
#else
#error "cfacts: unsupported CPU"
#endif

/* ---- structs ---------------------------------------------------------------------------- */

typedef struct Field {
    const char *name;  /* the Auk field name */
    const char *cname; /* the C member, when it differs */
    char ty[64];       /* the Auk type */
    size_t off, size;
} Field;

static Field fields[64];
static int nfields;
static const char *s_auk, *s_c;
static size_t s_size, s_align;

static void begin(const char *auk, const char *c, size_t size, size_t align) {
    s_auk = auk;
    s_c = c;
    s_size = size;
    s_align = align;
    nfields = 0;
}

static void add(const char *name, const char *cname, const char *ty, size_t off, size_t size) {
    Field *f = &fields[nfields++];
    f->name = name;
    f->cname = cname;
    snprintf(f->ty, sizeof f->ty, "%s", ty);
    f->off = off;
    f->size = size;
}

static const char *int_ty(size_t size, int is_signed) {
    switch (size) {
    case 1: return is_signed ? "i8" : "u8";
    case 2: return is_signed ? "i16" : "u16";
    case 4: return is_signed ? "i32" : "u32";
    case 8: return is_signed ? "i64" : "u64";
    }
    fprintf(stderr, "cfacts: no integer type of %zu bytes\n", size);
    exit(1);
}

static int npad;

/* Fill [pos, end) with fields that keep every later offset where C has it: the widest
 * unsigned word the position's alignment allows, then wider ones as the position grows. */
static size_t pad(size_t pos, size_t end) {
    while (pos < end) {
        size_t k = s_align < 8 ? s_align : 8;
        while (k > 1 && (pos % k != 0 || k > end - pos)) k /= 2;
        size_t n = k == (s_align < 8 ? s_align : 8) ? (end - pos) / k : 1;
        const char *w = int_ty(k, 0);
        if (n == 1) {
            printf("  _pad%d: %s,\n", npad++, w);
        } else {
            printf("  _pad%d: [%s; %zu],\n", npad++, w, n);
        }
        pos += k * n;
    }
    return pos;
}

static int by_off(const void *a, const void *b) {
    const Field *x = a, *y = b;
    return x->off < y->off ? -1 : x->off > y->off;
}

static void end(void) {
    qsort(fields, (size_t)nfields, sizeof(Field), by_off);
    printf("/// C: %s", s_c);
    const char *sep = "; ";
    for (int i = 0; i < nfields; i++) {
        if (fields[i].cname != NULL) {
            printf("%s%s=%s", sep, fields[i].name, fields[i].cname);
            sep = " ";
        }
    }
    printf("\npub raw struct %s {\n", s_auk);
    npad = 0;
    size_t pos = 0;
    for (int i = 0; i < nfields; i++) {
        Field *f = &fields[i];
        if (f->off < pos) {
            fprintf(stderr, "cfacts: %s.%s overlaps the field before it\n", s_c, f->name);
            exit(1);
        }
        pos = pad(pos, f->off);
        printf("  %s: %s,\n", f->name, f->ty);
        pos += f->size;
    }
    pad(pos, s_size);
    printf("}\n");
    printf("raw assert raw.size_of<%s>() == %zu && raw.align_of<%s>() == %zu\n", s_auk, s_size, s_auk, s_align);
    for (int i = 0; i < nfields; i++) {
        printf("raw assert raw.offset_of<%s>(.%s) == %zu\n", s_auk, fields[i].name, fields[i].off);
    }
    printf("\n");
}

#define MEMBER(T, f) (((T *)0)->f)
#define STRUCT(A, T) begin(#A, #T, sizeof(T), _Alignof(T))
/* a field of the Auk type `ty` */
#define FIELD(T, f, ty) add(#f, NULL, ty, offsetof(T, f), sizeof(MEMBER(T, f)))
/* a field whose C member has another name on this platform */
#define FIELD_AS(T, f, c, ty) add(#f, #c, ty, offsetof(T, c), sizeof(MEMBER(T, c)))
/* an integer field: the fixed-width type of its size and signedness */
#define INT(T, f) add(#f, NULL, int_ty(sizeof(MEMBER(T, f)), (__typeof__(MEMBER(T, f)))-1 < 0), offsetof(T, f), sizeof(MEMBER(T, f)))
#define PTR(T, f, to) add(#f, NULL, "raw.Ptr<" to ">", offsetof(T, f), sizeof(MEMBER(T, f)))
static char arr_buf[64];
static const char *arr(const char *elem, size_t n) {
    snprintf(arr_buf, sizeof arr_buf, "[%s; %zu]", elem, n);
    return arr_buf;
}
#define BYTES(T, f) add(#f, NULL, arr("u8", sizeof(MEMBER(T, f))), offsetof(T, f), sizeof(MEMBER(T, f)))

/* An opaque C type: words of its alignment, w0, w1, ... (named, so a raw struct literal can
 * spell a static initializer), or an array `w` of them when there are more than 8. */
static void opaque_(const char *auk, const char *c, size_t size, size_t align) {
    const char *w = int_ty(align, 0);
    printf("/// C: %s; opaque\npub raw struct %s {\n", c, auk);
    if (size / align > 8) {
        printf("  w: [%s; %zu],\n", w, size / align);
    } else {
        for (size_t i = 0; i < size / align; i++) printf("  w%zu: %s,\n", i, w);
    }
    printf("}\n");
    printf("raw assert raw.size_of<%s>() == %zu && raw.align_of<%s>() == %zu\n\n", auk, size, auk, align);
}
#define OPAQUE(A, T) opaque_(#A, #T, sizeof(T), _Alignof(T))

/* A static initializer of an opaque type, as a struct literal of its words. */
static void init_(const char *name, const char *auk, const void *p, size_t size, size_t align) {
    if (size / align > 8) {
        fprintf(stderr, "cfacts: %s: an initializer of more than 8 words\n", name);
        exit(1);
    }
    printf("pub raw let %s: %s = %s {", name, auk, auk);
    const char *sep = " ";
    for (size_t i = 0; i < size / align; i++) {
        uint64_t v = 0;
        memcpy(&v, (const uint8_t *)p + i * align, align); /* little-endian: the low bytes */
        if (v != 0) {
            printf("%sw%zu: %llu", sep, i, (unsigned long long)v);
            sep = ", ";
        }
    }
    printf(" } // C: %s\n", name);
}
#define INIT(NAME, A, T)                                         \
    do {                                                         \
        static T v_ = NAME;                                      \
        init_(#NAME, #A, &v_, sizeof(T), _Alignof(T));           \
    } while (0)

/* ---- constants -------------------------------------------------------------------------- */

static void konst(const char *name, const char *ty, long long v) {
    printf("pub raw let %s: %s = %lld // C: %s\n", name, ty, v, name);
}
static void konst_u(const char *name, const char *ty, unsigned long long v) {
    printf("pub raw let %s: %s = %llu // C: %s\n", name, ty, v, name);
}
#define I32(N) konst(#N, "i32", (long long)(int32_t)(N))
#define I16(N) konst(#N, "i16", (long long)(int16_t)(N))
#define U32(N) konst(#N, "u32", (long long)(uint32_t)(N))
#define U64(N) konst_u(#N, "u64", (unsigned long long)(N))
/* a pointer-valued constant (SIG_DFL, MAP_FAILED, ...), as its address */
#define ADDR(N) konst(#N, "i64", (long long)(intptr_t)(N))
/* a constant only some platforms have: HAS_<N> and its value (0 where it doesn't exist) */
static void has(const char *name, int present, long long v) {
    printf("pub raw let HAS_%s: bool = %s\n", name, present ? "true" : "false");
    if (present) {
        printf("pub raw let %s: i32 = %d // C: %s\n", name, (int32_t)v, name);
    } else {
        printf("pub raw let %s: i32 = 0\n", name);
    }
}

static void comment(const char *s) { printf("\n// ---- %s ----\n\n", s); }

#define TYPEDEF(T) printf("// %s: %s\n", #T, int_ty(sizeof(T), (T)-1 < 0))

int main(void) {
    printf("// Generated by runtime/gen/cfacts.sh on %s-%s: the C library facts the runtime uses\n", OS, ARCH);
    printf("// (docs/lowlevel.md, section 11). Do not edit; run the script again.\n");
    printf("// Every platform's file declares the same items above \"only on %s\" (the end).\n", OS);

    comment("C typedefs (the dialect has no aliases: write the fixed-width type)");
    TYPEDEF(off_t);
    TYPEDEF(pid_t);
    TYPEDEF(mode_t);
    TYPEDEF(uid_t);
    TYPEDEF(gid_t);
    TYPEDEF(socklen_t);
    TYPEDEF(sa_family_t);
    TYPEDEF(in_port_t);
    TYPEDEF(time_t);
    TYPEDEF(ssize_t);
    TYPEDEF(nfds_t);
    TYPEDEF(clockid_t);
    TYPEDEF(sig_atomic_t);
    printf("// pthread_t, pthread_key_t, sigset_t, ...: the opaque structs below\n");

    comment("files: open, fcntl, stat");
    I32(O_RDONLY);
    I32(O_WRONLY);
    I32(O_RDWR);
    I32(O_CREAT);
    I32(O_EXCL);
    I32(O_TRUNC);
    I32(O_APPEND);
    I32(O_NONBLOCK);
    I32(O_CLOEXEC);
    I32(O_DIRECTORY);
    I32(F_GETFD);
    I32(F_SETFD);
    I32(F_GETFL);
    I32(F_SETFL);
    I32(FD_CLOEXEC);
    U32(S_IFMT);
    U32(S_IFDIR);
    U32(S_IFREG);
    U32(S_IFLNK);
    I32(PATH_MAX);
    U64(TIOCGWINSZ);
    I32(SEEK_SET);
    I32(SEEK_CUR);
    I32(SEEK_END);

    comment("errno values");
    I32(EPERM);
    I32(ENOENT);
    I32(EINTR);
    I32(EIO);
    I32(EBADF);
    I32(EAGAIN);
    I32(EWOULDBLOCK);
    I32(ENOMEM);
    I32(EACCES);
    I32(EEXIST);
    I32(ENOTDIR);
    I32(EISDIR);
    I32(EINVAL);
    I32(EPIPE);
    I32(ENOSYS);
    I32(ENOTEMPTY);
    I32(ENAMETOOLONG);
    I32(ENODATA);
    I32(EINPROGRESS);
    I32(EADDRINUSE);
    I32(ECONNABORTED);
    I32(ECONNRESET);
    I32(ECONNREFUSED);
    I32(ETIMEDOUT);

    comment("signals");
    I32(SIGINT);
    I32(SIGILL);
    I32(SIGABRT);
    I32(SIGFPE);
    I32(SIGKILL);
    I32(SIGBUS);
    I32(SIGSEGV);
    I32(SIGPIPE);
    I32(SIGTERM);
    I32(SIGCHLD);
    I32(SIGWINCH);
    I32(SA_ONSTACK);
    I32(SA_RESTART);
    I32(SA_RESETHAND);
    I32(SA_NODEFER);
    I32(SA_SIGINFO);
    I32(SS_DISABLE);
    I32(MINSIGSTKSZ);
    ADDR(SIG_DFL);
    ADDR(SIG_IGN);
    I32(WNOHANG);

    comment("sockets");
    I32(AF_UNSPEC);
    I32(AF_UNIX);
    I32(AF_INET);
    I32(AF_INET6);
    I32(SOCK_STREAM);
    I32(SOCK_DGRAM);
    I32(SOL_SOCKET);
    I32(SO_REUSEADDR);
    I32(SO_ERROR);
    I32(SO_KEEPALIVE);
    I32(SCM_RIGHTS);
    I32(IPPROTO_TCP);
    I32(SHUT_RD);
    I32(SHUT_WR);
    I32(SHUT_RDWR);
    I32(MSG_PEEK);
    I32(AI_PASSIVE);
    I32(AI_NUMERICHOST);
#if defined(SO_NOSIGPIPE)
    has("SO_NOSIGPIPE", 1, SO_NOSIGPIPE);
#else
    has("SO_NOSIGPIPE", 0, 0);
#endif
#if defined(MSG_NOSIGNAL)
    has("MSG_NOSIGNAL", 1, MSG_NOSIGNAL);
#else
    has("MSG_NOSIGNAL", 0, 0);
#endif
    I16(POLLIN);
    I16(POLLOUT);
    I16(POLLERR);
    I16(POLLHUP);
    I16(POLLNVAL);

    comment("time, memory, threads, dynamic loading, processes");
    I32(CLOCK_REALTIME);
    I32(CLOCK_MONOTONIC);
    I32(PROT_NONE);
    I32(PROT_READ);
    I32(PROT_WRITE);
    I32(MAP_SHARED);
    I32(MAP_PRIVATE);
    I32(MAP_ANON);
    ADDR(MAP_FAILED);
    I32(PTHREAD_CREATE_JOINABLE);
    I32(PTHREAD_CREATE_DETACHED);
    I32(RTLD_LAZY);
    I32(RTLD_NOW);
    I32(RTLD_GLOBAL);
    I32(RTLD_LOCAL);
    ADDR(RTLD_DEFAULT);
#if defined(POSIX_SPAWN_CLOEXEC_DEFAULT)
    has("POSIX_SPAWN_CLOEXEC_DEFAULT", 1, POSIX_SPAWN_CLOEXEC_DEFAULT);
#else
    has("POSIX_SPAWN_CLOEXEC_DEFAULT", 0, 0);
#endif

    comment("opaque types (only their size and alignment are the platform's)");
    OPAQUE(PthreadT, pthread_t);
    OPAQUE(PthreadMutex, pthread_mutex_t);
    OPAQUE(PthreadMutexAttr, pthread_mutexattr_t);
    OPAQUE(PthreadCond, pthread_cond_t);
    OPAQUE(PthreadCondAttr, pthread_condattr_t);
    OPAQUE(PthreadOnce, pthread_once_t);
    OPAQUE(PthreadAttr, pthread_attr_t);
    OPAQUE(PthreadKey, pthread_key_t);
    OPAQUE(SigSet, sigset_t);
    OPAQUE(PosixSpawnFileActions, posix_spawn_file_actions_t);
    OPAQUE(PosixSpawnAttr, posix_spawnattr_t);
    printf("raw assert raw.size_of<raw.JmpBuf>() >= %zu && raw.align_of<raw.JmpBuf>() >= %zu // C: jmp_buf (_setjmp)\n\n", sizeof(jmp_buf), _Alignof(jmp_buf));
    INIT(PTHREAD_MUTEX_INITIALIZER, PthreadMutex, pthread_mutex_t);
    INIT(PTHREAD_COND_INITIALIZER, PthreadCond, pthread_cond_t);
    INIT(PTHREAD_ONCE_INIT, PthreadOnce, pthread_once_t);

    comment("structs");
    STRUCT(Timespec, struct timespec);
    INT(struct timespec, tv_sec);
    INT(struct timespec, tv_nsec);
    end();

    STRUCT(Timeval, struct timeval);
    INT(struct timeval, tv_sec);
    INT(struct timeval, tv_usec);
    end();

    STRUCT(Stat, struct stat);
    INT(struct stat, st_dev);
    INT(struct stat, st_ino);
    INT(struct stat, st_mode);
    INT(struct stat, st_nlink);
    INT(struct stat, st_uid);
    INT(struct stat, st_gid);
    INT(struct stat, st_rdev);
    INT(struct stat, st_size);
    INT(struct stat, st_blksize);
    INT(struct stat, st_blocks);
#if defined(__APPLE__)
    FIELD_AS(struct stat, st_atim, st_atimespec, "Timespec");
    FIELD_AS(struct stat, st_mtim, st_mtimespec, "Timespec");
    FIELD_AS(struct stat, st_ctim, st_ctimespec, "Timespec");
#else
    FIELD(struct stat, st_atim, "Timespec");
    FIELD(struct stat, st_mtim, "Timespec");
    FIELD(struct stat, st_ctim, "Timespec");
#endif
    end();

    STRUCT(Dirent, struct dirent);
    INT(struct dirent, d_ino);
    INT(struct dirent, d_reclen);
    INT(struct dirent, d_type);
    BYTES(struct dirent, d_name);
    end();

    STRUCT(Winsize, struct winsize);
    INT(struct winsize, ws_row);
    INT(struct winsize, ws_col);
    INT(struct winsize, ws_xpixel);
    INT(struct winsize, ws_ypixel);
    end();

    STRUCT(Pollfd, struct pollfd);
    INT(struct pollfd, fd);
    INT(struct pollfd, events);
    INT(struct pollfd, revents);
    end();

    STRUCT(Iovec, struct iovec);
    PTR(struct iovec, iov_base, "()");
    INT(struct iovec, iov_len);
    end();

    STRUCT(Msghdr, struct msghdr);
    PTR(struct msghdr, msg_name, "()");
    INT(struct msghdr, msg_namelen);
    PTR(struct msghdr, msg_iov, "Iovec");
    INT(struct msghdr, msg_iovlen);
    PTR(struct msghdr, msg_control, "()");
    INT(struct msghdr, msg_controllen);
    INT(struct msghdr, msg_flags);
    end();

    STRUCT(Cmsghdr, struct cmsghdr);
    INT(struct cmsghdr, cmsg_len);
    INT(struct cmsghdr, cmsg_level);
    INT(struct cmsghdr, cmsg_type);
    end();

    STRUCT(Sockaddr, struct sockaddr);
    INT(struct sockaddr, sa_family);
    BYTES(struct sockaddr, sa_data);
    end();

    STRUCT(SockaddrIn, struct sockaddr_in);
    INT(struct sockaddr_in, sin_family);
    INT(struct sockaddr_in, sin_port);
    FIELD(struct sockaddr_in, sin_addr, "u32");
    end();

    STRUCT(SockaddrIn6, struct sockaddr_in6);
    INT(struct sockaddr_in6, sin6_family);
    INT(struct sockaddr_in6, sin6_port);
    INT(struct sockaddr_in6, sin6_flowinfo);
    FIELD(struct sockaddr_in6, sin6_addr, "[u8; 16]");
    INT(struct sockaddr_in6, sin6_scope_id);
    end();

    STRUCT(SockaddrUn, struct sockaddr_un);
    INT(struct sockaddr_un, sun_family);
    BYTES(struct sockaddr_un, sun_path);
    end();

    STRUCT(SockaddrStorage, struct sockaddr_storage);
    INT(struct sockaddr_storage, ss_family);
    end();

    STRUCT(Addrinfo, struct addrinfo);
    INT(struct addrinfo, ai_flags);
    INT(struct addrinfo, ai_family);
    INT(struct addrinfo, ai_socktype);
    INT(struct addrinfo, ai_protocol);
    INT(struct addrinfo, ai_addrlen);
    PTR(struct addrinfo, ai_canonname, "u8");
    PTR(struct addrinfo, ai_addr, "Sockaddr");
    PTR(struct addrinfo, ai_next, "Addrinfo");
    end();

    /* sa_handler and sa_sigaction share a union at the same offset: one field, a code address
     * (raw.cast(raw.fn_of(handler)); SIG_DFL/SIG_IGN are raw.from_int of theirs) */
    STRUCT(Sigaction, struct sigaction);
    PTR(struct sigaction, sa_handler, "()");
    FIELD(struct sigaction, sa_mask, "SigSet");
    INT(struct sigaction, sa_flags);
    end();

    STRUCT(StackT, stack_t);
    PTR(stack_t, ss_sp, "()");
    INT(stack_t, ss_size);
    INT(stack_t, ss_flags);
    end();

    STRUCT(DlInfo, Dl_info);
    PTR(Dl_info, dli_fname, "u8");
    PTR(Dl_info, dli_fbase, "()");
    PTR(Dl_info, dli_sname, "u8");
    PTR(Dl_info, dli_saddr, "()");
    end();

    comment("signal handler context (stack.c): the fault address, the interrupted PC and SP");
    printf("pub raw let SIGINFO_ADDR: i64 = %zu // C: offsetof(siginfo_t, si_addr)\n", offsetof(siginfo_t, si_addr));
#if defined(__APPLE__)
    printf("/// The mcontext pointer's offset in a ucontext_t (macOS: uc_mcontext is a pointer).\n");
    printf("raw let UC_MCONTEXT: i64 = %zu\n", offsetof(ucontext_t, uc_mcontext));
#if defined(__aarch64__)
    size_t pc = offsetof(struct __darwin_mcontext64, __ss.__pc), sp = offsetof(struct __darwin_mcontext64, __ss.__sp);
#else
    size_t pc = offsetof(struct __darwin_mcontext64, __ss.__rip), sp = offsetof(struct __darwin_mcontext64, __ss.__rsp);
#endif
    printf("raw let MC_PC: i64 = %zu\nraw let MC_SP: i64 = %zu\n", pc, sp);
    printf("fn mcontext(uc: raw.Ptr<()>): raw.Ptr<u8> uses raw {\n");
    printf("  let p: raw.Ptr<raw.Ptr<u8>> = raw.cast(raw.cast<u8>(uc).offset(UC_MCONTEXT))\n");
    printf("  p.load()\n}\n");
    printf("/// The interrupted program counter in a signal handler's ucontext (read or write it).\n");
    printf("pub fn uc_pc(uc: raw.Ptr<()>): raw.Ptr<u64> uses raw = raw.cast(mcontext(uc).offset(MC_PC))\n");
    printf("/// The interrupted stack pointer.\n");
    printf("pub fn uc_sp(uc: raw.Ptr<()>): raw.Ptr<u64> uses raw = raw.cast(mcontext(uc).offset(MC_SP))\n");
#else
#if defined(__aarch64__)
    size_t pc = offsetof(ucontext_t, uc_mcontext.pc), sp = offsetof(ucontext_t, uc_mcontext.sp);
#else
    size_t pc = offsetof(ucontext_t, uc_mcontext.gregs[REG_RIP]), sp = offsetof(ucontext_t, uc_mcontext.gregs[REG_RSP]);
#endif
    printf("raw let UC_PC: i64 = %zu\nraw let UC_SP: i64 = %zu\n", pc, sp);
    printf("/// The interrupted program counter in a signal handler's ucontext (read or write it).\n");
    printf("pub fn uc_pc(uc: raw.Ptr<()>): raw.Ptr<u64> uses raw = raw.cast(raw.cast<u8>(uc).offset(UC_PC))\n");
    printf("/// The interrupted stack pointer.\n");
    printf("pub fn uc_sp(uc: raw.Ptr<()>): raw.Ptr<u64> uses raw = raw.cast(raw.cast<u8>(uc).offset(UC_SP))\n");
#endif
    printf("/// The faulting address of a SIGSEGV/SIGBUS (siginfo_t's si_addr).\n");
    printf("pub fn si_addr(si: raw.Ptr<()>): raw.Ptr<()> uses raw {\n");
    printf("  let p: raw.Ptr<raw.Ptr<()>> = raw.cast(raw.cast<u8>(si).offset(SIGINFO_ADDR))\n");
    printf("  p.load()\n}\n");

    comment("C macros over values: wait status, file mode, control messages");
    /* The same on every supported libc; runtime/test/abi checks them against the macros. */
    printf("pub fn wifexited(s: i32): bool = (s & 0x7f) == 0\n");
    printf("pub fn wexitstatus(s: i32): i32 = (s >> 8) & 0xff\n");
    printf("pub fn wifsignaled(s: i32): bool = (s & 0x7f) != 0 && (s & 0x7f) != 0x7f\n");
    printf("pub fn wtermsig(s: i32): i32 = s & 0x7f\n");
    printf("pub fn s_isdir(m: u32): bool = (m & S_IFMT) == S_IFDIR\n");
    printf("pub fn s_isreg(m: u32): bool = (m & S_IFMT) == S_IFREG\n");
    /* CMSG_ALIGN's unit: CMSG_SPACE(1) - CMSG_LEN(0) == align(1) */
    size_t cmsg_align = CMSG_SPACE(1) - CMSG_LEN(0);
    printf("raw let CMSG_ALIGN_TO: usize = %zu\n", cmsg_align);
    printf("/// CMSG_ALIGN(sizeof(struct cmsghdr)): where a control message's data starts.\n");
    printf("raw let CMSG_HDR: usize = (raw.size_of<Cmsghdr>() + CMSG_ALIGN_TO - 1) / CMSG_ALIGN_TO * CMSG_ALIGN_TO\n");
    printf("pub fn cmsg_align(n: usize): usize = (n + CMSG_ALIGN_TO - 1) / CMSG_ALIGN_TO * CMSG_ALIGN_TO\n");
    printf("pub fn cmsg_len(n: usize): usize = CMSG_HDR + n\n");
    printf("pub fn cmsg_space(n: usize): usize = CMSG_HDR + cmsg_align(n)\n");
    printf("pub fn cmsg_data(c: raw.Ptr<Cmsghdr>): raw.Ptr<u8> uses raw = raw.cast<u8>(c).offset(CMSG_HDR)\n");
    printf("pub fn cmsg_firsthdr(m: raw.Ptr<Msghdr>): raw.Ptr<Cmsghdr> uses raw =\n");
    printf("  if usize(m.msg_controllen) >= raw.size_of<Cmsghdr>() { raw.cast(m.msg_control) } else { raw.null() }\n");

    comment("C library globals behind macros: errno, stdout, stderr");
#if defined(__APPLE__)
    const char *errno_fn = "__error", *out = "__stdoutp", *err = "__stderrp";
#else
    const char *errno_fn = "__errno_location", *out = "stdout", *err = "stderr";
#endif
    printf("extern fn c_errno_location(): raw.Ptr<i32> = \"int *%s(void)\"\n", errno_fn);
    printf("extern var c_stdout: raw.Ptr<()> = \"%s\"\n", out);
    printf("extern var c_stderr: raw.Ptr<()> = \"%s\"\n", err);
    printf("/// The calling thread's errno.\n");
    printf("pub fn errno_ptr(): raw.Ptr<i32> uses ffi = c_errno_location()\n");
    printf("pub fn errno(): i32 uses raw, ffi = c_errno_location().load()\n");
    printf("pub fn set_errno(e: i32) uses raw, ffi { c_errno_location().store(e) }\n");
    printf("/// C's `stdout`/`stderr` (a FILE *).\n");
    printf("pub fn stdout(): raw.Ptr<()> uses raw = c_stdout\n");
    printf("pub fn stderr(): raw.Ptr<()> uses raw = c_stderr\n");

    printf("\n// ---- only on %s ----\n\n", OS);
#if defined(__APPLE__)
    U64(DISPATCH_TIME_NOW);
    U64(DISPATCH_TIME_FOREVER);
#else
    I32(AT_PHDR);
    I32(ET_DYN);
    I32(SHT_SYMTAB);
    I32(STT_FUNC);
    I32(SELFMAG);
    printf("pub raw let ELFMAG: u32 = 0x464c457f // \"\\x7fELF\" as a little-endian u32\n");
    printf("pub fn elf64_st_type(info: u8): u8 = info & 0xf\n\n");
    STRUCT(Elf64Ehdr, Elf64_Ehdr);
    FIELD(Elf64_Ehdr, e_ident, "[u8; 16]");
    INT(Elf64_Ehdr, e_type);
    INT(Elf64_Ehdr, e_machine);
    INT(Elf64_Ehdr, e_version);
    INT(Elf64_Ehdr, e_entry);
    INT(Elf64_Ehdr, e_phoff);
    INT(Elf64_Ehdr, e_shoff);
    INT(Elf64_Ehdr, e_flags);
    INT(Elf64_Ehdr, e_ehsize);
    INT(Elf64_Ehdr, e_phentsize);
    INT(Elf64_Ehdr, e_phnum);
    INT(Elf64_Ehdr, e_shentsize);
    INT(Elf64_Ehdr, e_shnum);
    INT(Elf64_Ehdr, e_shstrndx);
    end();
    STRUCT(Elf64Shdr, Elf64_Shdr);
    INT(Elf64_Shdr, sh_name);
    INT(Elf64_Shdr, sh_type);
    INT(Elf64_Shdr, sh_flags);
    INT(Elf64_Shdr, sh_addr);
    INT(Elf64_Shdr, sh_offset);
    INT(Elf64_Shdr, sh_size);
    INT(Elf64_Shdr, sh_link);
    INT(Elf64_Shdr, sh_info);
    INT(Elf64_Shdr, sh_addralign);
    INT(Elf64_Shdr, sh_entsize);
    end();
    STRUCT(Elf64Sym, Elf64_Sym);
    INT(Elf64_Sym, st_name);
    INT(Elf64_Sym, st_info);
    INT(Elf64_Sym, st_other);
    INT(Elf64_Sym, st_shndx);
    INT(Elf64_Sym, st_value);
    INT(Elf64_Sym, st_size);
    end();
#endif
    return 0;
}
