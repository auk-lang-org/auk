// The C side of cabi.auk: the same structs and functions, compiled by cc, so each direction
// of every call uses the platform's C ABI as the C compiler implements it. Prints "ok" or what
// failed.
#include <stdint.h>
#include <stdio.h>

typedef struct { float a; } F1;
typedef struct { float a, b; } F2;
typedef struct { float a, b, c; } F3;
typedef struct { float a, b, c, d; } F4;
typedef struct { float a, b, c, d, e; } F5;
typedef struct { double a; } D1;
typedef struct { double a, b; } D2;
typedef struct { double a, b, c; } D3;
typedef struct { double a, b, c, d; } D4;
typedef struct { double a, b, c, d, e; } D5;
typedef struct { double a; int64_t b; } DI;
typedef struct { int64_t a; double b; } ID;
typedef struct { float a; int32_t b; } FI;
typedef struct { float a, b; int32_t c; } FFI;
typedef struct { double a; float b; } DF;
typedef struct { float a; double b; } FD;
typedef struct { float a[4]; } FA;
typedef struct { F2 a, b; } NF;
typedef struct { int64_t a, b; } II;
typedef struct { int64_t a, b, c; } I3;
typedef union { float f; int32_t i; } U;

#define EACH(X) X(f1, F1) X(f2, F2) X(f3, F3) X(f4, F4) X(f5, F5) X(d1, D1) X(d2, D2) X(d3, D3) \
  X(d4, D4) X(d5, D5) X(di, DI) X(id, ID) X(fi, FI) X(ffi, FFI) X(df, DF) X(fd, FD) X(fa, FA)    \
  X(nf, NF) X(ii, II) X(i3, I3) X(u, U)
#define DECL(n, T) T auk_##n(T);
EACH(DECL)
double auk_many_d(double, double, double, double, double, double, double, D2, double);
double auk_many_f(double, double, double, double, double, double, double, F4, float);
int64_t auk_many_i(int64_t, int64_t, int64_t, int64_t, int64_t, II, int64_t);
int64_t auk_many_i7(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, II, int64_t);
double auk_many_di(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, DI, double);
double auk_many_big(I3, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, F5, double);
int32_t auk_calls_c(void);

F1 c_f1(F1 x) { return (F1){x.a + 1}; }
F2 c_f2(F2 x) { return (F2){x.a + 1, x.b + 1}; }
F3 c_f3(F3 x) { return (F3){x.a + 1, x.b + 1, x.c + 1}; }
F4 c_f4(F4 x) { return (F4){x.a + 1, x.b + 1, x.c + 1, x.d + 1}; }
F5 c_f5(F5 x) { return (F5){x.a + 1, x.b + 1, x.c + 1, x.d + 1, x.e + 1}; }
D1 c_d1(D1 x) { return (D1){x.a + 1}; }
D2 c_d2(D2 x) { return (D2){x.a + 1, x.b + 1}; }
D3 c_d3(D3 x) { return (D3){x.a + 1, x.b + 1, x.c + 1}; }
D4 c_d4(D4 x) { return (D4){x.a + 1, x.b + 1, x.c + 1, x.d + 1}; }
D5 c_d5(D5 x) { return (D5){x.a + 1, x.b + 1, x.c + 1, x.d + 1, x.e + 1}; }
DI c_di(DI x) { return (DI){x.a + 1, x.b + 1}; }
ID c_id(ID x) { return (ID){x.a + 1, x.b + 1}; }
FI c_fi(FI x) { return (FI){x.a + 1, x.b + 1}; }
FFI c_ffi(FFI x) { return (FFI){x.a + 1, x.b + 1, x.c + 1}; }
DF c_df(DF x) { return (DF){x.a + 1, x.b + 1}; }
FD c_fd(FD x) { return (FD){x.a + 1, x.b + 1}; }
FA c_fa(FA x) { return (FA){{x.a[0] + 1, x.a[1] + 1, x.a[2] + 1, x.a[3] + 1}}; }
NF c_nf(NF x) { return (NF){{x.a.a + 1, x.a.b + 1}, {x.b.a + 1, x.b.b + 1}}; }
II c_ii(II x) { return (II){x.a + 1, x.b + 1}; }
I3 c_i3(I3 x) { return (I3){x.a + 1, x.b + 1, x.c + 1}; }
U c_u(U x) { U y; y.i = x.i + 1; return y; }
double c_many_d(double a, double b, double c, double d, double e, double f, double g, D2 x, double h) {
  return g * 1000 + x.a * 100 + x.b * 10 + h;
}
double c_many_f(double a, double b, double c, double d, double e, double f, double g, F4 x, float h) {
  return g * 100000 + x.a * 10000.0 + x.b * 1000.0 + x.c * 100.0 + x.d * 10.0 + h;
}
int64_t c_many_i(int64_t a, int64_t b, int64_t c, int64_t d, int64_t e, II x, int64_t h) {
  return e * 1000 + x.a * 100 + x.b * 10 + h;
}
int64_t c_many_i7(int64_t a, int64_t b, int64_t c, int64_t d, int64_t e, int64_t f, int64_t g, II x, int64_t h) {
  return g * 1000 + x.a * 100 + x.b * 10 + h;
}
double c_many_di(int64_t a, int64_t b, int64_t c, int64_t d, int64_t e, int64_t f, DI x, double h) {
  return f * 1000.0 + x.a * 100 + x.b * 10.0 + h;
}
double c_many_big(I3 x, int64_t a, int64_t b, int64_t c, int64_t d, int64_t e, int64_t f, F5 y, double h) {
  return (double)(x.a + x.b + x.c + f) + (double)(y.a + y.e) * 100 + h * 1000;
}

static int bad = 0;
#define CHECK(c) do { if (!(c)) { printf("FAIL %s (line %d)\n", #c, __LINE__); bad = 1; } } while (0)

int main(void) {
  F1 f1 = auk_f1((F1){1.5f});
  CHECK(f1.a == 2.5f);
  F2 f2 = auk_f2((F2){1.5f, -2});
  CHECK(f2.a == 2.5f && f2.b == -1);
  F3 f3 = auk_f3((F3){1, 2, 3});
  CHECK(f3.a == 2 && f3.b == 3 && f3.c == 4);
  F4 f4 = auk_f4((F4){1, 2, 3, 4});
  CHECK(f4.a == 2 && f4.b == 3 && f4.c == 4 && f4.d == 5);
  F5 f5 = auk_f5((F5){1, 2, 3, 4, 5});
  CHECK(f5.a == 2 && f5.b == 3 && f5.c == 4 && f5.d == 5 && f5.e == 6);
  D1 d1 = auk_d1((D1){1.5});
  CHECK(d1.a == 2.5);
  D2 d2 = auk_d2((D2){1, 2});
  CHECK(d2.a == 2 && d2.b == 3);
  D3 d3 = auk_d3((D3){1, 2, 3});
  CHECK(d3.a == 2 && d3.b == 3 && d3.c == 4);
  D4 d4 = auk_d4((D4){1, 2, 3, 4});
  CHECK(d4.a == 2 && d4.b == 3 && d4.c == 4 && d4.d == 5);
  D5 d5 = auk_d5((D5){1, 2, 3, 4, 5});
  CHECK(d5.a == 2 && d5.b == 3 && d5.c == 4 && d5.d == 5 && d5.e == 6);
  DI di = auk_di((DI){1.5, 7});
  CHECK(di.a == 2.5 && di.b == 8);
  ID id = auk_id((ID){7, 1.5});
  CHECK(id.a == 8 && id.b == 2.5);
  FI fi = auk_fi((FI){1.5f, 7});
  CHECK(fi.a == 2.5f && fi.b == 8);
  FFI ffi = auk_ffi((FFI){1.5f, 2.5f, 7});
  CHECK(ffi.a == 2.5f && ffi.b == 3.5f && ffi.c == 8);
  DF df = auk_df((DF){1.5, 2.5f});
  CHECK(df.a == 2.5 && df.b == 3.5f);
  FD fd = auk_fd((FD){1.5f, 2.5});
  CHECK(fd.a == 2.5f && fd.b == 3.5);
  FA fa = auk_fa((FA){{1, 2, 3, 4}});
  CHECK(fa.a[0] == 2 && fa.a[1] == 3 && fa.a[2] == 4 && fa.a[3] == 5);
  NF nf = auk_nf((NF){{1, 2}, {3, 4}});
  CHECK(nf.a.a == 2 && nf.a.b == 3 && nf.b.a == 4 && nf.b.b == 5);
  II ii = auk_ii((II){1, 2});
  CHECK(ii.a == 2 && ii.b == 3);
  I3 i3 = auk_i3((I3){1, 2, 3});
  CHECK(i3.a == 2 && i3.b == 3 && i3.c == 4);
  U u;
  u.i = 41;
  CHECK(auk_u(u).i == 42);
  CHECK(auk_many_d(1, 2, 3, 4, 5, 6, 7, (D2){8, 9}, 3) == 7893);
  CHECK(auk_many_f(1, 2, 3, 4, 5, 6, 7, (F4){1, 2, 3, 4}, 5) == 712345);
  CHECK(auk_many_i(1, 2, 3, 4, 5, (II){6, 7}, 8) == 5678);
  CHECK(auk_many_i7(1, 2, 3, 4, 5, 6, 7, (II){8, 9}, 3) == 7893);
  CHECK(auk_many_di(1, 2, 3, 4, 5, 6, (DI){7, 8}, 9) == 6789);
  CHECK(auk_many_big((I3){1, 2, 3}, 0, 0, 0, 0, 0, 4, (F5){1, 0, 0, 0, 2}, 5) == 5310);
  int32_t r = auk_calls_c();
  if (r != 0) printf("FAIL auk_calls_c: %d\n", r), bad = 1;
  if (!bad) printf("ok\n");
  return bad;
}
