# Makefile - Project 3: Rust (aya + xsk-rs) multi-queue AF_XDP reflector
#
#   make          build the eBPF object AND the user-space binary
#   make ebpf     eBPF crate only   (nightly + rust-src + bpf-linker)
#   make user     user-space only   (stable Rust + clang/llvm + libelf + zlib)
#   make test     unit tests (no root / NIC needed)
#
# Recipe lines start with ">" instead of a TAB (see .RECIPEPREFIX), so the
# file is safe to copy/paste.
.RECIPEPREFIX = >

CARGO ?= cargo

all: ebpf user

# The eBPF crate has its own rust-toolchain.toml (nightly + rust-src) and
# .cargo/config.toml (target = bpfel-unknown-none, build-std = core), so a
# plain `cargo build` inside it does the right thing.
# Output: xsk-reflect-ebpf/target/bpfel-unknown-none/release/xsk-reflect-ebpf
ebpf:
> cd xsk-reflect-ebpf && $(CARGO) build --release

# Output: target/release/xsk-reflect
user:
> $(CARGO) build --release

test:
> $(CARGO) test -p xsk-reflect

clean:
> $(CARGO) clean
> cd xsk-reflect-ebpf && $(CARGO) clean

.PHONY: all ebpf user test clean
