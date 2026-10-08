#ifndef COMPOSITOR_POSTER_PIXELS_H
#define COMPOSITOR_POSTER_PIXELS_H
#include <stdint.h>
void poster_halftone(uint8_t *pixels, const uint8_t *source, int width, int height, int stride,
                     double cell, const double *angles, int shape, double strength);
#endif
