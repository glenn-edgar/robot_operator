// ltree_sqlite.c - SQLite ltree extension with quantifier support
#include <sqlite3ext.h>
SQLITE_EXTENSION_INIT1
#include <string.h>
#include <ctype.h>
#include <stdbool.h>
#include <stdlib.h>
#include <stddef.h>

#define MAX_LABELS 128
#define MAX_LABEL_LEN 256

// Pattern element types
typedef enum {
    ELEM_EXACT,      // 'label' - exact match
    ELEM_ANY,        // '*' - match any single label
    ELEM_PREFIX,     // 'COL*' - prefix match
    ELEM_QUANTIFIED  // '*{n,m}' - match n to m labels
} ElemType;

typedef struct {
    ElemType type;
    char value[MAX_LABEL_LEN];  // For EXACT or PREFIX
    int min_count;               // For QUANTIFIED
    int max_count;               // For QUANTIFIED (-1 = unlimited)
} PatternElement;

// Parse quantifier: *{n}, *{n,}, *{n,m}, *{,m}
static bool parse_quantifier(const char *str, int *min, int *max) {
    if (*str != '{') return false;
    str++;
    
    *min = 0;
    *max = -1;  // -1 means unlimited
    
    // Parse min
    if (isdigit(*str)) {
        *min = atoi(str);
        while (isdigit(*str)) str++;
    }
    
    if (*str == '}') {
        // {n} - exact count
        *max = *min;
        return true;
    }
    
    if (*str != ',') return false;
    str++;
    
    // Parse max
    if (isdigit(*str)) {
        *max = atoi(str);
        while (isdigit(*str)) str++;
    } else {
        *max = -1;  // {n,} - unlimited
    }
    
    return (*str == '}');
}

// Parse pattern into elements
static int parse_pattern(const char *pattern, PatternElement *elements, int max_elements) {
    int elem_count = 0;
    const char *start = pattern;
    
    while (*start && elem_count < max_elements) {
        const char *end = start;
        while (*end && *end != '.') end++;
        
        int len = end - start;
        if (len == 0) break;
        
        PatternElement *elem = &elements[elem_count];
        
        // Check for quantified wildcard: *{n,m}
        if (len >= 3 && start[0] == '*' && start[1] == '{') {
            elem->type = ELEM_QUANTIFIED;
            if (!parse_quantifier(start + 1, &elem->min_count, &elem->max_count)) {
                return -1;  // Parse error
            }
        }
        // Check for single wildcard: *
        else if (len == 1 && start[0] == '*') {
            elem->type = ELEM_ANY;
        }
        // Check for prefix wildcard: COL*
        else if (len > 1 && start[len-1] == '*') {
            elem->type = ELEM_PREFIX;
            memcpy(elem->value, start, len - 1);
            elem->value[len - 1] = '\0';
        }
        // Exact match
        else {
            elem->type = ELEM_EXACT;
            memcpy(elem->value, start, len);
            elem->value[len] = '\0';
        }
        
        elem_count++;
        
        if (*end == '.') start = end + 1;
        else break;
    }
    
    return elem_count;
}

// Split path into labels
static int split_path(const char *path, char labels[][MAX_LABEL_LEN], int max_labels) {
    int count = 0;
    const char *start = path;
    
    while (*start && count < max_labels) {
        const char *end = start;
        while (*end && *end != '.') end++;
        
        int len = end - start;
        if (len >= MAX_LABEL_LEN) return -1;
        
        memcpy(labels[count], start, len);
        labels[count][len] = '\0';
        count++;
        
        if (*end == '.') start = end + 1;
        else break;
    }
    
    return count;
}

// Match a single label against a pattern element
static bool match_label(const char *label, const PatternElement *elem) {
    switch (elem->type) {
        case ELEM_ANY:
            return true;
            
        case ELEM_EXACT:
            return strcmp(label, elem->value) == 0;
            
        case ELEM_PREFIX:
            return strncmp(label, elem->value, strlen(elem->value)) == 0;
            
        case ELEM_QUANTIFIED:
            // Should not be called for QUANTIFIED
            return false;
    }
    return false;
}

// Recursive matcher with quantifier support
static bool match_recursive(char labels[][MAX_LABEL_LEN], int label_count, int label_idx,
                           PatternElement *pattern, int pattern_count, int pattern_idx) {
    // Both exhausted - match
    if (pattern_idx >= pattern_count && label_idx >= label_count) {
        return true;
    }
    
    // Pattern exhausted but labels remain - no match
    if (pattern_idx >= pattern_count) {
        return false;
    }
    
    PatternElement *elem = &pattern[pattern_idx];
    
    // Handle quantified wildcard *{n,m}
    if (elem->type == ELEM_QUANTIFIED) {
        int min = elem->min_count;
        int max = elem->max_count;
        if (max == -1) max = label_count - label_idx;  // Unlimited
        
        // Try matching different numbers of labels
        for (int consumed = min; consumed <= max && label_idx + consumed <= label_count; consumed++) {
            if (match_recursive(labels, label_count, label_idx + consumed,
                              pattern, pattern_count, pattern_idx + 1)) {
                return true;
            }
        }
        return false;
    }
    
    // Labels exhausted but pattern remains - check if remaining pattern can match empty
    if (label_idx >= label_count) {
        // Check if all remaining pattern elements can match zero labels
        for (int i = pattern_idx; i < pattern_count; i++) {
            if (pattern[i].type == ELEM_QUANTIFIED && pattern[i].min_count == 0) {
                continue;
            }
            return false;
        }
        return true;
    }
    
    // Normal label matching
    if (!match_label(labels[label_idx], elem)) {
        return false;
    }
    
    // Continue with next label and pattern element
    return match_recursive(labels, label_count, label_idx + 1,
                          pattern, pattern_count, pattern_idx + 1);
}

// Main ltree matching function with quantifier support
static bool ltree_match_impl(const char *path, const char *pattern_str) {
    char labels[MAX_LABELS][MAX_LABEL_LEN];
    PatternElement pattern[MAX_LABELS];
    
    int label_count = split_path(path, labels, MAX_LABELS);
    if (label_count < 0) return false;
    
    int pattern_count = parse_pattern(pattern_str, pattern, MAX_LABELS);
    if (pattern_count < 0) return false;
    
    return match_recursive(labels, label_count, 0, pattern, pattern_count, 0);
}

// SQLite function: ltree_match(path, pattern)
static void ltree_match_func(sqlite3_context *context, int argc, sqlite3_value **argv) {
    if (argc != 2) {
        sqlite3_result_error(context, "ltree_match requires 2 arguments", -1);
        return;
    }
    
    const char *path = (const char*)sqlite3_value_text(argv[0]);
    const char *pattern = (const char*)sqlite3_value_text(argv[1]);
    
    if (!path || !pattern) {
        sqlite3_result_null(context);
        return;
    }
    
    int result = ltree_match_impl(path, pattern) ? 1 : 0;
    sqlite3_result_int(context, result);
}

// SQLite function: ltree_ancestor(child, parent)
static void ltree_ancestor_func(sqlite3_context *context, int argc, sqlite3_value **argv) {
    if (argc != 2) {
        sqlite3_result_error(context, "ltree_ancestor requires 2 arguments", -1);
        return;
    }
    
    const char *child = (const char*)sqlite3_value_text(argv[0]);
    const char *parent = (const char*)sqlite3_value_text(argv[1]);
    
    if (!child || !parent) {
        sqlite3_result_null(context);
        return;
    }
    
    int parent_len = strlen(parent);
    int result = (strncmp(child, parent, parent_len) == 0 && 
                  (child[parent_len] == '.' || child[parent_len] == '\0')) ? 1 : 0;
    
    sqlite3_result_int(context, result);
}

// SQLite function: ltree_descendant(parent, child)
static void ltree_descendant_func(sqlite3_context *context, int argc, sqlite3_value **argv) {
    sqlite3_value *reversed[2] = {argv[1], argv[0]};
    ltree_ancestor_func(context, argc, reversed);
}

// SQLite function: ltree_depth(path)
static void ltree_depth_func(sqlite3_context *context, int argc, sqlite3_value **argv) {
    if (argc != 1) {
        sqlite3_result_error(context, "ltree_depth requires 1 argument", -1);
        return;
    }
    
    const char *path = (const char*)sqlite3_value_text(argv[0]);
    if (!path) {
        sqlite3_result_null(context);
        return;
    }
    
    char labels[MAX_LABELS][MAX_LABEL_LEN];
    int count = split_path(path, labels, MAX_LABELS);
    sqlite3_result_int(context, count);
}

// Extension entry point
int sqlite3_ltree_init(sqlite3 *db, char **pzErrMsg, 
                       const sqlite3_api_routines *pApi) {
    SQLITE_EXTENSION_INIT2(pApi);
    
    sqlite3_create_function(db, "ltree_match", 2, 
                           SQLITE_UTF8 | SQLITE_DETERMINISTIC, 0,
                           ltree_match_func, 0, 0);
    
    sqlite3_create_function(db, "ltree_ancestor", 2,
                           SQLITE_UTF8 | SQLITE_DETERMINISTIC, 0,
                           ltree_ancestor_func, 0, 0);
    
    sqlite3_create_function(db, "ltree_descendant", 2,
                           SQLITE_UTF8 | SQLITE_DETERMINISTIC, 0,
                           ltree_descendant_func, 0, 0);
    
    sqlite3_create_function(db, "ltree_depth", 1,
                           SQLITE_UTF8 | SQLITE_DETERMINISTIC, 0,
                           ltree_depth_func, 0, 0);
    
    return SQLITE_OK;
}

