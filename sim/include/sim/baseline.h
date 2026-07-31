/* Baseline tuning for the eight classes. See src/baseline.c. */
#ifndef SIM_BASELINE_H
#define SIM_BASELINE_H

#include "sim/sim.h"

extern const char *const sim_class_names[SIM_MAX_CLASSES];

/* Fill cfg with the baseline tuning for every class. */
void sim_settings_baseline(sim_settings *cfg, const sim_map *map);

#endif
