/*
 * Everything the generated game asks of the machine it runs on, and the two things the
 * machine asks of the game.
 *
 * The generated C (game.c) never names SDL, a window or a file. It calls these, and one of two
 * hand-written runtimes answers them: rg_sdl.c, which opens a window, reads the keyboard and
 * plays sound, and rg_headless.c, which has no window at all and is what the tests run. The
 * same game.c links against either.
 */
#ifndef RG_RUNTIME_H
#define RG_RUNTIME_H

#include <stdint.h>

/* --- what the game provides --- */

/* The whole program, from power-on. The runtime calls it once. A game with a game loop never
 * comes back from it; the runtime ends the run from inside rg_wait_vblank or rg_halt. */
void rg_game_main(void);

/* Hands every variable the game keeps to rg_dump_variable, by its Ruby name. */
void rg_game_dump_variables(void);

/* --- what the runtime provides --- */

/* The end of a frame: the picture is shown, the buttons are read, and the game waits for the
 * next frame. The console calls this moment the vertical blank, which is where the name comes
 * from. A run that has played all the frames it was asked for ends here. */
void rg_wait_vblank(void);

/* The game stopped on purpose (`halt`). Never comes back. */
_Noreturn void rg_halt(void);

/* The game did something the interpreter refuses (pushed onto a full list, read past the end
 * of one): says so, in the words given printf-style, and stops. Never comes back. */
_Noreturn void rg_fault(const char *format, ...) __attribute__((format(printf, 1, 2)));

/* Whether a button is down (held), or went down since the last frame (pressed): 1 or 0. The
 * buttons are numbered in the order the console's key register holds them — a, b, select,
 * start, right, left, up, down, r, l — and -1 means any of them. */
int32_t rg_held(int32_t button);
int32_t rg_pressed(int32_t button);

/* One variable's name and value, for whatever the runtime does with them (the headless one
 * prints them, so a test can compare them with the interpreter's). */
void rg_dump_variable(const char *name, int32_t value);

/* Calls a routine picked out of an array of them. Its own function so the generated C names
 * every call the same way. */
static inline void rg_call_routine(void (*routine)(void)) { routine(); }

#endif
