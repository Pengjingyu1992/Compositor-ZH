#include "LayerLockPixels.h"

void layer_preserve_alpha(uint8_t *edited, const uint8_t *original, long width, long height, long edited_stride, long original_stride) {
    for (long y = 0; y < height; y++) {
        uint8_t *out = edited + y * edited_stride;
        const uint8_t *base = original + y * original_stride;
        for (long x = 0; x < width; x++, out += 4, base += 4) {
            unsigned alpha = out[3], kept = base[3];
            for (int c = 0; c < 3; c++) {
                unsigned value = alpha ? (out[c] * kept + alpha / 2) / alpha : base[c];
                out[c] = (uint8_t)(value > kept ? kept : value);
            }
            out[3] = (uint8_t)kept;
        }
    }
}

int layer_alpha_equal(const uint8_t *a, const uint8_t *b, long width, long height, long a_stride, long b_stride) {
    for (long y = 0; y < height; y++)
        for (long x = 0; x < width; x++)
            if (a[y * a_stride + x * 4 + 3] != b[y * b_stride + x * 4 + 3]) return 0;
    return 1;
}
