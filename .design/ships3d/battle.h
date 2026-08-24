/* A fight recorded by `vectorwake-server battlecap`, and the pictures made
 * from it. The positions, the rounds and the deaths in here were all produced
 * by the simulation core and the same brains the arena flies; nothing in a
 * frame was posed. */
#ifndef BATTLE_H
#define BATTLE_H

typedef struct {
    unsigned char cls, team, alive, thrust;
    int x, y;               /* Q8 px, sim space: y increases south */
    unsigned short heading; /* 1/65536 of a turn, 0 is north, clockwise */
    int energy;
} cap_ship;

typedef struct {
    unsigned char spec, team, level;
    int x, y, vx, vy;
    unsigned short life;
} cap_shot;

typedef struct {
    unsigned char type, a, b;
    int v;
} cap_ev;

typedef struct {
    int mw, mh;
    unsigned char *tile;
    unsigned char spec_kind[256];  /* 0 gun, 1 bomb, 2 mine */
    int spec_blast[256];           /* Q8 px */
    int frames;
    unsigned *tick;
    int *ship_n;
    cap_ship **ships;
    int *shot_n;
    cap_shot **shots;
    int *ev_n;
    cap_ev **evs;
} capture;

capture *cap_load(const char *path);
void cap_free(capture *c);

#define EV_FIRE 1
#define EV_BOUNCE 2
#define EV_HIT 3
#define EV_DEATH 4
#define EV_SPAWN 5
#define EV_EXPIRE 6

#endif
