# SQLite ltree Extension

A SQLite extension that implements PostgreSQL-style ltree (label tree) functionality for hierarchical path matching and navigation. This extension provides efficient pattern-based querying of tree-structured data stored as dot-separated paths.

## Overview

The ltree extension enables hierarchical path operations in SQLite, supporting the ChainTree architecture's need for flexible node addressing and pattern-based queries across distributed control systems. Paths follow the format `kb.second_test.GATE_root._0.COL_wait._2` where each component represents a level in the hierarchy.

## Features

- **Exact Path Matching** - Direct path comparison
- **Wildcard Patterns** - Single-level (`*`) and prefix matching (`COL*`)
- **Quantified Wildcards** - Specify repetition counts (`*{2}`, `*{1,3}`, `*{2,}`, `*{,3}`)
- **Ancestor/Descendant Queries** - Navigate hierarchical relationships
- **Path Depth Calculation** - Count hierarchy levels
- **High Performance** - C implementation optimized for embedded and server deployments

## Building

### Prerequisites

- GCC compiler
- SQLite3 development libraries
- Make

On Ubuntu/Debian:
```bash
sudo apt install build-essential libsqlite3-dev sqlite3
```

### Compile

```bash
make              # Build library and test program
make test         # Run test suite
make install      # Install to /usr/local/lib (requires sudo)
```

The build produces:
- `ltree.so` (Linux) or `ltree.dylib` (macOS) - The loadable extension
- `test_ltree` - Test suite executable

## Installation

### System-Wide Installation

```bash
sudo make install
```

Installs to `/usr/local/lib/ltree.so`

### Custom Installation Path

```bash
make install PREFIX=/opt/myapp LIBDIR=/opt/myapp/extensions
```

## Usage

### Loading the Extension

#### From SQLite CLI

```sql
.load ./ltree.so
-- or if installed system-wide
.load /usr/local/lib/ltree.so
```

#### From Python

```python
import sqlite3

conn = sqlite3.connect('mydb.db')
conn.enable_load_extension(True)
conn.load_extension('./ltree.so')
conn.enable_load_extension(False)

# Now use ltree functions
cursor = conn.execute(
    "SELECT ltree_match('kb.test.GATE_root._0', 'kb.*.GATE*.*')"
)
print(cursor.fetchone()[0])  # Returns 1 (true)
```

#### From C

```c
sqlite3 *db;
char *err_msg = NULL;

sqlite3_open("mydb.db", &db);
sqlite3_enable_load_extension(db, 1);
sqlite3_load_extension(db, "./ltree.so", "sqlite3_ltree_init", &err_msg);
```

## API Reference

### ltree_match(path, pattern)

Match a path against a pattern with wildcard support.

**Returns:** 1 if match, 0 if no match

**Examples:**

```sql
-- Exact match
SELECT ltree_match('kb.second_test.GATE_root._0', 'kb.second_test.GATE_root._0');
-- Returns: 1

-- Single wildcard (matches one level)
SELECT ltree_match('kb.second_test.GATE_root._0', 'kb.*.GATE_root._0');
-- Returns: 1

-- Prefix matching
SELECT ltree_match('kb.test.COL_wait._0', 'kb.*.COL*.*');
-- Returns: 1

-- Multiple wildcards
SELECT ltree_match('kb.second_test.GATE_root._0', 'kb.*.*.*');
-- Returns: 1
```

### Quantified Wildcards

Control how many levels a wildcard matches:

```sql
-- Exact count: *{n}
SELECT ltree_match('kb.a.b.GATE', 'kb.*{2}.GATE');
-- Returns: 1 (matches exactly 2 levels: 'a.b')

-- Range: *{min,max}
SELECT ltree_match('kb.a.b.c.GATE', 'kb.*{2,4}.GATE');
-- Returns: 1 (matches 3 levels, within range 2-4)

-- Minimum: *{n,}
SELECT ltree_match('kb.a.b.c.d.GATE', 'kb.*{2,}.GATE');
-- Returns: 1 (matches 4 levels, minimum is 2)

-- Maximum: *{,m}
SELECT ltree_match('kb.a.GATE', 'kb.*{,2}.GATE');
-- Returns: 1 (matches 1 level, maximum is 2)
```

### ltree_ancestor(child_path, ancestor_path)

Check if ancestor_path is an ancestor of child_path.

**Returns:** 1 if true, 0 if false

**Examples:**

```sql
SELECT ltree_ancestor('kb.test.GATE._0.COL_wait', 'kb.test.GATE');
-- Returns: 1 (GATE is ancestor of COL_wait)

SELECT ltree_ancestor('kb.test', 'kb.test.GATE');
-- Returns: 0 (test is not ancestor of GATE)
```

### ltree_descendant(ancestor_path, descendant_path)

Check if descendant_path is a descendant of ancestor_path.

**Returns:** 1 if true, 0 if false

**Examples:**

```sql
SELECT ltree_descendant('kb.test', 'kb.test.GATE._0');
-- Returns: 1

SELECT ltree_descendant('kb.test.GATE', 'kb.test');
-- Returns: 0
```

### ltree_depth(path)

Return the depth (number of levels) in a path.

**Returns:** Integer depth count

**Examples:**

```sql
SELECT ltree_depth('kb');
-- Returns: 1

SELECT ltree_depth('kb.test.GATE._0');
-- Returns: 4

SELECT ltree_depth('kb.second_test.GATE_root._0.COL_wait._2');
-- Returns: 6
```

## Pattern Syntax

### Basic Wildcards

- `*` - Matches exactly one path component at any level
- `prefix*` - Matches any component starting with "prefix"

### Quantified Wildcards

- `*{n}` - Matches exactly n components
- `*{n,m}` - Matches between n and m components (inclusive)
- `*{n,}` - Matches n or more components
- `*{,m}` - Matches up to m components

### Pattern Examples

```sql
-- Match any GATE node at depth 3
'kb.*.GATE*'

-- Match COL nodes 2-4 levels deep
'kb.*{2,4}.COL*'

-- Match any path ending in _0
'*.*._0'

-- Complex: GATE followed by 1-2 levels, then COL
'kb.*.GATE*.*{1,2}.COL*'
```

## Practical Query Examples

### Find All Descendant Nodes

```sql
SELECT path FROM nodes 
WHERE ltree_descendant('kb.test.GATE_root', path);
```

### Find Nodes by Pattern

```sql
-- All COL (collector) nodes
SELECT path FROM nodes 
WHERE ltree_match(path, '*.*.COL*.*');

-- All nodes at specific depth
SELECT path FROM nodes 
WHERE ltree_depth(path) = 4;

-- GATE nodes with exactly 2 intermediate levels
SELECT path FROM nodes
WHERE ltree_match(path, 'kb.*{2}.GATE*.*');
```

### Build Indexes for Performance

```sql
-- Index for ancestor queries
CREATE INDEX idx_path ON nodes(path);

-- Index for depth queries
CREATE INDEX idx_depth ON nodes((ltree_depth(path)));
```

## ChainTree Integration

This extension supports the ChainTree architecture's hierarchical node addressing:

```sql
-- Match behavior tree node types
WHERE ltree_match(path, '*.*.GATE*.*')     -- Gate nodes
WHERE ltree_match(path, '*.*.COL*.*')      -- Collector nodes  
WHERE ltree_match(path, '*.*.SEQ*.*')      -- Sequence nodes
WHERE ltree_match(path, '*.*.LEAF*.*')     -- Leaf nodes

-- Find execution path
WHERE ltree_ancestor(current_node, 'kb.test.GATE_root')

-- Query by hierarchy depth
WHERE ltree_depth(path) BETWEEN 3 AND 5
```

## Performance Considerations

- **Pattern Complexity**: Simple wildcards are faster than quantified patterns
- **Indexing**: Create indexes on path columns for large datasets
- **Quantifiers**: `*{n}` is faster than `*{n,m}` which is faster than `*{n,}`
- **Prefix Patterns**: `prefix*` patterns are optimized for early termination

## Testing

Run the comprehensive test suite:

```bash
make test
```

Expected output:
```
SQLite ltree Extension Test Suite
==================================
Extension loaded successfully: ./ltree.so

=== Testing Exact Matching ===
✓ PASS: Exact match - full path
✓ PASS: Exact match - no match

=== Testing Wildcard Matching ===
✓ PASS: Single wildcard
✓ PASS: Multiple wildcards
✓ PASS: All wildcards

...

Test Results: 28 passed, 0 failed
```

## Troubleshooting

### Extension Won't Load

```bash
# Check file exists and has correct permissions
ls -l ltree.so
chmod 755 ltree.so

# Verify SQLite version supports extensions
sqlite3 --version

# Check for missing dependencies
ldd ltree.so  # Linux
otool -L ltree.dylib  # macOS
```

### Compilation Errors

```bash
# Ensure SQLite dev headers are installed
find /usr -name sqlite3.h

# Check compiler version
gcc --version
```

## Architecture Notes

### Path Format

Paths use dot-separated components following ChainTree conventions:
- `kb` - Knowledge base root
- Component names may include underscores and mixed case
- Index suffixes use underscore prefix (`_0`, `_1`, etc.)

### Memory Management

The extension uses SQLite's memory allocation functions for automatic cleanup. No manual memory management required in SQL queries.

### Thread Safety

The extension is thread-safe when used with SQLite's default threading modes (serialized or multi-threaded).

## License

Part of the ChainTree distributed control system architecture.

## Related Documentation

- ChainTree Architecture Overview
- PostgreSQL ltree documentation (inspiration for this implementation)
- SQLite extension development guide

## Version History

- **1.0.0** - Initial release with core ltree functionality
  - Pattern matching with wildcards and quantifiers
  - Ancestor/descendant queries
  - Path depth calculation
  - Comprehensive test suite

