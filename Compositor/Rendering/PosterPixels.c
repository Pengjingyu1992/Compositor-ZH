#include "PosterPixels.h"
#include <math.h>

static double clamp01(double n) { return fmax(0, fmin(1, n)); }
static double circle_area(double r) {
    double area = 3.141592653589793 * r * r;
    if (r > .5) area -= 4 * (r * r * acos(.5 / r) - .5 * sqrt(r * r - .25));
    return clamp01(area);
}
static double ink(const uint8_t *p, int channel) {
    if (p[3] == 0) return 0;
    double r = clamp01((double)p[0] / p[3]), g = clamp01((double)p[1] / p[3]), b = clamp01((double)p[2] / p[3]);
    double black = 1 - fmax(r, fmax(g, b));
    if (channel == 3) return black;
    double color = channel == 0 ? r : channel == 1 ? g : b;
    return black >= .99999 ? 0 : clamp01((1 - color - black) / (1 - black));
}
void poster_halftone(uint8_t *pixels, const uint8_t *source, int width, int height, int stride,
                     double cell, const double *angles, int shape, double strength) {
    double radius[256], cs[4], sn[4];
    for (int n = 0; n < 256; n++) {
        double lo = 0, hi = .707106781186548;
        for (int k = 0; k < 16; k++) { double mid = (lo + hi) / 2; if (circle_area(mid) < n / 255.0) lo = mid; else hi = mid; }
        radius[n] = (lo + hi) / 2;
    }
    for (int c = 0; c < 4; c++) { cs[c] = cos(angles[c] * .0174532925199433); sn[c] = sin(angles[c] * .0174532925199433); }
    for (int y = 0; y < height; y++) for (int x = 0; x < width; x++) {
        uint8_t *out = pixels + y * stride + x * 4; const uint8_t *old = source + y * stride + x * 4;
        if (!old[3]) continue;
        double dots[4];
        for (int c = 0; c < 4; c++) {
            double u = ((x + .5) * cs[c] + (y + .5) * sn[c]) / cell;
            double v = (-(x + .5) * sn[c] + (y + .5) * cs[c]) / cell;
            double cu = floor(u) + .5, cv = floor(v) + .5;
            int sx = (int)floor((cu * cs[c] - cv * sn[c]) * cell), sy = (int)floor((cu * sn[c] + cv * cs[c]) * cell);
            sx = sx < 0 ? 0 : sx >= width ? width - 1 : sx; sy = sy < 0 ? 0 : sy >= height ? height - 1 : sy;
            double tone = ink(source + sy * stride + sx * 4, c), dx = fabs(u - cu), dy = fabs(v - cv);
            double distance = shape == 1 ? fmax(dx, dy) : shape == 2 ? dy : hypot(dx, dy);
            double limit = shape == 1 ? sqrt(tone) / 2 : shape == 2 ? tone / 2 : radius[(int)round(tone * 255)];
            dots[c] = tone <= 0 ? 0 : tone >= 1 ? 1 : clamp01((limit - distance) * cell + .5);
        }
        for (int c = 0; c < 3; c++) {
            double printed = (1 - dots[c]) * (1 - dots[3]) * old[3];
            out[c] = (uint8_t)round(fmax(0, fmin(old[3], old[c] * (1 - strength) + printed * strength)));
        }
    }
}
