// Fuzz RawTherapee's processing-profile reader: rtengine::procparams::ProcParams::load(path)
// (rtengine/procparams.cc), the Glib::KeyFile-based .pp3 parser RawTherapee runs on every sidecar
// next to an opened image and on every profile a user loads or pastes. (ProcParams::save() is not
// called: with pedited == nullptr, its default, it dereferences the null pointer for every input,
// rtengine/procparams.cc saveFramingParams(): `pedited->framing`, so UBSan would stop on every run.)
#include <cstddef>
#include <cstdint>
#include "rt_fuzz_common.h"
#include "rtengine/procparams.h"

extern "C" int LLVMFuzzerInitialize(int*, char***) {
  rt_fuzz_settings(/*enableLibRaw=*/true);
  return 0;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
  RtTempFile f(data, size, ".pp3");
  if (!f.ok()) return 0;
  rtengine::procparams::ProcParams pp;
  (void)pp.load(f.path());
  return 0;
}
