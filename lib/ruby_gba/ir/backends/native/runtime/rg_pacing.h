/*
 * WHAT PACES THE WINDOW'S FRAMES: the monitor, or the console's own clock.
 *
 * The console draws a frame every 280,896 ticks of a clock running at 2^24 ticks a second, which
 * is a little under sixty frames a second, and a game is written to that pace. A monitor shows a
 * new picture only when it refreshes, and almost none refreshes at exactly the console's rate.
 * Timing the frames from the console's clock on a monitor that is very nearly as fast, sixty a
 * second say, lets the two drift past each other: for a stretch every few seconds a picture is
 * finished just before or just after a refresh, by chance, so some pictures are shown twice and
 * some never. A game that slides its whole screen at a steady speed shows that as a stutter.
 *
 * So where the monitor's rate is very nearly a WHOLE NUMBER of the console's — sixty a second,
 * a hundred and twenty, two hundred and forty, and the rates television left behind just under
 * each — the monitor paces the game instead: each picture is shown for that whole number of
 * refreshes, and the game runs faster or slower by however much the two rates differ, which at
 * sixty a second is about half a percent. The sound is played that much faster too, or the game
 * would make more of it than is played.
 *
 * Any other monitor (seventy-five a second, a hundred and forty-four) cannot show the console's
 * frames evenly whatever is done: each picture is up for two refreshes, or three, as they fall.
 * Those keep the console's clock, which at least keeps the game at its own speed. A picture
 * still WAITS FOR A REFRESH there, so that the monitor never shows the top of one picture over
 * the bottom of the one before — but only on a monitor faster than the console, where the wait
 * is shorter than a frame. On a slower one (fifty a second) the wait would hold the game back to
 * the monitor's pace, and a monitor that does not say its rate could be either, so those are
 * handed each picture as it is finished.
 *
 * This is a file of its own, with nothing of SDL in it, so the choice can be tested as plain
 * arithmetic (test_native_pacing.rb).
 */
#ifndef RG_PACING_H
#define RG_PACING_H

#include <stdint.h>

#define RG_CONSOLE_TICKS_A_SECOND 16777216
#define RG_CONSOLE_TICKS_A_FRAME 280896
#define RG_CONSOLE_FRAMES_A_SECOND ((double)RG_CONSOLE_TICKS_A_SECOND / RG_CONSOLE_TICKS_A_FRAME)

/* The pictures a second a monitor may pace the game at: either side of the console's own rate
 * by no more than a player would notice in a game's speed or hear in its pitch. */
#define RG_PACED_SLOWEST 59.0
#define RG_PACED_FASTEST 61.0

/* The most refreshes one picture is shown for. No monitor is faster than this many times the
 * console's rate, so a rate past it is a monitor reporting nonsense. */
#define RG_MOST_REFRESHES_A_PICTURE 16

typedef struct {
  int refreshes;         /* how many of the monitor's refreshes each picture is shown for; 0 when the console's clock paces */
  int waits_for_refresh; /* 1 when a picture handed to the display waits for the monitor's next refresh */
  double speed;          /* how fast the game then runs: 1.0 is the console's own rate */
} rg_pacing;

/* The pacing for a monitor that refreshes +refreshes_a_second+ times a second; nought, or less,
 * is a monitor that does not say. */
static inline rg_pacing rg_pacing_for(double refreshes_a_second) {
  const rg_pacing unwaited = {0, 0, 1.0};
  if (!(refreshes_a_second >= RG_PACED_SLOWEST)) return unwaited;
  if (refreshes_a_second > RG_PACED_FASTEST * RG_MOST_REFRESHES_A_PICTURE) return unwaited;

  int refreshes = (int)(refreshes_a_second / RG_CONSOLE_FRAMES_A_SECOND + 0.5);
  double pictures_a_second = refreshes_a_second / refreshes;
  if (pictures_a_second < RG_PACED_SLOWEST || pictures_a_second > RG_PACED_FASTEST) {
    /* A rate that reaches here is at least the slowest paced one and is not paced, so it is past
     * the fastest: a monitor faster than the console. */
    return (rg_pacing){0, 1, 1.0};
  }
  return (rg_pacing){refreshes, 1, pictures_a_second / RG_CONSOLE_FRAMES_A_SECOND};
}

/*
 * A CLOCK STANDS BEHIND THE MONITOR. Showing a picture comes straight back, without waiting for
 * a refresh, while the window is hidden or minimised, and a game must never run as fast as the
 * computer can go. So where the monitor paces the frames the game is also held to a pace of the
 * window's own: a shade faster than the monitor's frames, so that it never holds back a game the
 * monitor is holding, and with a few frames let through at once. Those few matter. Showing a
 * picture does not always wait for the very next refresh: a display may take a few pictures into
 * a queue first and only then start holding the game to its pace, and a limit with no slack
 * would keep that queue from ever filling, so the monitor would never get to pace anything.
 */
#define RG_FASTEST_PERCENT_OVER_MONITOR 1
#define RG_FRAMES_LET_THROUGH 4

/* One frame at that fastest pace, in nanoseconds, for a game the monitor paces. */
static inline uint64_t rg_fastest_frame_ns(rg_pacing pacing) {
  double monitor_frame_ns = 1000000000.0 / (RG_CONSOLE_FRAMES_A_SECOND * pacing.speed);
  return (uint64_t)(monitor_frame_ns * 100.0 / (100 + RG_FASTEST_PERCENT_OVER_MONITOR));
}

/* The moment before which the next frame may not begin. +earliest+ is that moment as it stood a
 * frame ago (nought before the first) and +now+ is when this frame ended; the game waits for the
 * moment given back when it is still to come. Running slower than the limit earns no more than
 * the few frames let through, however long for. */
static inline uint64_t rg_earliest_next_frame(uint64_t earliest, uint64_t now, uint64_t fastest_frame_ns) {
  uint64_t let_through = RG_FRAMES_LET_THROUGH * fastest_frame_ns;
  earliest += fastest_frame_ns;
  return earliest + let_through < now ? now - let_through : earliest;
}

#endif
