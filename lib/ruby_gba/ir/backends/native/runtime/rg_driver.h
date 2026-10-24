/*
 * WHICH MACHINE THE GAME IS RUNNING ON: a window (rg_sdl.c), or no window at all (rg_headless.c).
 *
 * The game calls rg_wait_vblank, rg_held and the rest of rg_runtime.h without knowing which, and
 * rg_runtime.c hands each call to the driver chosen when the program started. That is what lets
 * the program a player runs also run with no window, scripted buttons and a printed picture —
 * the same binary the tests can drive — by starting it with --headless.
 */
#ifndef RG_DRIVER_H
#define RG_DRIVER_H

#include <stdarg.h>
#include <stdint.h>

struct rg_list;

typedef struct {
  void (*wait_vblank)(void);
  /* These two never come back (C has no way to say so of a pointer to a function). */
  void (*halt)(void);
  void (*fault)(const char *format, va_list args);
  /* One variable's name and value, which only the windowless driver has anywhere to print. */
  void (*dump_variable)(const char *name, int32_t value);
  /* One line of the sound log (rg_sound.h), as it happens; the same, only the windowless driver
   * prints it. */
  void (*sound_logged)(const char *line);
  /* One of the game's lists (rg_list.h), handed over after the variables; a driver with nowhere
   * to print it leaves this out. */
  void (*dump_list)(const struct rg_list *list);
} rg_driver;

/* The driver in use; set by whichever main() started the program. */
extern const rg_driver *rg_active_driver;

/* A driver says which buttons are down, a bit each in the order rg_runtime.h lists them, at
 * every frame boundary; a button down now and not at the last boundary is pressed for the
 * frame that is starting (rg_runtime.c works that out, the same for every driver). */
void rg_buttons_read(uint32_t held);

/* Buttons down from power-on, before the game's first statement: a driver says so before it starts
 * the game. None of them counts as pressed until the first frame boundary reads it down. */
void rg_buttons_held_from_power_on(uint32_t held);

/* WHERE THE CARTRIDGE'S CLOCK GETS ITS TIME, said by the driver before it starts the game, or not
 * at all for a cartridge with no clock. Either way the time is the date and the hour a clock
 * SAYS, with no time zone, as IR::Clock reads it.
 *
 * The windowless driver starts the clock at a moment of the test's (see #clock_at): +seconds+
 * from the start of 1970 as such a clock counts them, +ticks+ more of the console's 2^24 a second,
 * and whether the clock was ever set. From then it moves on one of the console's frames at each
 * frame boundary, as the interpreter's does, so the two agree frame by frame.
 *
 * The window says what the computer's own clock reads instead, local time, before the game
 * starts and as each frame boundary hands the game its next frame: a clock keeps real time, so a
 * game held or paused finds the time gone by when it goes on, as a cartridge switched off finds
 * its clock still counting. */
void rg_clock_starts_at(int64_t seconds, int64_t ticks, int32_t set);
void rg_clock_reads(int32_t year, int32_t month, int32_t day, int32_t hour, int32_t minute, int32_t second);

/* What every driver does as a frame begins, after deciding to play it: the picture's work for
 * the frame boundary, then one frame of the music — the interpreter's order. */
void rg_frame_begins(void);

/* The windowless driver: plays FRAMES frames under the buttons on standard input and prints
 * every frame (see rg_headless.c). Its arguments are the number of frames, then nothing:
 * argv as main() gets it, less anything that came before the number. */
int rg_headless_main(int argc, char **argv);

#endif
