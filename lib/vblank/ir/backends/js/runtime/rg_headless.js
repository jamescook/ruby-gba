/*
 * The runtime with no window: what the tests run a game against, under node.
 *
 *   node game.js FRAMES [options] < buttons
 *
 * It is the native runtime's rg_headless.c, saying the same thing in the same words, so one Ruby
 * reader drives either (Native::HeadlessRun, which JS::HeadlessRun is): it plays FRAMES frames
 * and stops at the start of the next, reads each frame's buttons as a line of standard input (a
 * number, a bit per button), and at every frame boundary prints "frame N", every variable ("var
 * name value"), every list ("list name", a tab, its items), every sprite last drawn ("sprite" and
 * four numbers), what the mixer made and is playing, where the window sits ("camera X Y"), the
 * picture's check number ("picture-crc"), and then "buttons?" — and only then reads that frame's
 * line. At the end it prints "end" and the same again, and how many pages the screen has.
 *
 * The options are rg_headless.c's: --every-picture, --held-from-power-on MASK, --save FILE,
 * --save-cut-after N, --sound-out FILE, --sound-voice N, --picture-out FILE and --clock-at
 * SECONDS TICKS SET, each meaning what it means there.
 *
 * Everything it reads and writes is done with node's synchronous calls on the file descriptors
 * themselves, never through process.stdout: a frame's buttons have to be read before the game
 * may go on, and node's streams would hand the line over later, from its event loop.
 */

const rg_fs = require("fs");

let headless_frames_to_play = 0;
let headless_frame = 0;
let headless_every_picture = false;
let headless_sound_out = null;
let headless_picture_out = null;
let headless_save_path = null;
let headless_out = [];
let headless_slices_printed = 0;
const headless_left = new Int16Array(RG_SOUND_FRAME_MOST);
const headless_right = new Int16Array(RG_SOUND_FRAME_MOST);
const headless_both = new Int16Array(2 * RG_SOUND_FRAME_MOST);

function headless_print(text) { headless_out.push(text); }

/* Everything printed so far goes out, in one write. */
function headless_flush() {
  if (headless_out.length === 0) return;
  const text = headless_out.join("");
  headless_out = [];
  const bytes = Buffer.from(text, "utf8");
  let written = 0;
  while (written < bytes.length) written += rg_fs.writeSync(1, bytes, written, bytes.length - written);
}

/* The bytes of standard input read but not yet taken as a line. */
let headless_input = Buffer.alloc(0);
let headless_input_ended = false;

/* The next line of standard input, or null once it has ended. */
function headless_read_line() {
  for (;;) {
    const newline = headless_input.indexOf(10);
    if (newline >= 0) {
      const line = headless_input.subarray(0, newline).toString("utf8");
      headless_input = headless_input.subarray(newline + 1);
      return line;
    }
    if (headless_input_ended) {
      if (headless_input.length === 0) return null;
      const line = headless_input.toString("utf8");
      headless_input = Buffer.alloc(0);
      return line;
    }
    const chunk = Buffer.alloc(4096);
    let read;
    try {
      read = rg_fs.readSync(0, chunk, 0, chunk.length, null);
    } catch (error) {
      if (error.code === "EAGAIN") continue;
      if (error.code === "EOF") read = 0;
      else throw error;
    }
    if (read === 0) headless_input_ended = true;
    else headless_input = Buffer.concat([headless_input, chunk.subarray(0, read)]);
  }
}

/* The CRC-32 zip files use, which Ruby's Zlib.crc32 works out from the same bytes. */
const headless_crc_table = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let bit = 0; bit < 8; bit++) c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c >>> 0;
  }
  return table;
})();

function headless_picture_crc(pixels) {
  let crc = 0xFFFFFFFF;
  for (let i = 0; i < pixels.length; i++) {
    crc = headless_crc_table[(crc ^ pixels[i]) & 0xFF] ^ (crc >>> 8);
    crc = headless_crc_table[(crc ^ (pixels[i] >> 8)) & 0xFF] ^ (crc >>> 8);
  }
  return ((crc ^ 0xFFFFFFFF) >>> 0).toString(16).padStart(8, "0");
}

function headless_print_pixels(word, pixels) {
  const hexes = new Array(pixels.length);
  for (let i = 0; i < pixels.length; i++) hexes[i] = pixels[i].toString(16).padStart(4, "0");
  headless_print(`${word} ${hexes.join("")}\n`);
}

/* A picture's pixels as bytes, two each with the low byte first. */
function headless_pixel_bytes(pixels) {
  const bytes = Buffer.alloc(pixels.length * 2);
  for (let i = 0; i < pixels.length; i++) bytes.writeUInt16LE(pixels[i], i * 2);
  return bytes;
}

function headless_write_picture(shown_pixels) {
  const both = Buffer.concat([headless_pixel_bytes(shown_pixels), headless_pixel_bytes(rg_screen_stored())]);
  rg_fs.writeSync(headless_picture_out, both, 0, both.length, 0);
}

function headless_print_sprites() {
  for (let place = 0; place < rg_screen_drawn_count(); place++) {
    const drawn = rg_screen_drawn_sprite(place);
    headless_print(`sprite ${drawn.name} ${drawn.picture} ${drawn.x} ${drawn.y}\n`);
  }
}

function headless_print_mix() {
  if (!rg_game_mix[0]) return;

  if (rg_mix_slices_made() > headless_slices_printed) {
    headless_print(`mix${Array.from(rg_mix_newest_slice(), (sample) => ` ${sample}`).join("")}\n`);
    headless_slices_printed = rg_mix_slices_made();
  }
  let mixing_line = "mixing";
  for (let voice = 0; voice < rg_mix_voice_count(); voice++) {
    const reading = rg_mix_voice_sounding(voice);
    if (!reading) continue;
    mixing_line += ` ${reading.recording} ${reading.loudness} ${reading.level} ${reading.owner} ${reading.effect} ${reading.lane}`;
  }
  const [dropped, music_held] = rg_mix_drops();
  headless_print(`${mixing_line}\nmix_peak ${rg_mix_peak()}\nmix_drops ${dropped} ${music_held}\n`);
}

function headless_print_moment(heading, with_picture) {
  headless_print(`${heading}\n`);
  rg_game_dump_state();
  headless_print_sprites();
  headless_print_mix();
  headless_print(`camera ${rg_screen_camera_x()} ${rg_screen_camera_y()}\n`);
  headless_print(`motor ${rg_motor_on()}\n`);
  const shown_pixels = rg_screen_shown();
  if (with_picture) headless_print_pixels("picture", shown_pixels);
  else headless_print(`picture-crc ${headless_picture_crc(shown_pixels)}\n`);
  if (headless_picture_out !== null) headless_write_picture(shown_pixels);
}

function headless_write_save_file() {
  const writing = `${headless_save_path}.writing`;
  try {
    rg_fs.writeFileSync(writing, rg_save_bytes());
    rg_fs.renameSync(writing, headless_save_path);
  } catch (error) {
    rg_fs.writeSync(2, `the save memory could not be written to ${headless_save_path}\n`);
    process.exit(1);
  }
}

function headless_finish() {
  headless_print_moment("end", headless_picture_out === null);
  if (headless_picture_out === null) headless_print_pixels("stored", rg_screen_stored());
  headless_print(`pages ${rg_screen_two_pages() ? 2 : 1}\n`);
  headless_flush();
  if (headless_sound_out !== null) rg_fs.closeSync(headless_sound_out);
  if (headless_picture_out !== null) rg_fs.closeSync(headless_picture_out);
  if (headless_save_path) headless_write_save_file();
  process.exit(0);
}

/* The frame's sound, written down as rg_headless.c writes it: a sample of the left speaker, then
 * the right's at the same moment, and so on. */
function headless_write_frame_sound() {
  const count = rg_sound_render_frame(headless_left, headless_right);
  if (headless_sound_out === null) return;
  for (let i = 0; i < count; i++) {
    headless_both[2 * i] = headless_left[i];
    headless_both[2 * i + 1] = headless_right[i];
  }
  const bytes = Buffer.from(headless_both.buffer, 0, count * 4);
  rg_fs.writeSync(headless_sound_out, bytes);
}

/* A frame boundary, after the game has yielded it: the frame's sound, then the next frame begun,
 * shown, and its buttons read — or the run over, once it has played every frame it was asked for. */
function headless_wait_vblank() {
  headless_write_frame_sound();
  if (headless_frame >= headless_frames_to_play) headless_finish();
  rg_frame_begins();
  headless_frame++;
  headless_print_moment(`frame ${headless_frame}`, headless_every_picture);
  headless_print("buttons?\n");
  headless_flush();
  const line = headless_read_line();
  const mask = line === null ? 0 : parseInt(line, 10);
  rg_buttons_read(Number.isNaN(mask) ? 0 : mask);
}

const headless_driver = {
  dump_variable(name, value) { headless_print(`var ${name} ${value}\n`); },
  dump_list(list) {
    const items = [];
    for (let i = 0; i < list.length; i++) items.push(list.items[rg_list_slot(list, i)]);
    headless_print(`list ${list.name}\t${items.join(" ")}\n`);
  },
  sound_logged(line) { headless_print(`sound ${line}\n`); },
};

function headless_open_or_stop(path, flags, what) {
  try {
    return rg_fs.openSync(path, flags);
  } catch (error) {
    rg_fs.writeSync(2, `the ${what} could not be written to ${path}\n`);
    process.exit(2);
  }
}

function headless_read_options(args) {
  if (args.length < 1) {
    rg_fs.writeSync(2, "give the number of frames to play, and the buttons for each frame on standard input\n");
    process.exit(2);
  }
  headless_frames_to_play = parseInt(args[0], 10);
  for (let i = 1; i < args.length; i++) {
    const option = args[i], next = args[i + 1];
    if (option === "--every-picture") {
      headless_every_picture = true;
    } else if (option === "--sound-out" && next !== undefined) {
      headless_sound_out = headless_open_or_stop(next, "w", "sound");
      i++;
    } else if (option === "--picture-out" && next !== undefined) {
      headless_picture_out = headless_open_or_stop(next, "w", "picture");
      i++;
    } else if (option === "--sound-voice" && next !== undefined) {
      rg_sound_hear_only(parseInt(next, 10));
      i++;
    } else if (option === "--save" && next !== undefined) {
      i++;
      if (rg_save_size() === 0) continue;
      headless_save_path = next;
      if (rg_fs.existsSync(next)) {
        const kept = rg_fs.readFileSync(next);
        if (kept.length !== rg_save_size()) {
          rg_fs.writeSync(2, `the file at ${next} is not this game's save memory, which is ${rg_save_size()} bytes\n`);
          process.exit(2);
        }
        rg_save_bytes().set(kept);
      }
    } else if (option === "--save-cut-after" && next !== undefined) {
      rg_save_cut_power_after(parseInt(next, 10));
      i++;
    } else if (option === "--held-from-power-on" && next !== undefined) {
      rg_buttons_held_from_power_on(parseInt(next, 10));
      i++;
    } else if (option === "--clock-at" && i + 3 < args.length) {
      rg_clock_starts_at(parseInt(args[i + 1], 10), parseInt(args[i + 2], 10), parseInt(args[i + 3], 10));
      i += 3;
    }
  }
}

/* Plays the game: each time its generator yields, a frame has ended. A game that stops — halted,
 * gone wrong, or run out of program — ends the run. */
function rg_driver_start() {
  rg_active_driver = headless_driver;
  headless_read_options(process.argv.slice(2));
  try {
    const game = rg_game_main();
    while (!game.next().done) headless_wait_vblank();
  } catch (error) {
    if (!(error instanceof RgStopped)) throw error;
    if (error.went_wrong) {
      headless_flush();
      rg_fs.writeSync(2, `${error.message}\n`);
      process.exit(RG_GAME_WENT_WRONG);
    }
  }
  headless_finish();
}
