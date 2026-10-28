# Makefile - Project 2: multi-queue / multi-threaded AF_XDP reflector
#
# Build requirements (Debian/Ubuntu):
#   sudo apt install clang llvm gcc make libbpf-dev libxdp-dev libelf-dev zlib1g-dev
#
# NOTE: recipe lines start with ">" instead of a TAB (see .RECIPEPREFIX)
# so the file is safe to copy/paste.
.RECIPEPREFIX = >

CLANG ?= clang
CC    ?= gcc

# clang -target bpf does not know the multiarch include dir (asm/types.h).
ARCH_INC := /usr/include/$(shell uname -m)-linux-gnu

CFLAGS     ?= -O2 -g -Wall -Wextra
BPF_CFLAGS := -O2 -g -Wall -target bpf -I$(ARCH_INC)

all: xdp_kern.o xsk_reflect_mq

# eBPF object: XDP program + XSKMAP + per-queue stats map
xdp_kern.o: src/xdp_kern.c src/common.h
> $(CLANG) $(BPF_CFLAGS) -c $< -o $@

# User space: libbpf (load/attach/maps) + libxdp (UMEM/XSK/rings) + pthreads
xsk_reflect_mq: src/xsk_reflect_mq.c src/common.h
> $(CC) $(CFLAGS) $< -o $@ -lxdp -lbpf -pthread

clean:
> rm -f xdp_kern.o xsk_reflect_mq

.PHONY: all clean
