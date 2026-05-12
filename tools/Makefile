# Builds the RTL test-vector generator.
# Invoke from the repo root:
#   make -C tools          # build
#   make -C tools run      # build + emit vectors into tb/vectors/

CC      ?= gcc
CFLAGS  ?= -O2 -Wall -Wextra -std=c11
INCLUDES = -I..
LDLIBS   = -lm

REPO_ROOT := $(abspath ..)
CSV       := $(REPO_ROOT)/sim/output/reference_run.csv
OUT_DIR   := $(REPO_ROOT)/tb/vectors

BIN := gen_rtl_vectors$(if $(filter Windows_NT,$(OS)),.exe,)

all: $(BIN)

$(BIN): gen_rtl_vectors.c ../aaa_key_engine.c ../aaa_key_engine.h
	$(CC) $(CFLAGS) $(INCLUDES) -o $@ gen_rtl_vectors.c ../aaa_key_engine.c $(LDLIBS)

run: $(BIN)
	mkdir -p $(OUT_DIR)
	./$(BIN) $(CSV) $(OUT_DIR)

clean:
	rm -f $(BIN)

.PHONY: all run clean
