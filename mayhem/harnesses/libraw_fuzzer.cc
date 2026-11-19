// Fuzz RawTherapee's vendored LibRaw (external/libraw) through its public API, the way
// RawTherapee's rtengine/rawimage.cc drives it: open a raw from memory, unpack the sensor data,
// develop it (dcraw_process) and extract the embedded thumbnail.
// Reaches every raw identify/metadata parser and decoder (TIFF/DNG/CR2/CR3/NEF/RAF/ORF/RW2/X3F, ...).
#include <cstddef>
#include <cstdint>
#include "libraw/libraw.h"

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  if (size == 0) return -1;  // open_buffer() rejects an empty buffer (LIBRAW_IO_ERROR)
  LibRaw lr;
  // LibRaw's own allocation cap (libraw_rawdata_params.max_raw_memory_mb); keeps decoded rasters
  // inside libFuzzer's RSS limit. Fresh object per input, so no state is shared across inputs.
  lr.imgdata.rawparams.max_raw_memory_mb = 512;
  lr.imgdata.params.use_camera_wb = 1;
  if (lr.open_buffer(data, size) != LIBRAW_SUCCESS) return 0;
  if (lr.unpack() == LIBRAW_SUCCESS) {
    if (lr.dcraw_process() == LIBRAW_SUCCESS) {
      int err = 0;
      libraw_processed_image_t *img = lr.dcraw_make_mem_image(&err);
      if (img) LibRaw::dcraw_clear_mem(img);
    }
  }
  if (lr.unpack_thumb() == LIBRAW_SUCCESS) {
    int err = 0;
    libraw_processed_image_t *th = lr.dcraw_make_mem_thumb(&err);
    if (th) LibRaw::dcraw_clear_mem(th);
  }
  lr.recycle();
  return 0;
}
