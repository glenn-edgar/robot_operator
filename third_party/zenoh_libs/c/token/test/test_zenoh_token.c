/**
 * @file test_zenoh_token.c
 * @brief Unit tests for zenoh_token.
 *
 * No external dependencies — pure C, runs anywhere libzenoh_token builds.
 */

#include "zenoh_token.h"

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int pass_count = 0;
static int fail_count = 0;

#define CHECK(cond, msg) do {                                              \
    if (cond) {                                                            \
        ++pass_count;                                                      \
    } else {                                                               \
        ++fail_count;                                                      \
        fprintf(stderr, "FAIL: %s (%s:%d)\n", msg, __FILE__, __LINE__);    \
    }                                                                      \
} while (0)

#define CHECK_EQ_U32(a, b, msg) do {                                       \
    uint32_t _a = (a), _b = (b);                                           \
    if (_a == _b) {                                                        \
        ++pass_count;                                                      \
    } else {                                                               \
        ++fail_count;                                                      \
        fprintf(stderr, "FAIL: %s — got 0x%08x, expected 0x%08x (%s:%d)\n",\
                msg, _a, _b, __FILE__, __LINE__);                          \
    }                                                                      \
} while (0)

/* ------------------------------------------------------------------ */
/*  zt_hash                                                            */
/* ------------------------------------------------------------------ */

static void test_hash_known_vectors(void) {
    /* FNV1a-32 test vectors verified against
     * https://datatracker.ietf.org/doc/html/draft-eastlake-fnv-22 */
    CHECK_EQ_U32(zt_hash(""),       0x811c9dc5u, "hash empty string");
    CHECK_EQ_U32(zt_hash("a"),      0xe40c292cu, "hash 'a'");
    CHECK_EQ_U32(zt_hash("foobar"), 0xbf9cf968u, "hash 'foobar'");
}

static void test_hash_deterministic(void) {
    uint32_t a = zt_hash("robot/42/telemetry");
    uint32_t b = zt_hash("robot/42/telemetry");
    CHECK_EQ_U32(a, b, "hash is deterministic across calls");
}

static void test_hash_distinct_inputs(void) {
    uint32_t a = zt_hash("topic_a");
    uint32_t b = zt_hash("topic_b");
    CHECK(a != b, "distinct strings produce distinct tokens");
}

static void test_hash_null(void) {
    /* zt_hash(NULL) should return the sentinel without crashing. */
    uint32_t t = zt_hash(NULL);
    CHECK_EQ_U32(t, 0xFFFFFFFFu, "hash NULL returns sentinel");
}

/* ------------------------------------------------------------------ */
/*  zt_hash_list                                                       */
/* ------------------------------------------------------------------ */

static void test_hash_list_basic(void) {
    const char *topics[] = { "sensor/temp", "sensor/hum", "sensor/baro" };
    uint32_t out[3] = {0};
    zt_status_t st = zt_hash_list(topics, 3, out);
    CHECK(st == ZT_OK, "hash_list returns OK");
    CHECK_EQ_U32(out[0], zt_hash(topics[0]), "list[0] matches scalar hash");
    CHECK_EQ_U32(out[1], zt_hash(topics[1]), "list[1] matches scalar hash");
    CHECK_EQ_U32(out[2], zt_hash(topics[2]), "list[2] matches scalar hash");
}

static void test_hash_list_zero_length(void) {
    uint32_t buf[1] = { 0xdeadbeef };
    const char *empty[] = { NULL };
    zt_status_t st = zt_hash_list((const char *const *)empty, 0, buf);
    CHECK(st == ZT_OK, "hash_list of length 0 returns OK");
    CHECK_EQ_U32(buf[0], 0xdeadbeef, "hash_list of length 0 doesn't write");
}

static void test_hash_list_null_args(void) {
    uint32_t out[1];
    const char *topics[] = { "x" };
    CHECK(zt_hash_list(NULL, 1, out)    == ZT_ERR_INVALID_ARG, "NULL topics rejected");
    CHECK(zt_hash_list(topics, 1, NULL) == ZT_ERR_INVALID_ARG, "NULL out rejected");
}

static void test_hash_list_null_entry(void) {
    const char *topics[] = { "ok", NULL, "ok2" };
    uint32_t out[3];
    zt_status_t st = zt_hash_list(topics, 3, out);
    CHECK(st == ZT_ERR_INVALID_ARG, "NULL list entry rejected");
}

/* ------------------------------------------------------------------ */
/*  Registry                                                           */
/* ------------------------------------------------------------------ */

static void test_registry_register_lookup(void) {
    zt_registry_clear();
    const char *t = "robot/42/cmd";
    uint32_t h = zt_hash(t);
    CHECK(zt_register(h, t) == ZT_OK, "register OK");
    const char *back = zt_lookup(h);
    CHECK(back != NULL,           "lookup finds registered topic");
    CHECK(strcmp(back, t) == 0,   "lookup returns matching string");
    CHECK(zt_registry_size() == 1,"registry size is 1");
}

static void test_registry_duplicate_same(void) {
    zt_registry_clear();
    const char *t = "topic/x";
    uint32_t h = zt_hash(t);
    CHECK(zt_register(h, t) == ZT_OK, "first register OK");
    CHECK(zt_register(h, t) == ZT_OK, "duplicate same (token,topic) is no-op");
    CHECK(zt_registry_size() == 1,   "size still 1 after duplicate");
}

static void test_registry_duplicate_collision(void) {
    /* Force a (synthetic) collision by registering two different topics under
     * the same token. Real FNV1a collisions are vanishingly rare for short
     * topic strings, so we contrive one. */
    zt_registry_clear();
    CHECK(zt_register(0xCAFEBABE, "topic_a") == ZT_OK,           "first OK");
    CHECK(zt_register(0xCAFEBABE, "topic_b") == ZT_ERR_DUPLICATE,"collision rejected");
}

static void test_registry_lookup_missing(void) {
    zt_registry_clear();
    CHECK(zt_lookup(0x12345678) == NULL, "lookup of unregistered token is NULL");
}

static void test_registry_invalid_args(void) {
    zt_registry_clear();
    CHECK(zt_register(0, NULL) == ZT_ERR_INVALID_ARG, "register NULL topic rejected");
}

static void test_registry_growth(void) {
    /* Registering many entries should trigger growth without losing data. */
    zt_registry_clear();
    enum { N = 200 };
    char buf[32];
    uint32_t tokens[N];
    for (int i = 0; i < N; ++i) {
        snprintf(buf, sizeof(buf), "topic/%d", i);
        tokens[i] = zt_hash(buf);
        zt_status_t st = zt_register(tokens[i], buf);
        if (st != ZT_OK) {
            /* If we hit a real collision among these short strings, treat as
             * acceptable but don't double-count it. */
            CHECK(st == ZT_ERR_DUPLICATE, "register under load: only acceptable error is DUPLICATE");
        }
    }
    /* Now look up every one. */
    for (int i = 0; i < N; ++i) {
        snprintf(buf, sizeof(buf), "topic/%d", i);
        const char *back = zt_lookup(tokens[i]);
        CHECK(back != NULL && strcmp(back, buf) == 0,
              "lookup after growth returns correct string");
    }
    zt_registry_clear();
    CHECK(zt_registry_size() == 0, "clear empties the registry");
}

/* ------------------------------------------------------------------ */
/*  main                                                               */
/* ------------------------------------------------------------------ */

int main(void) {
    test_hash_known_vectors();
    test_hash_deterministic();
    test_hash_distinct_inputs();
    test_hash_null();

    test_hash_list_basic();
    test_hash_list_zero_length();
    test_hash_list_null_args();
    test_hash_list_null_entry();

    test_registry_register_lookup();
    test_registry_duplicate_same();
    test_registry_duplicate_collision();
    test_registry_lookup_missing();
    test_registry_invalid_args();
    test_registry_growth();

    printf("\nzenoh_token tests: %d passed, %d failed\n", pass_count, fail_count);
    return fail_count == 0 ? 0 : 1;
}
