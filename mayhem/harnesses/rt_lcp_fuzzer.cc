// Fuzz RawTherapee's Adobe Lens Correction Profile reader: rtengine::LCPProfile(path)
// (rtengine/lcp.cc), the expat-driven XML parser RawTherapee runs on user-selected .lcp files.
// A FILE-INPUT target (Mayhemfile `@@`, one process per input), not a persistent libFuzzer one: on
// invalid XML the constructor throws without fclose()ing the file, so a persistent process leaks one
// fd per rejected input until g_fopen() fails and every later input parses nothing.
#include <cstdio>
#include <exception>
#include "rt_fuzz_common.h"
#include "rtengine/lcp.h"

int main(int argc, char** argv) {
  if (argc < 2) {
    std::fprintf(stderr, "usage: %s <file.lcp>\n", argv[0]);
    return 2;
  }
  rt_fuzz_settings(/*enableLibRaw=*/true);
  // The constructor throws std::runtime_error on malformed XML / unreadable files; its only caller,
  // LCPStore::getProfile() (rtengine/lcp.cc), catches every exception and treats it as "no profile".
  try {
    rtengine::LCPProfile p(argv[1]);
    // Interpolate the parsed perspective-model frames, as LCPMapper's constructor does.
    using M = rtengine::LCPCorrectionMode;
    for (M mode : {M::VIGNETTE, M::DISTORTION, M::CA}) {
      rtengine::LCPModelCommon a, b, c;
      p.calcParams(mode, 50.f, 10.f, 8.f, &a, &b, &c);
    }
  } catch (const std::exception&) {
  }
  return 0;
}
