// Fuzz RawTherapee's non-raw image loader: rtengine::StdImageSource::load() (rtengine/
// stdimagesource.cc -> imageio.cc loadJPEG/loadTIFF/loadPNG + FramesData metadata), then
// getImage() which runs Image8/Image16/Imagefloat::getStdImage() on the decoded image.
// StdImageSource picks the decoder from the file EXTENSION, so the first input byte selects the
// extension (.jpg/.tif/.png) and the rest is the file.
#include <cstddef>
#include <cstdint>
#include "rt_fuzz_common.h"
#include "rtengine/stdimagesource.h"
#include "rtengine/imagefloat.h"
#include "rtengine/procparams.h"
#include "rtengine/rtengine.h"

extern "C" int LLVMFuzzerInitialize(int*, char***) {
  rt_fuzz_settings(/*enableLibRaw=*/true);
  return 0;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
  if (size < 1) return -1;
  static const char* const kExt[] = {".jpg", ".tif", ".png"};
  RtTempFile f(data + 1, size - 1, kExt[data[0] % 3]);
  if (!f.ok()) return 0;
  rtengine::StdImageSource src;
  if (src.load(f.path()) != 0) return 0;
  int w = 0, h = 0;
  src.getFullSize(w, h, 0);
  // Our own extra output buffer below (3 floats/pixel); the decoder's buffer is already allocated.
  if (w <= 0 || h <= 0 || (uint64_t)w * (uint64_t)h > (16u << 20)) return 0;
  rtengine::Imagefloat out(w, h);
  PreviewProps pp(0, 0, w, h, 1);
  rtengine::procparams::ToneCurveParams tc;
  rtengine::procparams::RAWParams raw;
  src.getImage(src.getWB(), 0, &out, pp, tc, raw);
  return 0;
}
