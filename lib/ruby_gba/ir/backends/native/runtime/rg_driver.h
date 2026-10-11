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

typedef struct {
  void (*wait_vblank)(void);
  /* These two never come back (C has no way to say so of a pointer to a function). */
  void (*halt)(void);
  void (*fault)(const char *format, va_list args);
  /* The buttons down now, and the ones that went down at the last frame boundary, a bit
   * each in the order rg_runtime.h lists them. */
  uint32_t (*held)(void);
  uint32_t (*pressed)(void);
  /* One variable's name and value, which only the windowless driver has anywhere to print. */
  void (*dump_variable)(const char *name, int32_t value);
} rg_driver;

/* The driver in use; set by whichever main() started the program. */
extern const rg_driver *rg_active_driver;

/* The windowless driver: plays FRAMES frames under the buttons on standard input and prints
 * every frame (see rg_headless.c). Its arguments are argv as main() gets it, without the
 * --headless that chose it. */
int rg_headless_main(int argc, char **argv);

#endif
