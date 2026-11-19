// Fuzz RawTherapee's own raw decoder: rtengine::RawImage over the legacy DCraw class
// (rtengine/dcraw.cc, rtengine/rawimage.cc) with settings->enableLibRaw = false, i.e. RawTherapee's
// "LibRaw disabled" preference. Same call sequence as RawImageSource::load(): identify-only
// loadRaw(false), then loadRaw(true) to decode the sensor data, then compress_image().
// DCraw::identify() rejects every file under 100000 bytes (rtengine/dcraw.cc, `/*RT*/ if (fsize<100000)`),
// and Mayhem's libFuzzer runs with -max_len=4096, which cuts every seed and mutant below that. So a
// shorter input is zero-extended to 100000 bytes on disk (its bytes unchanged, at the start of the
// file): the headers identify() parses are fuzzed, and the tail reads as zeros, as in a raw file with
// a zero-filled sensor area. Inputs of 100000 bytes or more are written as they are.
#include <cstddef>
#include <cstdint>
#include "rt_fuzz_common.h"
#include "rtengine/rawimage.h"

namespace {
// raw_width/raw_height are protected DCraw members; RawImage only exposes the width getter.
struct RawProbe : rtengine::RawImage {
  using rtengine::RawImage::RawImage;
  uint64_t rawW() const { return raw_width; }
  uint64_t rawH() const { return raw_height; }
};
}  // namespace

extern "C" int LLVMFuzzerInitialize(int*, char***) {
  rt_fuzz_settings(/*enableLibRaw=*/false);
  return 0;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
  if (size == 0) return -1;  // gfopen()/identify() reject an empty file
  RtTempFile f(data, size, ".raw", /*min_size=*/100000);
  if (!f.ok()) return 0;
  RawProbe ri(f.path());
  if (ri.loadRaw(false, 0, false) != 0) return 0;
  // Memory cap, the one RawTherapee applies on its LibRaw path in the same function
  // (RawImage::loadRaw: libraw open_buffer -> LIBRAW_TOO_BIG, libraw_rawdata_params.max_raw_memory_mb).
  // The legacy path has no cap of its own, so a 16-byte header can ask for a 65535x65535 sensor and
  // the decode allocates raw (u16) + image (4 x u16) + float_raw_image (up to 3 x f32) buffers.
  const uint64_t rw = ri.rawW(), rh = ri.rawH();
  const uint64_t w = (uint64_t)ri.get_width(), h = (uint64_t)ri.get_height();
  const uint64_t bytes = (rh + 7) * rw * 2 + rh * rw * 12 + w * h * 8;
  if (bytes > 512ull * 1024 * 1024) return 0;
  if (ri.loadRaw(true, 0, true) != 0) return 0;
  float** c = ri.compress_image(0);
  (void)c;
  return 0;
}
