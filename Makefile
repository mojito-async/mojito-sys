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

SYS_CSRCS := $(sort $(shell find native -name '*.c' -type f))
SYS_SSRCS := $(sort $(shell find native -name '*.S' -type f))
SYS_OBJS  := $(patsubst native/%.c,$(SYS_BUILD)/%.o,$(SYS_CSRCS)) \
             $(patsubst native/%.S,$(SYS_BUILD)/%.o,$(SYS_SSRCS))
SYS_DEPS  := $(SYS_OBJS:.o=.d)

# ---- S0 spike (existing) -----------------------------------------------------

CSRCS := $(wildcard $(SPIKE)/*.c)
SSRCS := $(wildcard $(SPIKE)/*.S)
OBJS  := $(patsubst $(SPIKE)/%.c,$(BUILD)/%.o,$(CSRCS)) \
         $(patsubst $(SPIKE)/%.S,$(BUILD)/%.o,$(SSRCS))

LIB_OBJS     := $(filter-out $(BUILD)/selftest.o,$(OBJS))
SELFTEST_BIN := $(BUILD)/selftest

.DELETE_ON_ERROR:
.PHONY: test-s6 all selftest test bench test-s1 test-s2 test-s2-conformance \
        test-s2-stress test-s2-integration test-s2-pkg test-s3 test-s5 \
        test-contract-sweep bench-io clean

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
	$(CC) $(CFLAGS) -I$(SYS_INC) -MMD -MF $@.d -c $< -o $@

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
bench-io: $(DYLIB_SYS)
	MOJO=$(MOJO) ./benchmark/io/run.sh

test-s1: $(DYLIB_SYS)
	MOJO=$(MOJO) ./tests/s1/run.sh
test-s2: $(DYLIB_SYS)
	MOJO=$(MOJO) ./tests/s2/native/run.sh
test-s2-conformance: $(DYLIB_SYS) $(DYLIB)
	MOJO=$(MOJO) ./tests/s2/conformance/run.sh
test-s2-stress: $(DYLIB_SYS)
	MOJO=$(MOJO) ./tests/s2/stress/run.sh
test-s2-integration: $(DYLIB_SYS) $(DYLIB)
	MOJO=$(MOJO) ./tests/s2/integration/run.sh
test-s2-pkg: $(DYLIB_SYS)
	MOJO=$(MOJO) ./tests/s2/pkg/run.sh

test-s3: $(DYLIB_SYS)
	MOJO=$(MOJO) ./tests/s3/run.sh

test-s5: $(DYLIB_SYS)
	MOJO=$(MOJO) ./tests/s5/run.sh

# ABI-wide contract sweep (mojito-async#170, fix item 1): every public
# mjs_* entry point in the 0-or-negative-errno family gets a real,
# live-handle invocation whose rc sign is checked. Runs on every host (no
# platform guard): unsupported backends (epoll off Linux, io_uring
# without host support / MOJITO_IO_URING=1) degrade to a real, in-contract
# -ENOSYS this driver observes and sweeps rather than skipping.
test-contract-sweep: $(DYLIB_SYS)
	@CC=$(CC) ./tests/contract_sweep/run.sh

# S6 I/O conformance lanes (mojito-async#141 item 5: these existed with no
# Makefile target at all, so the I/O layer was inside no gate).  Each lane
# exits 2 on a host where its backend is the -ENOSYS stub, and 2 is an
# ENVIRONMENT result the gate must not treat as a pass — which is exactly why
# this target is NOT in precommit/gate.sh's check list: on a macOS dev host it
# would block every commit on a platform condition rather than a defect.  It
# belongs in the Linux CI lane from mojito-async#141.
test-s6: $(DYLIB_SYS)
	@rc=0; \
	for lane in ./tests/s6/*/run.sh; do \
	    [ -x "$$lane" ] || continue; \
	    printf '== %s\n' "$$lane"; \
	    MOJO=$(MOJO) CC=$(CC) "$$lane" || rc=$$?; \
	done; \
	exit $$rc

-include $(SYS_DEPS)
clean:
	rm -rf $(BUILD) $(DYLIB) $(DYLIB_SYS)
