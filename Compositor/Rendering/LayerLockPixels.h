#include <stdint.h>
void layer_preserve_alpha(uint8_t *edited, const uint8_t *original, long width, long height, long edited_stride, long original_stride);
int layer_alpha_equal(const uint8_t *a, const uint8_t *b, long width, long height, long a_stride, long b_stride);
