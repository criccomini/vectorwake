// The sound kit, synthesised. See sfx.h for what this is and why.
//
// The vocabulary is deliberately narrow and matches the art direction. Guns
// are short and bright with a hard transient, bombs heave out of a tube,
// explosions are noise under a descending sine, which is what gives a blast a
// body rather than a hiss, and the interface ticks. Nothing rings for longer
// than the thing that caused it is on screen.
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
// different generator would have rewritten the whole kit at once.

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

// A finished buffer as the bytes of a 16-bit mono wav, header and all. The
// voice is freed either way.
static unsigned char *voice_wav(voice *v, size_t *len) {
    unsigned char *wav;
    size_t data_bytes;
    int i;

    data_bytes = (size_t)v->n * 2;
    wav = (unsigned char *)malloc(44 + data_bytes);
    if (!wav) { voice_free(v); return NULL; }

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

    for (i = 0; i < v->n; i++) {
        double x = v->buf[i];
        int s;
        if (x < -1.0) x = -1.0;
        if (x > 1.0) x = 1.0;
        s = (int)(x * 32767.0);
        put16(wav + 44 + i * 2, (uint16_t)(int16_t)s);
    }

    voice_free(v);
    *len = 44 + data_bytes;
    return wav;
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
        ph += f / RATE;
        if (ph >= 1.0) ph -= 1.0;
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
        ph += f / RATE;
        if (ph >= 1.0) ph -= 1.0;
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

// Phase modulation, with the modulation index on an envelope of its own.
//
// Every other source in this file builds a sound out of whole parts and then
// takes some of it away with a filter. This one makes the parts. Modulating a
// sine's phase with a second sine throws up a skirt of sidebands at the
// carrier plus and minus every multiple of the modulator, and how far that
// skirt reaches is the index. An index that starts high and collapses is
// therefore a spectrum that starts as a wall and clears into one tone, which
// is not something any filter can do to a square wave and is most of what a
// weapon going off sounds like: a crack that resolves into the note the thing
// it left rings at.
//
// The ratio decides what kind of wall. A whole number lands every sideband on
// the harmonic series and the burst reads as a bright instrument. Well off a
// whole number they land between the harmonics and it reads as metal being
// struck. That is the axis the four bolts climb, and it is a difference in
// kind rather than in degree, which is the thing three earlier attempts at
// this ladder could not buy with any amount of moving numbers.
static void v_fm(voice *v, double car0, double car1, double ratio,
                 double index0, double index1, double gain, double bite) {
    double pc = 0.0, pm = 0.0;
    int i;
    for (i = 0; i < v->n; i++) {
        double t = (double)i / RATE;
        double x = t / v->dur;
        double f = car1 + (car0 - car1) * exp(-7.0 * x);
        double k = index1 + (index0 - index1) * pow(1.0 - x, bite);
        pc += 2.0 * SFX_PI * f / RATE;
        pm += 2.0 * SFX_PI * f * ratio / RATE;
        v->buf[i] += sin(pc + k * sin(pm)) * gain * env3(t, v->dur);
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

// A one-pole lowpass, run `poles` times. One pole falls off slowly enough
// that filtered noise keeps a thin high end, which reads as hiss; anything
// that has to be genuinely dark asks for more than one.
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

// A resonant bandpass whose center sweeps, mixed over the dry signal.
//
// Resonance is what gives a sound a body to have come out of. A narrow peak
// that rings up around 1.5 kHz is a tin can; the same peak down at 200 and
// sliding is a throat. Neither can be had from the lowpasses above, which only
// take things away: a resonator hands some of it back, louder, at one place.
//
// The cookbook bandpass with constant peak gain, coefficients rebuilt every
// sample because the center is moving. That is a transcendental or three per
// sample, which is nothing against how rarely this runs.
static void v_reson(voice *v, double f0, double f1, double q, double wet) {
    double x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0;
    int i;
    for (i = 0; i < v->n; i++) {
        double fc = f0 + (f1 - f0) * ((double)i / v->n);
        double w, alpha, a0, b0, a1, a2, x, y;
        if (fc < 20.0) fc = 20.0;
        if (fc > RATE * 0.45) fc = RATE * 0.45;
        w = 2.0 * SFX_PI * fc / RATE;
        alpha = sin(w) / (2.0 * q);
        a0 = 1.0 + alpha;
        b0 = alpha / a0;
        a1 = -2.0 * cos(w) / a0;
        a2 = (1.0 - alpha) / a0;
        x = v->buf[i];
        y = b0 * x - b0 * x2 - a1 * y1 - a2 * y2;
        x2 = x1; x1 = x;
        y2 = y1; y1 = y;
        v->buf[i] = x * (1.0 - wet) + y * wet;
    }
}

// Ring modulation: everything already in the buffer, multiplied by a sine.
//
// It moves every partial to the sum and difference of itself and the
// modulator, which lands them off the harmonic series. That is the whole
// difference between a note and a clang, and it is how a shell reads as metal
// rather than as a low instrument.
static void v_ring(voice *v, double f0, double f1, double depth) {
    double ph = 0.0;
    int i;
    for (i = 0; i < v->n; i++) {
        double f = f0 + (f1 - f0) * ((double)i / v->n);
        ph += 2.0 * SFX_PI * f / RATE;
        v->buf[i] *= 1.0 - depth + depth * sin(ph);
    }
}

// A comb short enough to be a body rather than an echo.
//
// Feed a delay line back into itself through a one-zero lowpass and it rings
// at the rate its length beats out, losing its high end a little faster each
// trip round. That is the plucked string, and at a delay of half a millisecond
// to four it is not a string: it is the size of whatever the sound came out
// of. Damping is how much survives each trip, which is how hard that thing is.
//
// A resonator has one peak and this has a peak at every multiple of one
// frequency, all the way up. The difference is audible and it is the whole
// reason both are here: one peak is a filter and a stack of them is a shape
// with air in it.
//
// A previous version of the bolts fed a comb of twenty to forty milliseconds,
// which is long enough that the ear hears the repeats separately and calls
// them a room. Below about five it stops being a delay and becomes a timbre.
static void v_comb(voice *v, double hz, double damp) {
    double dl = RATE / hz;
    int d = (int)dl, i;
    double frac = dl - d, prev = 0.0;
    if (d < 2 || d + 1 >= v->n) return;
    for (i = d + 1; i < v->n; i++) {
        double tap = v->buf[i - d] * (1.0 - frac) + v->buf[i - d - 1] * frac;
        double s = 0.5 * (tap + prev);
        prev = tap;
        v->buf[i] += s * damp;
    }
}

// Reflections, arriving later, duller, and out of the body's own register.
//
// The same delay line fed back on itself as v_comb above, and the only
// difference is how long it is, which turns out to be the whole difference
// between two effects. Under about five milliseconds the repeats fuse and the
// ear hears one timbre with a body. Past about thirty they come apart and it
// hears a series of arrivals, which is a room.
//
// What comes back is band limited, and that is the part that took a listen to
// get right. The first version had only a lowpass in the loop, on the reasoning
// that air and every surface take the top end first, which is true. Measured,
// its echo was enormous: forty decibels of tail where there had been silence.
// Nobody could hear it. A bomb in this kit is a wall of sub with almost nothing
// above two hundred hertz, so a dark return lands exactly where the body
// already is, twenty-five decibels down, on speakers that mostly cannot make
// those frequencies anyway.
//
// A real distant reflection is not a sub rumble. Long wavelengths bend around
// obstacles and arrive as part of the direct sound rather than as a separate
// event; what comes back off a far wall as a discrete arrival is the mid band.
// So the loop takes the bottom off as well as the top, and the return sits in
// the register these sounds deliberately leave empty, where it cannot be masked
// and where a laptop can reproduce it.
// How many times it comes back is `feedback`, and how loud it is is `level`,
// and those have to be separate numbers. Run as one, the way a plain feedback
// delay does it, the return can never be louder than what it is reflecting,
// and what it is reflecting here is a bomb: a wall of sub with almost nothing
// in the band this returns in. That version measured forty decibels of tail
// where there had been silence and was still inaudible, because forty
// decibels above nothing is nothing. A room is allowed to hand back more mid
// than arrived at it. It concentrates into a few arrivals what left as a
// spread, and a send and return is how you say so.
static void v_echo(voice *v, double secs, double feedback, double level,
                   double lo, double hi) {
    int d = (int)(secs * RATE), i;
    double al = 1.0 - exp(-2.0 * SFX_PI * hi / RATE);
    double ah = exp(-2.0 * SFX_PI * lo / RATE);
    double y = 0.0, px = 0.0, py = 0.0;
    double *wet;
    if (d < 1 || d >= v->n) return;
    wet = (double *)calloc((size_t)v->n, sizeof(double));
    if (!wet) return;
    for (i = d; i < v->n; i++) {
        double x = v->buf[i - d] + wet[i - d];
        y += al * (x - y);              // down from hi
        py = ah * (py + y - px);        // up from lo
        px = y;
        wet[i] = py * feedback;
    }
    for (i = 0; i < v->n; i++) v->buf[i] += wet[i] * level;
    free(wet);
}

// A wavefolder, where v_drive is a limiter.
//
// Drive rounds a peak off and adds a little of the odd harmonics. This turns
// the peak back on itself, so the harmonics it throws up were never in the
// source at all and do not fall where the ear expects them. Loudness is what
// drive sounds like; this sounds like something being damaged.
static void v_fold(voice *v, double k) {
    int i;
    for (i = 0; i < v->n; i++) v->buf[i] = sin(v->buf[i] * k);
}

// A decay laid over a finished buffer.
//
// Every source in this file carries its own envelope. A comb does not: it goes
// on handing back whatever it is given for as long as it is given anything, so
// a body with any ring in it props the sound up against the decay its sources
// were written with, and what should fall away instead sits at a plateau and
// occasionally climbs. This puts the decay back afterwards over the whole
// thing. There is no attack in it, so the transient it is laid over survives
// untouched.
static void v_taper(voice *v, double curve) {
    int i;
    for (i = 0; i < v->n; i++) {
        double x = (double)i / v->n;
        v->buf[i] *= pow(1.0 - x, curve);
    }
}

// A slow front, in place of the hard one every other sound here has.
//
// It is what separates a bomb from a gun at any rung. A bolt cracks off a rail
// and a charge heaves out of a tube, and how long it takes to leave is most of
// what says how big it was. Without this the two families converge as they
// climb, since both ladders get deeper and longer as they go and the top of
// the gun ends up nearer the bottom of the bomb than either is to its own
// neighbour.
//
// Smoothstep rather than a straight ramp: a linear fade has a corner where it
// meets full level, and a corner in an envelope is a click.
static void v_swell(voice *v, double secs) {
    int m = (int)(secs * RATE);
    int i;
    if (m > v->n) m = v->n;
    for (i = 0; i < m; i++) {
        double x = (double)i / m;
        v->buf[i] *= x * x * (3.0 - 2.0 * x);
    }
}

static void v_fade_out(voice *v) {
    int m = (int)(0.008 * RATE);
    int i;
    if (m > v->n) m = v->n;
    for (i = 0; i < m; i++) v->buf[v->n - 1 - i] *= (double)i / m;
}

static void v_normalize(voice *v) {
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

// The gun, the bomb and the detonation each have four rungs, and every rung is
// its own sound. A pilot under fire should be able to hear what is being
// pointed at them without reading a scoreboard, and the rung is the most useful
// thing there is to know about an incoming round: it is the whole of the damage
// a bolt carries and the whole of the radius a bomb clears.
//
// Two designs failed at this before the one below, and they failed the same
// way. Both wrote one recipe and walked its numbers per rung, the first moving
// weight alone and the second moving every parameter it had. Measured with
// client/tools/sfxladder they came out 2.5 to 4.5 dB apart and then 7.6 to 8.4,
// and the player who flew both called the first one sound and the second slight
// alterations of each other. A recipe stretched far enough is still a recipe.
// Every rung of it arrives as the same event slightly off, and which of four
// events it is remains the thing that was asked and not answered.
//
// So the eight launch sounds below share no table and no parameters, only the
// tools they call. Each is written to a brief: the bolts run from a weenie to
// something nasty and the charges from tinny and hollow to throaty and bass
// heavy. The ladders are steep for it, two octaves and two and a half, every
// step at least a tritone.
//
// The detonations further down are still a table, because their brief is one
// thing getting bigger rather than four things being different.
//
// Loudness is not decided here. Every buffer is normalized to the same peak
// before it is written, so these decide timbre only, and the gains in the
// .sound files carry the climb. Those gains are not in order and are not meant
// to be: a folded buffer is dense and a resonant one is sparse, so eight sounds
// at one peak are eight loudnesses, and the numbers that even them out are
// solved from each sound's loudest 300 ms window rather than chosen.

// A bolt leaving the rail. Rung zero is a toy and rung three is a weapon that
// is hurting itself to fire.
//
// What the four share is the shape of the gesture, and that is the whole of
// what keeps them one family: a pulse falling fast, bright air over it, and a
// crack at the front that reaches full level in four and a half milliseconds
// however heavy the rung. Nothing here swells, and every charge does.

// Every bolt is a strike that resolves into a note.
//
// Each one is phase modulation over a comb, and the pair carry one idea
// between them: the gun is a body being hit, the rung is how big the body is,
// and how hard it is hit decides whether what comes back is a note or a noise.
// Each comb is tuned to the note its carrier lands on, so the body rings at
// the pitch the strike resolves to rather than at some size picked separately.
//
// The three ladders before this one were the same instrument at four
// settings: a square wave falling, filtered, driven, and in the last of them
// crushed down to a few dozen levels. Pulling those settings further apart
// bought measurement and not much hearing, because a listener does not grade a
// timbre, they name it, and four settings of one thing have one name. That is
// why the tool below is one none of them had rather than a wider spread of
// what they all used.
//
// Two things climb the ladder and they climb in different currencies.
//
// The ratio between modulator and carrier goes 2, 1.75, 1.414, 2.76. A whole
// number lands every sideband on the harmonic series and the burst is a bright
// clean instrument. Seven over four is still rational, so it holds together
// with no beating in it, but its sidebands sit a fourth under the note and it
// reads hollow. Root two lands nothing on a harmonic of anything, which is the
// definition of metal, and 2.76 is the ratio that makes bells. Rung three is
// not a heavier version of rung zero. It is a different material, and material
// is the kind of difference a listener names.
//
// The index goes 3 to 11 and its collapse slows from a bite of 7 to one of
// 2.2. The index is how wide the burst is at the moment of firing and the bite
// is how fast it clears, so rung zero is over as a wall before it has been
// heard as one and rung three snarls for a fifth of its length before it finds
// a pitch. Weight is the audible cost of firing rather than a bigger number.
//
// A wide index throws sidebands a long way up, so without a ceiling the heavy
// rungs measure brighter than the light ones, which is backwards twice over:
// against the brief, and against how a big heavy thing actually radiates. The
// lowpass at the end of each falls 11 kHz, 3.8, 1.15, 1.9. It is not monotone
// because the rungs are not one recipe: rung three needs more room above its
// note than rung two does to keep its bell audible under all that sub.
//
// The taper is there because a comb has no envelope of its own. It keeps
// handing back what it is given for as long as it is given anything, so the
// first version of these came out flat and occasionally climbing where they
// should have been falling away.
//
// What holds the four together is that they all land somewhere. The carrier
// falls onto E6, A5, C5 and E4: an A minor triad, descending, across two
// octaves. Four frequencies an equal distance apart are one thing at four
// heights. Four intervals the ear already knows are four places, and it can
// name which one it is hearing without having heard the others first. That is
// the entire job of this ladder, and client/tools/sfxladder checks the tuning
// because nothing else it measures could see a bolt slide a tone off its note.

// E6, tapped with something small. A whole-number ratio and an index gone in
// four milliseconds, so there is barely a strike at all: a glass tick, and
// then the note, in a body too small to hold anything.
static void k_gun0(voice *v) {
    v_fm(v, 2600, 1318.51, 2.00, 3.0, 0.10, 0.72, 7.0);
    v_noise(v, 0.030, 9000, 4500, 5.0, 11);
    v_comb(v, 1318.51, 0.40);
    v_highpass(v, 900);
    lowpass(v->buf, v->n, 11000, 1);
    v_taper(v, 1.4);
}

// A5, and the ratio has come off a whole number for the first time. Seven over
// four is a rational number, so this still rings cleanly rather than beating,
// but its strongest sideband sits a fourth under the note and that reads as
// hollow. A body twice the size of rung zero's and a little drive on the end.
static void k_gun1(voice *v) {
    v_fm(v, 1480, 880.00, 1.75, 4.5, 0.22, 0.74, 5.0);
    v_noise(v, 0.040, 7000, 3000, 4.0, 11);
    v_comb(v, 880.00, 0.52);
    v_drive(v, 1.4);
    lowpass(v->buf, v->n, 3800, 2);
    v_taper(v, 2.0);
}

// C5 through a ratio of root two, which is the least harmonic number there is
// in the sense that matters here: no sideband it throws lands on a harmonic of
// anything. The burst is a struck plate. The ceiling is low and the body is
// big and damp, which is what stops the plate reading as a chime, the failure
// this ratio invites. There is no separate sub in it: one was tried and beat
// against the inharmonic sidebands at forty hertz, which is a warble rather
// than a weapon.
static void k_gun2(voice *v) {
    v_fm(v, 940, 523.25, 1.414, 7.5, 0.34, 0.70, 3.2);
    v_noise(v, 0.045, 5200, 1800, 3.4, 11);
    v_comb(v, 523.25, 0.60);
    v_drive(v, 1.7);
    lowpass(v->buf, v->n, 1150, 2);
    v_taper(v, 1.8);
}

// E4 at 2.76, the ratio that makes bells, held open for a fifth of the sound
// before it collapses. Everything here is the cost of firing it: the widest
// burst, the slowest clear, two octaves of sub under the note, the biggest
// body, and a fold at the end that puts harmonics up where nothing generated
// them. The subs are exact octaves of the landing note, so they lock to it
// instead of beating against it.
static void k_gun3(voice *v) {
    v_fm(v, 620, 329.63, 2.76, 11.0, 0.48, 0.66, 2.2);
    v_sine(v, 164.81, 164.81, 0.40, 0.55);
    v_sine(v, 82.41, 82.41, 0.30, 0.70);
    v_noise(v, 0.050, 4000, 1100, 3.0, 11);
    v_comb(v, 329.63, 0.66);
    v_drive(v, 2.0);
    v_fold(v, 1.5);
    lowpass(v->buf, v->n, 1900, 2);
    v_taper(v, 2.0);
}

// Build a sound at its own length and lay it into a longer buffer.
//
// Every envelope in this file decays over the buffer's own length rather than
// over a span of time, which is deliberate and is why one curve fits sounds of
// four sizes. It also means a buffer made longer to hold a tail is a longer
// sound rather than a longer silence, and the swept resonators stretch with it,
// so simply extending a bomb to make room for its echo rewrites the bomb. The
// body is built at the length it has always had and copied in, and the rest of
// the buffer belongs to whatever comes after.
static void body_into(voice *v, double secs, void (*make)(voice *)) {
    voice b;
    int i;
    if (!voice_init(&b, secs)) return;
    make(&b);
    for (i = 0; i < b.n && i < v->n; i++) v->buf[i] += b.buf[i];
    voice_free(&b);
}

// A charge leaving the tube.
//
// Built apart from each other for the same reason the bolts are, and the
// distance to travel is further: a rung zero bomb is a tin of something going
// off and a rung three bomb clears four times the room. So the bottom of this
// ladder is hollow and metallic, all shell and no charge, and the top is
// nearly all charge, a throat opening under a wall of sub.
//
// Every one of them swells rather than cracks. That is the family's mark and
// it is not decoration: without it the heaviest bolt and the lightest shell
// arrive as the same kind of event, which is the one confusion here that
// costs a pilot something.

// Tinny and hollow. A square is hollow by construction, having only the odd
// harmonics, and a narrow resonance up at 1.4 kHz with a clang ring-modulated
// through it is the tin. There is no sub at all: this is the shell, and there
// is hardly anything in it.
static void bomb0_body(voice *v) {
    v_square(v, 330, 145, 0.44, 0.50, 0.45);
    v_sine(v, 190, 74, 0.26, 0.55);
    v_noise(v, 0.22, 4200, 800, 2.4, 23);
    v_ring(v, 430, 330, 0.30);
    v_reson(v, 1450, 900, 7.0, 0.62);
    v_drive(v, 1.7);
    v_swell(v, 0.024);
}

static void k_bomb0(voice *v) {
    body_into(v, 0.20, bomb0_body);
    v_echo(v, 0.035, 0.26, 2.60, 1100, 5000);
}

// A real charge. The tin is still audible but it is a ring over the top now
// rather than the whole sound, and a saw underneath gives it something to
// throw.
static void bomb1_body(voice *v) {
    v_saw(v, 245, 82, 0.46, 0.70);
    v_sine(v, 150, 52, 0.44, 0.80);
    v_sine(v, 78, 34, 0.24, 0.60);
    v_noise(v, 0.26, 3000, 320, 2.2, 23);
    v_reson(v, 900, 420, 4.5, 0.44);
    v_drive(v, 2.0);
    v_swell(v, 0.024);
}

static void k_bomb1(voice *v) {
    body_into(v, 0.32, bomb1_body);
    v_echo(v, 0.075, 0.40, 2.80, 700, 3000);
}

// Throaty. The resonance has come down out of the tin and into the chest,
// where it sweeps while the sound is still going, which is what a throat is.
// The saw is backed off to let it be heard: a saw's own harmonics reach a long
// way up and they sit exactly where this needs to be quiet.
static void k_bomb2(voice *v) {
    v_saw(v, 172, 56, 0.30, 0.95);
    v_sine(v, 104, 34, 0.56, 1.05);
    v_sine(v, 54, 25, 0.52, 0.60);
    v_noise(v, 0.19, 1900, 210, 2.0, 23);
    v_reson(v, 500, 180, 5.0, 0.52);
    v_drive(v, 2.3);
    v_swell(v, 0.040);
}

// Throaty and bass heavy. Almost none of this is above two hundred hertz. The
// sub is the loudest thing in the buffer, the throat is down at the bottom of
// its range, and what little air there is has been shut down to a rumble, so
// the whole seven hundred milliseconds is weight arriving and then leaving.
static void k_bomb3(voice *v) {
    v_saw(v, 118, 33, 0.20, 1.30);
    v_sine(v, 70, 22, 0.72, 1.40);
    v_sine(v, 40, 18, 1.25, 0.60);
    v_noise(v, 0.08, 900, 95, 1.9, 23);
    v_reson(v, 240, 72, 6.0, 0.62);
    v_drive(v, 2.6);
    v_swell(v, 0.072);
}

// A bomb going off: noise for the air, a falling sine for the body.
//
// This is where a bomb rung is actually spent, so it is the half of the ladder
// that matters most and it was flat until now: one blast for every rung,
// because the shell in flight carries a spec rather than the rung that fired
// it. The rung is readable off the spec after all, by the same route that
// colors the round, so the detonation can say what cleared the room.
//
// A bigger charge is duller, longer and later rather than louder. The crack at
// the front is the same fifty milliseconds at every rung, since that is the
// detonation itself; behind it a rumble arrives, and how long it waits, how
// dark it is and how long it rolls are the rung. The tail stretches from a
// third of a second to nearly a whole one. Loudness still comes from the
// .sound gains, which climb 0.62 to 0.75 and stop under a death.
static const double BLAST_AIR[3][4] = {{0.62, 0.72, 0.86, 1.00},
                                       {3000, 2800, 1500,  480},
                                       { 320,  270,  128,   30}};
static const double BLAST_BODY[3][4] = {{ 235,  180,  132,   80},
                                        {  52,   40,   28,   17},
                                        {0.44, 0.54, 0.67, 0.94}};
static const double BLAST_SUB[3][4] = {{ 122,   92,   64,   32},
                                       {  36,   29,   20,   12},
                                       {0.22, 0.38, 0.64, 1.40}};
static const double BLAST_DRIVE[4] = {1.90, 2.10, 2.30, 2.40};

// How fast the air stops moving. A small charge is a crack that is over; a big
// one keeps rolling, so the top rungs hold their noise up long after the crack
// rather than merely running for longer, which is the difference between a
// bigger explosion and the same explosion in a longer buffer.
static const double BLAST_TAIL[4] = {2.80, 2.30, 1.80, 1.30};

// The crack at the front, which barely moves. It is what says a detonation
// happened at all, and it is the same event at every rung; what a rung buys is
// everything behind it.
static const double BLAST_CRACK[4] = {0.34, 0.36, 0.38, 0.40};
// How long the rumble behind it takes to arrive, in seconds.
static const double BLAST_ROLL[4] = {0.000, 0.024, 0.052, 0.090};

// How much room the blast happened in. Delay, how much comes back, and how
// much of the top end survives a trip, per rung.
//
// Tighter than the launch family's, and deliberately: a detonation is already
// most of a second of decaying noise, so distinct repeats inside it would only
// read as flutter. What this buys is density arriving from further away as the
// rung climbs, which is what a bigger hole in a room actually sounds like.
static const double BLAST_ROOM[5][4] = {{0.030, 0.055, 0.085, 0.130},
                                        {0.16,  0.28,  0.40,  0.52},
                                        { 1.50,  1.40,  1.30,  1.10},
                                        { 900,   650,   420,   280},
                                        {5200,  3000,  1700,   950}};

// And it is fifty milliseconds long at every rung, which has to be asked for.
// `env` decays over a fraction of the buffer rather than over a span of time,
// so one curve across four buffers is a crack that stretches with the rung: at
// the top it ran a seventh of a second, three times the bottom's, and a bright
// front held that much longer is why the biggest detonation first measured as
// the brightest rather than the deepest.
#define BLAST_CRACK_SECS 0.05

static void blast_body(voice *v, int lvl) {
    voice rumble;
    int i;

    v_noise(v, BLAST_CRACK[lvl], 7000, 1200, v->dur / BLAST_CRACK_SECS, 37);
    // Built apart so it can be filtered without taking the crack down with it.
    // The single pole v_noise applies is not enough on its own: it leaves a
    // thin high end that reads as hiss, and with the tail held up as long as
    // the top rungs hold theirs, that hiss is enough to make the biggest
    // detonation measure as the brightest.
    if (voice_init(&rumble, v->dur)) {
        v_noise(&rumble, BLAST_AIR[0][lvl], BLAST_AIR[1][lvl],
                BLAST_AIR[2][lvl], BLAST_TAIL[lvl], 41);
        lowpass(rumble.buf, rumble.n, BLAST_AIR[1][lvl], 2);
        // And it arrives behind the crack rather than with it, further behind
        // the bigger the charge. That gap is what a large explosion sounds
        // like from any distance at all: the sharp part reaches you, and then
        // the ground goes. It is also the only thing separating the top two
        // rungs by more than length, since both are long, dark and rolling.
        v_swell(&rumble, BLAST_ROLL[lvl]);
        for (i = 0; i < v->n; i++) v->buf[i] += rumble.buf[i];
        voice_free(&rumble);
    }
    v_sine(v, BLAST_BODY[0][lvl], BLAST_BODY[1][lvl], BLAST_BODY[2][lvl], 0.5);
    v_sine(v, BLAST_SUB[0][lvl], BLAST_SUB[1][lvl], BLAST_SUB[2][lvl], 0.6);
    v_drive(v, BLAST_DRIVE[lvl]);
}

// How long the detonation itself is, before the room answers it.
static const double BLAST_SECS[4] = {0.28, 0.46, 0.64, 0.85};

static void blast_at(voice *v, int lvl) {
    voice b;
    int i;
    if (voice_init(&b, BLAST_SECS[lvl])) {
        blast_body(&b, lvl);
        for (i = 0; i < b.n && i < v->n; i++) v->buf[i] += b.buf[i];
        voice_free(&b);
    }
    v_echo(v, BLAST_ROOM[0][lvl], BLAST_ROOM[1][lvl], BLAST_ROOM[2][lvl],
            BLAST_ROOM[3][lvl], BLAST_ROOM[4][lvl]);
}

static void k_blast0(voice *v) { blast_at(v, 0); }
static void k_blast1(voice *v) { blast_at(v, 1); }
static void k_blast2(voice *v) { blast_at(v, 2); }
static void k_blast3(voice *v) { blast_at(v, 3); }

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
    v_loop_noise(v, 0.90, 520, 101);      // the rumble
    v_loop_noise(v, 0.24, 2600, 103);     // a little air over it
    v_loop_sine(v, 58, 0.39);
    v_loop_sine(v, 87, 0.20);
    v_loop_sine(v, 146, 0.09);
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

// A tempo has to divide the sample rate's minute, or the loop does not close.
//
// A beat is RATE * 60 / BPM samples and a track is a whole number of beats, so
// the seam lands on the downbeat only when that division is exact. 22050 * 60
// is 1323000, which is 2^3 * 3^3 * 5^3 * 7^2, and the tempos below are the
// divisors of it that fall where this genre lives. 96 and 112 are not among
// them, which is worth knowing before wondering why they are absent.
//
// Everything else about a track is what makes eight of them eight rather than
// one played eight times: the key, the four chords, how they are voiced, and
// the note the lead holds over each.
typedef struct {
    int bpm;
    int bars;                  // four chords, so a multiple of four
    int root[4][2];            // what the bass walks, pitch class and octave
    int voicing[4][3][2];      // the pad, low to high
    int top[4][2];             // the note the lead holds
} track;

// The arpeggio is not in there because it is not a separate decision: it is
// the pad's own three notes an octave up, played up and back down. That was
// true of the first track before it was a table, and writing it out again per
// track would only be an opportunity to disagree with the chord.

static const track TRACKS[] = {
    // Neon wake. A minor, i-VI-III-VII, which is the progression the whole
    // style is built on and the reason every track in it sounds like every
    // other. This is the one that was here before there were eight.
    {100, 8,
     {{9, 2}, {5, 2}, {0, 3}, {7, 2}},
     {{{9, 3}, {0, 4}, {4, 4}},
      {{5, 3}, {9, 3}, {0, 4}},
      {{4, 3}, {7, 3}, {0, 4}},
      {{2, 3}, {7, 3}, {11, 3}}},
     {{4, 5}, {0, 5}, {7, 4}, {2, 5}}},

    // Long dark. D minor, i-VII-VI-VII, and the slowest tempo the divisors
    // allow. The bass walks down and comes back, which is most of why this one
    // feels like waiting rather than driving.
    {84, 8,
     {{2, 2}, {0, 2}, {10, 1}, {0, 2}},
     {{{2, 3}, {5, 3}, {9, 3}},
      {{0, 3}, {4, 3}, {7, 3}},
      {{10, 2}, {2, 3}, {5, 3}},
      {{0, 3}, {4, 3}, {7, 3}}},
     {{9, 4}, {7, 4}, {5, 4}, {7, 4}}},

    // Coast road. E minor, i-III-VII-VI, the one progression here that spends
    // more time major than minor and is the brightest for it.
    {90, 8,
     {{4, 2}, {7, 2}, {2, 2}, {0, 2}},
     {{{4, 3}, {7, 3}, {11, 3}},
      {{2, 3}, {7, 3}, {11, 3}},
      {{2, 3}, {6, 3}, {9, 3}},
      {{0, 3}, {4, 3}, {7, 3}}},
     {{11, 4}, {2, 5}, {9, 4}, {7, 4}}},

    // Cold open. C minor, i-VI-VII-VI, a progression that never resolves
    // anywhere and just leans back and forth, which is the point of it.
    {105, 8,
     {{0, 2}, {8, 1}, {10, 1}, {8, 1}},
     {{{0, 3}, {3, 3}, {7, 3}},
      {{8, 2}, {0, 3}, {3, 3}},
      {{10, 2}, {2, 3}, {5, 3}},
      {{8, 2}, {0, 3}, {3, 3}}},
     {{7, 4}, {3, 4}, {5, 4}, {0, 5}}},

    // Undertow. F minor, i-VII-VI-V, four chords walking down by step onto a
    // major fifth. The lead walks down with them, which is the only track here
    // whose top line is a line rather than four held notes.
    {98, 8,
     {{5, 2}, {3, 2}, {1, 2}, {0, 2}},
     {{{5, 3}, {8, 3}, {0, 4}},
      {{3, 3}, {7, 3}, {10, 3}},
      {{1, 3}, {5, 3}, {8, 3}},
      {{0, 3}, {4, 3}, {7, 3}}},
     {{0, 5}, {10, 4}, {8, 4}, {7, 4}}},

    // Overdrive. G minor, i-VI-III-VII again but at a hundred and twenty,
    // where the same four chords stop being wistful and start being a chase.
    {120, 8,
     {{7, 2}, {3, 2}, {10, 1}, {5, 2}},
     {{{7, 3}, {10, 3}, {2, 4}},
      {{3, 3}, {7, 3}, {10, 3}},
      {{10, 2}, {2, 3}, {5, 3}},
      {{5, 3}, {9, 3}, {0, 4}}},
     {{2, 5}, {10, 4}, {5, 4}, {0, 5}}},

    // Low ceiling. B minor, i-VII-VI-VII, voiced higher than the rest so it
    // sits over an arena rather than under one.
    {108, 8,
     {{11, 2}, {9, 2}, {7, 2}, {9, 2}},
     {{{11, 3}, {2, 4}, {6, 4}},
      {{9, 3}, {1, 4}, {4, 4}},
      {{7, 3}, {11, 3}, {2, 4}},
      {{9, 3}, {1, 4}, {4, 4}}},
     {{6, 5}, {4, 5}, {2, 5}, {1, 5}}},

    // Redline. F sharp minor, i-VI-VII-i, the fastest tempo the divisors allow
    // and the only progression that comes home before it repeats.
    {126, 8,
     {{6, 2}, {2, 2}, {4, 2}, {6, 2}},
     {{{6, 3}, {9, 3}, {1, 4}},
      {{2, 3}, {6, 3}, {9, 3}},
      {{4, 3}, {8, 3}, {11, 3}},
      {{6, 3}, {9, 3}, {1, 4}}},
     {{1, 5}, {9, 4}, {11, 4}, {1, 5}}},
};

#define TRACK_COUNT ((int)(sizeof(TRACKS) / sizeof(TRACKS[0])))


// Equal temperament from A4 = 440, with the pitch class given as a semitone
// index from C.
static double nf(int pc, int oct) {
    return 440.0 * pow(2.0, (12 + oct * 12 + pc - 69) / 12.0);
}

// A saw with an exponential decay. Two of them a few cents apart is the whole
// width of this mix, since it is mono and there is no chorus. Every voice in
// the track goes through `lowpass`: the genre is a filter sweep with a band
// behind it, and a raw saw is the sound of something that has not been
// recorded yet.
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
            ph += freq[vi] / RATE;
            if (ph >= 1.0) ph -= 1.0;
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
            ph += freq[vi] / RATE;
            if (ph >= 1.0) ph -= 1.0;
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
    int i, p;
    if (!src) return;
    // Wrapped by walking rather than by a remainder per sample. A pad is six
    // seconds of samples and there are twelve of them in a track, so that
    // division was a measurable slice of the whole render.
    p = pos % n;
    if (p < 0) p += n;
    for (i = 0; i < len; i++) {
        dst[p] += src[i] * gain;
        if (++p == n) p = 0;
    }
}

// One helper for the four calls that mix a freshly rendered note and drop it.
static void mix_free(double *dst, int n, int pos, double *src, int len,
                     double gain) {
    track_at(dst, n, pos, src, len, gain);
    free(src);
}

// A track, built a few milliseconds at a time.
//
// One of these takes about an eighth of a second to render, which is fine once
// behind the menu at boot and not fine at all three minutes into a firefight,
// where it is a frozen frame. So the work is cut into steps small enough to
// hide inside a frame, and the client builds the next track while the current
// one is still playing.
//
// The steps are the score's own units: a pad voice, a lead note, a bar of
// bass, a bar of arpeggio, a bar of drums. None of them is longer than about
// four milliseconds. The order they are visited in is the order the old
// single-call renderer visited them, which matters for exactly one reason:
// the drums draw from a seeded generator, so a bar of drums rendered out of
// turn would be a different bar of drums.
struct sfx_music_job {
    const track *t;
    int beat, bar, bars_per_chord, n;
    int step, steps;
    voice v;
    double *drums;
    rng r;
    int ok;
};

// Per chord: three pad voices, a lead, and then bass, arpeggio and drums for
// each of its bars. Then two to finish: the turnaround with the sidechain, and
// the drums with the drive over the top.
static int job_per_chord(const sfx_music_job *j) {
    return 4 + 3 * j->bars_per_chord;
}

sfx_music_job *sfx_music_begin(int i) {
    sfx_music_job *j;
    if (i < 0 || i >= TRACK_COUNT) return NULL;
    j = (sfx_music_job *)calloc(1, sizeof(*j));
    if (!j) return NULL;
    j->t = &TRACKS[i];
    j->beat = RATE * 60 / j->t->bpm;
    j->bar = j->beat * 4;
    j->bars_per_chord = j->t->bars / 4;
    j->n = j->bar * j->t->bars;
    j->steps = 4 * job_per_chord(j) + 2;
    j->ok = voice_init(&j->v, (double)j->n / RATE);
    j->drums = (double *)calloc((size_t)(j->n > 0 ? j->n : 1), sizeof(double));
    if (!j->drums) j->ok = 0;
    rng_seed(&j->r, 20250802);
    return j;
}

// One chord's worth of the four voices that are not drums.
static void job_chord(sfx_music_job *j, int c, int k) {
    const track *t = j->t;
    int base = c * j->bars_per_chord * j->bar;
    double *bed = j->v.buf;
    int len;

    if (k < 3) {
        // Pad: one chord held across its bars, arriving before the bar it
        // belongs to so the change is a swell rather than an edit.
        double *p = note_pad(nf(t->voicing[c][k][0], t->voicing[c][k][1]),
                             (double)(j->bars_per_chord * j->bar) / RATE + 0.5,
                             &len);
        mix_free(bed, j->n, base - (int)(0.12 * RATE), p, len, 0.16);
        return;
    }
    if (k == 3) {
        // Lead: one note, most of the chord, and then out of the way.
        double *l = note_lead(nf(t->top[c][0], t->top[c][1]),
                              (double)(j->bars_per_chord * j->bar - j->beat) /
                                  RATE, &len);
        mix_free(bed, j->n, base + j->beat, l, len, 0.10);
        return;
    }
    {
        int bar = (k - 4) / 3, which = (k - 4) % 3;
        int b0 = base + bar * j->bar;
        double root = nf(t->root[c][0], t->root[c][1]);
        int e, s, beat;

        if (which == 0) {
            // Bass on the eighths, up an octave for the last one, which is
            // what stops a driving bassline from being a drone.
            for (e = 0; e < 8; e++) {
                double f = root * (e == 7 ? 2.0 : 1.0);
                double *lo = note_saw(f, 0.30, &len, 5.0, 900.0, 0.0);
                mix_free(bed, j->n, b0 + e * j->beat / 2, lo, len, 0.50);
                lo = note_saw(f / 2.0, 0.26, &len, 6.0, 420.0, 0.0);
                mix_free(bed, j->n, b0 + e * j->beat / 2, lo, len, 0.22);
            }
        } else if (which == 1) {
            // Arpeggio on the sixteenths: the pad's own notes an octave up,
            // up and back down, four times a bar.
            static const int UPDOWN[4] = {0, 1, 2, 1};
            for (s = 0; s < 16; s++) {
                const int *note = t->voicing[c][UPDOWN[s % 4]];
                double f = nf(note[0], note[1] + 1) *
                           ((bar == j->bars_per_chord - 1 && s >= 12) ? 2.0
                                                                     : 1.0);
                // A beat at a hundred is 13230 samples, so a sixteenth is
                // 3307.5 and the grid has to be computed from the beat rather
                // than from a rounded sixteenth. Multiplying a truncated 3307
                // instead walks the arpeggio off the beat by half a sample a
                // step.
                double *a = note_saw(f, 0.20, &len, 9.0, 3000.0, 0.006);
                mix_free(bed, j->n, b0 + s * j->beat / 4, a, len,
                         (s % 2) ? 0.16 : 0.22);
            }
        } else {
            // Four on the floor, snare on two and four, hats on the eighths
            // with the weight on the off-beat.
            for (beat = 0; beat < 4; beat++) {
                double *d = kick(&j->r, &len);
                mix_free(j->drums, j->n, b0 + beat * j->beat, d, len, 0.80);
                if (beat % 2 == 1) {
                    d = snare(&j->r, &len);
                    mix_free(j->drums, j->n, b0 + beat * j->beat, d, len, 0.34);
                }
                d = hat(&j->r, &len);
                mix_free(j->drums, j->n, b0 + beat * j->beat, d, len, 0.09);
                d = hat(&j->r, &len);
                mix_free(j->drums, j->n, b0 + beat * j->beat + j->beat / 2, d,
                         len, 0.16);
            }
        }
    }
}

int sfx_music_step(sfx_music_job *j) {
    int per, len, i;
    if (!j) return 1;
    if (!j->ok || j->step >= j->steps) { j->step = j->steps; return 1; }
    per = job_per_chord(j);

    if (j->step < 4 * per) {
        job_chord(j, j->step / per, j->step % per);
    } else if (j->step == 4 * per) {
        // The turnaround: one extra snare on the last off-beat, so the last
        // bar points at the first instead of merely stopping next to it.
        double *d = snare(&j->r, &len);
        mix_free(j->drums, j->n, j->n - j->beat / 2, d, len, 0.30);

        // Sidechain. Everything but the drums ducks under each kick and comes
        // back over the beat, which is the breathing this music is mostly made
        // of. The shape repeats every beat, so it is worth computing once: the
        // pow it is built from was a twentieth of the render on its own.
        {
            double *duck = (double *)malloc((size_t)j->beat * sizeof(double));
            if (duck) {
                for (i = 0; i < j->beat; i++) {
                    double x = (double)i / j->beat;
                    duck[i] = 0.55 + 0.45 * pow(dmin(1.0, x / 0.45), 0.6);
                }
                for (i = 0; i < j->n; i++) j->v.buf[i] *= duck[i % j->beat];
                free(duck);
            }
        }
    } else {
        for (i = 0; i < j->n; i++) j->v.buf[i] += j->drums[i];
        v_drive(&j->v, 1.15);
    }
    j->step++;
    return j->step >= j->steps;
}

static void job_free(sfx_music_job *j) {
    if (!j) return;
    voice_free(&j->v);
    free(j->drums);
    free(j);
}

unsigned char *sfx_music_take(sfx_music_job *j, size_t *len) {
    unsigned char *wav = NULL;
    if (j && j->ok && j->step >= j->steps) {
        v_normalize(&j->v);              // a loop must not fade
        wav = voice_wav(&j->v, len);
    }
    job_free(j);
    return wav;
}

void sfx_music_cancel(sfx_music_job *j) { job_free(j); }

int sfx_music_count(void) { return TRACK_COUNT; }

int sfx_music_bpm(int i) {
    if (i < 0 || i >= TRACK_COUNT) return 0;
    return TRACKS[i].bpm;
}


// --- rendering -------------------------------------------------------------

typedef struct {
    const char *name;
    double dur;
    int loop;              // played end to end forever, so it must not fade
    void (*make)(voice *);
} entry;

// Length is an axis the rungs climb only as far as the arena allows. A gun
// fires every 250 ms whatever rung it is on, so a bolt that grew freely with
// the rung would start overlapping its own repeat at the top, and 155 ms
// leaves the gap that stops it. A bomb is thrown every 1.5 seconds and can
// have the room.
static const entry KIT[] = {
    {"gun0",   0.062, 0, k_gun0},
    {"gun1",   0.086, 0, k_gun1},
    {"gun2",   0.118, 0, k_gun2},
    {"gun3",   0.155, 0, k_gun3},
    {"bomb0",  0.22,  0, k_bomb0},
    {"bomb1",  0.44,  0, k_bomb1},
    {"bomb2",  0.50,  0, k_bomb2},
    {"bomb3",  0.78,  0, k_bomb3},
    {"blast0", 0.34,  0, k_blast0},
    {"blast1",  0.56,  0, k_blast1},
    {"blast2",  0.76,  0, k_blast2},
    {"blast3",  0.90,  0, k_blast3},
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
    // The soundtrack has two components and no maker. Which of the eight
    // tracks is in one changes while the game runs, so they are built through
    // sfx_music_begin rather than rendered from a name, and there are two of
    // them because a crossfade needs both tracks audible at once and a
    // component holds one buffer.
    {"music_a", 0.0,   1, NULL},
    {"music_b", 0.0,   1, NULL},
};

#define KIT_COUNT ((int)(sizeof(KIT) / sizeof(KIT[0])))

const char *const sfx_names[] = {
    "gun0", "gun1", "gun2", "gun3",
    "bomb0", "bomb1", "bomb2", "bomb3",
    "blast0", "blast1", "blast2", "blast3",
    "death", "hit", "bounce", "spawn", "prize",
    "rust", "charge", "flag", "thrust", "ui_move", "ui_go",
    "music_a", "music_b", NULL,
};

int sfx_is_loop(const char *name) {
    int i;
    for (i = 0; i < KIT_COUNT; i++) {
        if (strcmp(KIT[i].name, name) == 0) return KIT[i].loop;
    }
    return 0;
}

unsigned char *sfx_render(const char *name, size_t *len) {
    const entry *k = NULL;
    voice v;
    int i;

    for (i = 0; i < KIT_COUNT; i++) {
        if (strcmp(KIT[i].name, name) == 0) { k = &KIT[i]; break; }
    }
    // A name with no maker is a component the kit fills some other way: the
    // soundtrack, which is built a step at a time by sfx_music_step.
    if (!k || !k->make || !voice_init(&v, k->dur)) return NULL;
    k->make(&v);

    // A loop must not fade: the fade is a hole in the middle of the sound once
    // the buffer is played end to end.
    if (!k->loop) v_fade_out(&v);
    v_normalize(&v);
    return voice_wav(&v, len);
}
