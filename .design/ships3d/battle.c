#include "battle.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    const unsigned char *p;
    size_t n, i;
    int bad;
} rd;

static unsigned char u8(rd *r) {
    if (r->i + 1 > r->n) { r->bad = 1; return 0; }
    return r->p[r->i++];
}

static unsigned short u16(rd *r) {
    unsigned short v;
    if (r->i + 2 > r->n) { r->bad = 1; return 0; }
    v = (unsigned short)(r->p[r->i] | (r->p[r->i + 1] << 8));
    r->i += 2;
    return v;
}

static unsigned u32(rd *r) {
    unsigned v;
    if (r->i + 4 > r->n) { r->bad = 1; return 0; }
    v = (unsigned)r->p[r->i] | ((unsigned)r->p[r->i + 1] << 8)
      | ((unsigned)r->p[r->i + 2] << 16) | ((unsigned)r->p[r->i + 3] << 24);
    r->i += 4;
    return v;
}

static int i32(rd *r) { return (int)u32(r); }

capture *cap_load(const char *path) {
    FILE *f = fopen(path, "rb");
    unsigned char *buf;
    long len;
    capture *c;
    rd r;
    int i, s;
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    len = ftell(f);
    fseek(f, 0, SEEK_SET);
    buf = malloc((size_t)len);
    if (!buf || fread(buf, 1, (size_t)len, f) != (size_t)len) {
        fclose(f);
        free(buf);
        return NULL;
    }
    fclose(f);
    r.p = buf;
    r.n = (size_t)len;
    r.i = 0;
    r.bad = 0;
    if (len < 6 || memcmp(buf, "VWCAP1", 6)) { free(buf); return NULL; }
    r.i = 6;
    c = calloc(1, sizeof *c);
    c->mw = u16(&r);
    c->mh = u16(&r);
    c->tile = malloc((size_t)c->mw * c->mh);
    if (r.i + (size_t)c->mw * c->mh > r.n) { free(buf); free(c->tile); free(c); return NULL; }
    memcpy(c->tile, buf + r.i, (size_t)c->mw * c->mh);
    r.i += (size_t)c->mw * c->mh;
    s = u8(&r);
    for (i = 0; i < s; i++) {
        c->spec_kind[i] = u8(&r);
        c->spec_blast[i] = i32(&r);
    }
    c->frames = (int)u32(&r);
    c->tick = malloc((size_t)c->frames * sizeof *c->tick);
    c->ship_n = malloc((size_t)c->frames * sizeof *c->ship_n);
    c->ships = malloc((size_t)c->frames * sizeof *c->ships);
    c->shot_n = malloc((size_t)c->frames * sizeof *c->shot_n);
    c->shots = malloc((size_t)c->frames * sizeof *c->shots);
    c->ev_n = malloc((size_t)c->frames * sizeof *c->ev_n);
    c->evs = malloc((size_t)c->frames * sizeof *c->evs);
    for (i = 0; i < c->frames && !r.bad; i++) {
        int k, n;
        c->tick[i] = u32(&r);
        n = u8(&r);
        c->ship_n[i] = n;
        c->ships[i] = malloc((size_t)(n ? n : 1) * sizeof **c->ships);
        for (k = 0; k < n; k++) {
            cap_ship *sh = &c->ships[i][k];
            sh->cls = u8(&r);
            sh->team = u8(&r);
            sh->alive = u8(&r);
            sh->thrust = u8(&r);
            sh->x = i32(&r);
            sh->y = i32(&r);
            sh->heading = u16(&r);
            sh->energy = i32(&r);
        }
        n = u16(&r);
        c->shot_n[i] = n;
        c->shots[i] = malloc((size_t)(n ? n : 1) * sizeof **c->shots);
        for (k = 0; k < n; k++) {
            cap_shot *w = &c->shots[i][k];
            w->spec = u8(&r);
            w->team = u8(&r);
            w->level = u8(&r);
            w->x = i32(&r);
            w->y = i32(&r);
            w->vx = i32(&r);
            w->vy = i32(&r);
            w->life = u16(&r);
        }
        n = u8(&r);
        c->ev_n[i] = n;
        c->evs[i] = malloc((size_t)(n ? n : 1) * sizeof **c->evs);
        for (k = 0; k < n; k++) {
            cap_ev *e = &c->evs[i][k];
            e->type = u8(&r);
            e->a = u8(&r);
            e->b = u8(&r);
            e->v = i32(&r);
        }
    }
    if (r.bad) c->frames = i > 0 ? i - 1 : 0;
    free(buf);
    return c;
}

void cap_free(capture *c) {
    int i;
    if (!c) return;
    for (i = 0; i < c->frames; i++) {
        free(c->ships[i]);
        free(c->shots[i]);
        free(c->evs[i]);
    }
    free(c->tick);
    free(c->ship_n);
    free(c->ships);
    free(c->shot_n);
    free(c->shots);
    free(c->ev_n);
    free(c->evs);
    free(c->tile);
    free(c);
}
