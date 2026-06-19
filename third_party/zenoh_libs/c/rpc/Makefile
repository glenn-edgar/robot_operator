# Makefile for zenoh_rpc
#
# STATUS: scaffold only. The library compiles but does not currently link
# against zenoh-pico. Once zenoh-pico is installed (see README), uncomment
# the ZENOH_LIBS line below and fill in the TODOs in src/zenoh_rpc.c.

CC       ?= gcc
AR       ?= ar

ZENOH_PICO_HOME       ?= $(HOME)/src/zenoh-pico
ZENOH_PICO_INCLUDE    := $(ZENOH_PICO_HOME)/include
ZENOH_PICO_GEN_INC    := $(ZENOH_PICO_HOME)/build/include
ZENOH_PICO_LIB        := $(ZENOH_PICO_HOME)/lib-combined

ZENOH_DEFS := -DZENOH_LINUX -DZENOH_COMPILER_GCC -DZENOH_C_STANDARD=11

CFLAGS   := -Wall -Wextra -std=c11 -O2 -fPIC -Wno-format-truncation $(ZENOH_DEFS)
CPPFLAGS := -I./include -I../token/include -I$(ZENOH_PICO_INCLUDE) -I$(ZENOH_PICO_GEN_INC)
LDFLAGS  := -L../token/build -L$(ZENOH_PICO_LIB)
LIBS     := -lzenoh_token -lzenohpico -lpthread

PREFIX   ?= /usr/local

SRC_DIR   := src
INC_DIR   := include
TEST_DIR  := test
BUILD_DIR := build
OBJ_DIR   := $(BUILD_DIR)/obj

LIB_SRC   := $(SRC_DIR)/zenoh_rpc.c
LIB_OBJ   := $(OBJ_DIR)/zenoh_rpc.o
TEST_SRC  := $(TEST_DIR)/test_zenoh_rpc.c
TEST_OBJ  := $(OBJ_DIR)/test_zenoh_rpc.o

STATIC_LIB := $(BUILD_DIR)/libzenoh_rpc.a
SHARED_LIB := $(BUILD_DIR)/libzenoh_rpc.so
TEST_BIN   := $(BUILD_DIR)/test_zenoh_rpc

STRESS_SRC := $(TEST_DIR)/stress_rpc.c
STRESS_OBJ_ASAN := $(OBJ_DIR)/stress_rpc.asan.o
LIB_OBJ_ASAN   := $(OBJ_DIR)/zenoh_rpc.asan.o
STRESS_BIN_ASAN := $(BUILD_DIR)/stress_rpc.asan

ASAN_CFLAGS := -fsanitize=address -fno-omit-frame-pointer -g -O1

TOKEN_LIB := ../token/build/libzenoh_token.a

.PHONY: all libs test stress-asan clean install dirs run-test run-stress-asan

all: libs test

dirs:
	@mkdir -p $(OBJ_DIR)

$(TOKEN_LIB):
	@echo ">> Building dependency: ../token"
	$(MAKE) -C ../token libs

$(LIB_OBJ): $(LIB_SRC) $(INC_DIR)/zenoh_rpc.h | dirs
	$(CC) $(CFLAGS) $(CPPFLAGS) -c -o $@ $<

$(TEST_OBJ): $(TEST_SRC) $(INC_DIR)/zenoh_rpc.h | dirs
	$(CC) $(CFLAGS) $(CPPFLAGS) -c -o $@ $<

$(STATIC_LIB): $(LIB_OBJ)
	$(AR) rcs $@ $^

$(SHARED_LIB): $(LIB_OBJ) $(TOKEN_LIB)
	$(CC) -shared -o $@ $(LIB_OBJ) $(LDFLAGS) $(LIBS)

libs: $(STATIC_LIB) $(SHARED_LIB)

test: $(TEST_BIN)

$(TEST_BIN): $(TEST_OBJ) $(STATIC_LIB) $(TOKEN_LIB)
	$(CC) $(CFLAGS) -o $@ $(TEST_OBJ) $(STATIC_LIB) $(LDFLAGS) $(LIBS)

run-test: $(TEST_BIN)
	@echo
	@echo "Running zenoh_rpc tests..."
	@echo
	LD_LIBRARY_PATH=$(BUILD_DIR):../token/build:$(ZENOH_PICO_LIB) $(TEST_BIN) $(TEST_ARGS)

# ---------------------------------------------------------------------------
# ASan stress test — links the rpc source with -fsanitize=address. zenoh-pico
# itself stays unmodified (host of well-tested code; ASan would mostly be
# noise there). Token lib is small, link against its non-ASan build.
# ---------------------------------------------------------------------------

$(LIB_OBJ_ASAN): $(LIB_SRC) $(INC_DIR)/zenoh_rpc.h | dirs
	$(CC) $(CFLAGS) $(ASAN_CFLAGS) $(CPPFLAGS) -c -o $@ $<

$(STRESS_OBJ_ASAN): $(STRESS_SRC) $(INC_DIR)/zenoh_rpc.h | dirs
	$(CC) $(CFLAGS) $(ASAN_CFLAGS) $(CPPFLAGS) -c -o $@ $<

$(STRESS_BIN_ASAN): $(STRESS_OBJ_ASAN) $(LIB_OBJ_ASAN) $(TOKEN_LIB)
	$(CC) $(CFLAGS) $(ASAN_CFLAGS) -o $@ $(STRESS_OBJ_ASAN) $(LIB_OBJ_ASAN) \
	    $(LDFLAGS) $(LIBS)

stress-asan: $(STRESS_BIN_ASAN)

run-stress-asan: $(STRESS_BIN_ASAN)
	@echo
	@echo "Running stress_rpc under ASan..."
	@echo
	LD_LIBRARY_PATH=$(BUILD_DIR):../token/build:$(ZENOH_PICO_LIB) \
	  ASAN_OPTIONS=detect_leaks=1:abort_on_error=0:halt_on_error=0:print_stacktrace=1 \
	  $(STRESS_BIN_ASAN) $(STRESS_ARGS)

install: libs
	install -d $(PREFIX)/lib $(PREFIX)/include/zenoh_rpc
	install -m 644 $(STATIC_LIB) $(PREFIX)/lib/
	install -m 755 $(SHARED_LIB) $(PREFIX)/lib/
	install -m 644 $(INC_DIR)/zenoh_rpc.h $(PREFIX)/include/zenoh_rpc/

clean:
	rm -rf $(BUILD_DIR)
