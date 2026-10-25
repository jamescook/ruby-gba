/*
 * What rg_runtime.h promises the game, handed to the driver that started the program (see
 * rg_driver.h). Nothing here knows whether there is a window.
 */
#include <stdlib.h>
#include "rg_runtime.h"
#include "rg_driver.h"
#include "rg_mix.h"
#include "rg_pacing.h"
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

/* Down before the first frame boundary and not yet seen there, so the first boundary still finds
 * them going down — the interpreter's hold, and the console's keys from power-on. */
void rg_buttons_held_from_power_on(uint32_t now) { held = now & ALL_BUTTONS; }

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

/* --- the cartridge's clock (Reference#value_of_clock) --- */

/* The readings in IR::Clock::READINGS's order, which is the number the game asks by. Nothing ties
 * the two together but the native run of test_clock.rb, which reads every one of them. */
enum { CLOCK_HOUR, CLOCK_MINUTE, CLOCK_SECOND, CLOCK_YEAR, CLOCK_MONTH, CLOCK_DAY, CLOCK_WEEKDAY, CLOCK_PRESENT, CLOCK_SET };

#define SECONDS_A_DAY 86400

static int32_t clock_present;
static int32_t clock_set;
static int32_t clock_counts_frames; /* moved on a frame at each boundary, rather than told the time */
static int64_t clock_seconds;       /* the time now, as seconds from the start of 1970... */
static int64_t clock_ticks;         /* ...and the console's ticks into the next second */

void rg_clock_starts_at(int64_t seconds, int64_t ticks, int32_t set) {
  clock_present = 1;
  clock_set = set != 0;
  clock_counts_frames = 1;
  clock_seconds = seconds;
  clock_ticks = ticks;
}

/* Division that rounds down rather than towards nothing, so a moment before 1970 lands on the
 * day it is in. */
static int64_t floor_div(int64_t a, int64_t b) { return a / b - (a % b != 0 && (a < 0) != (b < 0)); }

/* The days from the start of 1970 to a date, and back. A calendar of plain arithmetic rather than
 * the C library's, which would bring the computer's time zone into it: every fourth year a leap
 * year, but not every hundredth, but every four hundredth. The year is counted from March, so
 * the leap day falls at the end of it, and the counting goes in whole 400-year cycles, which
 * always hold the same number of days. */
static int64_t days_from_date(int64_t year, int64_t month, int64_t day) {
  year -= month <= 2;
  int64_t era = floor_div(year, 400);
  int64_t year_of_era = year - era * 400;
  int64_t day_of_year = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1;
  int64_t day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
  return era * 146097 + day_of_era - 719468;
}

static void date_from_days(int64_t days, int64_t *year, int32_t *month, int32_t *day) {
  days += 719468;
  int64_t era = floor_div(days, 146097);
  int64_t day_of_era = days - era * 146097;
  int64_t year_of_era = (day_of_era - day_of_era / 1460 + day_of_era / 36524 - day_of_era / 146096) / 365;
  int64_t day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
  int64_t from_march = (5 * day_of_year + 2) / 153;
  *day = (int32_t)(day_of_year - (153 * from_march + 2) / 5 + 1);
  *month = (int32_t)(from_march < 10 ? from_march + 3 : from_march - 9);
  *year = year_of_era + era * 400 + (*month <= 2);
}

void rg_clock_reads(int32_t year, int32_t month, int32_t day, int32_t hour, int32_t minute, int32_t second) {
  clock_present = 1;
  clock_set = 1;
  clock_counts_frames = 0;
  clock_seconds = days_from_date(year, month, day) * SECONDS_A_DAY + hour * 3600 + minute * 60 + second;
  clock_ticks = 0;
}

/* A frame of the console's later: 280,896 of its ticks, a little more than a sixtieth of a
 * second. */
static void clock_frame(void) {
  if (!clock_counts_frames) return;
  clock_ticks += RG_CONSOLE_TICKS_A_FRAME;
  clock_seconds += clock_ticks / RG_CONSOLE_TICKS_A_SECOND;
  clock_ticks %= RG_CONSOLE_TICKS_A_SECOND;
}

int32_t rg_clock_reading(int32_t reading, int32_t offset_days, int32_t offset_seconds) {
  if (!clock_present) return 0;
  if (reading == CLOCK_PRESENT) return 1;
  if (!clock_set) return 0;
  if (reading == CLOCK_SET) return 1;

  int64_t now = clock_seconds + (int64_t)offset_days * SECONDS_A_DAY + offset_seconds;
  int64_t days = floor_div(now, SECONDS_A_DAY);
  int64_t into_day = now - days * SECONDS_A_DAY;
  int64_t year;
  int32_t month, day;
  date_from_days(days, &year, &month, &day);
  switch (reading) {
  case CLOCK_HOUR: return (int32_t)(into_day / 3600);
  case CLOCK_MINUTE: return (int32_t)(into_day / 60 % 60);
  case CLOCK_SECOND: return (int32_t)(into_day % 60);
  case CLOCK_YEAR: return (int32_t)year;
  case CLOCK_MONTH: return month;
  case CLOCK_DAY: return day;
  case CLOCK_WEEKDAY: return (int32_t)(days + 4 - floor_div(days + 4, 7) * 7); /* 1 January 1970 was a Thursday */
  default: rg_fault("the clock has no reading numbered %d", (int)reading);
  }
}

/* SETTING THE CLOCK (Reference#exec_set_clock): how far the time set is from the clock's own, to
 * the whole second, in days and the seconds left over, kept here until the game takes the two
 * parts into its saved numbers (rg_clock_kept_days and rg_clock_kept_seconds). The clock itself is never changed — in a
 * window it is the computer's — and from then on it reads as set. */
static int32_t clock_kept_days;
static int32_t clock_kept_seconds;

void rg_clock_set_to(int32_t year, int32_t month, int32_t day, int32_t hour, int32_t minute, int32_t second) {
  if (!clock_present) return;
  int64_t today = floor_div(clock_seconds, SECONDS_A_DAY);
  int64_t days = days_from_date(year, month, day) - today;
  int64_t seconds = hour * 3600 + minute * 60 + second - (clock_seconds - today * SECONDS_A_DAY);
  if (seconds < 0) {
    seconds += SECONDS_A_DAY;
    days -= 1;
  }
  clock_kept_days = (int32_t)days;
  clock_kept_seconds = (int32_t)seconds;
  clock_set = 1;
}

/* The days and the seconds rg_clock_set_to kept — or +current+, the game's own number as it was,
 * with no clock to have set. */
int32_t rg_clock_kept_days(int32_t current) { return clock_present ? clock_kept_days : current; }
int32_t rg_clock_kept_seconds(int32_t current) { return clock_present ? clock_kept_seconds : current; }

/* The middle of Reference#advance_frame, in its order: the picture is switched on, the timers
 * tick, and then the music moves on. */
void rg_frame_begins(void) {
  rg_screen_frame_started();
  timers_frame();
  /* The interpreter's order (Reference#advance_frame): the mix, then the tune, then every
   * sounding note's shape, and then the frame is counted, which moves a clock started at a
   * test's moment. */
  rg_mix_frame();
  rg_music_frame();
  rg_mix_step_shapes();
  clock_frame();
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

void rg_dump_list(const struct rg_list *list) {
  if (rg_active_driver->dump_list) rg_active_driver->dump_list(list);
}

/* A button's bit in +buttons+, or any of them for -1. */
static int32_t button_down(uint32_t buttons, int32_t button) {
  if (button < 0) return buttons != 0;
  return (int32_t)((buttons >> button) & 1u);
}

int32_t rg_held(int32_t button) { return button_down(held, button); }
int32_t rg_pressed(int32_t button) { return button_down(pressed, button); }
