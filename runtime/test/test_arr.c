/* [T]: element lifetimes, copy-on-write, slices, sorting. */
#include "harness.h"

static DuckArr *ints(int n, ...) {
    DuckArr *a = duck_arr_new(&duck_ops_int, 0);
    va_list ap;
    va_start(ap, n);
    for (int i = 0; i < n; i++) DUCK_ARR_PUSH(int64_t, &a, va_arg(ap, int));
    va_end(ap);
    return a;
}

TEST(arr_basic_ops) {
    DuckArr *a = duck_arr_new(&duck_ops_int, 0);
    for (int64_t i = 0; i < 100; i++) duck_arr_push(&a, &i);
    CHECK_INT(duck_arr_len(a), 100);
    CHECK_INT(DUCK_ARR_AT(int64_t, a, 99, "t"), 99);
    int64_t out = -1;
    CHECK(duck_arr_pop(&a, &out) && out == 99);
    CHECK_INT(duck_arr_len(a), 99);
    int64_t v = 1000;
    duck_arr_insert(&a, 0, &v, "t");
    CHECK_INT(DUCK_ARR_AT(int64_t, a, 0, "t"), 1000);
    CHECK_INT(DUCK_ARR_AT(int64_t, a, 1, "t"), 0);
    v = 2000;
    duck_arr_insert(&a, duck_arr_len(a), &v, "t");
    CHECK_INT(DUCK_ARR_AT(int64_t, a, 100, "t"), 2000);
    duck_arr_remove(&a, 0, &out, "t");
    CHECK_INT(out, 1000);
    CHECK_INT(DUCK_ARR_AT(int64_t, a, 0, "t"), 0);
    v = -5;
    duck_arr_set(&a, 3, &v, "t");
    CHECK_INT(DUCK_ARR_AT(int64_t, a, 3, "t"), -5);
    CHECK(duck_arr_get_opt(a, 3, &out) && out == -5);
    CHECK(!duck_arr_get_opt(a, 101, &out));
    CHECK(!duck_arr_get_opt(a, -1, &out));
    duck_arr_clear(&a);
    CHECK_INT(duck_arr_len(a), 0);
    CHECK(!duck_arr_pop(&a, &out));
    duck_release(a);
}

static void arr_oob(void *p) {
    DuckArr *a = p;
    duck_arr_at(a, 3, "list.duck:9:5");
}
static void arr_neg(void *p) {
    DuckArr *a = p;
    int64_t v = 1;
    duck_arr_set(&a, -1, &v, "list.duck:10:5");
}
static void arr_remove_oob(void *p) {
    DuckArr *a = p;
    duck_arr_remove(&a, 7, NULL, "x");
}
static void arr_slice_oob(void *p) { duck_arr_slice(p, 1, 4, "x"); }

TEST(arr_bounds_panics) {
    DuckArr *a = ints(3, 1, 2, 3);
    EXPECT_PANIC(arr_oob, a, "index 3 out of range for length 3\n  at list.duck:9:5");
    EXPECT_PANIC(arr_neg, a, "index -1 out of range for length 3");
    EXPECT_PANIC(arr_remove_oob, a, "index 7 out of range");
    EXPECT_PANIC(arr_slice_oob, a, "slice 1..4 out of range for length 3");
    duck_release(a);
}

TEST(arr_str_elements_lifetimes) {
    DuckArr *a = duck_arr_new(&duck_ops_str, 0);
    DuckStr *s = S("shared");
    for (int i = 0; i < 10; i++) duck_arr_push(&a, &s);
    CHECK_INT(duck_refcount(s), 11);
    DuckStr *t = S("other");
    duck_arr_set(&a, 0, &t, "t");
    CHECK_INT(duck_refcount(s), 10);
    CHECK_INT(duck_refcount(t), 2);
    /* setting an element to itself */
    duck_arr_set(&a, 0, duck_arr_at(a, 0, "t"), "t");
    CHECK_INT(duck_refcount(t), 2);
    /* push an element of the same array (may realloc) */
    duck_arr_push(&a, duck_arr_at(a, 0, "t"));
    CHECK_INT(duck_refcount(t), 3);
    DuckStr *popped = NULL;
    CHECK(duck_arr_pop(&a, &popped) && popped == t);
    duck_release(popped);
    DuckStr *got = NULL;
    CHECK(duck_arr_get_opt(a, 1, &got) && got == s);
    CHECK_INT(duck_refcount(s), 11);
    duck_release(got);
    CHECK_STR(duck_arr_show(a), "[\"other\", \"shared\", \"shared\", \"shared\", \"shared\", \"shared\", \"shared\", "
                                "\"shared\", \"shared\", \"shared\"]");
    duck_release(a);
    CHECK_INT(duck_refcount(s), 1);
    CHECK_INT(duck_refcount(t), 1);
    duck_release(s);
    duck_release(t);
}

TEST(arr_copy_on_write) {
    DuckArr *a = ints(3, 1, 2, 3);
    DuckArr *b = duck_retain(a); /* `let b = a` */
    int64_t v = 99;
    duck_arr_set(&b, 0, &v, "t"); /* mutating the shared array copies */
    CHECK(a != b);
    CHECK_INT(DUCK_ARR_AT(int64_t, a, 0, "t"), 1);
    CHECK_INT(DUCK_ARR_AT(int64_t, b, 0, "t"), 99);
    CHECK_INT(duck_refcount(a), 1);
    DuckArr *b_before = b;
    duck_arr_push(&b, &v); /* unique now: mutates in place (no copy) */
    CHECK(b == b_before || duck_arr_len(b) == 4);
    CHECK_INT(duck_arr_len(a), 3);
    CHECK_INT(duck_arr_len(b), 4);
    /* push / pop / remove / insert / sort / reverse on a shared array */
    DuckArr *c = duck_retain(a);
    duck_arr_push(&c, &v);
    duck_arr_reverse(&c);
    CHECK_INT(DUCK_ARR_AT(int64_t, c, 0, "t"), 99);
    CHECK_STR(duck_arr_show(a), "[1, 2, 3]");
    duck_release(c);
    c = duck_retain(a);
    duck_arr_remove(&c, 0, NULL, "t");
    CHECK_STR(duck_arr_show(a), "[1, 2, 3]");
    CHECK_STR(duck_arr_show(c), "[2, 3]");
    duck_release(c);
    c = duck_retain(a);
    duck_arr_clear(&c);
    CHECK_INT(duck_arr_len(a), 3);
    duck_release(c);
    duck_release(a);
    duck_release(b);
}

TEST(arr_cow_nested_strings) {
    /* [[str]]: copying the outer array must retain inner arrays */
    DuckArr *inner = duck_arr_new(&duck_ops_str, 0);
    DuckStr *s = S("x");
    duck_arr_push(&inner, &s);
    DuckArr *outer = duck_arr_new(&duck_ops_arr, 0);
    duck_arr_push(&outer, &inner);
    duck_arr_push(&outer, &inner);
    DuckArr *copy = duck_retain(outer);
    duck_arr_pop(&copy, NULL);
    CHECK_INT(duck_arr_len(outer), 2);
    CHECK_INT(duck_arr_len(copy), 1);
    CHECK_INT(duck_refcount(inner), 4); /* our ref + 2 in outer + 1 in copy */
    CHECK_STR(duck_arr_show(outer), "[[\"x\"], [\"x\"]]");
    /* mutate inner via outer[0]: COW of the element */
    DuckArr **slot = duck_arr_make_unique(&copy);
    DuckStr *y = S("y");
    duck_arr_push(&slot[0], &y);
    CHECK_STR(duck_arr_show(copy), "[[\"x\", \"y\"]]");
    CHECK_STR(duck_arr_show(outer), "[[\"x\"], [\"x\"]]");
    CHECK(duck_arr_eq(outer, outer));
    CHECK(!duck_arr_eq(outer, copy));
    duck_release(copy), duck_release(outer), duck_release(inner), duck_release(s), duck_release(y);
}

TEST(arr_slices_share) {
    DuckArr *a = ints(6, 0, 1, 2, 3, 4, 5);
    DuckArr *s = duck_arr_slice(a, 1, 5, "t");
    CHECK_INT(duck_arr_len(s), 4);
    CHECK(s->data == a->data + sizeof(int64_t)); /* shares the buffer, O(1) */
    CHECK_INT(DUCK_ARR_AT(int64_t, s, 0, "t"), 1);
    DuckArr *ss = duck_arr_slice(s, 1, 3, "t"); /* [h, ..t] of a slice */
    CHECK(ss->base == a);                       /* views always point at the owner */
    CHECK_STR(duck_arr_show(ss), "[2, 3]");
    CHECK_INT(duck_refcount(a), 3);
    /* mutating a slice copies; the base is untouched */
    int64_t v = 42;
    duck_arr_set(&s, 0, &v, "t");
    CHECK(s->base == NULL);
    CHECK_STR(duck_arr_show(s), "[42, 2, 3, 4]");
    CHECK_STR(duck_arr_show(a), "[0, 1, 2, 3, 4, 5]");
    /* push on a slice must not clobber the base's next element */
    duck_arr_push(&ss, &v);
    CHECK_STR(duck_arr_show(ss), "[2, 3, 42]");
    CHECK_STR(duck_arr_show(a), "[0, 1, 2, 3, 4, 5]");
    /* the base stays alive while a view exists */
    DuckArr *tail = duck_arr_slice(a, 4, 6, "t");
    duck_release(a);
    CHECK_STR(duck_arr_show(tail), "[4, 5]");
    DuckArr *empty = duck_arr_slice(tail, 2, 2, "t");
    CHECK_INT(duck_arr_len(empty), 0);
    DuckArr *t2 = duck_arr_take(tail, 10), *k2 = duck_arr_skip(tail, 1);
    CHECK_STR(duck_arr_show(t2), "[4, 5]");
    CHECK_STR(duck_arr_show(k2), "[5]");
    duck_release(t2), duck_release(k2);
    duck_release(empty), duck_release(tail), duck_release(s), duck_release(ss);
}

TEST(arr_slices_of_strings) {
    DuckArr *a = duck_arr_new(&duck_ops_str, 0);
    const char *words[] = {"a", "b", "c", "d"};
    for (int i = 0; i < 4; i++) {
        DuckStr *w = S(words[i]);
        duck_arr_push(&a, &w);
        duck_release(w);
    }
    DuckArr *v = duck_arr_slice(a, 2, 4, "t");
    duck_release(a);
    DuckArr *c = duck_arr_copy(v);
    duck_release(v); /* frees the base and its strings */
    CHECK_STR(duck_arr_show(c), "[\"c\", \"d\"]");
    duck_release(c);
}

TEST(arr_concat_reverse_extend) {
    DuckArr *a = ints(2, 1, 2), *b = ints(3, 3, 4, 5);
    DuckArr *c = duck_arr_concat(a, b);
    CHECK_STR(duck_arr_show(c), "[1, 2, 3, 4, 5]");
    DuckArr *r = duck_arr_reversed(c);
    CHECK_STR(duck_arr_show(r), "[5, 4, 3, 2, 1]");
    CHECK_STR(duck_arr_show(c), "[1, 2, 3, 4, 5]");
    duck_arr_extend(&a, a); /* self-extend */
    CHECK_STR(duck_arr_show(a), "[1, 2, 1, 2]");
    CHECK_INT(duck_arr_sum_int(c, "t"), 15);
    DuckStr *sep = S(", ");
    CHECK_STR(duck_arr_join(c, sep), "1, 2, 3, 4, 5");
    duck_release(sep);
    CHECK(duck_arr_contains(c, &(int64_t){4}));
    CHECK(!duck_arr_contains(c, &(int64_t){9}));
    CHECK(duck_arr_index_of(c, &(int64_t){3}).val == 2);
    CHECK(duck_arr_cmp(a, c) < 0 || duck_arr_cmp(a, c) > 0);
    DuckArr *p = ints(2, 1, 2);
    CHECK(duck_arr_cmp(p, c) < 0); /* prefix sorts first */
    CHECK(duck_arr_hash(p) == duck_arr_hash(b) || !duck_arr_eq(p, b));
    duck_release(a), duck_release(b), duck_release(c), duck_release(r), duck_release(p);
}

typedef struct {
    int64_t key;
    int64_t seq;
} Pair;

static int pair_cmp(const void *x, const void *y, void *ctx) {
    (void)ctx;
    return duck_int_cmp(((const Pair *)x)->key, ((const Pair *)y)->key);
}
static const DuckElemOps pair_ops = {sizeof(Pair), NULL, NULL, NULL, NULL, NULL, NULL};

TEST(arr_sort_stable) {
    DuckArr *a = duck_arr_new(&pair_ops, 0);
    uint64_t x = 12345;
    for (int64_t i = 0; i < 1000; i++) {
        x = x * 6364136223846793005ULL + 1442695040888963407ULL;
        Pair p = {(int64_t)(x >> 59), i}; /* lots of equal keys */
        duck_arr_push(&a, &p);
    }
    DuckArr *keep = duck_retain(a);
    duck_arr_sort_with(&a, pair_cmp, NULL);
    const Pair *ps = duck_arr_data(a);
    for (int64_t i = 1; i < 1000; i++) {
        CHECK(ps[i - 1].key <= ps[i].key);
        if (ps[i - 1].key == ps[i].key) CHECK(ps[i - 1].seq < ps[i].seq);
    }
    CHECK(((const Pair *)duck_arr_data(keep))[0].seq == 0); /* original untouched */
    duck_release(keep);
    duck_release(a);

    DuckArr *w = duck_arr_new(&duck_ops_str, 0);
    const char *words[] = {"pear", "apple", ("\xC3\xA9" "clair"), "fig", "apple"};
    for (int i = 0; i < 5; i++) {
        DuckStr *s = S(words[i]);
        duck_arr_push(&w, &s);
        duck_release(s);
    }
    DuckArr *sorted = duck_arr_sorted(w);
    CHECK_STR(duck_arr_show(sorted), "[\"apple\", \"apple\", \"fig\", \"pear\", \"\xC3\xA9" "clair\"]");
    DuckArr *f = duck_arr_new(&duck_ops_float, 0);
    double ds[] = {2.5, -1.0, 0.1, 10.0};
    for (int i = 0; i < 4; i++) duck_arr_push(&f, &ds[i]);
    duck_arr_sort(&f);
    CHECK_STR(duck_arr_show(f), "[-1.0, 0.1, 2.5, 10.0]");
    duck_release(w), duck_release(sorted), duck_release(f);
}

TEST(arr_literal_and_show) {
    int64_t xs[] = {3, 1, 2};
    DuckArr *a = duck_arr_from(&duck_ops_int, xs, 3);
    CHECK_STR(duck_arr_show(a), "[3, 1, 2]");
    DuckArr *e = duck_arr_new(&duck_ops_int, 0);
    CHECK_STR(duck_arr_show(e), "[]");
    bool bs[] = {true, false};
    DuckArr *b = duck_arr_from(&duck_ops_bool, bs, 2);
    CHECK_STR(duck_arr_show(b), "[true, false]");
    uint32_t cs[] = {'a', 'b'};
    DuckArr *c = duck_arr_from(&duck_ops_char, cs, 2);
    DuckStr *empty = S("");
    CHECK_STR(duck_arr_join(c, empty), "ab");
    duck_release(empty);
    duck_release(a), duck_release(e), duck_release(b), duck_release(c);
}

static void sum_overflow(void *p) {
    (void)p;
    DuckArr *a = duck_arr_new(&duck_ops_int, 0);
    DUCK_ARR_PUSH(int64_t, &a, INT64_MAX);
    DUCK_ARR_PUSH(int64_t, &a, 1);
    duck_arr_sum_int(a, "sum.duck:1:1");
}

TEST(arr_sum_overflow_panics) { EXPECT_PANIC(sum_overflow, NULL, "integer overflow"); }
