/*
 * What rg_runtime.h promises the game, handed to the driver that started the program (see
 * rg_driver.h). Nothing here knows whether there is a window.
 */
#include <stdlib.h>
#include "rg_runtime.h"
#include "rg_driver.h"
#include "rg_screen.h"
#include "rg_sound.h"

const rg_driver *rg_active_driver;

#define ALL_BUTTONS 0x3FFu

static uint32_t held;    /* buttons down now, a bit each */
static uint32_t seen;    /* ...and at the last frame boundary, to tell a press from a hold */
static uint32_t pressed; /* buttons that went down at the last frame boundary */

/* A button counts as pressed on the one frame it goes down, however long it is then held — the
 * edge the interpreter's read_buttons finds. */
void rg_buttons_read(uint32_t now) {
  held = now & ALL_BUTTONS;
  pressed = held & ~seen;
  seen = held;
}

/* The frame the game drew has ended, whoever is driving and whether or not the run stops here. */
void rg_wait_vblank(void) {
  rg_screen_frame_ended();
  rg_active_driver->wait_vblank();
}

/* --- timers (Reference @timers) --- */

/* One timer: whether it has ever been started, whether it is running, its rate, and how many
 * times it has ticked since it was last started, the part of a tick it is through included. The
 * interpreter keeps that count as Ruby's Float, which is this machine's double, and adds to it
 * with the same division, so the two cross a whole tick on the same frame. */
typedef struct { int32_t started, running, ticks_a_second, frames_a_second; double ticked; } game_timer;
static game_timer timers[RG_MAX_TIMERS];

/* The timers in the order each was first started, which is the order the interpreter walks them
 * in (the order its Hash got them). */
static int32_t timers_started[RG_MAX_TIMERS];
static int32_t timers_started_count;

enum { NO_TIMER = -1 };
static int32_t ticking = NO_TIMER;

static void fault_unless_timer(int32_t timer) {
  if (timer < 0 || timer >= RG_MAX_TIMERS) rg_fault("timer number %d is not one of the %d there is room for", (int)timer, RG_MAX_TIMERS);
}

/* Reference#exec_timer_start */
void rg_timer_start(int32_t timer, int32_t ticks_a_second, int32_t frames_a_second) {
  fault_unless_timer(timer);
  if (!timers[timer].started) timers_started[timers_started_count++] = timer;
  timers[timer] = (game_timer){1, 1, ticks_a_second, frames_a_second, 0.0};
}

/* Reference#exec_timer_stop: a timer never started has nothing to stop. */
void rg_timer_stop(int32_t timer) {
  fault_unless_timer(timer);
  timers[timer].running = 0;
}

/* Reference#timer_ticks */
int32_t rg_timer_ticks(int32_t timer) {
  fault_unless_timer(timer);
  return timers[timer].started ? (int32_t)((int64_t)timers[timer].ticked % 65536) : 0;
}

int32_t rg_timer_ticking(int32_t timer) { return timer == ticking; }

/* Reference#accrue_timer, for every running timer: a frame's worth of ticks more, and the game's
 * handler once for each whole tick crossed. How many that is is settled before the first of them
 * runs, so a handler that stops its own timer, or starts it again, still finishes the ticks this
 * frame crossed. */
static void timers_frame(void) {
  for (int32_t i = 0; i < timers_started_count; i++) {
    game_timer *timer = &timers[timers_started[i]];
    if (!timer->running) continue;
    int64_t before = (int64_t)timer->ticked;
    timer->ticked += (double)timer->ticks_a_second / timer->frames_a_second;
    int64_t crossed = (int64_t)timer->ticked - before;
    ticking = timers_started[i];
    for (int64_t tick = 0; tick < crossed; tick++) rg_game_timer_ticks();
    ticking = NO_TIMER;
  }
}

/* The middle of Reference#advance_frame, in its order: the picture is switched on, the timers
 * tick, and then the music moves on. */
void rg_frame_begins(void) {
  rg_screen_frame_started();
  timers_frame();
  rg_music_frame();
}

/* A driver's halt and fault never come back; abort() is only there to say so to the compiler. */
_Noreturn void rg_halt(void) {
  rg_active_driver->halt();
  abort();
}

_Noreturn void rg_fault(const char *format, ...) {
  va_list args;
  va_start(args, format);
  rg_active_driver->fault(format, args);
  va_end(args);
  abort();
}

void rg_dump_variable(const char *name, int32_t value) { rg_active_driver->dump_variable(name, value); }

/* A button's bit in +buttons+, or any of them for -1. */
static int32_t button_down(uint32_t buttons, int32_t button) {
  if (button < 0) return buttons != 0;
  return (int32_t)((buttons >> button) & 1u);
}

int32_t rg_held(int32_t button) { return button_down(held, button); }
int32_t rg_pressed(int32_t button) { return button_down(pressed, button); }
