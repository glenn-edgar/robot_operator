// test_ltree.c
#include <sqlite3.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stddef.h>

#define TEST_DB "test_ltree.db"

// Test result tracking
static int tests_passed = 0;
static int tests_failed = 0;

// Print test result
static void check_result(const char *test_name, int expected, int actual) {
    if (expected == actual) {
        printf("✓ PASS: %s\n", test_name);
        tests_passed++;
    } else {
        printf("✗ FAIL: %s (expected %d, got %d)\n", test_name, expected, actual);
        tests_failed++;
    }
}

// Execute a query and return integer result
static int exec_query(sqlite3 *db, const char *query) {
    sqlite3_stmt *stmt;
    int result = -1;
    
    if (sqlite3_prepare_v2(db, query, -1, &stmt, NULL) == SQLITE_OK) {
        if (sqlite3_step(stmt) == SQLITE_ROW) {
            result = sqlite3_column_int(stmt, 0);
        }
        sqlite3_finalize(stmt);
    }
    return result;
}

// Test exact matching
static void test_exact_match(sqlite3 *db) {
    printf("\n=== Testing Exact Matching ===\n");
    
    check_result("Exact match - full path",
                 1, exec_query(db, 
                 "SELECT ltree_match('kb.second_test.GATE_root._0', 'kb.second_test.GATE_root._0')"));
    
    check_result("Exact match - no match",
                 0, exec_query(db, 
                 "SELECT ltree_match('kb.second_test.GATE_root._0', 'kb.second_test.GATE_root._1')"));
}

// Test wildcard matching
static void test_wildcard_match(sqlite3 *db) {
    printf("\n=== Testing Wildcard Matching ===\n");
    
    check_result("Single wildcard",
                 1, exec_query(db, 
                 "SELECT ltree_match('kb.second_test.GATE_root._0', 'kb.*.GATE_root._0')"));
    
    check_result("Multiple wildcards",
                 1, exec_query(db, 
                 "SELECT ltree_match('kb.second_test.GATE_root._0', 'kb.*.*.* ')"));
    
    check_result("All wildcards",
                 1, exec_query(db, 
                 "SELECT ltree_match('kb.second_test.GATE_root._0', '*.*.*.*')"));
}

// Test prefix matching
static void test_prefix_match(sqlite3 *db) {
    printf("\n=== Testing Prefix Matching ===\n");
    
    check_result("Prefix match COL",
                 1, exec_query(db, 
                 "SELECT ltree_match('kb.test.COL_wait._0', 'kb.*.COL*.*')"));
    
    check_result("Prefix match GATE",
                 1, exec_query(db, 
                 "SELECT ltree_match('kb.test.GATE_root._0', 'kb.*.GATE*.*')"));
    
    check_result("Prefix no match",
                 0, exec_query(db, 
                 "SELECT ltree_match('kb.test.LEAF_node._0', 'kb.*.COL*.*')"));
}

// Test quantified wildcards
static void test_quantified_match(sqlite3 *db) {
    printf("\n=== Testing Quantified Wildcards ===\n");
    
    // Exact count {n}
    check_result("Exact count {2}",
                 1, exec_query(db, 
                 "SELECT ltree_match('kb.a.b.GATE', 'kb.*{2}.GATE')"));
    
    check_result("Exact count {2} - no match",
                 0, exec_query(db, 
                 "SELECT ltree_match('kb.a.b.c.GATE', 'kb.*{2}.GATE')"));
    
    // Range {n,m}
    check_result("Range {1,3}",
                 1, exec_query(db, 
                 "SELECT ltree_match('kb.a.b.GATE', 'kb.*{1,3}.GATE')"));
    
    check_result("Range {2,4}",
                 1, exec_query(db, 
                 "SELECT ltree_match('kb.a.b.c.GATE', 'kb.*{2,4}.GATE')"));
    
    check_result("Range {2,4} - too few",
                 0, exec_query(db, 
                 "SELECT ltree_match('kb.a.GATE', 'kb.*{2,4}.GATE')"));
    
    // Minimum {n,}
    check_result("Minimum {2,}",
                 1, exec_query(db, 
                 "SELECT ltree_match('kb.a.b.c.d.GATE', 'kb.*{2,}.GATE')"));
    
    check_result("Minimum {3,} - too few",
                 0, exec_query(db, 
                 "SELECT ltree_match('kb.a.b.GATE', 'kb.*{3,}.GATE')"));
    
    // Maximum {,m}
    check_result("Maximum {,2}",
                 1, exec_query(db, 
                 "SELECT ltree_match('kb.a.GATE', 'kb.*{,2}.GATE')"));
    
    check_result("Maximum {,2} - too many",
                 0, exec_query(db, 
                 "SELECT ltree_match('kb.a.b.c.d.GATE', 'kb.*{,2}.GATE')"));
}

// Test ancestor/descendant
static void test_ancestor_descendant(sqlite3 *db) {
    printf("\n=== Testing Ancestor/Descendant ===\n");
    
    check_result("Ancestor - true",
                 1, exec_query(db, 
                 "SELECT ltree_ancestor('kb.second_test.GATE_root._0.COL_wait', 'kb.second_test.GATE_root')"));
    
    check_result("Ancestor - false",
                 0, exec_query(db, 
                 "SELECT ltree_ancestor('kb.second_test.GATE_root', 'kb.second_test.GATE_root._0')"));
    
    check_result("Descendant - true",
                 1, exec_query(db, 
                 "SELECT ltree_descendant('kb.second_test', 'kb.second_test.GATE_root._0')"));
    
    check_result("Descendant - false",
                 0, exec_query(db, 
                 "SELECT ltree_descendant('kb.second_test.GATE_root._0', 'kb.second_test')"));
}

// Test depth
static void test_depth(sqlite3 *db) {
    printf("\n=== Testing Depth ===\n");
    
    check_result("Depth 1", 1, exec_query(db, "SELECT ltree_depth('kb')"));
    check_result("Depth 2", 2, exec_query(db, "SELECT ltree_depth('kb.test')"));
    check_result("Depth 4", 4, exec_query(db, "SELECT ltree_depth('kb.second_test.GATE_root._0')"));
    check_result("Depth 6", 6, exec_query(db, 
                 "SELECT ltree_depth('kb.second_test.GATE_root._0.COL_wait._2')"));
}

// Test complex patterns
static void test_complex_patterns(sqlite3 *db) {
    printf("\n=== Testing Complex Patterns ===\n");
    
    check_result("Complex: kb.*{2}.GATE*.*.COL*.*",
                 1, exec_query(db, 
                 "SELECT ltree_match('kb.a.b.GATE_root.c.COL_wait.d', 'kb.*{2}.GATE*.*.COL*.*')"));
    
    check_result("Complex: *.second_test.*{1,2}.COL*",
                 1, exec_query(db, 
                 "SELECT ltree_match('kb.second_test.GATE.COL_wait', '*.second_test.*{1,2}.COL*')"));
    
    check_result("Complex: kb.*{,3}.LEAF*",
                 1, exec_query(db, 
                 "SELECT ltree_match('kb.a.b.LEAF_node', 'kb.*{,3}.LEAF*')"));
}

int main(int argc, char **argv) {
    sqlite3 *db;
    char *err_msg = NULL;
    int rc;
    
    printf("SQLite ltree Extension Test Suite\n");
    printf("==================================\n");
    
    // Open database
    rc = sqlite3_open(":memory:", &db);
    if (rc != SQLITE_OK) {
        fprintf(stderr, "Cannot open database: %s\n", sqlite3_errmsg(db));
        return 1;
    }
    
    // Load extension
    sqlite3_enable_load_extension(db, 1);
    
    const char *ext_name = (argc > 1) ? argv[1] : "./ltree.so";
    rc = sqlite3_load_extension(db, ext_name, "sqlite3_ltree_init", &err_msg);
    if (rc != SQLITE_OK) {
        fprintf(stderr, "Cannot load extension: %s\n", err_msg);
        sqlite3_free(err_msg);
        sqlite3_close(db);
        return 1;
    }
    
    printf("Extension loaded successfully: %s\n", ext_name);
    
    // Run tests
    test_exact_match(db);
    test_wildcard_match(db);
    test_prefix_match(db);
    test_quantified_match(db);
    test_ancestor_descendant(db);
    test_depth(db);
    test_complex_patterns(db);
    
    // Summary
    printf("\n==================================\n");
    printf("Test Results: %d passed, %d failed\n", tests_passed, tests_failed);
    
    sqlite3_close(db);
    
    return (tests_failed > 0) ? 1 : 0;
}
