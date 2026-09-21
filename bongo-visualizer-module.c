/* bongo-visualizer-module.c --- software-shader music visualizer for Bongo

Copyright (C) 2026  Free Software Foundation, Inc.

This file is not part of GNU Emacs.

This module draws the whole visualizer in C, in the spirit of the
Sonic Pi scope and spectrum displays:

  * a real FFT (Hann-windowed) of the PCM window, mapped to log-spaced
    columns, with attack/release smoothing and falling peak caps;
  * a "software shader": every frame accumulates an HDR float buffer
    additively, runs a separable box-blur bloom pass, then tone-maps to
    ARGB32 with a scope graticule, vignette and scanlines;
  * a bright pink oscilloscope trace with a glowing bloom;
  * direct writes into the canvas pixel buffer through the Emacs 31+
    Module Canvas API (`env->canvas_data'), followed by `canvas-refresh'.

Because the pixel buffer is touched directly, no per-frame Lisp vector
is allocated or copied.

Build:  make           (produces bongo-visualizer-module.dylib)
Load:   (module-load "/path/to/bongo-visualizer-module.dylib")
Call:   (bongo-vis-render CANVAS SAMPLES WIDTH HEIGHT TIME STYLE)
        SAMPLES is a vector of floats in [-1, 1]; STYLE is 0 (scope and
        spectrum), 1 (scope only) or 2 (spectrum only).
*/

#include <emacs-module.h>

#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

int plugin_is_GPL_compatible;

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

/* ------------------------------------------------------------------ */
/* Persistent scratch state (one visualizer, one canvas).              */

static int W = 0, H = 0;          /* canvas dimensions                    */
static int N = 0;                 /* current FFT size (power of two)      */
static double *levels = NULL;     /* smoothed level per column            */
static double *peaks = NULL;      /* falling peak per column              */
static double *fre = NULL;        /* FFT real part                        */
static double *fim = NULL;        /* FFT imaginary part                   */
static double *hann = NULL;       /* Hann window                          */
static double *mag = NULL;        /* magnitude spectrum                   */
static float *acc = NULL;         /* HDR accumulation buffer (RGB)        */
static float *bloom = NULL;       /* bloom scratch                        */
static float *tmp = NULL;         /* blur scratch                         */

static void
free_state (void)
{
  free (levels); free (peaks);
  free (fre); free (fim); free (hann); free (mag);
  free (acc); free (bloom); free (tmp);
  levels = peaks = fre = fim = hann = mag = NULL;
  acc = bloom = tmp = NULL;
  W = H = N = 0;
}

static bool
ensure_fft (int n)
{
  if (n < 8)
    return false;
  if (n != N)
    {
      free (fre); free (fim); free (hann); free (mag);
      fre = calloc ((size_t) n, sizeof (double));
      fim = calloc ((size_t) n, sizeof (double));
      hann = calloc ((size_t) n, sizeof (double));
      mag = calloc ((size_t) n / 2 + 1, sizeof (double));
      N = n;
      if (!fre || !fim || !hann || !mag)
        return false;
      for (int i = 0; i < n; i++)
        hann[i] = 0.5 - 0.5 * cos (2.0 * M_PI * i / (double) (n - 1));
    }
  return true;
}

static bool
ensure_state (int w, int h, int n)
{
  if (w <= 0 || h <= 0 || n < 8)
    return false;

  if (w != W || h != H)
    {
      free (levels); free (peaks);
      free (acc); free (bloom); free (tmp);
      levels = calloc ((size_t) w, sizeof (double));
      peaks = calloc ((size_t) w, sizeof (double));
      acc = calloc ((size_t) w * h * 3, sizeof (float));
      bloom = calloc ((size_t) w * h * 3, sizeof (float));
      tmp = calloc ((size_t) w * h * 3, sizeof (float));
      W = w; H = h;
      if (!levels || !peaks || !acc || !bloom || !tmp)
        return false;
    }

  return ensure_fft (n);
}

/* ------------------------------------------------------------------ */
/* Small helpers.                                                      */

static inline int
clampi (int x, int lo, int hi)
{
  return x < lo ? lo : (x > hi ? hi : x);
}

static inline double
clampd (double x, double lo, double hi)
{
  return x < lo ? lo : (x > hi ? hi : x);
}

static inline void
add_pixel (float *buf, int x, int y, double r, double g, double b, double a)
{
  if (x < 0 || x >= W || y < 0 || y >= H || a <= 0.0)
    return;
  size_t i = ((size_t) y * W + x) * 3;
  buf[i    ] += (float) (r * a);
  buf[i + 1] += (float) (g * a);
  buf[i + 2] += (float) (b * a);
}

static void
hsv_to_rgb (double h, double s, double v, double *r, double *g, double *b)
{
  h -= floor (h);
  double f = h * 6.0;
  int i = (int) f;
  double q = v * (1.0 - s * (f - i));
  double p = v * (1.0 - s);
  double t = v * (1.0 - s * (1.0 - (f - i)));
  switch (i % 6)
    {
    case 0: *r = v; *g = t; *b = p; break;
    case 1: *r = q; *g = v; *b = p; break;
    case 2: *r = p; *g = v; *b = t; break;
    case 3: *r = p; *g = q; *b = v; break;
    case 4: *r = t; *g = p; *b = v; break;
    default: *r = v; *g = p; *b = q; break;
    }
}

static void
draw_line (float *buf, int x0, int y0, int x1, int y1,
           double r, double g, double b, double a)
{
  int dx = abs (x1 - x0), sx = x0 < x1 ? 1 : -1;
  int dy = -abs (y1 - y0), sy = y0 < y1 ? 1 : -1;
  int err = dx + dy;
  for (;;)
    {
      add_pixel (buf, x0, y0, r, g, b, a);
      if (x0 == x1 && y0 == y1)
        break;
      int e2 = 2 * err;
      if (e2 >= dy) { err += dy; x0 += sx; }
      if (e2 <= dx) { err += dx; y0 += sy; }
    }
}

/* ------------------------------------------------------------------ */
/* FFT (iterative radix-2, in place).                                  */

static void
fft (double *re, double *im, int n)
{
  for (int i = 1, j = 0; i < n; i++)
    {
      int bit = n >> 1;
      for (; j & bit; bit >>= 1)
        j ^= bit;
      j ^= bit;
      if (i < j)
        {
          double t = re[i]; re[i] = re[j]; re[j] = t;
          t = im[i]; im[i] = im[j]; im[j] = t;
        }
    }

  for (int len = 2; len <= n; len <<= 1)
    {
      double ang = -2.0 * M_PI / len;
      double wr = cos (ang), wi = sin (ang);
      for (int i = 0; i < n; i += len)
        {
          double cr = 1.0, ci = 0.0;
          for (int k = 0; k < len / 2; k++)
            {
              double ur = re[i + k], ui = im[i + k];
              double vr = re[i + k + len / 2] * cr - im[i + k + len / 2] * ci;
              double vi = re[i + k + len / 2] * ci + im[i + k + len / 2] * cr;
              re[i + k] = ur + vr; im[i + k] = ui + vi;
              re[i + k + len / 2] = ur - vr;
              im[i + k + len / 2] = ui - vi;
              double nr = cr * wr - ci * wi;
              ci = cr * wi + ci * wr;
              cr = nr;
            }
        }
    }
}

/* ------------------------------------------------------------------ */
/* Separable box blur over an interleaved 3-channel float buffer.      */

static void
box_blur_3 (float *buf, float *scratch, int w, int h, int r)
{
  if (r < 1)
    return;

  /* Horizontal: buf -> scratch.  */
  for (int c = 0; c < 3; c++)
    for (int y = 0; y < h; y++)
      {
        const float *src = buf + (size_t) y * w * 3 + c;
        float *dst = scratch + (size_t) y * w * 3 + c;
        double sum = 0.0;
        int count = 0;
        for (int k = -r; k <= r; k++)
          {
            sum += src[clampi (k, 0, w - 1) * 3];
            count++;
          }
        for (int x = 0; x < w; x++)
          {
            dst[x * 3] = (float) (sum / count);
            sum += src[clampi (x + r + 1, 0, w - 1) * 3]
                 - src[clampi (x - r, 0, w - 1) * 3];
          }
      }

  /* Vertical: scratch -> buf.  */
  for (int c = 0; c < 3; c++)
    for (int x = 0; x < w; x++)
      {
        double sum = 0.0;
        int count = 0;
        for (int k = -r; k <= r; k++)
          {
            sum += scratch[((size_t) clampi (k, 0, h - 1) * w + x) * 3 + c];
            count++;
          }
        for (int y = 0; y < h; y++)
          {
            buf[((size_t) y * w + x) * 3 + c] = (float) (sum / count);
            sum += scratch[((size_t) clampi (y + r + 1, 0, h - 1) * w + x) * 3 + c]
                 - scratch[((size_t) clampi (y - r, 0, h - 1) * w + x) * 3 + c];
          }
      }
}

/* ------------------------------------------------------------------ */
/* The frame.                                                          */

static void
render (uint32_t *pixels, const double *samples, int nsamp,
        double rate, double time, int style, bool transparent)
{
  const int w = W, h = H;
  const size_t npx = (size_t) w * h;

  /* Pick the largest power of two <= nsamp (clamped).  */
  int n = 32;
  while (n * 2 <= nsamp && n < 4096)
    n <<= 1;
  /* The glue ensured a matching FFT of size N; bail out if not.  */
  if (n > N || w > 8192)
    return;

  double fmin = 40.0, fmax = rate * 0.5;
  bool silent = (nsamp < 32);
  int offset = silent ? 0 : nsamp - n;

  /* STYLE selects what to draw, following the Sonic Pi visualisers:
       0  scope and spectrum together (default)
       1  scope only: a large oscilloscope
       2  spectrum only: the analyser wings                       */
  bool draw_spectrum = (style != 1);
  bool draw_scope = (style != 2);

  /* ---- Spectrum: window, FFT, magnitude, log-spaced columns.  ---- */
  double target[8192];
  if (!silent && draw_spectrum)
    {
      for (int i = 0; i < n; i++)
        {
          fre[i] = samples[offset + i] * hann[i];
          fim[i] = 0.0;
        }
      fft (fre, fim, n);
      for (int k = 0; k <= n / 2; k++)
        mag[k] = sqrt (fre[k] * fre[k] + fim[k] * fim[k]);

      for (int x = 0; x < w; x++)
        {
          double frac = (w > 1) ? (double) x / (w - 1) : 0.0;
          double freq = fmin * pow (fmax / fmin, frac);
          double binf = freq * n / rate;
          int b0 = clampi ((int) binf, 1, n / 2 - 1);
          int b1 = clampi (b0 + 1, 1, n / 2 - 1);
          double t = binf - floor (binf);
          double m = mag[b0] * (1.0 - t) + mag[b1] * t;
          /* Hann coherent gain 0.5, so a full-scale sine peaks at n/4.  */
          double amp = m / (n * 0.25);
          double db = 20.0 * log10 (amp + 1e-9);
          target[x] = clampd ((db + 58.0) / 58.0, 0.0, 1.0);
        }
    }

  for (int x = 0; x < w; x++)
    {
      double tgt = (silent || !draw_spectrum) ? 0.0 : target[x];
      double cur = levels[x];
      double a = (tgt > cur) ? 0.55 : 0.14;   /* fast attack, slow release */
      cur += (tgt - cur) * a;
      levels[x] = cur;
      if (cur >= peaks[x])
        peaks[x] = cur;
      else
        {
          peaks[x] -= 0.013;
          if (peaks[x] < cur)
            peaks[x] = cur;
        }
    }

  /* ---- HDR accumulation buffer.  ---- */
  memset (acc, 0, npx * 3 * sizeof (float));

  int mid = h / 2;
  double maxh = mid - 3.0;
  if (maxh < 3.0)
    maxh = 3.0;

  /* ---- Mirrored spectrum "wings", Sonic Pi style.
     The colour runs through the rainbow from low (red) to high (violet)
     frequency, and the envelope is brightest along its edge.  ---- */
  if (draw_spectrum)
    {
      for (int x = 0; x < w; x++)
        {
          double frac = (w > 1) ? (double) x / (w - 1) : 0.0;
          double r, g, b;
          /* A pink phosphor: hot magenta at the low end fading to a
             pale rose at the high end, with a slow shimmer.  */
          hsv_to_rgb (0.94 - 0.09 * frac + 0.02 * sin (time * 0.25),
                      0.85 - 0.30 * frac, 1.0, &r, &g, &b);

          double v = levels[x];
          double hh = v * maxh;
          int ih = (int) hh;
          for (int dy = -ih; dy <= ih; dy++)
            {
              int y = mid + dy;
              if (y < 1 || y >= h - 1)
                continue;
              double u = (hh > 0.5) ? fabs ((double) dy) / hh : 0.0;
              double inten = 0.07 + 0.40 * u * u;   /* brighter at the edge */
              add_pixel (acc, x, y, r, g, b, inten);
            }
          /* Bright envelope line on both edges.  */
          if (ih > 0)
            {
              add_pixel (acc, x, mid + ih, 1.8, 1.15, 1.55, 0.85);
              add_pixel (acc, x, mid - ih, 1.8, 1.15, 1.55, 0.85);
            }
          /* Falling peak caps, only when clearly above the bar.  */
          double pv = peaks[x];
          if (pv > 0.04 && (pv - v) * maxh >= 2.0)
            {
              int py = mid + (int) (pv * maxh);
              int py2 = mid - (int) (pv * maxh);
              add_pixel (acc, x, py, 2.3, 1.5, 2.0, 0.95);
              add_pixel (acc, x, py2, 2.3, 1.5, 2.0, 0.95);
            }
        }
    }

  /* ---- Sonic Pi neon oscilloscope trace along the spine.  ---- */
  if (draw_scope && !silent && n > 1)
    {
      double amp = (style == 1) ? (h * 0.5 - 2.0) : (maxh * 0.85);
      int prev_x = -1, prev_y = -1;
      for (int x = 0; x < w; x++)
        {
          int si = (int) ((double) x / (w - 1) * (n - 1));
          double s = samples[offset + si];
          int y = mid - (int) (s * amp);
          y = clampi (y, 1, h - 2);
          if (prev_x >= 0)
            draw_line (acc, prev_x, prev_y, x, y, 1.0, 0.28, 0.62, 0.9);
          prev_x = x;
          prev_y = y;
        }
      /* Dim zero axis, as on a scope graticule.  */
      for (int x = 0; x < w; x++)
        add_pixel (acc, x, mid, 0.32, 0.08, 0.18, 0.45);
    }

  /* ---- Bloom: blur a copy and add it back.  ---- */
  memcpy (bloom, acc, npx * 3 * sizeof (float));
  int radius = h / 12;
  if (radius < 2) radius = 2;
  box_blur_3 (bloom, tmp, w, h, radius);
  box_blur_3 (bloom, tmp, w, h, radius);

  /* ---- Tone-map to ARGB32.  ---- */
  double style_glow = (style == 1) ? 0.55 : 0.85;
  int grid_x = w / 8;
  int grid_y = h / 4;
  if (grid_x < 1) grid_x = 1;
  if (grid_y < 1) grid_y = 1;
  for (int y = 0; y < h; y++)
    {
      double dy = (h > 1) ? (2.0 * y / (h - 1) - 1.0) : 0.0;
      double bg = 0.008 + 0.018 * (1.0 - (double) y / (h - 1));
      double scan = (y & 1) ? 0.93 : 1.0;
      double gline = (y % grid_y == 0) ? 0.012 : 0.0;
      for (int x = 0; x < w; x++)
        {
          size_t i = ((size_t) y * w + x) * 3;
          double r, g, b;
          int A;

          if (transparent)
            {
              /* Leave the background transparent so whatever is behind
                 the canvas (the mode line) shows through.  The alpha is
                 the brightness of the HDR signal, so antialiased edges
                 and the bloom fade out smoothly.  */
              r = acc[i]     + bloom[i]     * style_glow;
              g = acc[i + 1] + bloom[i + 1] * style_glow;
              b = acc[i + 2] + bloom[i + 2] * style_glow;
              double lum = r > g ? r : g;
              if (b > lum)
                lum = b;
              A = (int) (clampd (lum, 0.0, 1.0) * 255.0 + 0.5);
              /* The NS canvas turns alpha 0 back into opaque, so 1 is
                 the most transparent value that actually works.  */
              if (A < 1)
                A = 1;
            }
          else
            {
              double dx = (w > 1) ? (2.0 * x / (w - 1) - 1.0) : 0.0;
              double vig = 1.0 - 0.5 * (dx * dx + dy * dy);
              if (vig < 0.0) vig = 0.0;
              double grid = gline + ((x % grid_x == 0) ? 0.012 : 0.0);
              r = bg * 0.75 + grid * 0.60 + acc[i]     + bloom[i]     * style_glow;
              g = bg * 0.50 + grid * 0.40 + acc[i + 1] + bloom[i + 1] * style_glow;
              b = bg * 0.80 + grid * 0.55 + acc[i + 2] + bloom[i + 2] * style_glow;
              r *= vig * scan; g *= vig * scan; b *= vig * scan;
              A = 0xFF;
            }

          /* soft highlight roll-off */
          r = r / (1.0 + 0.35 * r);
          g = g / (1.0 + 0.35 * g);
          b = b / (1.0 + 0.35 * b);
          int R = (int) (clampd (r, 0.0, 1.0) * 255.0 + 0.5);
          int G = (int) (clampd (g, 0.0, 1.0) * 255.0 + 0.5);
          int B = (int) (clampd (b, 0.0, 1.0) * 255.0 + 0.5);
          pixels[(size_t) y * w + x] =
            ((uint32_t) A << 24) | ((uint32_t) R << 16)
            | ((uint32_t) G << 8) | (uint32_t) B;
        }
    }
}

/* ------------------------------------------------------------------ */
/* Emacs module glue.                                                  */

static emacs_value
Fbongo_vis_render (emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                   void *data)
{
  (void) data;

  emacs_value canvas = args[0];
  emacs_value samples = args[1];
  int w = (int) env->extract_integer (env, args[2]);
  int h = (int) env->extract_integer (env, args[3]);
  double rate = env->extract_float (env, args[4]);
  double time = env->extract_float (env, args[5]);
  int style = (nargs > 6) ? (int) env->extract_integer (env, args[6]) : 0;
  bool transparent = (nargs > 7) && env->is_not_nil (env, args[7]);

  if (env->non_local_exit_check (env) != emacs_funcall_exit_return)
    return env->intern (env, "nil");

  uint32_t *pixels = env->canvas_data (env, canvas);
  if (!pixels)
    return env->intern (env, "nil");

  ptrdiff_t nsamp = env->vec_size (env, samples);
  if (env->non_local_exit_check (env) != emacs_funcall_exit_return)
    return env->intern (env, "nil");

  enum { MAX_SAMPLES = 8192 };
  double local[MAX_SAMPLES];
  if (nsamp > MAX_SAMPLES)
    nsamp = MAX_SAMPLES;
  double *s = local;
  for (ptrdiff_t i = 0; i < nsamp; i++)
    s[i] = env->extract_float (env, env->vec_get (env, samples, i));
  if (env->non_local_exit_check (env) != emacs_funcall_exit_return)
    return env->intern (env, "nil");

  /* Set up the per-canvas and per-FFT scratch before rendering.  */
  int n = 32;
  while (n * 2 <= nsamp && n < 4096)
    n <<= 1;
  if (w <= 0 || h <= 0 || !ensure_state (w, h, n))
    return env->intern (env, "nil");

  render (pixels, s, (int) nsamp, rate, time, style, transparent);

  emacs_value refresh = env->intern (env, "canvas-refresh");
  emacs_value refresh_args[2] = { canvas, env->intern (env, "nil") };
  env->funcall (env, refresh, 2, refresh_args);

  return env->intern (env, "nil");
}

/* Debug helper: return pixel (X, Y) of CANVAS as an ARGB fixnum.
   WIDTH is the canvas width in pixels.  */
static emacs_value
Fbongo_vis_pixel (emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                  void *data)
{
  (void) nargs; (void) data;
  uint32_t *pixels = env->canvas_data (env, args[0]);
  int x = (int) env->extract_integer (env, args[1]);
  int y = (int) env->extract_integer (env, args[2]);
  int width = (int) env->extract_integer (env, args[3]);
  if (!pixels || x < 0 || y < 0 || width <= 0)
    return env->make_integer (env, 0);
  return env->make_integer (env, (intmax_t) pixels[(size_t) y * width + x]);
}

static double
spectrum_level (double *mag, int n, double rate, double frac)
{
  double fmin = 40.0, fmax = rate * 0.5;
  double freq = fmin * pow (fmax / fmin, frac);
  double binf = freq * n / rate;
  int b0 = clampi ((int) binf, 1, n / 2 - 1);
  int b1 = clampi (b0 + 1, 1, n / 2 - 1);
  double t = binf - floor (binf);
  double m = mag[b0] * (1.0 - t) + mag[b1] * t;
  double amp = m / (n * 0.25);
  double db = 20.0 * log10 (amp + 1e-9);
  return clampd ((db + 58.0) / 58.0, 0.0, 1.0);
}

/* Copy the floats of the Lisp vector VEC into a fresh array.  */
static double *
extract_samples (emacs_env *env, emacs_value vec, ptrdiff_t *count)
{
  ptrdiff_t n = env->vec_size (env, vec);
  if (env->non_local_exit_check (env) != emacs_funcall_exit_return)
    return NULL;
  double *out = malloc ((size_t) (n ? n : 1) * sizeof (double));
  if (!out)
    return NULL;
  for (ptrdiff_t i = 0; i < n; i++)
    out[i] = env->extract_float (env, env->vec_get (env, vec, i));
  if (env->non_local_exit_check (env) != emacs_funcall_exit_return)
    {
      free (out);
      return NULL;
    }
  *count = n;
  return out;
}

/* (bongo-vis-spectrum SAMPLES RATE BINS) -> vector of BINS floats in
   [0, 1], log spaced from 40 Hz to Nyquist.  Stateless; smooth in Lisp.  */
static emacs_value
Fbongo_vis_spectrum (emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                     void *data)
{
  (void) nargs; (void) data;
  double rate = env->extract_float (env, args[1]);
  int bins = (int) env->extract_integer (env, args[2]);
  if (env->non_local_exit_check (env) != emacs_funcall_exit_return)
    return env->intern (env, "nil");
  if (bins < 1) bins = 1;
  if (bins > 4096) bins = 4096;

  ptrdiff_t nsamp = 0;
  double *s = extract_samples (env, args[0], &nsamp);
  if (!s)
    return env->intern (env, "nil");

  int n = 32;
  while (n * 2 <= nsamp && n < 4096)
    n <<= 1;
  bool ok = (nsamp >= 32) && ensure_fft (n);
  if (ok)
    {
      ptrdiff_t base = nsamp - n;
      for (int i = 0; i < n; i++)
        {
          fre[i] = s[base + i] * hann[i];
          fim[i] = 0.0;
        }
      fft (fre, fim, n);
      for (int k = 0; k <= n / 2; k++)
        mag[k] = sqrt (fre[k] * fre[k] + fim[k] * fim[k]);
    }
  free (s);

  emacs_value *vals = malloc ((size_t) bins * sizeof *vals);
  if (!vals)
    return env->intern (env, "nil");
  for (int i = 0; i < bins; i++)
    {
      double level = 0.0;
      if (ok)
        {
          double frac = (bins > 1) ? (double) i / (bins - 1) : 0.0;
          level = spectrum_level (mag, n, rate, frac);
        }
      vals[i] = env->make_float (env, level);
    }
  emacs_value result = env->funcall (env, env->intern (env, "vector"),
                                     bins, vals);
  free (vals);
  return result;
}

/* (bongo-vis-waveform SAMPLES BINS) -> vector of BINS floats in [-1, 1],
   block averages of SAMPLES.  */
static emacs_value
Fbongo_vis_waveform (emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                     void *data)
{
  (void) nargs; (void) data;
  int bins = (int) env->extract_integer (env, args[1]);
  if (env->non_local_exit_check (env) != emacs_funcall_exit_return)
    return env->intern (env, "nil");
  if (bins < 1) bins = 1;
  if (bins > 4096) bins = 4096;

  ptrdiff_t nsamp = 0;
  double *s = extract_samples (env, args[0], &nsamp);
  if (!s)
    return env->intern (env, "nil");

  emacs_value *vals = malloc ((size_t) bins * sizeof *vals);
  if (!vals)
    {
      free (s);
      return env->intern (env, "nil");
    }
  for (int i = 0; i < bins; i++)
    {
      double level = 0.0;
      if (nsamp > 0)
        {
          long a = (long) ((intmax_t) i * nsamp / bins);
          long b = (long) ((intmax_t) (i + 1) * nsamp / bins);
          if (b <= a) b = a + 1;
          /* Decimate rather than average: averaging a periodic
             waveform over a whole block would cancel it out.  */
          long pick = a + (b - a) / 2;
          if (pick >= nsamp) pick = nsamp - 1;
          level = s[pick];
        }
      vals[i] = env->make_float (env, level);
    }
  free (s);
  emacs_value result = env->funcall (env, env->intern (env, "vector"),
                                     bins, vals);
  free (vals);
  return result;
}

static emacs_value
Fbongo_vis_reset (emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                  void *data)
{
  (void) nargs; (void) args; (void) data;
  free_state ();
  return env->intern (env, "nil");
}

static void
define (emacs_env *env, const char *name, ptrdiff_t min_arity,
        ptrdiff_t max_arity,
        emacs_value (*fn) (emacs_env *, ptrdiff_t, emacs_value *, void *),
        const char *doc)
{
  emacs_value f = env->make_function (env, min_arity, max_arity, fn, doc, NULL);
  emacs_value sym = env->intern (env, name);
  emacs_value args[2] = { sym, f };
  env->funcall (env, env->intern (env, "defalias"), 2, args);
}

int
emacs_module_init (struct emacs_runtime *ert)
{
  emacs_env *env = ert->get_environment (ert);

  define (env, "bongo-vis-render", 6, 8, Fbongo_vis_render,
          "Render one visualizer frame into CANVAS.\n"
          "SAMPLES is a vector of floats in [-1, 1],\n"
          "WIDTH and HEIGHT are the canvas dimensions, RATE is the\n"
          "sample rate, TIME is the frame timestamp, and optional\n"
          "STYLE selects a look.  When TRANSPARENT is non-nil the\n"
          "background is left transparent.");
  define (env, "bongo-vis-pixel", 4, 4, Fbongo_vis_pixel,
          "Return the ARGB pixel at X, Y in CANVAS of WIDTH (debug helper).\n"
          "\n(fn CANVAS X Y WIDTH)");
  define (env, "bongo-vis-spectrum", 3, 3, Fbongo_vis_spectrum,
          "Return a vector of BINS log spaced spectrum levels in [0, 1].\n"
          "SAMPLES is a vector of floats in [-1, 1] and RATE is the\n"
          "sample rate.\n\n(fn SAMPLES RATE BINS)");
  define (env, "bongo-vis-waveform", 2, 2, Fbongo_vis_waveform,
          "Return a vector of BINS block averaged samples in [-1, 1].\n"
          "\n(fn SAMPLES BINS)");
  define (env, "bongo-vis-reset", 0, 0, Fbongo_vis_reset,
          "Forget all visualizer state (levels, peaks, buffers).");

  emacs_value provide_args[1] = { env->intern (env, "bongo-visualizer-module") };
  env->funcall (env, env->intern (env, "provide"), 1, provide_args);

  return 0;
}
