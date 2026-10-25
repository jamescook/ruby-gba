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

/* --- tables --- */

/* A table of the game's numbers, written into the file as base64 (see Printer#print_const_array)
 * and made into a typed array of +Type+ when the script starts. JavaScript's own. A big game
 * carries millions of numbers — its maps, its pictures, its sound — and written as an array
 * literal each one is a piece of code for the browser to read and build, which runs a browser out
 * of memory before the game starts. A string is one piece however long it is. The bytes are
 * little-endian, read so on any machine; atob passes over the line breaks that keep the file
 * scrollable. */
function rg_table_from_base64(Type, text) {
  const raw = atob(text);
  const bytes = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
  return rg_table_from_bytes(Type, bytes, 0, bytes.length / Type.BYTES_PER_ELEMENT);
}

/* +count+ numbers of +Type+ from +bytes+ (a Uint8Array), starting +at+ that many bytes in: a table
 * written as base64, or one of the tables in a game's data file (see JS::Printer#data_file). */
function rg_table_from_bytes(Type, bytes, at, count) {
  const view = new DataView(bytes.buffer, bytes.byteOffset + at, count * Type.BYTES_PER_ELEMENT);
  const read = { Int8Array: "getInt8", Uint8Array: "getUint8", Int16Array: "getInt16", Uint16Array: "getUint16",
                 Int32Array: "getInt32" }[Type.name];
  const table = new Type(count);
  for (let i = 0; i < count; i++) table[i] = view[read](i * Type.BYTES_PER_ELEMENT, true);
  return table;
}

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

/* One timer: whether it has ever been started, whether it is running, its rate, and how far it has
 * ticked since it was last started, in frames_a_second-ths of a tick — whole numbers, as the
 * interpreter keeps them (Reference#accrue_timer), so the two cross a whole tick on the same frame.
 * A JavaScript number holds a whole number exactly far past any count a game reaches, and the
 * division below is then exact too. */
const rg_timers = [];
for (let i = 0; i < RG_MAX_TIMERS; i++) rg_timers.push({ started: 0, running: 0, ticks_a_second: 0, frames_a_second: 1, parts: 0 });
function rg_timer_whole_ticks(timer) { return Math.floor(timer.parts / timer.frames_a_second); }
/* The timers in the order each was first started, which is the order the interpreter walks them. */
const rg_timers_started = [];
let rg_timer_now_ticking = -1;

function rg_fault_unless_timer(timer) {
  if (timer < 0 || timer >= RG_MAX_TIMERS) rg_fault(`timer number ${timer} is not one of the ${RG_MAX_TIMERS} there is room for`);
}

function rg_timer_start(timer, ticks_a_second, frames_a_second) {
  rg_fault_unless_timer(timer);
  if (!rg_timers[timer].started) rg_timers_started.push(timer);
  rg_timers[timer] = { started: 1, running: 1, ticks_a_second, frames_a_second, parts: 0 };
}

function rg_timer_stop(timer) {
  rg_fault_unless_timer(timer);
  rg_timers[timer].running = 0;
}

function rg_timer_ticks(timer) {
  rg_fault_unless_timer(timer);
  return rg_timers[timer].started ? rg_timer_whole_ticks(rg_timers[timer]) % 65536 : 0;
}

function rg_timer_ticking(timer) { return timer === rg_timer_now_ticking ? 1 : 0; }

/* Reference#accrue_timer, for every running timer: a frame's worth of ticks more, and the game's
 * handler once for each whole tick crossed, how many settled before the first runs. */
function rg_timers_frame() {
  for (const number of rg_timers_started) {
    const timer = rg_timers[number];
    if (!timer.running) continue;
    const before = rg_timer_whole_ticks(timer);
    timer.parts += timer.ticks_a_second;
    const crossed = rg_timer_whole_ticks(timer) - before;
    rg_timer_now_ticking = number;
    for (let tick = 0; tick < crossed; tick++) rg_game_timer_ticks();
    rg_timer_now_ticking = -1;
  }
}

/* The middle of Reference#advance_frame, in its order: the picture switched on, the timers tick,
 * then the mix, the tune, and every sounding note's shape, and then the frame is counted, which
 * moves a clock started at a test's moment. */
function rg_frame_begins() {
  rg_screen_frame_started();
  rg_timers_frame();
  rg_mix_frame();
  rg_music_frame();
  rg_mix_step_shapes();
  rg_clock_frame();
}

/* --- the cartridge's clock (Reference#value_of_clock) --- */

/* The readings in IR::Clock::READINGS's order, which is the number the game asks by. Nothing ties
 * the two together but the JavaScript runs of test_clock.rb and test_clock_set.rb, which read every one
 * of them. The last three are the clock's count, which a game that sets the clock keeps its time
 * from: days since 2000-01-01, seconds into the day, and whether it counted on (IR::Clock::COUNT). */
const RG_CLOCK_HOUR = 0, RG_CLOCK_MINUTE = 1, RG_CLOCK_SECOND = 2, RG_CLOCK_YEAR = 3, RG_CLOCK_MONTH = 4, RG_CLOCK_DAY = 5,
  RG_CLOCK_WEEKDAY = 6, RG_CLOCK_PRESENT = 7, RG_CLOCK_SET = 8, RG_CLOCK_DAYS = 9, RG_CLOCK_SECONDS = 10,
  RG_CLOCK_COUNTING = 11;

/* From 1 January 1970, where the clock's seconds count from, to 1 January 2000. */
const RG_DAYS_TO_2000 = 10957;

const RG_SECONDS_A_DAY = 86400;

/* Whether there is a clock and it was set; whether it moves on a frame at each boundary rather
 * than being told the time; and the time now, as seconds from the start of 1970 and the console's
 * ticks into the next second. Every one a whole number well inside what a JavaScript number holds
 * exactly. */
let rg_clock_present = 0;
let rg_clock_set = 0;
let rg_clock_counts_frames = 0;
let rg_clock_seconds = 0;
let rg_clock_ticks = 0;

/* The windowless driver starts the clock at a test's moment, and it moves on from there. */
function rg_clock_starts_at(seconds, ticks, set) {
  rg_clock_present = 1;
  rg_clock_set = set ? 1 : 0;
  rg_clock_counts_frames = 1;
  rg_clock_seconds = seconds;
  rg_clock_ticks = ticks;
}

/* The days from the start of 1970 to a date, and back: the native runtime's calendar of plain
 * arithmetic, every fourth year a leap year, but not every hundredth, but every four hundredth.
 * Every division rounds down. Where C's own division cuts towards nothing, the numbers are never
 * below nothing and the two agree; where they can be (the era, the days, the weekday), rounding
 * down is what the C does too, so a moment before 1970 lands on the day it is in. */
function rg_days_from_date(year, month, day) {
  year -= month <= 2 ? 1 : 0;
  const era = Math.floor(year / 400);
  const year_of_era = year - era * 400;
  const day_of_year = Math.floor((153 * (month > 2 ? month - 3 : month + 9) + 2) / 5) + day - 1;
  const day_of_era = year_of_era * 365 + Math.floor(year_of_era / 4) - Math.floor(year_of_era / 100) + day_of_year;
  return era * 146097 + day_of_era - 719468;
}

function rg_date_from_days(days) {
  days += 719468;
  const era = Math.floor(days / 146097);
  const day_of_era = days - era * 146097;
  const year_of_era = Math.floor((day_of_era - Math.floor(day_of_era / 1460) + Math.floor(day_of_era / 36524) -
                                  Math.floor(day_of_era / 146096)) / 365);
  const day_of_year = day_of_era - (365 * year_of_era + Math.floor(year_of_era / 4) - Math.floor(year_of_era / 100));
  const from_march = Math.floor((5 * day_of_year + 2) / 153);
  const month = from_march < 10 ? from_march + 3 : from_march - 9;
  return { year: year_of_era + era * 400 + (month <= 2 ? 1 : 0), month, day: day_of_year - Math.floor((153 * from_march + 2) / 5) + 1 };
}

/* The page says what the browser's own clock reads instead, its local time, as each frame of the
 * game starts. */
function rg_clock_reads(year, month, day, hour, minute, second) {
  rg_clock_present = 1;
  rg_clock_set = 1;
  rg_clock_counts_frames = 0;
  rg_clock_seconds = rg_days_from_date(year, month, day) * RG_SECONDS_A_DAY + hour * 3600 + minute * 60 + second;
  rg_clock_ticks = 0;
}

/* A frame of the console's later: 280,896 of its ticks, a little more than a sixtieth of a
 * second (the sound's FRAME_TICKS and TICKS_A_SECOND, rg_sound.js). */
function rg_clock_frame() {
  if (!rg_clock_counts_frames) return;
  rg_clock_ticks += FRAME_TICKS;
  rg_clock_seconds += Math.floor(rg_clock_ticks / TICKS_A_SECOND);
  rg_clock_ticks %= TICKS_A_SECOND;
}

function rg_clock_reading(reading) {
  if (!rg_clock_present) return 0;
  if (reading === RG_CLOCK_PRESENT) return 1;
  const days = Math.floor(rg_clock_seconds / RG_SECONDS_A_DAY);
  const into_day = rg_clock_seconds - days * RG_SECONDS_A_DAY;
  if (reading === RG_CLOCK_DAYS) return days - RG_DAYS_TO_2000;
  if (reading === RG_CLOCK_SECONDS) return into_day;
  if (reading === RG_CLOCK_COUNTING) return rg_clock_set ? 1 : 0;
  if (!rg_clock_set) return 0;
  if (reading === RG_CLOCK_SET) return 1;

  const date = rg_date_from_days(days);
  switch (reading) {
  case RG_CLOCK_HOUR: return Math.floor(into_day / 3600);
  case RG_CLOCK_MINUTE: return Math.floor(into_day / 60) % 60;
  case RG_CLOCK_SECOND: return into_day % 60;
  case RG_CLOCK_YEAR: return date.year;
  case RG_CLOCK_MONTH: return date.month;
  case RG_CLOCK_DAY: return date.day;
  case RG_CLOCK_WEEKDAY: return days + 4 - Math.floor((days + 4) / 7) * 7; /* 1 January 1970 was a Thursday */
  default: return rg_fault(`the clock has no reading numbered ${reading}`);
  }
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
