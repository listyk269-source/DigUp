#pragma once
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
// Decode the full JPEG composition at thumbnail resolution into caller-owned RGB.
int digup_jpeg_thumbnail(const uint16_t *path, unsigned limit, uint8_t *rgb,
                         unsigned *width, unsigned *height);
int digup_expand_half(const void *source, float *destination, size_t count);
#ifdef __cplusplus
}
#endif
