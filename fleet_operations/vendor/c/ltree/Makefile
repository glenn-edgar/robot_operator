# Makefile for SQLite ltree extension

# Detect OS
UNAME_S := $(shell uname -s)

# Compiler and flags
CC = gcc

# Change CFLAGS line to:
CFLAGS = -Wall -Wextra -O2 -fPIC -I.

LDFLAGS = -shared

# Output files
ifeq ($(UNAME_S),Darwin)
    EXT_SUFFIX = .dylib
    LDFLAGS += -dynamiclib
else
    EXT_SUFFIX = .so
endif

LIBRARY = ltree$(EXT_SUFFIX)
TEST_PROG = test_ltree

# Installation paths
PREFIX = /usr/local
LIBDIR = $(PREFIX)/lib

# Source files
LIB_SRC = ltree_sqlite.c
TEST_SRC = test_ltree.c

.PHONY: all clean test install uninstall help

all: $(LIBRARY) $(TEST_PROG)

$(LIBRARY): $(LIB_SRC)
	@echo "Building ltree extension..."
	$(CC) $(CFLAGS) $(LDFLAGS) -o $(LIBRARY) $(LIB_SRC)
	@echo "Built: $(LIBRARY)"

$(TEST_PROG): $(TEST_SRC) $(LIBRARY)
	@echo "Building test program..."
	$(CC) $(CFLAGS) -o $(TEST_PROG) $(TEST_SRC)  -lsqlite3  -ldl
	@echo "Built: $(TEST_PROG)"

test: $(LIBRARY) $(TEST_PROG)
	@echo ""
	@echo "Running tests..."
	@echo ""
	@./$(TEST_PROG) $(LIBRARY)

install: $(LIBRARY)
	@echo "Installing ltree extension..."
	install -d $(LIBDIR)
	install -m 755 $(LIBRARY) $(LIBDIR)/
	@echo "Installed to $(LIBDIR)/$(LIBRARY)"

uninstall:
	@echo "Uninstalling ltree extension..."
	rm -f $(LIBDIR)/$(LIBRARY)
	@echo "Removed $(LIBDIR)/$(LIBRARY)"

clean:
	@echo "Cleaning build artifacts..."
	rm -f $(LIBRARY) $(TEST_PROG) *.o *~
	@echo "Clean complete"

help:
	@echo "SQLite ltree Extension - Build System"
	@echo ""
	@echo "Targets:"
	@echo "  make              - Build library and test program"
	@echo "  make test         - Build and run tests"
	@echo "  make install      - Install extension to $(LIBDIR)"
	@echo "  make uninstall    - Remove installed extension"
	@echo "  make clean        - Remove build artifacts"
	@echo "  make help         - Show this help message"

