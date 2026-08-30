# tests/docker/Dockerfile — the Linux host the S6 I/O lanes need.
#
# mojito-sys's epoll and io_uring backends are Linux-only: on every other
# host they are detect-and-exclude -ENOSYS stubs, which is why every
# behavioural conformance row printed UNSUPPORTED-PLATFORM and why
# mojito-async#141 lists a Linux runner as a P0 deliverable.  This image is
# that runner, reproducible on any developer machine with Docker rather than
# only inside CI.
#
# Deliberately minimal: the S6 lanes are pure C against native/include, so a
# C toolchain and Linux kernel headers are the whole requirement.  No Mojo
# here — the Mojo suites are a separate concern.
FROM gcc:13-bookworm

# strace is not used by the lanes; it is here because the first thing anyone
# debugging an io_uring result on an unfamiliar kernel will want.
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends strace \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /work
