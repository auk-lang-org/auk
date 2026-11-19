// The C side of lib.auk (`auk build --lib`): layouts, structs by value both ways, a callback,
// globals, thread-locals and atomics across pthreads. Prints "ok" or what failed.
#include <pthread.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

typedef struct { int64_t rc; uint32_t kind, flags; } Header;
typedef struct { Header h; int64_t len_bytes, len_chars; bool is_ascii; uint8_t data[]; } Str;
typedef union { int64_t i; double f; Str *s; } Value;
typedef struct { uint8_t a; int16_t b; int32_t c; uint8_t d; int64_t e; float f; uint16_t g[3]; } Mixed;
struct v2 { double x, y; };
typedef struct { float x, y; } F2;
typedef struct { int64_t a, b, c; uint8_t d; } Big;
typedef struct { int32_t a; uint8_t b; } Small;

int64_t auk_size(int32_t);
struct v2 auk_v2_add(struct v2, struct v2);
F2 auk_f2_scale(F2, float);
int64_t auk_big_sum(Big);
Big auk_mk_big(int64_t);
Small auk_small(Small, bool);
double auk_value_f(Value);
int64_t auk_str_len(Str *);
int32_t auk_calls_c(void);
int64_t auk_bump(int64_t);
int64_t auk_total(void);
int64_t auk_spawn(int64_t);
extern int32_t auk_flag;
extern struct { int32_t (*twice)(int32_t); int32_t *flag; } auk_ops;

struct v2 c_v2_sub(struct v2 a, struct v2 b) { return (struct v2){a.x - b.x, a.y - b.y}; }
int c_apply(int (*f)(int), int x) { return f(x); }

static int bad = 0;
#define CHECK(c) do { if (!(c)) { printf("FAIL %s (line %d)\n", #c, __LINE__); bad = 1; } } while (0)

static void *bumper(void *arg) {
  (void)arg;
  int64_t mine = auk_bump(500);
  return (void *)(intptr_t)(mine == 600);
}

int main(void) {
  CHECK(auk_size(0) == sizeof(Header));
  CHECK(auk_size(1) == sizeof(Str));
  CHECK(auk_size(2) == offsetof(Str, data));
  CHECK(auk_size(3) == sizeof(Value));
  CHECK(auk_size(4) == sizeof(Mixed));
  CHECK(auk_size(5) == offsetof(Mixed, b));
  CHECK(auk_size(6) == offsetof(Mixed, c));
  CHECK(auk_size(7) == offsetof(Mixed, d));
  CHECK(auk_size(8) == offsetof(Mixed, e));
  CHECK(auk_size(9) == offsetof(Mixed, f));
  CHECK(auk_size(10) == offsetof(Mixed, g));
  CHECK(auk_size(11) == _Alignof(Mixed));

  struct v2 s = auk_v2_add((struct v2){1.5, 2.0}, (struct v2){0.5, 1.0});
  CHECK(s.x == 2.0 && s.y == 3.0);
  F2 f = auk_f2_scale((F2){1.5f, -2.0f}, 2.0f);
  CHECK(f.x == 3.0f && f.y == -4.0f);
  CHECK(auk_big_sum((Big){1, 2, 3, 4}) == 10);
  Big b = auk_mk_big(10);
  CHECK(b.a == 10 && b.b == 20 && b.c == 30 && b.d == 4);
  Small sm = auk_small((Small){41, 7}, true);
  CHECK(sm.a == 42 && sm.b == 7);
  sm = auk_small((Small){1, 7}, false);
  CHECK(sm.a == 2 && sm.b == 0);
  Value v;
  v.f = 2.5;
  CHECK(auk_value_f(v) == 2.5);
  Str str = {{1, 2, 0}, 3, 3, true};
  CHECK(auk_str_len(&str) == 3);
  CHECK(auk_calls_c() == 0);
  CHECK(auk_flag == 7);
  CHECK(auk_ops.twice(5) == 10 && auk_ops.flag == &auk_flag);

  // a thread-local per thread, one atomic counter for all
  pthread_t ts[4];
  for (int i = 0; i < 4; i++) pthread_create(&ts[i], NULL, bumper, NULL);
  for (int i = 0; i < 4; i++) {
    void *ok = NULL;
    pthread_join(ts[i], &ok);
    CHECK(ok != NULL);
  }
  CHECK(auk_total() == 2000);
  CHECK(auk_bump(1) == 101);
  // threads started from Auk (pthread_create through FFI, an export fn as the start routine)
  CHECK(auk_spawn(3) == 2000 + 1 + 3000);
  if (!bad) printf("ok\n");
  return bad;
}
