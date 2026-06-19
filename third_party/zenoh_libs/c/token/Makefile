# Makefile for zenoh_token (FNV1a-32 hash utility)
#
# No external dependencies. Pure C99 + pthreads.
#
# Usage:
#   make                # build everything (libs + tests)
#   make libs           # static + shared libraries only
#   make test           # build test binary
#   make run-test       # build and run tests
#   make clean          # remove build artifacts
#   make install        # install to PREFIX (default /usr/local)

CC       ?= gcc
AR       ?= ar
CFLAGS   := -Wall -Wextra -std=c11 -O2 -fPIC
CPPFLAGS := -I./include
LDFLAGS  :=
LIBS     := -lpthread

PREFIX   ?= /usr/local

SRC_DIR   := src
INC_DIR   := include
TEST_DIR  := test
BUILD_DIR := build
OBJ_DIR   := $(BUILD_DIR)/obj

LIB_SRC   := $(SRC_DIR)/zenoh_token.c
LIB_OBJ   := $(OBJ_DIR)/zenoh_token.o
TEST_SRC  := $(TEST_DIR)/test_zenoh_token.c
TEST_OBJ  := $(OBJ_DIR)/test_zenoh_token.o

STATIC_LIB := $(BUILD_DIR)/libzenoh_token.a
SHARED_LIB := $(BUILD_DIR)/libzenoh_token.so
TEST_BIN   := $(BUILD_DIR)/test_zenoh_token

.PHONY: all libs test clean install dirs run-test

all: libs test

dirs:
	@mkdir -p $(OBJ_DIR)

$(LIB_OBJ): $(LIB_SRC) $(INC_DIR)/zenoh_token.h | dirs
	$(CC) $(CFLAGS) $(CPPFLAGS) -c -o $@ $<

$(TEST_OBJ): $(TEST_SRC) $(INC_DIR)/zenoh_token.h | dirs
	$(CC) $(CFLAGS) $(CPPFLAGS) -c -o $@ $<

$(STATIC_LIB): $(LIB_OBJ)
	$(AR) rcs $@ $^

$(SHARED_LIB): $(LIB_OBJ)
	$(CC) -shared -o $@ $^ $(LIBS)

libs: $(STATIC_LIB) $(SHARED_LIB)

test: $(TEST_BIN)

$(TEST_BIN): $(TEST_OBJ) $(STATIC_LIB)
	$(CC) $(CFLAGS) -o $@ $(TEST_OBJ) $(STATIC_LIB) $(LIBS)

run-test: $(TEST_BIN)
	@echo
	@echo "Running zenoh_token tests (no external dependencies)..."
	@echo
	$(TEST_BIN)

install: libs
	install -d $(PREFIX)/lib $(PREFIX)/include/zenoh_token
	install -m 644 $(STATIC_LIB) $(PREFIX)/lib/
	install -m 755 $(SHARED_LIB) $(PREFIX)/lib/
	install -m 644 $(INC_DIR)/zenoh_token.h $(PREFIX)/include/zenoh_token/

clean:
	rm -rf $(BUILD_DIR)
