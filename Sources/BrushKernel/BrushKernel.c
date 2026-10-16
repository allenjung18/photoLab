#include "BrushKernel.h"
#include <math.h>

/* BrushRaster.dabWeight: d in units of the radius. */
static inline double dab_weight(double d, double feather, double flow) {
    flow = flow < 0 ? 0 : (flow > 1 ? 1 : flow);
    if (d >= 1) return 0;
    double f = feather < 0 ? 0 : (feather > 1 ? 1 : feather);
    double inner = 1 - f;
    if (d <= inner) return flow;
    double t = (1 - d) / (1 - inner);
    return flow * t * t * (3 - 2 * t);
}

/* One dab's weight at pixel (x, y)'s centre, or a negative number outside it. */
static inline float dab_at(int x, int y, double cx, double cy, double r, double r2, double feather, double flow) {
    double fx = (double)x + 0.5 - cx, fy = (double)y + 0.5 - cy;
    double d2 = fx * fx + fy * fy;
    if (d2 >= r2) return -1;
    return (float)dab_weight(sqrt(d2) / r, feather, flow);
}

static inline float composed(float a, float c, int erase) {
    if (c == 0) return a;
    if (erase) return a * (1 - c);
    float s = a + c;
    return s < 1 ? s : 1;
}

static inline uint8_t quantize(float v) {
    float c = v < 0 ? 0 : (v > 1 ? 1 : v);
    return (uint8_t)roundf(c * 255);
}

void bk_clear(float *buffer, int width, int x0, int y0, int x1, int y1) {
    for (int y = y0; y <= y1; y++) {
        float *row = buffer + (long)y * width;
        for (int x = x0; x <= x1; x++) row[x] = 0;
    }
}

void bk_stamp(float *cover, int width, int x0, int y0, int x1, int y1,
              const double *cx, const double *cy, int count,
              double r, double feather, double flow) {
    double r2 = r * r;
    for (int i = 0; i < count; i++) {
        int dx0 = (int)floor(cx[i] - r), dx1 = (int)ceil(cx[i] + r);
        int dy0 = (int)floor(cy[i] - r), dy1 = (int)ceil(cy[i] + r);
        if (dx0 < x0) dx0 = x0;
        if (dx1 > x1) dx1 = x1;
        if (dy0 < y0) dy0 = y0;
        if (dy1 > y1) dy1 = y1;
        for (int y = dy0; y <= dy1; y++) {
            float *row = cover + (long)y * width;
            for (int x = dx0; x <= dx1; x++) {
                float a = dab_at(x, y, cx[i], cy[i], r, r2, feather, flow);
                if (a > row[x]) row[x] = a;
            }
        }
    }
}

void bk_compose(float *acc, const float *cover, int width, int x0, int y0, int x1, int y1, int erase) {
    for (int y = y0; y <= y1; y++) {
        long row = (long)y * width;
        for (int x = x0; x <= x1; x++) acc[row + x] = composed(acc[row + x], cover[row + x], erase);
    }
}

void bk_quantize(uint8_t *out, const float *acc, int count) {
    for (int i = 0; i < count; i++) out[i] = quantize(acc[i]);
}

void bk_quantize_live(uint8_t *out, const float *acc, const float *cover, int width,
                      int x0, int y0, int x1, int y1, int erase,
                      int has_tail, double tx, double ty, double r, double feather, double flow) {
    double r2 = r * r;
    for (int y = y0; y <= y1; y++) {
        long row = (long)y * width;
        for (int x = x0; x <= x1; x++) {
            float c = cover[row + x];
            if (has_tail) {
                float t = dab_at(x, y, tx, ty, r, r2, feather, flow);
                if (t > c) c = t;
            }
            out[row + x] = quantize(composed(acc[row + x], c, erase));
        }
    }
}
