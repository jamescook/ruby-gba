/*
 * Asks runtime/rg_pacing.h its two questions, a line of standard input each. See
 * test_native_pacing.rb.
 *
 *   monitor RATE   how the window paces its frames on a monitor refreshing RATE times a second:
 *                  prints how many refreshes a picture is shown for, whether a picture waits for
 *                  a refresh, and how fast the game then runs
 *
 *   frames RATE LEGS GAP COUNT [GAP COUNT ...]
 *                  plays one run of frames on such a monitor, in LEGS legs one after another:
 *                  COUNT frames, each coming round GAP nanoseconds after the one before unless
 *                  the limit on the game's speed holds it longer. Prints how many frames of each
 *                  leg the limit held, and then how long the whole run took
 */
#include <inttypes.h>
#include <stdio.h>
#include <string.h>
#include "rg_pacing.h"

int main(void) {
  char question[16];
  double refreshes_a_second;
  while (scanf("%15s %lf", question, &refreshes_a_second) == 2) {
    rg_pacing pacing = rg_pacing_for(refreshes_a_second);
    if (strcmp(question, "monitor") == 0) {
      printf("%d %d %.9f\n", pacing.refreshes, pacing.waits_for_refresh, pacing.speed);
      continue;
    }

    int legs;
    if (scanf("%d", &legs) != 1) return 1;
    uint64_t started = 1000000000u, now = started, earliest = 0;
    for (int leg = 0; leg < legs; leg++) {
      uint64_t gap, count, held = 0;
      if (scanf("%" SCNu64 " %" SCNu64, &gap, &count) != 2) return 1;
      for (uint64_t frame = 0; frame < count; frame++) {
        now += gap;
        earliest = rg_earliest_next_frame(earliest, now, rg_fastest_frame_ns(pacing));
        if (earliest <= now) continue;
        held++;
        now = earliest;
      }
      printf("%" PRIu64 " ", held);
    }
    printf("%" PRIu64 "\n", now - started);
  }
  return 0;
}
