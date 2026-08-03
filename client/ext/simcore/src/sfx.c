// The sound kit, synthesised. See sfx.h for what this is and why.
//
// The vocabulary is deliberately narrow and matches the art direction.
// Weapons are short and bright with a hard transient. Explosions are noise
// under a descending sine, which is what gives a blast a body rather than a
// hiss. The interface ticks. Nothing rings for longer than the thing that
// caused it is on screen.
//
// This file is written to compile as C++ as well as C, because Defold's build
// server hands .c files to clang++.

#include "sfx.h"

#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define RATE 22050

// math.h is allowed to leave M_PI out under a strict standard dialect, and
// which dialect Defold's build server picks is not this repository's to
// choose.
#define SFX_PI 3.14159265358979323846

static double dmin(double a, double b) { return a < b ? a : b; }

// --- the noise source ------------------------------------------------------
//
// Mersenne Twister, seeded the way CPython seeds it from a small integer, and
// drawing doubles the way CPython's random() draws them. That is a strange
// thing to want until you remember what it buys: this kit was originally a
// Python script, and matching its generator bit for bit is what let the port
// be checked against the files it replaced rather than judged by ear.
//
// It stays because a change to a sound should be a change somebody made. A
// different generator would have rewritten all fifteen at once.

typedef struct {
    uint32_t mt[624];
    int mti;
} rng;

static void rng_init_genrand(rng *r, uint32_t s) {
    r->mt[0] = s;
    for (r->mti = 1; r->mti < 624; r->mti++) {
        uint32_t p = r->mt[r->mti - 1];
        r->mt[r->mti] = (uint32_t)(1812433253u * (p ^ (p >> 30)) + (uint32_t)r->mti);
    }
}

// The key is always one word here, which collapses the reference version's
// walk over a key array: its `j` never leaves zero, so neither the key index
// nor the `+ j` term varies.
static void rng_seed(rng *r, uint32_t key) {
    int i = 1, k;
    rng_init_genrand(r, 19650218u);
    for (k = 624; k; k--) {
        uint32_t p = r->mt[i - 1];
        r->mt[i] = (uint32_t)((r->mt[i] ^ ((p ^ (p >> 30)) * 1664525u)) + key);
        i++;
        if (i >= 624) { r->mt[0] = r->mt[623]; i = 1; }
    }
    for (k = 623; k; k--) {
        uint32_t p = r->mt[i - 1];
        r->mt[i] = (uint32_t)((r->mt[i] ^ ((p ^ (p >> 30)) * 1566083941u)) - (uint32_t)i);
        i++;
        if (i >= 624) { r->mt[0] = r->mt[623]; i = 1; }
    }
    r->mt[0] = 0x80000000u;
}

static uint32_t rng_u32(rng *r) {
    static const uint32_t mag01[2] = {0u, 0x9908b0dfu};
    uint32_t y;
    if (r->mti >= 624) {
        int kk;
        for (kk = 0; kk < 624 - 397; kk++) {
            y = (r->mt[kk] & 0x80000000u) | (r->mt[kk + 1] & 0x7fffffffu);
            r->mt[kk] = r->mt[kk + 397] ^ (y >> 1) ^ mag01[y & 1u];
        }
        for (; kk < 623; kk++) {
            y = (r->mt[kk] & 0x80000000u) | (r->mt[kk + 1] & 0x7fffffffu);
            r->mt[kk] = r->mt[kk + (397 - 624)] ^ (y >> 1) ^ mag01[y & 1u];
        }
        y = (r->mt[623] & 0x80000000u) | (r->mt[0] & 0x7fffffffu);
        r->mt[623] = r->mt[396] ^ (y >> 1) ^ mag01[y & 1u];
        r->mti = 0;
    }
    y = r->mt[r->mti++];
    y ^= (y >> 11);
    y ^= (y << 7) & 0x9d2c5680u;
    y ^= (y << 15) & 0xefc60000u;
    y ^= (y >> 18);
    return y;
}

// Uniform on [-1, 1). The two draws are sequenced by hand because C does not
// promise an order for the operands of a single expression, and getting them
// backwards yields a perfectly good stream that is not this one.
static double rng_uniform(rng *r) {
    uint32_t a = rng_u32(r) >> 5;
    uint32_t b = rng_u32(r) >> 6;
    return -1.0 + 2.0 * ((a * 67108864.0 + b) * (1.0 / 9007199254740992.0));
}

// --- a buffer, and the handful of shaping tools these sounds need ----------

typedef struct {
    double *buf;
    int n;
    double dur;
} voice;

static int voice_init(voice *v, double dur) {
    v->n = (int)(dur * RATE);
    v->dur = dur;
    v->buf = (double *)calloc((size_t)(v->n > 0 ? v->n : 1), sizeof(double));
    return v->buf != NULL;
}

static void voice_free(voice *v) {
    free(v->buf);
    v->buf = NULL;
}

// Fast attack, exponential decay, silent at exactly `dur`.
static double env(double t, double dur, double curve) {
    const double attack = 0.004;
    double x;
    if (t < attack) return t / attack;
    x = (t - attack) / (dur - attack > 1e-6 ? dur - attack : 1e-6);
    if (x >= 1.0) return 0.0;
    return pow(1.0 - x, curve);
}

static double env3(double t, double dur) { return env(t, dur, 3.0); }

// A swept sine. Phase is integrated so the sweep has no clicks.
static void v_sine(voice *v, double f0, double f1, double gain, double curve) {
    double ph = 0.0;
    int i;
    for (i = 0; i < v->n; i++) {
        double t = (double)i / RATE;
        double x = pow(t / v->dur, curve);
        double f = f0 + (f1 - f0) * x;
        ph += 2.0 * SFX_PI * f / RATE;
        v->buf[i] += sin(ph) * gain * env3(t, v->dur);
    }
}

static void v_saw(voice *v, double f0, double f1, double gain, double curve) {
    double ph = 0.0;
    int i;
    for (i = 0; i < v->n; i++) {
        double t = (double)i / RATE;
        double f = f0 + (f1 - f0) * pow(t / v->dur, curve);
        ph = fmod(ph + f / RATE, 1.0);
        v->buf[i] += (2.0 * ph - 1.0) * gain * env3(t, v->dur);
    }
}

static void v_square(voice *v, double f0, double f1, double gain, double duty,
                     double curve) {
    double ph = 0.0;
    int i;
    for (i = 0; i < v->n; i++) {
        double t = (double)i / RATE;
        double f = f0 + (f1 - f0) * pow(t / v->dur, curve);
        ph = fmod(ph + f / RATE, 1.0);
        v->buf[i] += (ph < duty ? 1.0 : -1.0) * gain * env3(t, v->dur);
    }
}

// White noise through a one-pole lowpass whose corner can sweep.
//
// A sweep from bright to dark is what makes a burst read as an explosion
// rather than as static: the high end leaves first, exactly as air absorbs it.
static void v_noise(voice *v, double gain, double cutoff, double cutoff_end,
                    double curve, uint32_t seed) {
    rng r;
    double y = 0.0;
    int i;
    rng_seed(&r, seed);
    for (i = 0; i < v->n; i++) {
        double t = (double)i / RATE;
        double x = t / v->dur;
        double fc = cutoff + (cutoff_end - cutoff) * x;
        double a = 1.0 - exp(-2.0 * SFX_PI * (fc > 20.0 ? fc : 20.0) / RATE);
        y += a * (rng_uniform(&r) - y);
        v->buf[i] += y * gain * env(t, v->dur, curve);
    }
}

// --- looping ---------------------------------------------------------------
//
// A held sound is played end to end forever, so the last sample has to lead
// into the first one. Two rules do it: no envelope, and everything periodic in
// the buffer's own length.

// A sine snapped to a whole number of cycles in the buffer.
//
// Off by a fraction of a cycle and the wrap is a step, which is a click at
// exactly the loop rate, the most recognisable defect a looping sound has.
static void v_loop_sine(voice *v, double f, double gain) {
    double cycles = nearbyint(f * v->dur);
    int i;
    if (cycles < 1.0) cycles = 1.0;
    for (i = 0; i < v->n; i++)
        v->buf[i] += sin(2.0 * SFX_PI * cycles * i / v->n) * gain;
}

// Lowpassed noise that wraps. The filter is run twice around the same buffer
// and only the second lap is kept, so its state entering the loop is the state
// it left with. The noise itself is circular by construction, so nothing has
// to be crossfaded.
static void v_loop_noise(voice *v, double gain, double cutoff, uint32_t seed) {
    rng r;
    double *raw = (double *)malloc((size_t)v->n * sizeof(double));
    double a = 1.0 - exp(-2.0 * SFX_PI * (cutoff > 20.0 ? cutoff : 20.0) / RATE);
    double y = 0.0;
    int i;
    if (!raw) return;
    rng_seed(&r, seed);
    for (i = 0; i < v->n; i++) raw[i] = rng_uniform(&r);
    for (i = 0; i < v->n; i++) y += a * (raw[i] - y);    // settle the state
    for (i = 0; i < v->n; i++) {                         // the lap that is kept
        y += a * (raw[i] - y);
        v->buf[i] += y * gain;
    }
    free(raw);
}

static void v_highpass(voice *v, double fc) {
    double a = exp(-2.0 * SFX_PI * fc / RATE);
    double prev_x = 0.0, prev_y = 0.0;
    int i;
    for (i = 0; i < v->n; i++) {
        double x = v->buf[i];
        prev_y = a * (prev_y + x - prev_x);
        prev_x = x;
        v->buf[i] = prev_y;
    }
}

// Soft clipping. Gives a blast weight without letting it clip hard.
static void v_drive(voice *v, double k) {
    int i;
    for (i = 0; i < v->n; i++) v->buf[i] = tanh(v->buf[i] * k) / tanh(k);
}

static void v_fade_out(voice *v) {
    int m = (int)(0.008 * RATE);
    int i;
    if (m > v->n) m = v->n;
    for (i = 0; i < m; i++) v->buf[v->n - 1 - i] *= (double)i / m;
}

static void v_normalise(voice *v) {
    double hi = 1e-6;
    double k;
    int i;
    for (i = 0; i < v->n; i++) {
        double a = fabs(v->buf[i]);
        if (a > hi) hi = a;
    }
    k = 0.86 / hi;
    for (i = 0; i < v->n; i++) v->buf[i] *= k;
}

// --- the kit ---------------------------------------------------------------

// A bolt leaving the rail: bright, over before it registers.
static void k_gun(voice *v) {
    v_square(v, 1750, 460, 0.55, 0.32, 0.45);
    v_sine(v, 2400, 700, 0.30, 0.4);
    v_noise(v, 0.16, 7000, 900, 2.0, 11);
    v_drive(v, 1.6);
}

// Heavier and slower than a gun, so the ear knows which one fired.
static void k_bomb(voice *v) {
    v_saw(v, 280, 78, 0.5, 0.6);
    v_sine(v, 160, 46, 0.42, 0.7);
    v_noise(v, 0.22, 2600, 260, 2.0, 23);
    v_drive(v, 1.9);
}

// A bomb going off: noise for the air, a falling sine for the body.
static void k_blast(voice *v) {
    v_noise(v, 0.62, 5200, 190, 2.4, 37);
    v_sine(v, 190, 38, 0.55, 0.5);
    v_sine(v, 96, 30, 0.35, 0.6);
    v_drive(v, 2.1);
}

// A ship coming apart. The one event allowed a full second.
static void k_death(voice *v) {
    v_noise(v, 0.66, 4200, 120, 2.0, 53);
    v_sine(v, 240, 32, 0.5, 0.45);
    v_sine(v, 120, 24, 0.42, 0.55);
    v_saw(v, 90, 26, 0.22, 0.7);
    v_drive(v, 2.4);
}

// Something struck your hull. A crack, not a tone.
static void k_hit(voice *v) {
    v_noise(v, 0.7, 9000, 1400, 3.0, 67);
    v_sine(v, 620, 210, 0.3, 0.5);
    v_highpass(v, 300);
    v_drive(v, 1.5);
}

// A wall. Dull, brief, and quiet enough to hear forty times a minute.
static void k_bounce(voice *v) {
    v_sine(v, 340, 150, 0.5, 0.6);
    v_noise(v, 0.2, 2200, 500, 2.0, 71);
    v_drive(v, 1.3);
}

// Coming back: rising, clean, and unmistakably not a weapon.
static void k_spawn(voice *v) {
    v_sine(v, 220, 880, 0.42, 1.5);
    v_sine(v, 330, 1320, 0.22, 1.5);
    v_noise(v, 0.1, 900, 5200, 1.2, 83);
}

// A green picked up. Two intervals up, because that is what reward sounds
// like and arguing with it is not worth the novelty.
static void k_prize(voice *v) {
    voice a;
    int d = (int)(0.055 * RATE), i;
    v_sine(v, 880, 880, 0.34, 1.0);
    if (!voice_init(&a, v->dur)) return;
    v_sine(&a, 1320, 1320, 0.3, 1.0);
    for (i = d; i < v->n; i++) v->buf[i] += a.buf[i - d];
    voice_free(&a);
}

// A charge spent: a short downward chirp with a body to it, so it reads as
// something leaving your hands rather than a shot going out.
static void k_charge(voice *v) {
    v_sine(v, 700, 300, 0.34, 1.3);
    v_noise(v, 0.07, 400, 2600, 1.5, 41);
}

// A green that took something. The prize sound's intervals, downward and
// duller: the same event going the other way, which is what it is.
static void k_rust(voice *v) {
    voice a;
    int d = (int)(0.06 * RATE), i;
    v_sine(v, 660, 494, 0.3, 0.8);
    if (!voice_init(&a, v->dur)) return;
    v_sine(&a, 440, 330, 0.26, 0.8);
    for (i = d; i < v->n; i++) v->buf[i] += a.buf[i - d];
    voice_free(&a);
    v_noise(v, 0.05, 200, 1400, 1.4, 17);
}

// A flag changing hands: two tones, the second higher, quick.
static void k_flag(voice *v) {
    voice b;
    int d = (int)(0.08 * RATE), i;
    v_sine(v, 440, 460, 0.3, 1.0);
    if (!voice_init(&b, v->dur)) return;
    v_sine(&b, 660, 700, 0.3, 1.0);
    for (i = d; i < v->n; i++) v->buf[i] += b.buf[i - d];
    voice_free(&b);
}

// A held drive. Loops for as long as the pilot holds the key.
//
// Rocket, not engine: mostly filtered noise, with two low partials for a body
// so it does not read as tape hiss. Half a second is long enough that the ear
// cannot hear the repeat and short enough to be a small buffer.
static void k_thrust(voice *v) {
    v_loop_noise(v, 0.60, 520, 101);      // the rumble
    v_loop_noise(v, 0.16, 2600, 103);     // a little air over it
    v_loop_sine(v, 58, 0.26);
    v_loop_sine(v, 87, 0.13);
    v_loop_sine(v, 146, 0.06);
    v_drive(v, 1.25);
}

static void k_ui_move(voice *v) {
    v_square(v, 1200, 900, 0.4, 0.4, 1.0);
    v_noise(v, 0.14, 6000, 2000, 2.0, 97);
    v_highpass(v, 400);
}

static void k_ui_go(voice *v) {
    v_sine(v, 520, 1040, 0.42, 1.4);
    v_square(v, 260, 520, 0.16, 0.3, 1.4);
    v_drive(v, 1.4);
}

// --- the soundtrack --------------------------------------------------------
//
// One track, eight bars, playing under everything for as long as the game is
// open. It has to come round without a seam and it has to stay welcome after
// the fortieth pass, which are different problems: the first is arithmetic and
// the second is restraint. So there is no melody doing anything clever, and
// nothing in it arrives more often than the ear stops noticing.

#define BPM 100
#define BEAT (RATE * 60 / BPM)     // 13230 samples, exactly
#define BAR (BEAT * 4)
#define BARS 8

// Equal temperament from A4 = 440, with the pitch class given as a semitone
// index from C.
static double nf(int pc, int oct) {
    return 440.0 * pow(2.0, (12 + oct * 12 + pc - 69) / 12.0);
}

// A one-pole lowpass, run `poles` times. Every voice here goes through one:
// the genre is a filter sweep with a band behind it, and a raw saw is the
// sound of something that has not been recorded yet.
static void lowpass(double *buf, int n, double fc, int poles) {
    double a = 1.0 - exp(-2.0 * SFX_PI * fc / RATE);
    int p, i;
    for (p = 0; p < poles; p++) {
        double y = 0.0;
        for (i = 0; i < n; i++) {
            y += a * (buf[i] - y);
            buf[i] = y;
        }
    }
}

// A saw with an exponential decay. Two of them a few cents apart is the whole
// width of this mix, since it is mono and there is no chorus.
static double *note_saw(double f, double dur, int *n_out, double decay,
                        double cutoff, double detune) {
    int n = (int)(dur * RATE), i, vi;
    int nv = detune <= 0.0 ? 1 : 2;
    double freq[2];
    double *out = (double *)calloc((size_t)(n > 0 ? n : 1), sizeof(double));
    int at = (int)(0.004 * RATE);
    if (!out) return NULL;
    if (at < 1) at = 1;
    freq[0] = nv == 1 ? f : f * (1.0 - detune);
    freq[1] = f * (1.0 + detune);
    for (vi = 0; vi < nv; vi++) {
        double ph = 0.0;
        for (i = 0; i < n; i++) {
            ph = fmod(ph + freq[vi] / RATE, 1.0);
            out[i] += (2.0 * ph - 1.0) / nv;
        }
    }
    for (i = 0; i < n; i++) {
        double x = (double)i / n;
        out[i] *= i < at ? (double)i / at : exp(-decay * x);
    }
    lowpass(out, n, cutoff, 2);
    *n_out = n;
    return out;
}

// A pad: slow in, slow out, and detuned enough to beat gently. The rise and
// fall are the point, since an organ that arrives instantly is a stab.
static double *note_pad(double f, double dur, int *n_out) {
    int n = (int)(dur * RATE), i, vi;
    double freq[3];
    double *out = (double *)calloc((size_t)(n > 0 ? n : 1), sizeof(double));
    int rise = (int)(0.35 * RATE), fall = (int)(0.55 * RATE);
    if (!out) return NULL;
    freq[0] = f * 0.9965; freq[1] = f * 1.0035; freq[2] = f * 2.0;
    for (vi = 0; vi < 3; vi++) {
        double g = freq[vi] > f * 1.5 ? 0.35 : 1.0;
        double ph = 0.0;
        for (i = 0; i < n; i++) {
            ph = fmod(ph + freq[vi] / RATE, 1.0);
            out[i] += (2.0 * ph - 1.0) * g;
        }
    }
    for (i = 0; i < n; i++) {
        double a = 1.0;
        if (i < rise) a = (double)i / rise;
        if (i > n - fall) a *= (double)(n - i) / fall;
        out[i] *= a;
    }
    lowpass(out, n, 1400.0, 3);
    *n_out = n;
    return out;
}

// The one thing playing a tune. A sine with a fifth over it and a slow
// vibrato, quiet enough to be atmosphere rather than a part.
static double *note_lead(double f, double dur, int *n_out) {
    int n = (int)(dur * RATE), i;
    double *out = (double *)calloc((size_t)(n > 0 ? n : 1), sizeof(double));
    double ph = 0.0, ph5 = 0.0;
    if (!out) return NULL;
    for (i = 0; i < n; i++) {
        double t = (double)i / RATE;
        double vib = 1.0 + 0.004 * sin(2.0 * SFX_PI * 5.2 * t);
        double x, a;
        ph += 2.0 * SFX_PI * f * vib / RATE;
        ph5 += 2.0 * SFX_PI * f * 1.5 * vib / RATE;
        x = (double)i / n;
        a = dmin(1.0, i / (0.18 * RATE)) * dmin(1.0, (n - i) / (0.4 * RATE));
        out[i] = (sin(ph) + 0.3 * sin(ph5)) * a * (1.0 - 0.3 * x);
    }
    *n_out = n;
    return out;
}

// Four to the bar. A sine dropping fast onto a floor, with a click on top so
// it survives being played over a firefight.
static double *kick(rng *r, int *n_out) {
    int n = (int)(0.17 * RATE), click = (int)(0.005 * RATE), i;
    double *out = (double *)calloc((size_t)n, sizeof(double));
    double ph = 0.0;
    if (!out) return NULL;
    for (i = 0; i < n; i++) {
        double x = (double)i / n;
        ph += 2.0 * SFX_PI * (135.0 * exp(-7.0 * x) + 44.0) / RATE;
        out[i] = sin(ph) * exp(-6.0 * x);
    }
    for (i = 0; i < click; i++)
        out[i] += rng_uniform(r) * 0.35 * (1.0 - (double)i / click);
    *n_out = n;
    return out;
}

// Two and four, with the gate that dates this music exactly. A tail is allowed
// to bloom and is then cut off flat rather than allowed to fade, which is a
// mistake somebody made in 1982 and everybody kept.
static double *snare(rng *r, int *n_out) {
    const double gate = 0.19;
    int n = (int)(0.30 * RATE), i;
    double *body = (double *)malloc((size_t)n * sizeof(double));
    double *out = (double *)calloc((size_t)n, sizeof(double));
    double ph = 0.0, cut = gate * RATE;
    if (!body || !out) { free(body); free(out); return NULL; }
    for (i = 0; i < n; i++) body[i] = rng_uniform(r);
    lowpass(body, n, 5200.0, 1);
    for (i = 0; i < n; i++) {
        double x = (double)i / n;
        double tone, env_body, env_tail, g = 1.0;
        ph += 2.0 * SFX_PI * 195.0 / RATE;
        tone = sin(ph) * exp(-16.0 * x) * 0.45;
        env_body = exp(-22.0 * x);
        env_tail = exp(-3.2 * x) * 0.5;
        if (i > cut) {
            g = 1.0 - (i - cut) / (0.012 * RATE);
            if (g < 0.0) g = 0.0;
        }
        out[i] = (body[i] * (env_body + env_tail) + tone) * g;
    }
    free(body);
    *n_out = n;
    return out;
}

static double *hat(rng *r, int *n_out) {
    int n = (int)(0.045 * RATE), i;
    double *out = (double *)malloc((size_t)n * sizeof(double));
    double *lp = (double *)malloc((size_t)n * sizeof(double));
    if (!out || !lp) { free(out); free(lp); return NULL; }
    for (i = 0; i < n; i++) out[i] = rng_uniform(r);
    memcpy(lp, out, (size_t)n * sizeof(double));
    lowpass(lp, n, 2500.0, 1);
    for (i = 0; i < n; i++)
        out[i] = (out[i] - lp[i]) * exp(-38.0 * ((double)i / n));
    free(lp);
    *n_out = n;
    return out;
}

// A fixed number of bars, mixed into by sample offset, wrapping.
//
// Wrapping is the whole trick. A pad still ringing when the buffer ends comes
// back at the start rather than being chopped, so the loop point has nothing
// in it to hear, which is the difference between a loop and a repeat.
static void track_at(double *dst, int n, int pos, const double *src, int len,
                     double gain) {
    int i;
    if (!src) return;
    for (i = 0; i < len; i++) {
        int p = (pos + i) % n;
        if (p < 0) p += n;
        dst[p] += src[i] * gain;
    }
}

// One helper for the four calls that mix a freshly rendered note and drop it.
static void mix_free(double *dst, int n, int pos, double *src, int len,
                     double gain) {
    track_at(dst, n, pos, src, len, gain);
    free(src);
}

// The soundtrack: eight bars of synthwave that come round without a seam.
//
// Nothing here is sampled either. It is the genre's own furniture put up out
// of arithmetic, an eighth-note bass, a sixteenth arpeggio, a detuned pad and
// four on the floor under a gated snare, over i-VI-III-VII in A minor, which
// is the progression the whole style is built on and the reason every track in
// it sounds like every other.
//
// Two things make it loop rather than restart. Everything is mixed in through
// track_at, which wraps. And a hundred beats a minute at 22050 is 13230
// samples a beat exactly, so eight bars is a whole number of samples and the
// seam lands on the downbeat rather than a hair off it.
//
// It is most of the work on its own, nineteen seconds against a fifth of a
// second, and the obvious economy is to render it at a lower rate, since there
// is nothing in it above eight kilohertz except the hats. That does not work:
// the engine plays 22050 and 44100 and nothing else, and a buffer at any other
// rate is accepted without complaint and silent. Measured, not read.
static void k_music(voice *v) {
    // The root, the arpeggio cell it is played through, the pad voicing, and
    // the note the lead holds over it. Pitch classes are semitones from C.
    static const int ROOT[4][2] = {{9, 2}, {5, 2}, {0, 3}, {7, 2}};
    static const int CELL[4][4][2] = {
        {{9, 4}, {0, 5}, {4, 5}, {0, 5}},
        {{5, 4}, {9, 4}, {0, 5}, {9, 4}},
        {{4, 4}, {7, 4}, {0, 5}, {7, 4}},
        {{2, 4}, {7, 4}, {11, 4}, {7, 4}},
    };
    static const int VOICING[4][3][2] = {
        {{9, 3}, {0, 4}, {4, 4}},
        {{5, 3}, {9, 3}, {0, 4}},
        {{4, 3}, {7, 3}, {0, 4}},
        {{2, 3}, {7, 3}, {11, 3}},
    };
    static const int TOP[4][2] = {{4, 5}, {0, 5}, {7, 4}, {2, 5}};

    // BAR * BARS by construction, taken from the buffer so a wrap can never
    // land outside it.
    int n = v->n;
    double *drums = (double *)calloc((size_t)n, sizeof(double));
    double *bed = v->buf;
    rng r;
    int c, bar, e, s, beat, i, len;

    if (!drums) return;
    rng_seed(&r, 20250802);

    for (c = 0; c < 4; c++) {
        int base = c * 2 * BAR;
        double root = nf(ROOT[c][0], ROOT[c][1]);

        // Pad: one chord held across its two bars, arriving before the bar it
        // belongs to so the change is a swell rather than an edit.
        for (i = 0; i < 3; i++) {
            double *p = note_pad(nf(VOICING[c][i][0], VOICING[c][i][1]),
                                 2.0 * BAR / RATE + 0.5, &len);
            mix_free(bed, n, base - (int)(0.12 * RATE), p, len, 0.16);
        }

        // Lead: one note, most of the two bars, and then out of the way.
        {
            double *l = note_lead(nf(TOP[c][0], TOP[c][1]),
                                  2.0 * BAR / RATE - (double)BEAT / RATE, &len);
            mix_free(bed, n, base + BEAT, l, len, 0.10);
        }

        for (bar = 0; bar < 2; bar++) {
            int b0 = base + bar * BAR;

            // Bass on the eighths, up an octave for the last one, which is
            // what stops a driving bassline from being a drone.
            for (e = 0; e < 8; e++) {
                double f = root * (e == 7 ? 2.0 : 1.0);
                double *lo = note_saw(f, 0.30, &len, 5.0, 900.0, 0.0);
                mix_free(bed, n, b0 + e * BEAT / 2, lo, len, 0.50);
                lo = note_saw(f / 2.0, 0.26, &len, 6.0, 420.0, 0.0);
                mix_free(bed, n, b0 + e * BEAT / 2, lo, len, 0.22);
            }

            // Arpeggio on the sixteenths, the cell four times a bar.
            for (s = 0; s < 16; s++) {
                double f = nf(CELL[c][s % 4][0], CELL[c][s % 4][1]) *
                           ((bar == 1 && s >= 12) ? 2.0 : 1.0);
                // A beat is 13230 samples, so a sixteenth is 3307.5 and the
                // grid has to be computed from the beat rather than from a
                // rounded sixteenth. Multiplying a truncated 3307 instead
                // walks the arpeggio off the beat by half a sample per step.
                double *a = note_saw(f, 0.20, &len, 9.0, 3000.0, 0.006);
                mix_free(bed, n, b0 + s * BEAT / 4, a, len,
                         (s % 2) ? 0.16 : 0.22);
            }

            // Four on the floor, snare on two and four, hats on the eighths
            // with the weight on the off-beat.
            for (beat = 0; beat < 4; beat++) {
                double *d = kick(&r, &len);
                mix_free(drums, n, b0 + beat * BEAT, d, len, 0.80);
                if (beat % 2 == 1) {
                    d = snare(&r, &len);
                    mix_free(drums, n, b0 + beat * BEAT, d, len, 0.34);
                }
                d = hat(&r, &len);
                mix_free(drums, n, b0 + beat * BEAT, d, len, 0.09);
                d = hat(&r, &len);
                mix_free(drums, n, b0 + beat * BEAT + BEAT / 2, d, len, 0.16);
            }
        }
    }

    // The turnaround: one extra snare on the last off-beat, so the eighth bar
    // points at the first instead of merely stopping next to it.
    {
        double *d = snare(&r, &len);
        mix_free(drums, n, n - BEAT / 2, d, len, 0.30);
    }

    // Sidechain. Everything but the drums ducks under each kick and comes back
    // over the beat, which is the breathing this music is mostly made of.
    for (i = 0; i < n; i++) {
        double x = (double)(i % BEAT) / BEAT;
        bed[i] *= 0.55 + 0.45 * pow(dmin(1.0, x / 0.45), 0.6);
    }
    for (i = 0; i < n; i++) bed[i] += drums[i];
    free(drums);
    v_drive(v, 1.15);
}

// --- rendering -------------------------------------------------------------

typedef struct {
    const char *name;
    double dur;
    int loop;              // played end to end forever, so it must not fade
    void (*make)(voice *);
} entry;

static const entry KIT[] = {
    {"gun",     0.085, 0, k_gun},
    {"bomb",    0.24,  0, k_bomb},
    {"blast",   0.55,  0, k_blast},
    {"death",   0.95,  0, k_death},
    {"hit",     0.07,  0, k_hit},
    {"bounce",  0.075, 0, k_bounce},
    {"spawn",   0.32,  0, k_spawn},
    {"prize",   0.22,  0, k_prize},
    {"rust",    0.26,  0, k_rust},
    {"charge",  0.18,  0, k_charge},
    {"flag",    0.3,   0, k_flag},
    {"thrust",  0.5,   1, k_thrust},
    {"ui_move", 0.035, 0, k_ui_move},
    {"ui_go",   0.16,  0, k_ui_go},
    {"music",   (double)(BAR * BARS) / RATE, 1, k_music},
};

#define KIT_COUNT ((int)(sizeof(KIT) / sizeof(KIT[0])))

const char *const sfx_names[] = {
    "gun", "bomb", "blast", "death", "hit", "bounce", "spawn", "prize",
    "rust", "charge", "flag", "thrust", "ui_move", "ui_go", "music", NULL,
};

static void put32(unsigned char *p, uint32_t v) {
    p[0] = (unsigned char)(v & 0xff);
    p[1] = (unsigned char)((v >> 8) & 0xff);
    p[2] = (unsigned char)((v >> 16) & 0xff);
    p[3] = (unsigned char)((v >> 24) & 0xff);
}

static void put16(unsigned char *p, uint16_t v) {
    p[0] = (unsigned char)(v & 0xff);
    p[1] = (unsigned char)((v >> 8) & 0xff);
}

unsigned char *sfx_render(const char *name, size_t *len) {
    const entry *k = NULL;
    voice v;
    unsigned char *wav;
    size_t data_bytes;
    int i;

    for (i = 0; i < KIT_COUNT; i++) {
        if (strcmp(KIT[i].name, name) == 0) { k = &KIT[i]; break; }
    }
    if (!k || !voice_init(&v, k->dur)) return NULL;
    k->make(&v);

    // A loop must not fade: the fade is a hole in the middle of the sound once
    // the buffer is played end to end.
    if (!k->loop) v_fade_out(&v);
    v_normalise(&v);

    data_bytes = (size_t)v.n * 2;
    wav = (unsigned char *)malloc(44 + data_bytes);
    if (!wav) { voice_free(&v); return NULL; }

    memcpy(wav, "RIFF", 4);
    put32(wav + 4, (uint32_t)(36 + data_bytes));
    memcpy(wav + 8, "WAVEfmt ", 8);
    put32(wav + 16, 16);                       // pcm header length
    put16(wav + 20, 1);                        // pcm
    put16(wav + 22, 1);                        // mono
    put32(wav + 24, RATE);
    put32(wav + 28, RATE * 2);                 // bytes per second
    put16(wav + 32, 2);                        // bytes per frame
    put16(wav + 34, 16);                       // bits per sample
    memcpy(wav + 36, "data", 4);
    put32(wav + 40, (uint32_t)data_bytes);

    for (i = 0; i < v.n; i++) {
        double x = v.buf[i];
        int s;
        if (x < -1.0) x = -1.0;
        if (x > 1.0) x = 1.0;
        s = (int)(x * 32767.0);
        put16(wav + 44 + i * 2, (uint16_t)(int16_t)s);
    }

    voice_free(&v);
    *len = 44 + data_bytes;
    return wav;
}
