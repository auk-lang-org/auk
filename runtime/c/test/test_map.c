/* {K: V}: insertion order, replacement, removal, COW. */
#include "test.h"

static void put_si(AukMap **m, const char *k, int64_t v) {
    AukStr *ks = s(k);
    auk_map_set(m, &ks, &v);
    rel(ks);
}

static int64_t get_si(AukMap *m, const char *k, bool *found) {
    AukStr *ks = s(k);
    int64_t v = 0;
    *found = auk_map_get_opt(m, &ks, &v);
    rel(ks);
    return v;
}

static void map_insertion_order_and_replace(void) {
    AukMap *m = auk_map_new(&auk_ops_str, &auk_ops_int);
    put_si(&m, "zebra", 1);
    put_si(&m, "apple", 2);
    put_si(&m, "mango", 3);
    CHECK_STR(auk_map_show(m), "{\"zebra\": 1, \"apple\": 2, \"mango\": 3}");
    put_si(&m, "apple", 20); /* replace keeps position */
    CHECK_STR(auk_map_show(m), "{\"zebra\": 1, \"apple\": 20, \"mango\": 3}");
    CHECK_INT(auk_map_len(m), 3);
    bool found = false;
    CHECK(get_si(m, "apple", &found) == 20 && found);
    get_si(m, "nope", &found);
    CHECK(!found);
    AukStr *k = s("zebra");
    CHECK(auk_map_contains(m, &k));
    int64_t old = 0;
    CHECK(auk_map_remove(&m, &k, &old) && old == 1);
    CHECK(!auk_map_remove(&m, &k, NULL));
    CHECK(!auk_map_contains(m, &k));
    CHECK_STR(auk_map_show(m), "{\"apple\": 20, \"mango\": 3}");
    put_si(&m, "zebra", 9); /* re-inserted keys go to the end */
    CHECK_STR(auk_map_show(m), "{\"apple\": 20, \"mango\": 3, \"zebra\": 9}");
    AukArr *keys = auk_map_keys(m);
    AukArr *vals = auk_map_values(m);
    CHECK_STR(auk_arr_show(keys), "[\"apple\", \"mango\", \"zebra\"]");
    CHECK_STR(auk_arr_show(vals), "[20, 3, 9]");
    int64_t it = 0, n = 0;
    void *kp = NULL, *vp = NULL;
    while (auk_map_next(m, &it, &kp, &vp)) n += *(const int64_t *)vp;
    CHECK_INT(n, 32);
    CHECK_INT(*(const int64_t *)auk_map_at(m, &k, "t"), 9);
    rel(k);
    rel(keys);
    rel(vals);
    rel(m);
}

static void map_many_entries(void) {
    AukMap *m = auk_map_new(&auk_ops_int, &auk_ops_int);
    for (int64_t i = 0; i < 5000; i++) {
        int64_t v = i * i;
        auk_map_set(&m, &i, &v);
    }
    CHECK_INT(auk_map_len(m), 5000);
    for (int64_t i = 0; i < 5000; i += 2) CHECK(auk_map_remove(&m, &i, NULL));
    CHECK_INT(auk_map_len(m), 2500);
    for (int64_t i = 0; i < 5000; i++) {
        const int64_t *v = auk_map_find(m, &i);
        if (i % 2 != 0)
            CHECK(v != NULL && *v == i * i);
        else
            CHECK(v == NULL);
    }
    /* order of the survivors is still insertion order */
    int64_t it = 0, prev = -1;
    void *k = NULL;
    while (auk_map_next(m, &it, &k, NULL)) {
        CHECK(*(const int64_t *)k > prev);
        prev = *(const int64_t *)k;
    }
    /* churn: remove/insert the same keys many times */
    for (int round = 0; round < 50; round++) {
        for (int64_t i = 1; i < 200; i += 2) {
            CHECK(auk_map_remove(&m, &i, NULL));
            auk_map_set(&m, &i, &i);
        }
    }
    CHECK_INT(auk_map_len(m), 2500);
    it = 0;
    auk_map_next(m, &it, &k, NULL);
    CHECK_INT(*(const int64_t *)k, 201); /* 1..199 were moved to the end */
    rel(m);
}

static void map_copy_on_write(void) {
    AukMap *a = auk_map_new(&auk_ops_str, &auk_ops_str);
    AukStr *k = s("k"), *v1 = s("v1"), *v2 = s("v2");
    auk_map_set(&a, &k, &v1);
    AukMap *b = ret(a);
    auk_map_set(&b, &k, &v2);
    CHECK(a != b);
    CHECK(auk_str_eq(*(AukStr **)auk_map_at(a, &k, "t"), v1));
    CHECK(auk_str_eq(*(AukStr **)auk_map_at(b, &k, "t"), v2));
    AukMap *c = ret(a);
    CHECK(auk_map_remove(&c, &k, NULL));
    CHECK_INT(auk_map_len(a), 1);
    CHECK_INT(auk_map_len(c), 0);
    CHECK(!auk_map_eq(a, b));
    AukMap *d = auk_map_copy(a);
    CHECK(auk_map_eq(a, d));
    /* value object refcounts: v1 held by a and d */
    CHECK_INT(auk_refcount(v1), 3);
    /* setting a value that lives inside the map itself */
    auk_map_set(&d, &k, auk_map_at(d, &k, "t"));
    CHECK_INT(auk_refcount(v1), 3);
    rel(a);
    rel(b);
    rel(c);
    rel(d);
    CHECK_INT(auk_refcount(v1), 1);
    rel(k);
    rel(v1);
    rel(v2);
}

static void map_eq_ignores_order(void) {
    AukMap *a = auk_map_new(&auk_ops_str, &auk_ops_int);
    AukMap *b = auk_map_new(&auk_ops_str, &auk_ops_int);
    put_si(&a, "x", 1);
    put_si(&a, "y", 2);
    put_si(&b, "y", 2);
    put_si(&b, "x", 1);
    CHECK(auk_map_eq(a, b));
    put_si(&b, "x", 3);
    CHECK(!auk_map_eq(a, b));
    rel(a);
    rel(b);
}

static void missing_key(void *ctx) {
    AukStr *k = s("ghost");
    auk_map_at(ctx, &k, "m.auk:2:3");
}

static void map_missing_key_panics(void) {
    AukMap *m = auk_map_new(&auk_ops_str, &auk_ops_int);
    EXPECT_PANIC(missing_key, m, "key not found: \"ghost\"\n  at m.auk:2:3");
    rel(m);
}

static void map_nested_values(void) {
    /* {str: [int]} with COW on the inner list */
    AukMap *m = auk_map_new(&auk_ops_str, &auk_ops_arr);
    AukStr *k = s("xs");
    AukArr *xs = auk_arr_new(&auk_ops_int, 0);
    auk_map_set(&m, &k, &xs);
    AukMap *snap = ret(m);
    auk_map_make_unique(&m);
    AukArr **slot = auk_map_find(m, &k);
    PUSH(int64_t, slot, 7);
    CHECK_STR(auk_map_show(m), "{\"xs\": [7]}");
    CHECK_STR(auk_map_show(snap), "{\"xs\": []}");
    rel(m);
    rel(snap);
    rel(k);
    rel(xs);
}

const TestCase map_tests[] = {
    {"map_insertion_order_and_replace", map_insertion_order_and_replace},
    {"map_many_entries", map_many_entries},
    {"map_copy_on_write", map_copy_on_write},
    {"map_eq_ignores_order", map_eq_ignores_order},
    {"map_missing_key_panics", map_missing_key_panics},
    {"map_nested_values", map_nested_values},
    {NULL, NULL},
};
