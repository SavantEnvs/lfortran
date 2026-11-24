#!/usr/bin/env bash
#
# mayhem/build.sh — build LFortran for fuzzing (no LLVM backend).
#
#   mayhem/build-fuzz/  ASan+UBSan (halting) + SanCov instrumented build of the whole compiler:
#                       src/bin/lfortran (the CLI that mayhem/test.sh runs) and the static libs
#                       the libFuzzer harness mayhem/fuzz_lfortran.cpp links against, once per
#                       target (fuzz/<target> + fuzz/<target>-standalone).
# The build dir is gitignored (mayhem/.gitignore), so `git clean -ffdX` removes it.
set -euo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
FUZZ=mayhem/build-fuzz
TEST=mayhem/build-test
mkdir -p "$FUZZ" "$TEST"

# 1) Generate the sources upstream's build0.sh generates (AST/ASR headers, tokenizer, parser,
#    LSP sources). build0.sh itself is not used because its ci/version.sh needs `git describe`
#    to succeed (tags, a git-readable tree), which is not true for every identity that re-runs
#    this. Skipped when nothing it reads changed, so a re-run does not force a full rebuild.
GEN_STAMP="$FUZZ/.generated.stamp"
gen_inputs="grammar/AST.asdl src/libasr/ASR.asdl src/libasr/asdl_cpp.py src/libasr/wasm_instructions.txt
  src/libasr/wasm_instructions_visitor.py src/libasr/intrinsic_func_registry_util_gen.py
  src/lfortran/parser/tokenizer.re src/lfortran/parser/preprocessor.re src/lfortran/parser/parser.yy
  src/server/generator"
if [ ! -f "$GEN_STAMP" ] || [ ! -f src/lfortran/ast.h ] || [ ! -f src/lfortran/parser/parser.tab.cc ] \
   || [ -n "$(find $gen_inputs -newer "$GEN_STAMP" -print -quit)" ]; then
  v=$(git describe --tags --dirty 2>/dev/null || echo v0.0.0-mayhem)
  echo "${v#v}" > version
  python3 src/libasr/asdl_cpp.py grammar/AST.asdl src/lfortran/ast.h
  python3 src/libasr/asdl_cpp.py src/libasr/ASR.asdl src/libasr/asr.h
  python3 src/libasr/wasm_instructions_visitor.py
  python3 src/libasr/intrinsic_func_registry_util_gen.py
  (cd src/lfortran && re2c -W -b parser/tokenizer.re -o parser/tokenizer.cpp)
  (cd src/lfortran && re2c -W -b parser/preprocessor.re -o parser/preprocessor.cpp)
  (cd src/lfortran/parser && bison -Wall -d parser.yy)
  python3 src/server/generator/generate_lsp_code.py --schema src/server/generator/metaModel.json \
    --target-language c++ --output-dir src/server
  touch "$GEN_STAMP"
fi

COMMON_CMAKE=(-G Ninja -S . -DCMAKE_BUILD_TYPE=Release -DWITH_LLVM=no -DWITH_STACKTRACE=no
  -DWITH_RUNTIME_LIBRARY=no)

# 2) The fuzz build: the whole compiler instrumented (sanitizers + SanCov + DWARF 3). The custom
#    arena allocator is off so ASan sees each allocation's bounds. LeakSanitizer is turned off
#    (mayhem/lsan_off.cc, linked into every executable: leaks are not the bug class fuzzed here).
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o "$FUZZ/lsan_off.o"
# -fno-sanitize=null: every `module` without a `contains` block computes a member address through
# a null AST pointer in the Bison actions (parser.yy MODULE rule, `&x->base` on NULL), so UBSan's
# null check fired on every module and no module code could be fuzzed. A real NULL dereference
# still faults and ASan reports it as a SEGV; every other UBSan check stays on and halting.
FFLAGS="$SANITIZER_FLAGS -fno-sanitize=null -fsanitize=fuzzer-no-link $DEBUG_FLAGS"
cmake "${COMMON_CMAKE[@]}" -B "$FUZZ" -DWITH_LCOMPILERS_FAST_ALLOC=no \
  -DCMAKE_C_FLAGS="$FFLAGS" -DCMAKE_CXX_FLAGS="$FFLAGS" \
  -DCMAKE_C_FLAGS_RELEASE="-O1" -DCMAKE_CXX_FLAGS_RELEASE="-O1" \
  -DCMAKE_EXE_LINKER_FLAGS="$SRC/$FUZZ/lsan_off.o"
ninja -C "$FUZZ" -j"$MAYHEM_JOBS" lfortran

# 3) The libFuzzer targets: one harness (mayhem/fuzz_lfortran.cpp), one binary per CLI mode it
#    mirrors, each linked twice (libFuzzer + the standalone run-once reproducer). The defines
#    match the library build (HAVE_ZLIB; no LCOMPILERS_FAST_ALLOC, which changes Allocator's layout).
OUT="$FUZZ/fuzz"
mkdir -p "$OUT"
HFLAGS="$FFLAGS -std=gnu++17 -O1 -DHAVE_ZLIB=1 -I$FUZZ/src -Isrc -I$FUZZ/src/lfortran"
LIBS=("$FUZZ/src/lfortran/liblfortran_lib.a" "$FUZZ/src/libasr/libasr.a"
  "$FUZZ/src/runtime/liblfortran_runtime_static.a" -lm -lz)
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c -x c "$STANDALONE_FUZZ_MAIN" -o "$OUT/standalone_main.o"
targets=(lfortran:1 lfortran-asr:2 lfortran-cpp-backend:3 lfortran-fixedform:4 lfortran-fmt:5
  lfortran-fortran:6 lfortran-cpp:7 lfortran-wat:8 lfortran-gfortran-mod:9)
# Compile the harness objects in parallel (small), but link the 18 ASan+UBSan executables one at a
# time: each link of the whole compiler takes several GB, and linking them all at once got the
# linker OOM-killed on a cold build.
pids=()
for tm in "${targets[@]}"; do
  t=${tm%%:*} m=${tm##*:}
  # shellcheck disable=SC2086
  $CXX $HFLAGS -DLF_MODE="$m" -c mayhem/fuzz_lfortran.cpp -o "$OUT/$t.o" &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done
for tm in "${targets[@]}"; do
  t=${tm%%:*}
  # shellcheck disable=SC2086
  $CXX $FFLAGS $LIB_FUZZING_ENGINE "$OUT/$t.o" "$FUZZ/lsan_off.o" "${LIBS[@]}" -o "$OUT/$t"
  # shellcheck disable=SC2086
  $CXX $FFLAGS "$OUT/standalone_main.o" "$OUT/$t.o" "$FUZZ/lsan_off.o" "${LIBS[@]}" -o "$OUT/$t-standalone"
done
for tm in "${targets[@]}"; do t=${tm%%:*}; [ -x "$OUT/$t" ] && [ -x "$OUT/$t-standalone" ]; done
