#include <limits.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "sim/baseline.h"
#include "sim/pack.h"
#include "sim/sim.h"

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    static sim_map *map;
    static sim_map *decoded_map;
    static sim_settings *baseline;
    static sim_settings *decoded_settings;
    static sim_state *seed_state;
    static sim_state *state;
    static sim_state *next;
    static uint8_t snapshot[SIM_PACK_MAX];
    static uint8_t settings[SIM_SETTINGS_PACK_MAX];
    static uint8_t packed_map[SIM_MAP_PACK_MAX];
    static uint8_t scratch[SIM_MAP_PACK_MAX];
    static int snapshot_len;
    static int settings_len;
    static int map_len;
    if (!map) {
        map = malloc(sizeof *map);
        decoded_map = malloc(sizeof *decoded_map);
        baseline = malloc(sizeof *baseline);
        decoded_settings = malloc(sizeof *decoded_settings);
        seed_state = malloc(sizeof *seed_state);
        state = malloc(sizeof *state);
        next = malloc(sizeof *next);
        if (!map || !decoded_map || !baseline || !decoded_settings || !seed_state
            || !state || !next)
            abort();
        sim_map_arena(map);
        sim_settings_baseline(baseline, map);
        sim_settings_baseline(decoded_settings, map);
        sim_init(seed_state, 1);
        sim_spawn(seed_state, 0, 0, 8192, 8192, 0, baseline);
        sim_add_flag(seed_state, 8192, 8192);
        snapshot_len = sim_pack(seed_state, snapshot, sizeof snapshot);
        settings_len = sim_settings_pack(baseline, settings, sizeof settings);
        map_len = sim_map_pack(map, packed_map, sizeof packed_map);
        if (snapshot_len <= 0 || settings_len <= 0 || map_len <= 0) abort();
    }
    if (size == 0 || size - 1 > INT_MAX) return 0;

    const uint8_t *payload = data + 1;
    int len = (int)(size - 1);
    switch (data[0] % 6) {
        case 0:
        case 3: {
            const uint8_t *bytes = payload;
            int bytes_len = len;
            if (data[0] % 6 == 3) {
                memcpy(scratch, snapshot, (size_t)snapshot_len);
                for (int i = 0; i + 2 < len; i += 3) {
                    unsigned at = (unsigned)payload[i]
                                  | ((unsigned)payload[i + 1] << 8);
                    scratch[at % (unsigned)snapshot_len] = payload[i + 2];
                }
                bytes = scratch;
                bytes_len = snapshot_len;
            }
            *state = *seed_state;
            sim_state before = *state;
            if (sim_unpack(state, bytes, bytes_len) == 0)
                sim_step(next, state, NULL, 0, baseline, NULL);
            else if (memcmp(state, &before, sizeof before) != 0)
                abort();
            break;
        }
        case 1:
        case 4: {
            const uint8_t *bytes = payload;
            int bytes_len = len;
            if (data[0] % 6 == 4) {
                memcpy(scratch, settings, (size_t)settings_len);
                for (int i = 0; i + 2 < len; i += 3) {
                    unsigned at = (unsigned)payload[i]
                                  | ((unsigned)payload[i + 1] << 8);
                    scratch[at % (unsigned)settings_len] = payload[i + 2];
                }
                bytes = scratch;
                bytes_len = settings_len;
            }
            *decoded_settings = *baseline;
            sim_settings before = *decoded_settings;
            int result = sim_settings_unpack(decoded_settings, bytes, bytes_len);
            if (result != 0 && memcmp(decoded_settings, &before, sizeof before) != 0)
                abort();
            break;
        }
        default:
            if (data[0] % 6 == 5) {
                memcpy(scratch, packed_map, (size_t)map_len);
                for (int i = 0; i + 2 < len; i += 3) {
                    unsigned at = (unsigned)payload[i]
                                  | ((unsigned)payload[i + 1] << 8);
                    scratch[at % (unsigned)map_len] = payload[i + 2];
                }
                sim_map_unpack(decoded_map, scratch, map_len);
            } else {
                sim_map_unpack(decoded_map, payload, len);
            }
            break;
    }
    return 0;
}
