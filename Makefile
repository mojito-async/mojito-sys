# mojito-sys S0 spike — foundation lane (#8); S1 build layout (issue #24).
#
# Objects come exclusively from pattern rules into build/, so lanes that
# own additional sources (aarch64_switch.S, ms_ctx.c, native/**/*.c) are
# picked up automatically by the wildcards below without any Makefile edit.
#
# Default `all` keeps the S0 surface (libmojito_spike.dylib + selftest) and
# additionally builds the packaged S1 dylib (libmojito_sys.dylib). The S1
# native sources are stubbed with native/posix/mjs_page.c until the
# memory-page lane lands, so the packaged lib links from day one.

CC      ?= cc
CFLAGS  ?= -O2 -g -Wall -Wextra
SPIKE   := spike/context_switch
BUILD   := build
DYLIB   := libmojito_spike.dylib
MOJO    ?= mojo

# ---- S1 system library (issue #24) -------------------------------------
SYS_BUILD := $(BUILD)/sys
SYS_INC   := native/include
DYLIB_SYS := libmojito_sys.dylib

SYS_CSRCS := $(wildcard native/**/*.c)
SYS_SSRCS := $(wildcard native/**/*.S)
SYS_OBJS  := $(patsubst native/%.c,$(SYS_BUILD)/%.o,$(SYS_CSRCS)) \
             $(patsubst native/%.S,$(SYS_BUILD)/%.o,$(SYS_SSRCS))

# ---- S0 spike (existing) -----------------------------------------------------

CSRCS := $(wildcard $(SPIKE)/*.c)
SSRCS := $(wildcard $(SPIKE)/*.S)
OBJS  := $(patsubst $(SPIKE)/%.c,$(BUILD)/%.o,$(CSRCS)) \
         $(patsubst $(SPIKE)/%.S,$(BUILD)/%.o,$(SSRCS))

LIB_OBJS     := $(filter-out $(BUILD)/selftest.o,$(OBJS))
SELFTEST_BIN := $(BUILD)/selftest

.DELETE_ON_ERROR:
.PHONY: all selftest test bench test-s1 clean

all: $(DYLIB) $(SELFTEST_BIN) $(DYLIB_SYS)

$(BUILD):
	mkdir -p $@

$(SYS_BUILD):
	mkdir -p $@

$(BUILD)/%.o: $(SPIKE)/%.c | $(BUILD)
	$(CC) $(CFLAGS) -I$(SPIKE)/include -c $< -o $@

$(BUILD)/%.o: $(SPIKE)/%.S | $(BUILD)
	$(CC) -I$(SPIKE)/include -c $< -o $@

$(SYS_BUILD)/%.o: native/%.c | $(SYS_BUILD)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -I$(SYS_INC) -c $< -o $@

$(SYS_BUILD)/%.o: native/%.S | $(SYS_BUILD)
	@mkdir -p $(dir $@)
	$(CC) -I$(SYS_INC) -c $< -o $@

$(DYLIB): $(LIB_OBJS)
	$(CC) -dynamiclib -o $@ $^

$(DYLIB_SYS): $(SYS_OBJS)
	$(CC) -dynamiclib -o $@ $^

$(SELFTEST_BIN): $(BUILD)/selftest.o $(LIB_OBJS)
	$(CC) $(CFLAGS) -o $@ $^

selftest: $(SELFTEST_BIN)
	./$(SELFTEST_BIN)

test: $(DYLIB)
	MOJO=$(MOJO) ./tests/spike/run.sh
	MOJO=$(MOJO) ./tests/spike/run_t8_t14.sh

bench: $(DYLIB)
	$(MOJO) run -I $(SPIKE) -Xlinker $(DYLIB) benchmark/spike/bench_switch.mojo

test-s1: $(DYLIB_SYS)
	MOJO=$(MOJO) ./tests/s1/run.sh

clean:
	rm -rf $(BUILD) $(DYLIB) $(DYLIB_SYS)