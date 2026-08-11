/* Write a built-in arena out as a map file.
 *
 * A zone operator needs somewhere to start: this produces the reference
 * rooms in the same format the server loads and the client decodes, so a map
 * can be edited, or replaced wholesale, without rebuilding anything. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "sim/pack.h"
#include "sim/sim.h"

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <arena|pit> <out.vwmap>\n", argv[0]);
        return 2;
    }
    sim_map *m = malloc(sizeof *m);
    if (!m) return 1;
    if (strcmp(argv[1], "pit") == 0) sim_map_pit(m);
    else sim_map_arena(m);

    uint8_t *buf = malloc(SIM_MAP_PACK_MAX);
    int n = sim_map_pack(m, buf, SIM_MAP_PACK_MAX);
    if (n < 0) {
        fprintf(stderr, "pack failed\n");
        return 1;
    }
    FILE *f = fopen(argv[2], "wb");
    if (!f) {
        perror(argv[2]);
        return 1;
    }
    fwrite(buf, 1, (size_t)n, f);
    fclose(f);
    printf("%s: %d bytes, hash %08x, %u features\n", argv[2], n,
           sim_map_hash(m), m->feature_count);
    free(buf);
    free(m);
    return 0;
}
