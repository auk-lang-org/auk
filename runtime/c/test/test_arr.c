/* [T]: element lifetimes, copy-on-write, slices, sorting. */
#include "test.h"

static const char *T = "t";

static void arr_basic_ops(void) {
    AukArr *a = auk_arr_new(&auk_ops_int, 0);
    for (int64_t i = 0; i < 100; i++) auk_arr_push(&a, &i);
    CHECK_INT(auk_arr_len(a), 100);
    CHECK_INT(AT(int64_t, a, 99), 99);
    int64_t out = -1;
    CHECK(auk_arr_pop(&a, &out) && out == 99);
    CHECK_INT(auk_arr_len(a), 99);
    int64_t v = 1000;
    auk_arr_insert(&a, 0, &v, T);
    CHECK_INT(AT(int64_t, a, 0), 1000);
    CHECK_INT(AT(int64_t, a, 1), 0);
    v = 2000;
    auk_arr_insert(&a, auk_arr_len(a), &v, T);
    CHECK_INT(AT(int64_t, a, 100), 2000);
    auk_arr_remove(&a, 0, &out, T);
    CHECK_INT(out, 1000);
    CHECK_INT(AT(int64_t, a, 0), 0);
    v = -5;
    auk_arr_set(&a, 3, &v, T);
    CHECK_INT(AT(int64_t, a, 3), -5);
    CHECK(auk_arr_get_opt(a, 3, &out) && out == -5);
    CHECK(!auk_arr_get_opt(a, 101, &out));
    CHECK(!auk_arr_get_opt(a, -1, &out));
    auk_arr_clear(&a);
    CHECK_INT(auk_arr_len(a), 0);
    CHECK(!auk_arr_pop(&a, &out));
    rel(a);
}

static void bounds_at(void *ctx) { auk_arr_at(ctx, 3, "list.auk:9:5"); }
static void bounds_set(void *ctx) {
    AukArr *a = ctx;
    int64_t v = 1;
    auk_arr_set(&a, -1, &v, "list.auk:10:5");
}
static void bounds_remove(void *ctx) {
    AukArr *a = ctx;
    auk_arr_remove(&a, 7, NULL, "x");
}
static void bounds_slice(void *ctx) { auk_arr_slice(ctx, 1, 4, "x"); }

static void arr_bounds_panics(void) {
    AukArr *a = ints((int64_t[]){1, 2, 3}, 3);
    EXPECT_PANIC(bounds_at, a, "index 3 out of range for length 3\n  at list.auk:9:5");
    EXPECT_PANIC(bounds_set, a, "index -1 out of range for length 3");
    EXPECT_PANIC(bounds_remove, a, "index 7 out of range");
    EXPECT_PANIC(bounds_slice, a, "slice 1..4 out of range for length 3");
    rel(a);
}

static void arr_str_elements_lifetimes(void) {
    AukArr *a = auk_arr_new(&auk_ops_str, 0);
    AukStr *sh = s("shared");
    for (int i = 0; i < 10; i++) auk_arr_push(&a, &sh);
    CHECK_INT(auk_refcount(sh), 11);
    AukStr *t = s("other");
    auk_arr_set(&a, 0, &t, T);
    CHECK_INT(auk_refcount(sh), 10);
    CHECK_INT(auk_refcount(t), 2);
    /* setting an element to itself */
    auk_arr_set(&a, 0, auk_arr_at(a, 0, T), T);
    CHECK_INT(auk_refcount(t), 2);
    /* push an element of the same array (may realloc) */
    auk_arr_push(&a, auk_arr_at(a, 0, T));
    CHECK_INT(auk_refcount(t), 3);
    AukStr *popped = NULL;
    CHECK(auk_arr_pop(&a, &popped) && popped == t);
    rel(popped);
    AukStr *got = NULL;
    CHECK(auk_arr_get_opt(a, 1, &got) && got == sh);
    CHECK_INT(auk_refcount(sh), 11);
    rel(got);
    CHECK_STR(auk_arr_show(a), "[\"other\", \"shared\", \"shared\", \"shared\", \"shared\", \"shared\", "
                               "\"shared\", \"shared\", \"shared\", \"shared\"]");
    rel(a);
    CHECK_INT(auk_refcount(sh), 1);
    CHECK_INT(auk_refcount(t), 1);
    rel(sh);
    rel(t);
}

static void arr_push_own_moves(void) {
    AukArr *a = auk_arr_new(&auk_ops_str, 0);
    for (int i = 0; i < 20; i++) {
        AukStr *x = s("owned"); /* refcount 1, handed to the list */
        auk_arr_push_own(&a, &x);
        CHECK_INT(auk_refcount(x), 1);
    }
    /* a shared list is copied first; the copy takes the value */
    AukArr *b = ret(a);
    AukStr *y = s("new");
    auk_arr_push_own(&b, &y);
    CHECK(a != b);
    CHECK_INT(auk_arr_len(a), 20);
    CHECK_INT(auk_arr_len(b), 21);
    CHECK_INT(auk_refcount(y), 1);
    CHECK_INT(auk_refcount(AT(AukStr *, a, 0)), 2);
    rel(b);
    rel(a);
}

static void arr_copy_on_write(void) {
    AukArr *a = ints((int64_t[]){1, 2, 3}, 3);
    AukArr *b = ret(a); /* `let b = a` */
    int64_t v = 99;
    auk_arr_set(&b, 0, &v, T); /* mutating the shared array copies */
    CHECK(a != b);
    CHECK_INT(AT(int64_t, a, 0), 1);
    CHECK_INT(AT(int64_t, b, 0), 99);
    CHECK_INT(auk_refcount(a), 1);
    AukArr *b_before = b;
    auk_arr_push(&b, &v); /* unique now: mutates in place (no copy) */
    CHECK(b == b_before || auk_arr_len(b) == 4);
    CHECK_INT(auk_arr_len(a), 3);
    CHECK_INT(auk_arr_len(b), 4);
    /* push / pop / remove / insert / sort / reverse on a shared array */
    AukArr *c = ret(a);
    auk_arr_push(&c, &v);
    auk_arr_reverse(&c);
    CHECK_INT(AT(int64_t, c, 0), 99);
    CHECK_STR(auk_arr_show(a), "[1, 2, 3]");
    rel(c);
    c = ret(a);
    auk_arr_remove(&c, 0, NULL, T);
    CHECK_STR(auk_arr_show(a), "[1, 2, 3]");
    CHECK_STR(auk_arr_show(c), "[2, 3]");
    rel(c);
    c = ret(a);
    auk_arr_clear(&c);
    CHECK_INT(auk_arr_len(a), 3);
    rel(c);
    rel(a);
    rel(b);
}

static void arr_cow_nested_strings(void) {
    /* [[str]]: copying the outer array must retain inner arrays */
    AukArr *inner = auk_arr_new(&auk_ops_str, 0);
    AukStr *x = s("x");
    auk_arr_push(&inner, &x);
    AukArr *outer = auk_arr_new(&auk_ops_arr, 0);
    auk_arr_push(&outer, &inner);
    auk_arr_push(&outer, &inner);
    AukArr *copy = ret(outer);
    auk_arr_pop(&copy, NULL);
    CHECK_INT(auk_arr_len(outer), 2);
    CHECK_INT(auk_arr_len(copy), 1);
    CHECK_INT(auk_refcount(inner), 4); /* our ref + 2 in outer + 1 in copy */
    CHECK_STR(auk_arr_show(outer), "[[\"x\"], [\"x\"]]");
    /* mutate inner via outer[0]: COW of the element */
    AukArr **slot = auk_arr_make_unique(&copy);
    AukStr *y = s("y");
    auk_arr_push(slot, &y);
    CHECK_STR(auk_arr_show(copy), "[[\"x\", \"y\"]]");
    CHECK_STR(auk_arr_show(outer), "[[\"x\"], [\"x\"]]");
    CHECK(auk_arr_eq(outer, outer));
    CHECK(!auk_arr_eq(outer, copy));
    rel(copy);
    rel(outer);
    rel(inner);
    rel(x);
    rel(y);
}

static void arr_slices_share(void) {
    AukArr *a = ints((int64_t[]){0, 1, 2, 3, 4, 5}, 6);
    AukArr *sl = auk_arr_slice(a, 1, 5, T);
    CHECK_INT(auk_arr_len(sl), 4);
    CHECK(sl->data == a->data + sizeof(int64_t)); /* shares the buffer, O(1) */
    CHECK_INT(AT(int64_t, sl, 0), 1);
    AukArr *ss = auk_arr_slice(sl, 1, 3, T); /* [h, ..t] of a slice */
    CHECK(ss->base == a);                    /* views always point at the owner */
    CHECK_STR(auk_arr_show(ss), "[2, 3]");
    CHECK_INT(auk_refcount(a), 3);
    /* mutating a slice copies; the base is untouched */
    int64_t v = 42;
    auk_arr_set(&sl, 0, &v, T);
    CHECK(sl->base == NULL);
    CHECK_STR(auk_arr_show(sl), "[42, 2, 3, 4]");
    CHECK_STR(auk_arr_show(a), "[0, 1, 2, 3, 4, 5]");
    /* push on a slice must not clobber the base's next element */
    auk_arr_push(&ss, &v);
    CHECK_STR(auk_arr_show(ss), "[2, 3, 42]");
    CHECK_STR(auk_arr_show(a), "[0, 1, 2, 3, 4, 5]");
    /* the base stays alive while a view exists */
    AukArr *tail = auk_arr_slice(a, 4, 6, T);
    rel(a);
    CHECK_STR(auk_arr_show(tail), "[4, 5]");
    AukArr *empty = auk_arr_slice(tail, 2, 2, T);
    CHECK_INT(auk_arr_len(empty), 0);
    AukArr *t2 = auk_arr_take(tail, 10);
    AukArr *k2 = auk_arr_skip(tail, 1);
    CHECK_STR(auk_arr_show(t2), "[4, 5]");
    CHECK_STR(auk_arr_show(k2), "[5]");
    rel(t2);
    rel(k2);
    rel(empty);
    rel(tail);
    rel(sl);
    rel(ss);
}

static void arr_slices_of_strings(void) {
    AukArr *a = auk_arr_new(&auk_ops_str, 0);
    const char *words[] = {"a", "b", "c", "d"};
    for (int i = 0; i < 4; i++) {
        AukStr *w = s(words[i]);
        auk_arr_push(&a, &w);
        rel(w);
    }
    AukArr *v = auk_arr_slice(a, 2, 4, T);
    rel(a);
    AukArr *c = auk_arr_copy(v);
    rel(v); /* frees the base and its strings */
    CHECK_STR(auk_arr_show(c), "[\"c\", \"d\"]");
    rel(c);
}

static void arr_concat_reverse_extend(void) {
    AukArr *a = ints((int64_t[]){1, 2}, 2);
    AukArr *b = ints((int64_t[]){3, 4, 5}, 3);
    AukArr *c = auk_arr_concat(a, b);
    CHECK_STR(auk_arr_show(c), "[1, 2, 3, 4, 5]");
    AukArr *r = auk_arr_reversed(c);
    CHECK_STR(auk_arr_show(r), "[5, 4, 3, 2, 1]");
    CHECK_STR(auk_arr_show(c), "[1, 2, 3, 4, 5]");
    auk_arr_extend(&a, a); /* self-extend */
    CHECK_STR(auk_arr_show(a), "[1, 2, 1, 2]");
    CHECK_INT(auk_arr_sum_int(c, T), 15);
    AukStr *sep = s(", ");
    CHECK_STR(auk_arr_join(c, sep), "1, 2, 3, 4, 5");
    rel(sep);
    int64_t four = 4, nine = 9, three = 3;
    CHECK(auk_arr_contains(c, &four));
    CHECK(!auk_arr_contains(c, &nine));
    CHECK(auk_arr_index_of(c, &three).val == 2);
    CHECK(auk_arr_cmp(a, c) < 0 || auk_arr_cmp(a, c) > 0);
    AukArr *p = ints((int64_t[]){1, 2}, 2);
    CHECK(auk_arr_cmp(p, c) < 0); /* prefix sorts first */
    CHECK(auk_arr_hash(p) == auk_arr_hash(b) || !auk_arr_eq(p, b));
    rel(a);
    rel(b);
    rel(c);
    rel(r);
    rel(p);
}

typedef struct Pair {
    int64_t key;
    int64_t seq;
} Pair;

static int pair_cmp(const void *x, const void *y, void *ctx) {
    (void)ctx;
    return auk_int_cmp(((const Pair *)x)->key, ((const Pair *)y)->key);
}

static const AukElemOps PAIR_OPS = {sizeof(Pair), NULL, NULL, NULL, NULL, NULL, NULL, NULL};

static void arr_sort_stable(void) {
    AukArr *a = auk_arr_new(&PAIR_OPS, 0);
    uint64_t x = 12345;
    for (int64_t i = 0; i < 1000; i++) {
        x = x * 6364136223846793005ull + 1442695040888963407ull;
        Pair p = {(int64_t)(x >> 59), i}; /* lots of equal keys */
        auk_arr_push(&a, &p);
    }
    AukArr *keep = ret(a);
    auk_arr_sort_with(&a, pair_cmp, NULL);
    const Pair *ps = auk_arr_data(a);
    for (int i = 1; i < 1000; i++) {
        CHECK(ps[i - 1].key <= ps[i].key);
        if (ps[i - 1].key == ps[i].key) CHECK(ps[i - 1].seq < ps[i].seq);
    }
    CHECK(((const Pair *)auk_arr_data(keep))->seq == 0); /* original untouched */
    rel(keep);
    rel(a);

    AukArr *w = auk_arr_new(&auk_ops_str, 0);
    const char *words[] = {"pear", "apple", "éclair", "fig", "apple"};
    for (int i = 0; i < 5; i++) {
        AukStr *t = s(words[i]);
        auk_arr_push(&w, &t);
        rel(t);
    }
    AukArr *sorted = auk_arr_sorted(w);
    CHECK_STR(auk_arr_show(sorted), "[\"apple\", \"apple\", \"fig\", \"pear\", \"éclair\"]");
    AukArr *f = auk_arr_new(&auk_ops_float, 0);
    double ds[] = {2.5, -1.0, 0.1, 10.0};
    for (int i = 0; i < 4; i++) auk_arr_push(&f, &ds[i]);
    auk_arr_sort(&f);
    CHECK_STR(auk_arr_show(f), "[-1.0, 0.1, 2.5, 10.0]");
    rel(w);
    rel(sorted);
    rel(f);
}

static void arr_literal_and_show(void) {
    int64_t xs[3] = {3, 1, 2};
    AukArr *a = auk_arr_from(&auk_ops_int, xs, 3);
    CHECK_STR(auk_arr_show(a), "[3, 1, 2]");
    AukArr *e = auk_arr_new(&auk_ops_int, 0);
    CHECK_STR(auk_arr_show(e), "[]");
    bool bs[2] = {true, false};
    AukArr *b = auk_arr_from(&auk_ops_bool, bs, 2);
    CHECK_STR(auk_arr_show(b), "[true, false]");
    uint32_t cs[2] = {'a', 'b'};
    AukArr *c = auk_arr_from(&auk_ops_char, cs, 2);
    AukStr *empty = s("");
    CHECK_STR(auk_arr_join(c, empty), "ab");
    rel(empty);
    rel(a);
    rel(e);
    rel(b);
    rel(c);
}

static void sum_overflow(void *ctx) {
    (void)ctx;
    AukArr *a = ints((int64_t[]){INT64_MAX, 1}, 2);
    auk_arr_sum_int(a, "sum.auk:1:1");
}

static void arr_sum_overflow_panics(void) { EXPECT_PANIC(sum_overflow, NULL, "integer overflow"); }

const TestCase arr_tests[] = {
    {"arr_basic_ops", arr_basic_ops},
    {"arr_bounds_panics", arr_bounds_panics},
    {"arr_str_elements_lifetimes", arr_str_elements_lifetimes},
    {"arr_push_own_moves", arr_push_own_moves},
    {"arr_copy_on_write", arr_copy_on_write},
    {"arr_cow_nested_strings", arr_cow_nested_strings},
    {"arr_slices_share", arr_slices_share},
    {"arr_slices_of_strings", arr_slices_of_strings},
    {"arr_concat_reverse_extend", arr_concat_reverse_extend},
    {"arr_sort_stable", arr_sort_stable},
    {"arr_literal_and_show", arr_literal_and_show},
    {"arr_sum_overflow_panics", arr_sum_overflow_panics},
    {NULL, NULL},
};
