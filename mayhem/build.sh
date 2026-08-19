#!/usr/bin/env bash
#
# mayhem/build.sh — build ReadStat (autotools) TWICE:
#   (1) a NORMAL-flags build tree (no sanitizers) for the project's own `make check` testsuite
#       (test_readstat / test_dta_days / test_sav_date / test_double_decimals), which mayhem/test.sh
#       later RUNS.
#   (2) the SANITIZED in-place build ($SRC) with $SANITIZER_FLAGS + $DEBUG_FLAGS, then `make
#       <fuzzer>` for each of the 11 fuzz harnesses ReadStat's real OSS-Fuzz build.sh ships
#       (upstream/projects/readstat/build.sh — READSTAT_FUZZERS), each a libFuzzer binary
#       (--enable-fuzz-testing wires @SANITIZERS@=-fsanitize=fuzzer + @LIB_FUZZING_ENGINE@ into the
#       automake fuzz_PROGRAMS rules). Plus a standalone (non-fuzzer) reproducer per harness, linked
#       by hand against $STANDALONE_FUZZ_MAIN (automake has no rule for that).
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. Ragel is NOT installed
# (matches upstream's own OSS-Fuzz build.sh) — the generated *_parse.c files are committed in git
# and same-mtime-after-checkout keeps make from trying to regenerate them via the ragel rule.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

READSTAT_FUZZERS="
    fuzz_compression_sav
    fuzz_grammar_spss_format
    fuzz_format_sas_commands
    fuzz_format_spss_commands
    fuzz_format_stata_dictionary
    fuzz_format_dta
    fuzz_format_por
    fuzz_format_sav
    fuzz_format_sas7bcat
    fuzz_format_sas7bdat
    fuzz_format_xport"

# =================================================================================================
# (1) NORMAL-flags test build — an independent, clean (NON-sanitized) tree built BEFORE the sanitized
#     in-place build below (which regenerates configure/Makefile in $SRC). mayhem/test.sh runs
#     `make check` here, so it stays an honest oracle for PATCH grading.
#
#     Pulled via `git archive` (a PRISTINE copy of the committed tree), not `cp -a $SRC` — build.sh is
#     re-run on an already-built $SRC (§6.2 item 9 idempotency check, and every real PATCH-grading
#     rebuild), and by then $SRC carries step (2)'s sanitized .libs/*.so + Makefile from the PREVIOUS
#     run. A raw copy would drag those ASan-instrumented objects into this tree; make wouldn't
#     recompile them (mtimes look up to date) even though CFLAGS changed, and the final link would
#     fail with undefined __asan_* symbols against unsanitized LDFLAGS.
# =================================================================================================
TEST_BUILD_DIR="${TEST_BUILD_DIR:-${HOME:-/tmp}/mayhem-test-build}"
echo "build.sh: (1) NORMAL-flags test build in $TEST_BUILD_DIR"
rm -rf "$TEST_BUILD_DIR"
mkdir -p "$TEST_BUILD_DIR"
git -C "$SRC" archive HEAD | tar -x -C "$TEST_BUILD_DIR"
(
  cd "$TEST_BUILD_DIR"
  export CFLAGS="-g -O2 $COVERAGE_FLAGS" CXXFLAGS="-g -O2 $COVERAGE_FLAGS"
  unset LDFLAGS
  ./autogen.sh
  ./configure CC="$CC" CXX="$CXX"
  # check_PROGRAMS (test_readstat/test_dta_days/test_sav_date/test_double_decimals) aren't part of the
  # default `all` target — build each by name here so mayhem/test.sh only has to RUN them (automake
  # has no aggregate "check_PROGRAMS" make target, only the per-program ones).
  make test_readstat test_dta_days test_sav_date test_double_decimals -j"$MAYHEM_JOBS"
)
echo "$TEST_BUILD_DIR" > /mayhem/.mayhem-test-build-dir

# =================================================================================================
# (2) SANITIZED in-place build + fuzz harnesses (+ standalone reproducers).
# =================================================================================================
echo "build.sh: (2) SANITIZED build in $SRC"

# --- Crypto/checksum audit: disable the ZSAV zlib checksum gate, FUZZ BUILD ONLY -----------------
# fuzz_format_sav reaches zsav_read_compressed_data() (src/spss/readstat_zsav_read.c) whenever a SAV
# header declares binary/zlib compression. That function calls zlib's uncompress(), which verifies
# the zlib-format stream's Adler-32 trailer and rejects the whole block on any mismatch — a mutated
# byte in a compressed block fails that checksum with near-certainty, so once the fuzzer reaches the
# ZSAV branch, everything past decompression (the actual row-parsing code) is effectively
# unreachable by mutation alone. zlib has no build-time flag for this (unlike e.g. libogg's
# --disable-crc); the only way to skip it is inflateValidate(strm, 0) on the low-level streaming
# API, so swap the one-shot uncompress() call for inflateInit/inflateValidate(0)/inflate/inflateEnd
# with equivalent semantics (status==Z_OK + exact output size). Patched HERE, in the in-image
# SANITIZED build tree ($SRC) only — NOT a committed upstream edit (the git history stays purely
# additive; see GATE 5) — and NOT applied to the NORMAL-flags test tree copied out in step (1)
# above (via `git archive`, so it can't see this working-tree-only edit anyway), so
# mayhem/test.sh's oracle keeps exercising the real, checksum-verified ZSAV read path.
python3 - "$SRC/src/spss/readstat_zsav_read.c" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()
needle = (
    "        int status = uncompress(uncompressed_block, &uncompressed_block_len,\n"
    "                compressed_block, entry->compressed_size);\n"
)
replacement = (
    "        int status;\n"
    "        {\n"
    "            z_stream zstrm = {0};\n"
    "            status = inflateInit(&zstrm);\n"
    "            if (status == Z_OK) {\n"
    "                inflateValidate(&zstrm, 0);\n"
    "                zstrm.next_in = compressed_block;\n"
    "                zstrm.avail_in = (uInt)entry->compressed_size;\n"
    "                zstrm.next_out = uncompressed_block;\n"
    "                zstrm.avail_out = (uInt)uncompressed_block_len;\n"
    "                status = inflate(&zstrm, Z_FINISH);\n"
    "                uncompressed_block_len = zstrm.total_out;\n"
    "                if (status == Z_STREAM_END)\n"
    "                    status = Z_OK;\n"
    "                inflateEnd(&zstrm);\n"
    "            }\n"
    "        }\n"
)
if replacement in src:
    pass  # already patched -- build.sh must be idempotent (re-run on an already-built $SRC, §6.2 item 9)
elif needle in src:
    open(path, "w").write(src.replace(needle, replacement, 1))
else:
    sys.exit("mayhem/build.sh: zsav checksum-patch anchor not found in " + path
              + " -- upstream source changed, update the patch in mayhem/build.sh")
PYEOF

# NOTE: deliberately do NOT pass --enable-fuzz-testing. configure's own probe for it links a plain
# AC_LANG_PROGRAM() (a bare main()) with -fsanitize=fuzzer in CFLAGS, which always fails: libFuzzer's
# own main (pulled in by -fsanitize=fuzzer) collides with the test program's main AND needs an
# undefined LLVMFuzzerTestOneInput, so the configure-time link sanity-check can never pass. Instead,
# mirror how upstream's real OSS-Fuzz build.sh gets the same result: instrument the WHOLE project with
# -fsanitize=fuzzer-no-link (coverage counters, no main/engine) via global CFLAGS, and let
# @LIB_FUZZING_ENGINE@ (unconditionally AC_SUBST'd regardless of --enable-fuzz-testing, see
# configure.ac) add the real -fsanitize=fuzzer engine ONLY at each fuzz target's final link — by then
# the harness .c already defines LLVMFuzzerTestOneInput and no other main exists.
export CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link"
export CXXFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link"
export LDFLAGS="$SANITIZER_FLAGS"

./autogen.sh
./configure --enable-static CC="$CC" CXX="$CXX" LIB_FUZZING_ENGINE="$LIB_FUZZING_ENGINE"

# LeakSanitizer off-switch (SPEC §6.2 item 15): compile mayhem/lsan_off.c (defines only
# __lsan_is_turned_off) with the SAME sanitizer + debug flags as the fuzz binaries and link the
# object into every ASan-built binary below. Only the leak check is disabled; ASan stays on. The
# fuzz targets get it through @LIB_FUZZING_ENGINE@, which automake uses only at their final link.
LSAN_OFF_OBJ="$SRC/mayhem-lsan-off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.c" -o "$LSAN_OFF_OBJ"

for fuzzer in $READSTAT_FUZZERS; do
    make "$fuzzer" -j"$MAYHEM_JOBS" LIB_FUZZING_ENGINE="$LIB_FUZZING_ENGINE $LSAN_OFF_OBJ"
    # $SRC IS /mayhem (the build contract), so the binary just built at ./$fuzzer already lands
    # exactly where it needs to be — no copy required.
done

# --- Standalone (non-fuzzer) reproducers ----------------------------------------------------------
# Same harness sources, linked against $STANDALONE_FUZZ_MAIN instead of the libFuzzer engine, against
# the static lib the sanitized build above just produced (libtool puts it under .libs/).
LIBREADSTAT_A="$SRC/.libs/libreadstat.a"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -std=c99 -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o

build_standalone() {
  local name="$1" ; shift
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS -std=c99 "$@" /tmp/standalone_main.o "$LSAN_OFF_OBJ" "$LIBREADSTAT_A" -lm -lz \
      -o "/mayhem/${name}-standalone"
}

build_standalone fuzz_compression_sav       "$SRC/src/fuzz/fuzz_compression_sav.c"
build_standalone fuzz_grammar_spss_format   "$SRC/src/fuzz/fuzz_grammar_spss_format.c"

for pair in \
    "fuzz_format_sas_commands:fuzz_format_sas_commands" \
    "fuzz_format_spss_commands:fuzz_format_spss_commands" \
    "fuzz_format_stata_dictionary:fuzz_format_stata_dictionary" \
    "fuzz_format_dta:fuzz_format_dta" \
    "fuzz_format_por:fuzz_format_por" \
    "fuzz_format_sav:fuzz_format_sav" \
    "fuzz_format_sas7bcat:fuzz_format_sas7bcat" \
    "fuzz_format_sas7bdat:fuzz_format_sas7bdat" \
    "fuzz_format_xport:fuzz_format_xport" ; do
  name="${pair%%:*}"
  build_standalone "$name" \
      "$SRC/src/fuzz/fuzz_format.c" "$SRC/src/fuzz/${name}.c" "$SRC/src/test/test_buffer_io.c"
done

echo "build.sh: built ${READSTAT_FUZZERS} (+ -standalone reproducers); test tree in $TEST_BUILD_DIR"
