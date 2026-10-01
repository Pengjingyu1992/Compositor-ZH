#include "MosaicPixels.h"

/* Average premultiplied RGBA together, so translucent edges keep their color. */
void mosaic_pixels(uint8_t *pixels, size_t width, size_t height, size_t stride, size_t block) {
    if (!pixels || block < 2 || !width || !height) return;
    for (size_t top = 0; top < height; top += block) {
        const size_t bottom = top + block < height ? top + block : height;
        for (size_t left = 0; left < width; left += block) {
            const size_t right = left + block < width ? left + block : width;
            uint64_t sums[4] = {0, 0, 0, 0};
            const size_t count = (bottom - top) * (right - left);
            for (size_t y = top; y < bottom; ++y) {
                const uint8_t *row = pixels + y * stride;
                for (size_t x = left; x < right; ++x)
                    for (size_t c = 0; c < 4; ++c) sums[c] += row[x * 4 + c];
            }
            uint8_t average[4];
            for (size_t c = 0; c < 4; ++c) average[c] = (uint8_t)((sums[c] + count / 2) / count);
            for (size_t y = top; y < bottom; ++y) {
                uint8_t *row = pixels + y * stride;
                for (size_t x = left; x < right; ++x)
                    for (size_t c = 0; c < 4; ++c) row[x * 4 + c] = average[c];
            }
        }
    }
}
