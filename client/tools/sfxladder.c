// Can a pilot hear which rung fired?
//
//     make -C client/tools check
//
// The gun, the bomb and the detonation have one sound per rung, and the point
// of that is lost if two of them are one sound twice. This measures the gap, in units of
// audible difference rather than in synth parameters, and fails when a rung
// stops being its own.
//
// It is the audio half of client/tests/rung_test.lua, which does the same job
// for the colours those rounds are drawn in: a ramp is only a ramp if the
// steps can be told apart, and neither claim survives being left to taste.
//
// --- what is measured ------------------------------------------------------
//
// Each sound becomes a grid: third-octave bands down one side, hundredths of a
// second along the other, each cell the energy in that band during that
// hundredth, in dB under the loudest cell the sound has. The distance between
// two sounds is the RMS difference across the whole grid.
//
// A grid rather than one averaged spectrum, because averaging throws away two
// of the three things that separate these sounds. A rung that falls further
// differs from its neighbour in when its energy arrives, not only in where. A
// rung that rings twice as long is silent in cells where its neighbour is
// still going, which is most of what tells two detonations apart and none of
// what an average would see. Pitch, timbre and length all land in one number
// here, which is the number a listener is answering.
//
// Level does not, on purpose. Every buffer is normalised to the same peak
// before it is written and every grid to its own loudest cell, so this cannot
// be satisfied by making a rung louder. Loudness is real and it lives in the
// .sound gains; it is not what is being asked about.
//
// --- what is required ------------------------------------------------------
//
// Adjacent rungs have to differ. The ladder these replaced moved weight only,
// on the argument that a rung is the same weapon harder and so must not sound
// like a different weapon. Measured this way its steps were 2.5 to 4.5 dB
// apart and its ends 5.0 and 9.4, and what ended it was a player asking for a
// sound per rung after flying the whole ladder. So the floors sit past the
// widest step and the longer span that were not good enough, and the kit
// clears both by a decibel or more.
//
// The ladder has to climb one way. Four sounds that differ from their
// neighbours but wander up and down carry no information about which is
// heavier, so the spectral centroid falls monotonically: deeper is bigger,
// every rung.
//
// And a rung must not cross a family. A gun that has climbed far enough to be
// mistaken for a bomb is worse than a gun that all sounds the same, because
// the mistake it invites is about what is coming at you rather than about how
// hard it will land. So the nearest gun-to-bomb pair has to stay further apart
// than the widest step inside any of the ladders.

#include "../ext/simcore/src/sfx.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>

#define RATE 22050.0
#define PI 3.14159265358979323846

// Third-octave centres, 63 Hz to 10 kHz. Coarse next to a real loudness model
// and far more than enough to separate "two sounds" from "one sound twice".
static const double BAND[] = {
    63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630, 800,
    1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000,
};
#define BANDS ((int)(sizeof(BAND) / sizeof(BAND[0])))

// A hundredth of a second, and a second of them: longer than anything in any of
// the ladders, so a sound that outlasts its neighbour is measured doing it
// rather than truncated to agree with it.
#define HOP 220
#define FRAMES 100

// Where a cell counts as empty, in dB under the sound's loudest. Forty-five is
// the conservative end of what is arguably inaudible in a firefight, and
// conservative is the right direction: a deeper floor counts differences down
// in the decay tails that nobody can hear, and would make this report every
// ladder further apart than it is.
#define FLOOR (-45.0)

typedef struct {
    const char *name;
    double db[BANDS][FRAMES];
    int frames;                     // how many of them the sound reaches
    double centroid;                // Hz, over the whole sound
    double dur;                     // seconds
} grid;

// One band of a filter bank: the cookbook constant-peak bandpass, run over the
// whole sound and its output squared into frames. A bandpass rather than a
// single DFT bin because a band has a width and the energy in it is what the
// ear integrates.
static void band_energy(const double *x, int n, double f0, double q,
                        double *frame) {
    double w = 2.0 * PI * f0 / RATE;
    double alpha = sin(w) / (2.0 * q);
    double a0 = 1.0 + alpha;
    double b0 = alpha / a0, b2 = -alpha / a0;
    double a1 = -2.0 * cos(w) / a0, a2 = (1.0 - alpha) / a0;
    double x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0;
    int i;
    for (i = 0; i < FRAMES; i++) frame[i] = 0.0;
    for (i = 0; i < n; i++) {
        double y = b0 * x[i] + b2 * x2 - a1 * y1 - a2 * y2;
        int f = i / HOP;
        x2 = x1; x1 = x[i];
        y2 = y1; y1 = y;
        if (f < FRAMES) frame[f] += y * y;
    }
}

// Render one sound and reduce it to a grid. The wav the synth writes is the
// one the game plays, so this measures what a player hears rather than what
// the source says it should be.
static int measure(const char *name, grid *g) {
    unsigned char *wav;
    size_t len = 0;
    double *x, hi = 0.0, total = 0.0, num = 0.0;
    int n, b, f;

    wav = sfx_render(name, &len);
    if (!wav || len <= 44) { free(wav); return 0; }
    n = (int)((len - 44) / 2);
    x = (double *)malloc((size_t)n * sizeof(double));
    if (!x) { free(wav); return 0; }
    for (f = 0; f < n; f++) {
        int lo = wav[44 + f * 2], up = wav[45 + f * 2];
        x[f] = (double)(short)(lo | (up << 8)) / 32768.0;
    }
    free(wav);

    g->name = name;
    g->dur = n / RATE;
    g->frames = (n + HOP - 1) / HOP;
    if (g->frames > FRAMES) g->frames = FRAMES;
    for (b = 0; b < BANDS; b++) {
        double e = 0.0;
        band_energy(x, n, BAND[b], 4.3, g->db[b]);   // third-octave Q
        for (f = 0; f < FRAMES; f++) {
            if (g->db[b][f] > hi) hi = g->db[b][f];
            e += g->db[b][f];
        }
        total += e;
        num += e * BAND[b];
    }
    free(x);
    if (hi <= 0.0 || total <= 0.0) return 0;

    g->centroid = num / total;
    for (b = 0; b < BANDS; b++) {
        for (f = 0; f < FRAMES; f++) {
            // Floored, so cells with nothing in them cannot dominate a
            // distance by the depth of their own silence.
            double v = g->db[b][f] / hi;
            g->db[b][f] = v > 1e-6 ? 10.0 * log10(v) : FLOOR;
            if (g->db[b][f] < FLOOR) g->db[b][f] = FLOOR;
        }
    }
    return 1;
}

// Over the time either of them is sounding, and no longer. Averaging a bolt
// against a second of shared silence divides its difference from its
// neighbour by three, which would make the answer depend on how wide a window
// this file happens to declare.
static double distance(const grid *a, const grid *b) {
    int nf = a->frames > b->frames ? a->frames : b->frames;
    double sum = 0.0;
    int i, f;
    for (i = 0; i < BANDS; i++) {
        for (f = 0; f < nf; f++) {
            double d = a->db[i][f] - b->db[i][f];
            sum += d * d;
        }
    }
    return sqrt(sum / (BANDS * nf));
}

static double semitones(double f0, double f1) {
    return 12.0 * log2(f1 / f0);
}

// Past what the ladder that was not good enough managed, on every step.
#define ADJACENT 6.0
// The ends of a ladder are four sounds apart and should be obvious.
#define SPAN 11.0

static const char *const GUN[] = {"gun0", "gun1", "gun2", "gun3"};
static const char *const BOMB[] = {"bomb0", "bomb1", "bomb2", "bomb3"};
static const char *const BLAST[] = {"blast0", "blast1", "blast2", "blast3"};

static int fails;

static void check(const char *what, int ok, const char *detail) {
    if (ok) {
        printf("ok   %s\n", what);
    } else {
        fails++;
        printf("FAIL %s  -- %s\n", what, detail ? detail : "");
    }
}

// Every rung of one ladder: distinct from its neighbour, and deeper than it.
static double ladder(const char *family, const char *const *names, int n,
                     grid *out) {
    double widest = 0.0;
    char line[160];
    int i;

    for (i = 0; i < n; i++) {
        if (!measure(names[i], &out[i])) {
            fails++;
            printf("FAIL %s cannot be rendered\n", names[i]);
            return 0.0;
        }
        printf("     %-7s %6.0f Hz  %3.0f ms\n", names[i], out[i].centroid,
               out[i].dur * 1000.0);
    }
    for (i = 1; i < n; i++) {
        double d = distance(&out[i - 1], &out[i]);
        double st = semitones(out[i - 1].centroid, out[i].centroid);
        if (d > widest) widest = d;
        printf("     %s -> %s  %.1f dB apart, %+.1f semitones\n",
               names[i - 1], names[i], d, st);
        snprintf(line, sizeof(line), "%s rung %d is its own sound", family, i);
        check(line, d >= ADJACENT, "too near the rung below it");
        snprintf(line, sizeof(line), "%s rung %d is heavier than rung %d",
                 family, i, i - 1);
        check(line, st < 0.0, "its centroid did not fall");
    }
    {
        double d = distance(&out[0], &out[n - 1]);
        printf("     %s -> %s  %.1f dB apart end to end\n", names[0],
               names[n - 1], d);
        snprintf(line, sizeof(line), "%s ends nowhere near where it starts",
                 family);
        check(line, d >= SPAN, "the ladder is short");
    }
    return widest;
}

int main(void) {
    grid gun[4], bomb[4], blast[4];
    double widest = 0.0, near = 1e9, w;
    int i, j;

    widest = ladder("gun", GUN, 4, gun);
    w = ladder("bomb", BOMB, 4, bomb); if (w > widest) widest = w;
    w = ladder("blast", BLAST, 4, blast); if (w > widest) widest = w;

    // A rung is the same weapon harder. However far a ladder climbs, its top
    // has to stay further from the other weapon than its own rungs are from
    // each other, or the ladder has stopped being one weapon.
    {
        const char *a = "", *b = "";
        for (i = 0; i < 4; i++) {
            for (j = 0; j < 4; j++) {
                double d = distance(&gun[i], &bomb[j]);
                if (d < near) { near = d; a = GUN[i]; b = BOMB[j]; }
            }
        }
        printf("     nearest gun to bomb %.1f dB (%s, %s), "
               "widest rung step %.1f dB\n", near, a, b, widest);
    }
    check("no rung crosses from gun to bomb", near > widest,
          "a gun and a bomb are nearer than two rungs of one ladder");

    printf("%s\n", fails == 0 ? "ALL PASS" : "FAILED");
    return fails == 0 ? 0 : 1;
}
