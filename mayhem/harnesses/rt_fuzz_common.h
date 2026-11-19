// Shared helpers for the rtengine harnesses: rtengine's loaders take a file NAME (they gfopen /
// g_fopen / TIFFOpen / fopen it, and pick the decoder by extension), so each input is written to a
// fresh mkstemps() file under $TMPDIR and removed after the call.
#pragma once
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <unistd.h>
#include "rtengine/settings.h"

namespace rtengine { extern const Settings* settings; }

// rtengine reads the process-global Settings (verbose, enableLibRaw); RawTherapee sets it once at
// startup via rtengine::init(). Here it is set once in LLVMFuzzerInitialize and never written
// again, so no state carries across inputs.
inline void rt_fuzz_settings(bool enableLibRaw) {
  rtengine::Settings* s = rtengine::Settings::create();
  s->verbose = false;
  s->enableLibRaw = enableLibRaw;
  rtengine::settings = s;
}

class RtTempFile {
 public:
  // min_size > size zero-extends the file (ftruncate) to min_size bytes; the input bytes are
  // unchanged and stay at the start of the file.
  RtTempFile(const uint8_t* data, size_t size, const char* suffix, size_t min_size = 0) {
    const char* dir = getenv("TMPDIR");
    path_ = std::string(dir && *dir ? dir : "/tmp") + "/rtfuzz-XXXXXX" + suffix;
    int fd = mkstemps(&path_[0], (int)std::string(suffix).size());
    if (fd < 0) { path_.clear(); return; }
    size_t off = 0;
    while (off < size) {
      ssize_t n = write(fd, data + off, size - off);
      if (n <= 0) break;
      off += (size_t)n;
    }
    ok_ = off == size;
    if (ok_ && min_size > size && ftruncate(fd, (off_t)min_size) != 0) ok_ = false;
    close(fd);
  }
  ~RtTempFile() { if (!path_.empty()) unlink(path_.c_str()); }
  bool ok() const { return ok_; }
  const std::string& path() const { return path_; }
 private:
  std::string path_;
  bool ok_ = false;
};
