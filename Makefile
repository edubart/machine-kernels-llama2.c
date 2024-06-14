# choose your compiler, e.g. gcc/clang
# example override to clang: make run CC=clang
CC = gcc

# the most basic way of building that is most likely to work on most systems
.PHONY: run
run: run.c
	$(CC) -O3 -o run run.c -lm
	$(CC) -O3 -o runq runq.c -lm

# useful for a debug build, can then e.g. analyze with valgrind, example:
# $ valgrind --leak-check=full ./run out/model.bin -n 3
rundebug: run.c
	$(CC) -g -o run run.c -lm
	$(CC) -g -o runq runq.c -lm

# https://gcc.gnu.org/onlinedocs/gcc/Optimize-Options.html
# https://simonbyrne.github.io/notes/fastmath/
# -Ofast enables all -O3 optimizations.
# Disregards strict standards compliance.
# It also enables optimizations that are not valid for all standard-compliant programs.
# It turns on -ffast-math, -fallow-store-data-races and the Fortran-specific
# -fstack-arrays, unless -fmax-stack-var-size is specified, and -fno-protect-parens.
# It turns off -fsemantic-interposition.
# In our specific application this is *probably* okay to use
.PHONY: runfast
runfast: run.c
	$(CC) -Ofast -o run run.c -lm
	$(CC) -Ofast -o runq runq.c -lm

# additionally compiles with OpenMP, allowing multithreaded runs
# make sure to also enable multiple threads when running, e.g.:
# OMP_NUM_THREADS=4 ./run out/model.bin
.PHONY: runomp
runomp: run.c
	$(CC) -Ofast -fopenmp -march=native run.c  -lm  -o run
	$(CC) -Ofast -fopenmp -march=native runq.c  -lm  -o runq

.PHONY: win64
win64:
	x86_64-w64-mingw32-gcc -Ofast -D_WIN32 -o run.exe -I. run.c win.c
	x86_64-w64-mingw32-gcc -Ofast -D_WIN32 -o runq.exe -I. runq.c win.c

# compiles with gnu99 standard flags for amazon linux, coreos, etc. compatibility
.PHONY: rungnu
rungnu:
	$(CC) -Ofast -std=gnu11 -o run run.c -lm
	$(CC) -Ofast -std=gnu11 -o runq runq.c -lm

.PHONY: runompgnu
runompgnu:
	$(CC) -Ofast -fopenmp -std=gnu11 run.c  -lm  -o run
	$(CC) -Ofast -fopenmp -std=gnu11 runq.c  -lm  -o runq

# run all tests
.PHONY: test
test:
	pytest

# run only tests for run.c C implementation (is a bit faster if only C code changed)
.PHONY: testc
testc:
	pytest -k runc

# run the C tests, without touching pytest / python
# to increase verbosity level run e.g. as `make testcc VERBOSITY=1`
VERBOSITY ?= 0
.PHONY: testcc
testcc:
	$(CC) -DVERBOSITY=$(VERBOSITY) -O3 -o testc test.c -lm
	./testc

.PHONY: clean
clean:
	rm -f run runq runq_rv64
	rm -f matmul_kernel.so matmul_kernel.bin matmul_kernel.elf matmul_kernel.dump

RISCV_TOOLCHAIN=riscv64-linux-gnu-
# RISCV_TOOLCHAIN=riscv64-buildroot-linux-musl-

runq: matmul_kernel.cpp runq.c
	gcc -x c++ matmul_kernel.cpp -x c runq.c -o $@ \
		-march=native -Ofast -fno-strict-overflow -fopenmp -lm

runq_rv64: runq.c
	$(RISCV_TOOLCHAIN)gcc $< -o $@ \
		-march=rv64g -Ofast -fno-strict-overflow -static -lm

runq_rv64.sqfs: runq_rv64 tokenizer.bin
	mksquashfs $^ $@ -quiet \
		-mkfs-time 0 -all-time 0 -all-root \
		-noappend -no-exports -no-progress \
		-comp lzo

matmul_kernel.bin: matmul_kernel.cpp
	$(RISCV_TOOLCHAIN)g++ $< -o matmul_kernel.elf \
		-march=rv64g -O3 -fno-strict-overflow -fno-exceptions -fPIC \
		-ffreestanding -nostartfiles -nostdlib -static -Wl,-e,kernel_entry
	riscv64-buildroot-linux-musl-objdump -d matmul_kernel.elf > matmul_kernel.dump
	$(RISCV_TOOLCHAIN)objcopy --only-section=.text -S -O binary matmul_kernel.elf $@
	truncate -s 4096 $@

linux.bin:
	wget -O linux.bin https://github.com/cartesi/image-kernel/releases/download/v0.20.0/linux-6.5.13-ctsi-1-v0.20.0.bin

linux-matmul.bin: linux.bin matmul_kernel.bin
	cp linux.bin $@
	cat matmul_kernel.bin | dd of=$@ bs=1 seek=258048 conv=notrunc

matmul_kernel.so: matmul_kernel.cpp
	g++ $< -o $@ -march=native -O3 -fno-strict-overflow -fno-stack-protector -fno-plt -fno-exceptions -fPIC -fopenmp -shared -s

.PHONY: all
all: matmul_kernel.so linux-matmul.bin runq_rv64.sqfs

.PHONY: runq-test runq_rv64-test

# MODEL=llama2_7b_q80.bin
MODEL=stories110M_q80.bin
PARAMS=-p 0.7 -s 1 -n 100 -i 'The universe is'

runq-test: runq
	time -p ./runq $(MODEL) $(PARAMS)

runq_rv64-test: runq_rv64.sqfs linux-matmul.bin matmul_kernel.so runq
	CM_HOST_KERNEL=./matmul_kernel.so time -p cartesi-machine \
		--ram-image=linux-matmul.bin \
		--ram-length=12Gi \
		--flash-drive=label:model,filename:$(MODEL),mount:false \
		--flash-drive=label:runq,filename:runq_rv64.sqfs \
		--append-init="chown dapp:dapp /dev/pmem1" \
		--append-bootargs="hugepagesz=1G hugepages=10" \
		--workdir=/mnt/runq \
		--no-init-splash \
		--final-hash \
		-- "./runq_rv64 /dev/pmem1 $(PARAMS)"
	time -p cartesi-machine \
		--ram-image=linux-matmul.bin \
		--ram-length=12Gi \
		--flash-drive=label:model,filename:$(MODEL),mount:false \
		--flash-drive=label:runq,filename:runq_rv64.sqfs \
		--append-init="chown dapp:dapp /dev/pmem1" \
		--append-bootargs="hugepagesz=1G hugepages=10" \
		--workdir=/mnt/runq \
		--no-init-splash \
		--final-hash \
		-- "./runq_rv64 /dev/pmem1 $(PARAMS)"
