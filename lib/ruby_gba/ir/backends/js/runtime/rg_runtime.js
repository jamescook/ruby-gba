/*
 * Everything the game asks of the machine it runs on that is not the picture, the sound or the
 * save memory (the native runtime's rg_runtime.c): the buttons, the timers, the end of a frame,
 * and stopping.
 *
 * The game never names a page, a canvas or a file. It calls these, and the DRIVER that started it
 * answers what only a driver can: rg_headless.js, which node runs and prints from, or rg_page.js,
 * which draws to a canvas. A driver sets rg_active_driver to an object with these:
 *
 *   halted()                   the game stopped on purpose (`halt`)
 *   dump_variable(name, value) one variable, for the driver to print if it prints
 *   dump_list(list)            one list, the same way
 *   sound_logged(line)         one line of the sound log, as it happens
 *
 * and plays the game by asking rg_game_main's generator for one frame after another (see Printer).
 */

let rg_active_driver = null;

/* The game stopped, on purpose or because it went wrong. Thrown rather than returned, so it
 * comes out of however deep in the game's routines it happened, and the driver catches it. */
class RgStopped extends Error {
  constructor(message, went_wrong) {
    super(message);
    this.went_wrong = went_wrong;
  }
}

/* The game did something the interpreter refuses: says so in +message+ and stops. A driver with
 * no window ends with RG_GAME_WENT_WRONG, so whoever started it can tell the game going wrong from
 * the program failing in its own right. */
const RG_GAME_WENT_WRONG = 3;
function rg_fault(message) { throw new RgStopped(message, true); }

/* The game stopped on purpose (`halt`). Never comes back. */
function rg_halt() { throw new RgStopped("halt", false); }

/* --- buttons --- */

const RG_ALL_BUTTONS = 0x3FF;
let rg_buttons_held = 0;   /* buttons down now, a bit each */
let rg_buttons_seen = 0;   /* ...and at the last frame boundary, to tell a press from a hold */
let rg_buttons_pressed = 0; /* buttons that went down at the last frame boundary */

/* A driver says which buttons are down at every frame boundary, a bit each in the order the
 * console's key register holds them: a, b, select, start, right, left, up, down, r, l. A button
 * counts as pressed on the one frame it goes down. */
function rg_buttons_read(now) {
  rg_buttons_held = now & RG_ALL_BUTTONS;
  rg_buttons_pressed = rg_buttons_held & ~rg_buttons_seen;
  rg_buttons_seen = rg_buttons_held;
}

/* Down before the first frame boundary and not yet seen there, so the first boundary still finds
 * them going down. */
function rg_buttons_held_from_power_on(now) { rg_buttons_held = now & RG_ALL_BUTTONS; }

/* A button's bit in +buttons+, or any of them for -1. */
function rg_button_down(buttons, button) {
  if (button < 0) return buttons !== 0 ? 1 : 0;
  return (buttons >> button) & 1;
}

function rg_held(button) { return rg_button_down(rg_buttons_held, button); }
function rg_pressed(button) { return rg_button_down(rg_buttons_pressed, button); }

/* --- the end of a frame --- */

/* The frame the game drew has ended; the game then yields, and the driver takes the frame. */
function rg_wait_vblank() { rg_screen_frame_ended(); }

/* A routine the runtime asked for an answer cannot wait for a frame: the answer is wanted now. */
function rg_wait_vblank_while_answering() {
  rg_fault("the game waited for the screen while working out an answer the picture or a timer asked for");
}

/* A routine of the game's that can wait, run to its end where nothing can wait (see Printer). */
function rg_run_now(routine) {
  if (!routine.next().done) rg_wait_vblank_while_answering();
}

/* Calls a routine picked out of an array of them. */
function rg_call_routine(routine) { routine(); }

/* --- timers (Reference @timers) --- */

const RG_MAX_TIMERS = 32;

/* One timer: whether it has ever been started, whether it is running, its rate, and how many times
 * it has ticked since it was last started, the part of a tick it is through included — a float,
 * as the interpreter keeps it, added to with the same division, so the two cross a whole tick on
 * the same frame. */
const rg_timers = [];
for (let i = 0; i < RG_MAX_TIMERS; i++) rg_timers.push({ started: 0, running: 0, ticks_a_second: 0, frames_a_second: 1, ticked: 0 });
/* The timers in the order each was first started, which is the order the interpreter walks them. */
const rg_timers_started = [];
let rg_timer_now_ticking = -1;

function rg_fault_unless_timer(timer) {
  if (timer < 0 || timer >= RG_MAX_TIMERS) rg_fault(`timer number ${timer} is not one of the ${RG_MAX_TIMERS} there is room for`);
}

function rg_timer_start(timer, ticks_a_second, frames_a_second) {
  rg_fault_unless_timer(timer);
  if (!rg_timers[timer].started) rg_timers_started.push(timer);
  rg_timers[timer] = { started: 1, running: 1, ticks_a_second, frames_a_second, ticked: 0 };
}

function rg_timer_stop(timer) {
  rg_fault_unless_timer(timer);
  rg_timers[timer].running = 0;
}

function rg_timer_ticks(timer) {
  rg_fault_unless_timer(timer);
  return rg_timers[timer].started ? Math.trunc(rg_timers[timer].ticked) % 65536 : 0;
}

function rg_timer_ticking(timer) { return timer === rg_timer_now_ticking ? 1 : 0; }

/* Reference#accrue_timer, for every running timer: a frame's worth of ticks more, and the game's
 * handler once for each whole tick crossed, how many settled before the first runs. */
function rg_timers_frame() {
  for (const number of rg_timers_started) {
    const timer = rg_timers[number];
    if (!timer.running) continue;
    const before = Math.trunc(timer.ticked);
    timer.ticked += timer.ticks_a_second / timer.frames_a_second;
    const crossed = Math.trunc(timer.ticked) - before;
    rg_timer_now_ticking = number;
    for (let tick = 0; tick < crossed; tick++) rg_game_timer_ticks();
    rg_timer_now_ticking = -1;
  }
}

/* The middle of Reference#advance_frame, in its order: the picture switched on, the timers tick,
 * then the mix, the tune, and every sounding note's shape. */
function rg_frame_begins() {
  rg_screen_frame_started();
  rg_timers_frame();
  rg_mix_frame();
  rg_music_frame();
  rg_mix_step_shapes();
}

/* --- what the game hands the driver --- */

function rg_dump_variable(name, value) { rg_active_driver.dump_variable(name, value); }
function rg_dump_list(list) { rg_active_driver.dump_list(list); }

/* The game's name, as RubyGBA.game was given it, from the bytes the lowering writes it as. */
function rg_title() {
  let text = "";
  for (let i = 0; i < rg_game_title.length && rg_game_title[i] !== 0; i++) text += String.fromCharCode(rg_game_title[i]);
  return text;
}
