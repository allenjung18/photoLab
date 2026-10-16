#ifndef BRUSH_KERNEL_H
#define BRUSH_KERNEL_H

#include <stdint.h>

/*
 * The brush raster's per-pixel loops (BrushRaster.swift states the rule).
 * In C so they run at optimised speed in a debug build too: the Swift loops
 * cost ~250 ns a pixel unoptimised, which no live stroke can afford.
 * Buffers are row-major, `width` wide, top-down; rects are inclusive pixel
 * bounds (x0, y0) ... (x1, y1), already clipped to the buffer.
 */

/* `buffer` set to 0 over the rect. */
void bk_clear(float *buffer, int width, int x0, int y0, int x1, int y1);

/* Max-merges `count` round dabs (centres cx[i], cy[i], radius r, in pixels)
 * into `cover` over the rect: each pixel keeps the largest dab weight at its
 * centre (flow inside r * (1 - feather), smoothstep to 0 at r). */
void bk_stamp(float *cover, int width, int x0, int y0, int x1, int y1,
              const double *cx, const double *cy, int count,
              double r, double feather, double flow);

/* `acc` takes `cover` over the rect: a paint adds, clipped at 1; an erase
 * multiplies by 1 - cover. */
void bk_compose(float *acc, const float *cover, int width, int x0, int y0, int x1, int y1, int erase);

/* `out` = acc quantised to 8 bits (255 = 1), for `count` pixels. */
void bk_quantize(uint8_t *out, const float *acc, int count);

/* `out` over the rect = acc composed (as bk_compose) with the max of `cover`
 * and, when has_tail, one more dab at (tx, ty), quantised; `acc` and
 * `cover` are not written. The live stroke's bytes: its walked dabs are in
 * `cover`, its moving last-point dab is the tail. */
void bk_quantize_live(uint8_t *out, const float *acc, const float *cover, int width,
                      int x0, int y0, int x1, int y1, int erase,
                      int has_tail, double tx, double ty, double r, double feather, double flow);

#endif
