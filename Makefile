# mojito-sys S0 spike — foundation lane (#8)
#
# Objects come exclusively from pattern rules into build/, so lanes that own
# additional sources (aarch64_switch.S, ms_ctx.c) are picked up automatically
# by the wildcards below without any Makefile edit.

CC      ?= cc
CFLAGS  ?= -O2 -g -Wall -Wextra
SPIKE   := spike/context_switch
BUILD   := build
DYLIB   := libmojito_spike.dylib

CSRCS := $(wildcard $(SPIKE)/*.c)
SSRCS := $(wildcard $(SPIKE)/*.S)
OBJS  := $(patsubst $(SPIKE)/%.c,$(BUILD)/%.o,$(CSRCS)) \
         $(patsubst $(SPIKE)/%.S,$(BUILD)/%.o,$(SSRCS))

LIB_OBJS     := $(filter-out $(BUILD)/selftest.o,$(OBJS))
SELFTEST_BIN := $(BUILD)/selftest

.PHONY: all selftest test bench clean

all: $(DYLIB) $(SELFTEST_BIN)

$(BUILD):
	mkdir -p $@

$(BUILD)/%.o: $(SPIKE)/%.c | $(BUILD)
	$(CC) $(CFLAGS) -I$(SPIKE)/include -c $< -o $@

$(BUILD)/%.o: $(SPIKE)/%.S | $(BUILD)
	$(CC) -c $< -o $@

$(DYLIB): $(LIB_OBJS)
	$(CC) -dynamiclib -o $@ $^

$(SELFTEST_BIN): $(BUILD)/selftest.o $(LIB_OBJS)
	$(CC) $(CFLAGS) -o $@ $^

selftest: $(SELFTEST_BIN)
	./$(SELFTEST_BIN)

# Lanes #11/#12/#13 drive these; kept here so CONTRACT.md verification works.
test: $(DYLIB)
	./tests/spike/run.sh

bench: $(DYLIB)
	mojo run benchmark/spike/bench_switch.mojo

clean:
	rm -rf $(BUILD) $(DYLIB)
