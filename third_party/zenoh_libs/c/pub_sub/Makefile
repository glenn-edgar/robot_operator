# Makefile for zenoh_pubsub
#
# STATUS: scaffold only. The library compiles but does not currently link
# against zenoh-pico. Once zenoh-pico is installed (see README), uncomment
# the ZENOH_LIBS line below and fill in the TODOs in src/zenoh_pubsub.c.
#
# Prerequisites:
#   - zenoh-pico installed:
#       git clone https://github.com/eclipse-zenoh/zenoh-pico
#       cd zenoh-pico && mkdir build && cd build
#       cmake .. && make && sudo make install && sudo ldconfig
#   - libzenoh_token built (in ../token/build/)
#
# Usage:
#   make                # build everything (libs + test binary)
#   make libs           # static + shared libraries only
#   make test           # build test binary
#   make run-test       # build and run tests (API-surface only until zenoh-pico wired in)
#   make clean          # remove build artifacts
#   make install        # install to PREFIX (default /usr/local)

CC       ?= gcc
AR       ?= ar

# zenoh-pico location: defaults to a local source build (no sudo install),
# override with ZENOH_PICO_HOME for a system install (e.g. /usr/local).
ZENOH_PICO_HOME       ?= $(HOME)/src/zenoh-pico
ZENOH_PICO_INCLUDE    := $(ZENOH_PICO_HOME)/include
ZENOH_PICO_GEN_INC    := $(ZENOH_PICO_HOME)/build/include
ZENOH_PICO_LIB        := $(ZENOH_PICO_HOME)/lib-combined

# zenoh-pico platform defines — must match what zenoh-pico was built with.
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

LIB_SRC   := $(SRC_DIR)/zenoh_pubsub.c
LIB_OBJ   := $(OBJ_DIR)/zenoh_pubsub.o
TEST_SRC  := $(TEST_DIR)/test_zenoh_pubsub.c
TEST_OBJ  := $(OBJ_DIR)/test_zenoh_pubsub.o

STATIC_LIB := $(BUILD_DIR)/libzenoh_pubsub.a
SHARED_LIB := $(BUILD_DIR)/libzenoh_pubsub.so
TEST_BIN   := $(BUILD_DIR)/test_zenoh_pubsub

TOKEN_LIB := ../token/build/libzenoh_token.a

.PHONY: all libs test clean install dirs run-test

all: libs test

dirs:
	@mkdir -p $(OBJ_DIR)

$(TOKEN_LIB):
	@echo ">> Building dependency: ../token"
	$(MAKE) -C ../token libs

$(LIB_OBJ): $(LIB_SRC) $(INC_DIR)/zenoh_pubsub.h | dirs
	$(CC) $(CFLAGS) $(CPPFLAGS) -c -o $@ $<

$(TEST_OBJ): $(TEST_SRC) $(INC_DIR)/zenoh_pubsub.h | dirs
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
	@echo "Running zenoh_pubsub tests..."
	@echo
	LD_LIBRARY_PATH=$(BUILD_DIR):../token/build:$(ZENOH_PICO_LIB) $(TEST_BIN) $(TEST_ARGS)

install: libs
	install -d $(PREFIX)/lib $(PREFIX)/include/zenoh_pubsub
	install -m 644 $(STATIC_LIB) $(PREFIX)/lib/
	install -m 755 $(SHARED_LIB) $(PREFIX)/lib/
	install -m 644 $(INC_DIR)/zenoh_pubsub.h $(PREFIX)/include/zenoh_pubsub/

clean:
	rm -rf $(BUILD_DIR)
