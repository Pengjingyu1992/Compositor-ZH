#include "PosterPixels.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

static double clamp01(double n) { return fmax(0, fmin(1, n)); }
static double circle_area(double r) {
    double area = 3.141592653589793 * r * r;
    if (r > .5) area -= 4 * (r * r * acos(.5 / r) - .5 * sqrt(r * r - .25));
    return clamp01(area);
}

// Sample the whole rotated screen cell. Transparent samples carry no color weight.
static double screen_tone(const uint8_t *source, int width, int height, int stride,
                          double cx, double cy, double cs, double sn, double cell, int channel) {
    double darkness = 0, alpha = 0;
    for (int j = 0; j < 4; j++) for (int i = 0; i < 4; i++) {
        double u = ((i + .5) / 4 - .5) * cell, v = ((j + .5) / 4 - .5) * cell;
        int x = (int)floor(cx + u * cs - v * sn), y = (int)floor(cy + u * sn + v * cs);
        x = x < 0 ? 0 : x >= width ? width - 1 : x;
        y = y < 0 ? 0 : y >= height ? height - 1 : y;
        const uint8_t *p = source + y * stride + x * 4;
        double value = channel < 0 ? .2126 * p[0] + .7152 * p[1] + .0722 * p[2] : p[channel];
        darkness += p[3] - value; alpha += p[3];
    }
    return alpha > 0 ? clamp01(darkness / alpha) : 0;
}

int poster_halftone_screen(uint8_t *pixels, const uint8_t *source, int width, int height, int stride,
                           double maximum_radius, const double *angles, int shape, double strength, int channels) {
    if (width <= 0 || height <= 0 || !isfinite(maximum_radius) || maximum_radius <= 0
        || (channels != 1 && channels != 3)) return 0;
    size_t count = (size_t)width * height;
    if (count > SIZE_MAX / sizeof(uint16_t)) return 0;
    uint16_t *coverage = calloc(count, sizeof(uint16_t));
    if (!coverage) return 0;
    double radii[256], cell = maximum_radius * 1.4142135623730951;
    for (int n = 0; n < 256; n++) {
        double lo = 0, hi = .707106781186548;
        for (int k = 0; k < 20; k++) { double mid = (lo + hi) / 2; if (circle_area(mid) < n / 255.0) lo = mid; else hi = mid; }
        radii[n] = (lo + hi) * .5 * cell;
    }
    for (int channel = 0; channel < channels; channel++) {
        memset(coverage, 0, count * sizeof(uint16_t));
        double a = angles[channels == 1 ? 3 : channel] * .0174532925199433, cs = cos(a), sn = sin(a);
        double min_u = INFINITY, max_u = -INFINITY, min_v = INFINITY, max_v = -INFINITY;
        for (int k = 0; k < 4; k++) {
            double x = k & 1 ? width : 0, y = k & 2 ? height : 0;
            double u = (x * cs + y * sn) / cell, v = (-x * sn + y * cs) / cell;
            min_u = fmin(min_u, u); max_u = fmax(max_u, u); min_v = fmin(min_v, v); max_v = fmax(max_v, v);
        }
        for (int j = (int)floor(min_v) - 1; j <= (int)ceil(max_v) + 1; j++) {
            for (int i = (int)floor(min_u) - 1; i <= (int)ceil(max_u) + 1; i++) {
                double cx = ((i + .5) * cs - (j + .5) * sn) * cell;
                double cy = ((i + .5) * sn + (j + .5) * cs) * cell;
                double tone = screen_tone(source, width, height, stride, cx, cy, cs, sn, cell, channels == 1 ? -1 : channel);
                if (tone <= 0) continue;
                double limit = shape == 1 ? sqrt(tone) * cell / 2 : shape == 2 ? tone * cell / 2 : radii[(int)round(tone * 255)];
                double half_u = shape == 2 ? cell / 2 : limit;
                double reach = shape == 0 ? limit : half_u * fabs(cs) + limit * fabs(sn);
                double reach_y = shape == 0 ? limit : half_u * fabs(sn) + limit * fabs(cs);
                int x0 = (int)fmax(0, floor(cx - reach - 1)), x1 = (int)fmin(width - 1, ceil(cx + reach + 1));
                int y0 = (int)fmax(0, floor(cy - reach_y - 1)), y1 = (int)fmin(height - 1, ceil(cy + reach_y + 1));
                for (int y = y0; y <= y1; y++) for (int x = x0; x <= x1; x++) {
                    uint16_t *bits = coverage + (size_t)y * width + x;
                    if (*bits == UINT16_MAX) continue;
                    double dx = x + .5 - cx, dy = y + .5 - cy;
                    double u = dx * cs + dy * sn, v = -dx * sn + dy * cs;
                    if (shape == 0) {
                        double d2 = dx * dx + dy * dy;
                        if (limit >= .531 && d2 <= (limit - .531) * (limit - .531)) { *bits = UINT16_MAX; continue; }
                        if (d2 > (limit + .531) * (limit + .531)) continue;
                    } else {
                        if (fabs(u) <= half_u - .531 && fabs(v) <= limit - .531) { *bits = UINT16_MAX; continue; }
                    }
                    // Union sample masks from every intersecting dot. Never clip a circle to its screen cell.
                    for (int sy = 0; sy < 4; sy++) for (int sx = 0; sx < 4; sx++) {
                        double px = dx + (sx + .5) / 4 - .5, py = dy + (sy + .5) / 4 - .5;
                        double pu = px * cs + py * sn, pv = -px * sn + py * cs;
                        int inside = shape == 0 ? px * px + py * py <= limit * limit
                            : fabs(pu) <= half_u && fabs(pv) <= limit;
                        if (inside) *bits |= (uint16_t)(1u << (sy * 4 + sx));
                    }
                }
            }
        }
        for (int y = 0; y < height; y++) for (int x = 0; x < width; x++) {
            uint8_t *out = pixels + y * stride + x * 4; const uint8_t *old = source + y * stride + x * 4;
            if (!old[3]) continue;
            double printed = (1 - __builtin_popcount((unsigned)coverage[(size_t)y * width + x]) / 16.0) * old[3];
            for (int c = channels == 1 ? 0 : channel; c < (channels == 1 ? 3 : channel + 1); c++)
                out[c] = (uint8_t)round(fmax(0, fmin(old[3], old[c] * (1 - strength) + printed * strength)));
        }
    }
    free(coverage);
    return 1;
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
