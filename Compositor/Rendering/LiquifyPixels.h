#ifndef LiquifyPixels_h
#define LiquifyPixels_h
#include <stdint.h>
typedef struct { float dx, dy, frozen; } LiquifyNode;
// Grid offsets are in original layer pixels; image buffers are premultiplied RGBA8, top-left rows.
void liquify_dab(LiquifyNode *nodes, const LiquifyNode *before, int gw, int gh, float step,
                 int width, int height, float cx, float cy, float mx, float my, float radius,
                 float hardness, float amount, int tool, int fixed_edges);
void liquify_render(const uint8_t *source, int width, int height, int stride,
                    const LiquifyNode *nodes, int gw, int gh, float step,
                    const uint8_t *coverage, int coverage_stride, int keep_alpha,
                    uint8_t *out, int ow, int oh, int out_stride, int first_row, int end_row);
void liquify_overlay(const LiquifyNode *nodes, int gw, int gh, float step,
                     int width, int height, uint8_t *out, int ow, int oh, int stride);
#endif
