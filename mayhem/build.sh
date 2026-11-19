#!/usr/bin/env bash
# mayhem/build.sh — build RawTherapee's vendored LibRaw (external/libraw) with the fuzz flags and the
# libraw_fuzzer harness, plus a normal-flags LibRaw + its own sample tools for mayhem/test.sh; then
# RawTherapee's own engine (rtengine, upstream CMake) with the fuzz flags and the rt_* harnesses.
# Out-of-tree object dirs live under build-mayhem/ (gitignored by upstream's `build*` pattern).
set -euo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
LR="$SRC/external/libraw"
OUT="$SRC/build-mayhem"
mkdir -p "$OUT"

# The library's object list, exactly as LibRaw's own Makefile.dist builds lib/libraw.a.
mapfile -t SRCS < <(
  awk '/^LIB_OBJECTS=/{f=1} f{print} f&&!/\\$/{exit}' "$LR/Makefile.dist" \
    | tr ' \\' '\n\n' | sed -n 's|^object/\(.*\)\.o$|\1|p' \
    | while read -r o; do
        sed -n "s|^object/$o\.o: *\(src/[^ ]*\.cpp\).*|\1|p" "$LR/Makefile.dist" | head -n1
      done)
[ "${#SRCS[@]}" -gt 40 ] || { echo "could not derive LibRaw sources from Makefile.dist" >&2; exit 1; }

# build_lib <dir> <cxxflags...>: compile LibRaw (single-threaded libraw.a flavour) into <dir>/libraw.a
build_lib() {
  local dir="$1"; shift
  mkdir -p "$dir/obj"
  printf '%s\n' "${SRCS[@]}" | xargs -P "$MAYHEM_JOBS" -I{} sh -c '
      s="$1"; shift; d="$1"; shift
      o="$d/obj/$(echo "$s" | tr / _).o"
      exec "$CXX" "$@" -c "'"$LR"'/$s" -o "$o"' _ {} "$dir" \
      -I"$LR" -w -DUSE_ZLIB -DLIBRAW_NOTHREADS "$@"
  rm -f "$dir/libraw.a"
  ar crs "$dir/libraw.a" "$dir"/obj/*.o
}

# 1) Fuzz build: LibRaw itself instrumented with the sanitizers + DWARF 3.
build_lib "$OUT/fuzz" -O1 $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link
"$CXX" $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$OUT/lsan_off.o"
"$CC" $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$OUT/standalone_main.o"
"$CXX" $SANITIZER_FLAGS $DEBUG_FLAGS -I"$LR" -c "$SRC/mayhem/harnesses/libraw_fuzzer.cc" -o "$OUT/libraw_fuzzer.o"

# 2) Harness: libFuzzer binary + standalone run-once reproducer.
"$CXX" $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$OUT/libraw_fuzzer.o" "$OUT/lsan_off.o" \
  "$OUT/fuzz/libraw.a" -lz -lm -o "$SRC/libraw_fuzzer"
"$CXX" $SANITIZER_FLAGS $DEBUG_FLAGS "$OUT/standalone_main.o" "$OUT/libraw_fuzzer.o" "$OUT/lsan_off.o" \
  "$OUT/fuzz/libraw.a" -lz -lm -o "$SRC/libraw_fuzzer-standalone"

# 3) Test build with LibRaw's NORMAL flags (Makefile.dist: -O3 -w -DUSE_ZLIB): the library plus its
#    own sample tools raw-identify and dcraw_emu, which mayhem/test.sh runs.
build_lib "$OUT/test" -O2 $COVERAGE_FLAGS
for t in raw-identify dcraw_emu; do
  "$CXX" -O2 $COVERAGE_FLAGS -I"$LR" -w -DLIBRAW_NOTHREADS "$LR/samples/$t.cpp" "$OUT/test/libraw.a" \
    -lz -lm -o "$OUT/test/$t"
done

# 4) rtengine: upstream's own CMake build of the `rtengine` library target, sanitized + SanCov.
#    OPTION_OMP=OFF (deterministic, single-threaded), no JPEG XL / libcanberra (optional deps).
#    fmt comes from the pre-fetched source (Dockerfile), downloads off.
#    -fno-sanitize=enum: rtengine/dcp.cc stores the file's first two bytes into an enum
#    (`order_ = ByteOrder(bo)`) and UBSan's enum check fires on every non-TIFF input before any
#    parsing happens; every other ASan/UBSan check stays on and halting.
: "${FMT_SRC:=/opt/toolchains/deps/fmt-12.0.0/src}"
RT="$OUT/rt"
RTFLAGS="-O1 $SANITIZER_FLAGS -fno-sanitize=enum $DEBUG_FLAGS -fsanitize=fuzzer-no-link"
cmake -S "$SRC" -B "$RT" -DCMAKE_BUILD_TYPE=None -DOPTION_OMP=OFF -DUSE_LIBCANBERRA=OFF -DWITH_JXL=OFF \
  -DBUILD_BUNDLE=OFF -DCMAKE_INSTALL_PREFIX="$OUT/rt-install" \
  -DFETCHCONTENT_SOURCE_DIR_FMT="$FMT_SRC" -DFETCHCONTENT_FULLY_DISCONNECTED=ON \
  -DCMAKE_C_FLAGS="$RTFLAGS" -DCMAKE_CXX_FLAGS="$RTFLAGS"
cmake --build "$RT" --target rtengine -j"$MAYHEM_JOBS"

# rtengine calls into a few rtgui translation units (App -> Options, ProcParams -> ParamsEdited,
# EditDataProvider, langMgr, getExtension); RawTherapee links them into its executables the same way.
RTPKGS="cairomm-1.0 exiv2 expat fftw3f glibmm-2.4 giomm-2.4 gtkmm-3.0 libiptcdata lcms2 lensfun libpng libtiff-4 zlib librsvg-2.0"
read -r -a RTCF <<<"$(pkg-config --cflags $RTPKGS)"
read -r -a RTLIBS <<<"$(pkg-config --libs $RTPKGS)"
RTINC=(-I"$SRC" -I"$SRC/rtengine" -I"$SRC/rtgui" -I"$RT" -I"$RT/rtengine" -I"$RT/rtgui" -I"$SRC/mayhem/harnesses")
mkdir -p "$RT/gui"
printf '%s\n' options paramsedited editcallbacks multilangmgr pathutils \
  | xargs -P "$MAYHEM_JOBS" -I{} "$CXX" -std=c++17 $RTFLAGS "${RTCF[@]}" "${RTINC[@]}" -w \
      -c "$SRC/rtgui/{}.cc" -o "$RT/gui/{}.o"
RTARCH=(-Wl,--start-group "$RT"/gui/*.o "$RT/rtengine/librtengine.a" "$RT/external/libraw/lib/.libs/libraw_r.a"
        "$RT/external/libcjson.a" "$RT/external/libjpeg_ijg.a" "$RT/external/libklt.a"
        "$RT/_deps/fmt-build/libfmt.a" -Wl,--end-group "${RTLIBS[@]}" -ljpeg -lz -lm -lpthread)
for t in rt_dcraw_fuzzer rt_stdimage_fuzzer rt_procparams_fuzzer rt_dcp_fuzzer; do
  "$CXX" -std=c++17 $SANITIZER_FLAGS -fno-sanitize=enum $DEBUG_FLAGS -O1 "${RTCF[@]}" "${RTINC[@]}" \
    -c "$SRC/mayhem/harnesses/$t.cc" -o "$RT/$t.o"
  "$CXX" $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$RT/$t.o" "$OUT/lsan_off.o" "${RTARCH[@]}" \
    -o "$SRC/$t"
  "$CXX" $SANITIZER_FLAGS $DEBUG_FLAGS "$OUT/standalone_main.o" "$RT/$t.o" "$OUT/lsan_off.o" "${RTARCH[@]}" \
    -o "$SRC/$t-standalone"
done
# rt_lcp_fuzzer is a FILE-INPUT program (its own main(), Mayhemfile `@@`, one process per input):
# LCPProfile's constructor (rtengine/lcp.cc) throws on invalid XML without fclose()ing the file, so a
# persistent libFuzzer process leaks one fd per rejected input until every later g_fopen() fails.
# It is its own run-once reproducer, so it has no -standalone twin.
"$CXX" -std=c++17 $SANITIZER_FLAGS -fno-sanitize=enum $DEBUG_FLAGS -O1 "${RTCF[@]}" "${RTINC[@]}" \
  -c "$SRC/mayhem/harnesses/rt_lcp_fuzzer.cc" -o "$RT/rt_lcp_fuzzer.o"
"$CXX" $SANITIZER_FLAGS $DEBUG_FLAGS "$RT/rt_lcp_fuzzer.o" "$OUT/lsan_off.o" "${RTARCH[@]}" \
  -o "$SRC/rt_lcp_fuzzer"
rm -f "$SRC/rt_lcp_fuzzer-standalone"
echo "build.sh: done"
