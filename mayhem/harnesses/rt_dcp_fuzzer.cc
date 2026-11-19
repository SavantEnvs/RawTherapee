// Fuzz RawTherapee's DNG Camera Profile reader: rtengine::DCPProfile(path) (rtengine/dcp.cc), the
// TIFF-structured .dcp parser RawTherapee runs on every profile in the camera-profiles directories
// and on user-selected .dcp files. Then exercises the parsed matrices/LUTs the way the colour
// pipeline queries them.
#include <cstddef>
#include <cstdint>
#include "rt_fuzz_common.h"
#include "rtengine/dcp.h"

extern "C" int LLVMFuzzerInitialize(int*, char***) {
  rt_fuzz_settings(/*enableLibRaw=*/true);
  return 0;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
  RtTempFile f(data, size, ".dcp");
  if (!f.ok()) return 0;
  rtengine::DCPProfile p(f.path());
  if (p.isValid()) {
    (void)p.getIlluminants();
    (void)p.getHasToneCurve();
    (void)p.getHasLookTable();
    (void)p.getHasHueSatMap();
    (void)p.getHasBaselineExposureOffset();
  }
  return 0;
}
