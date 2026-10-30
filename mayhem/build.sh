#!/usr/bin/env bash
#
# mayhem/build.sh — builds the cppdap (Debug Adapter Protocol library bundled in libraries/cppdap)
# libFuzzer harness, its standalone reproducer, and cppdap's own unit-test suite.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

: "${SRC:=/mayhem}"
cd "$SRC"

DAP="$SRC/libraries/cppdap"
JSON_INC="$DAP/third_party/json/include"
LIB_SRCS="content_stream io nlohmann_json_serializer network null_json_serializer protocol_events
          protocol_requests protocol_response protocol_types session socket typeinfo typeof"
INCS="-I$DAP/include -I$DAP/src -I$JSON_INC -DCPPDAP_JSON_NLOHMANN=1"

# bg <dir> <cmd...>: run a compile in the background (bounded by MAYHEM_JOBS); a failure leaves <dir>/FAIL.
bg() {
  local d="$1"; shift
  while [ "$(jobs -rp | wc -l)" -ge "$MAYHEM_JOBS" ]; do wait -n || true; done
  ( "$@" || touch "$d/FAIL" ) &
}
join() { wait || true; [ ! -e "$1/FAIL" ] || { echo "compile failed" >&2; exit 1; }; }

# 1) cppdap library + harness objects, sanitized + DWARF 3. Build dirs sit at the repo root so the
#    upstream `/*build*` .gitignore rule covers them. The libFuzzer variant is compiled with
#    -fsanitize=fuzzer-no-link so the library code itself carries coverage instrumentation (linking
#    the engine alone leaves it blind); the standalone variant has no coverage hooks.
: "${FUZZ_COV_FLAGS:=-fsanitize=fuzzer-no-link}"
FZ="$SRC/build-fuzz"; SA="$SRC/build-standalone"
rm -rf "$FZ" "$SA"; mkdir -p "$FZ" "$SA"
for variant in fuzz standalone; do
  if [ "$variant" = fuzz ]; then D="$FZ"; COV="$FUZZ_COV_FLAGS"; else D="$SA"; COV=""; fi
  for f in $LIB_SRCS; do
    # shellcheck disable=SC2086
    bg "$D" $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $COV -O1 $INCS -c "$DAP/src/$f.cpp" -o "$D/$f.o"
  done
  # shellcheck disable=SC2086
  bg "$D" $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $COV -O1 $INCS -c "$DAP/fuzz/fuzz.cpp" -o "$D/fuzz_harness.o"
  # shellcheck disable=SC2086
  bg "$D" $CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$D/lsan_off.o"
  join "$D"
done
# shellcheck disable=SC2086
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$SA/standalone_main.o"

# 2) fuzzer + standalone reproducer
FZ_OBJS=""; SA_OBJS=""
for f in $LIB_SRCS; do FZ_OBJS="$FZ_OBJS $FZ/$f.o"; SA_OBJS="$SA_OBJS $SA/$f.o"; done
# shellcheck disable=SC2086
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$FZ/fuzz_harness.o" $FZ_OBJS "$FZ/lsan_off.o" \
     -lpthread -o "$SRC/cppdap-fuzzer"
# shellcheck disable=SC2086
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS "$SA/fuzz_harness.o" $SA_OBJS "$SA/lsan_off.o" "$SA/standalone_main.o" \
     -lpthread -o "$SRC/cppdap-fuzzer-standalone"

# 3) cppdap's own unit tests, NORMAL flags (no sanitizers), against system googletest/googlemock.
TB="$SRC/build-tests"
rm -rf "$TB"; mkdir -p "$TB"
TESTS="any chan content_stream dap json_serializer network optional rwmutex session socket traits typeinfo variant"
TOBJS=""
for f in $LIB_SRCS; do
  # shellcheck disable=SC2086
  bg "$TB" $CXX -O1 $COVERAGE_FLAGS $INCS -c "$DAP/src/$f.cpp" -o "$TB/$f.o"
  TOBJS="$TOBJS $TB/$f.o"
done
for t in $TESTS; do
  # shellcheck disable=SC2086
  bg "$TB" $CXX -O1 $COVERAGE_FLAGS $INCS -c "$DAP/src/${t}_test.cpp" -o "$TB/${t}_test.o"
  TOBJS="$TOBJS $TB/${t}_test.o"
done
join "$TB"
# shellcheck disable=SC2086
$CXX $COVERAGE_FLAGS $TOBJS -lgmock_main -lgmock -lgtest -lpthread -o "$TB/cppdap-unittests"
