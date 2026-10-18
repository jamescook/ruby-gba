/*
 * The runtime in a web page: the picture in a <canvas>, the keyboard as the gamepad, the sound
 * through Web Audio, and the save memory kept in the browser between visits. The native
 * runtime's window (rg_sdl.c) does the same with SDL, and the frame goes the same way here: the
 * frame's sound is played, the next frame begins, its picture is shown, and its buttons are read.
 *
 * A browser cannot be made to wait inside a script, so the page asks the game for one frame at a
 * time (the game's generator, see Printer), whenever the browser is about to draw — about sixty
 * times a second, more on a faster monitor, so a frame of the game is played only once a
 * sixtieth of a second has gone by since the last.
 *
 * Keys: the arrows, X for A, Z for B, Enter for Start, Backspace or right Shift for Select, A for
 * L and S for R — the window's keys.
 */

const PAGE_FRAME_MS = 1000 * 280896 / 2 ** 24; /* the console's frame: 280,896 ticks of its clock */
const PAGE_KEYS = { KeyX: 0, KeyZ: 1, Backspace: 2, ShiftRight: 2, Enter: 3, ArrowRight: 4, ArrowLeft: 5, ArrowUp: 6,
  ArrowDown: 7, KeyS: 8, KeyA: 9 };

let page_keys_down = 0;
let page_keys_tapped = 0;
let page_audio = null;
let page_sound_at = 0;
const page_samples = new Int16Array(RG_SOUND_FRAME_MOST);

const page_driver = {
  dump_variable() {},
  dump_list() {},
  sound_logged() {},
};

/* Where the save memory is kept: the browser's own storage for this page, by the game's name. */
function page_save_key() { return `ruby-gba-save:${rg_title()}`; }

function page_load_save() {
  if (rg_save_size() === 0) return;
  try {
    const kept = window.localStorage.getItem(page_save_key());
    if (!kept) return;
    const bytes = Uint8Array.from(atob(kept), (char) => char.charCodeAt(0));
    if (bytes.length === rg_save_size()) rg_save_bytes().set(bytes);
  } catch (error) {
    /* a browser that keeps nothing for this page plays the game from a new cartridge */
  }
}

function page_write_save() {
  try {
    let text = "";
    for (const byte of rg_save_bytes()) text += String.fromCharCode(byte);
    window.localStorage.setItem(page_save_key(), btoa(text));
    rg_save_file_written();
  } catch (error) {
    /* tried again when the save is next due */
  }
}

/* The picture as the console shows it: fifteen bits a pixel, each channel widened to eight. */
function page_present(context, image) {
  const pixels = rg_screen_shown();
  const rgba = image.data;
  for (let i = 0; i < pixels.length; i++) {
    const color = pixels[i];
    const red = color & 0x1F, green = (color >> 5) & 0x1F, blue = (color >> 10) & 0x1F;
    rgba[i * 4] = (red << 3) | (red >> 2);
    rgba[i * 4 + 1] = (green << 3) | (green >> 2);
    rgba[i * 4 + 2] = (blue << 3) | (blue >> 2);
    rgba[i * 4 + 3] = 255;
  }
  context.putImageData(image, 0, 0);
}

/* The frame's sound, queued to play straight after the frame before's. A browser plays nothing
 * until somebody has clicked or pressed a key on the page, so until then it is made and dropped,
 * which still moves every voice on. */
function page_play_sound() {
  const count = rg_sound_render_frame(page_samples);
  if (!page_audio || page_audio.state !== "running" || count === 0) return;
  const buffer = page_audio.createBuffer(1, count, RG_SOUND_RATE);
  const channel = buffer.getChannelData(0);
  for (let i = 0; i < count; i++) channel[i] = page_samples[i] / 32768;
  const source = page_audio.createBufferSource();
  source.buffer = buffer;
  source.connect(page_audio.destination);
  const now = page_audio.currentTime;
  if (page_sound_at < now + 0.02 || page_sound_at > now + 0.25) page_sound_at = now + 0.05;
  source.start(page_sound_at);
  page_sound_at += count / RG_SOUND_RATE;
}

function page_start_sound() {
  if (!page_audio) {
    const Context = window.AudioContext || window.webkitAudioContext;
    if (Context) page_audio = new Context();
  }
  if (page_audio && page_audio.state === "suspended") page_audio.resume();
}

function page_listen_to_keys() {
  window.addEventListener("keydown", (event) => {
    page_start_sound();
    const button = PAGE_KEYS[event.code];
    if (button === undefined) return;
    page_keys_down |= 1 << button;
    page_keys_tapped |= 1 << button;
    event.preventDefault();
  });
  window.addEventListener("keyup", (event) => {
    const button = PAGE_KEYS[event.code];
    if (button === undefined) return;
    page_keys_down &= ~(1 << button);
    event.preventDefault();
  });
  window.addEventListener("pointerdown", page_start_sound);
  window.addEventListener("blur", () => { page_keys_down = 0; });
}

/* A key that went down and came up again between two frames still counts for the next one. */
function page_read_buttons() {
  rg_buttons_read(page_keys_down | page_keys_tapped);
  page_keys_tapped = 0;
}

function page_say(text) {
  const said = document.getElementById("said");
  if (!said) return;
  said.textContent = text;
  said.hidden = false;
}

function rg_driver_start() {
  rg_active_driver = page_driver;
  const canvas = document.getElementById("screen");
  const context = canvas.getContext("2d");
  const image = context.createImageData(RG_SCREEN_WIDTH, RG_SCREEN_HEIGHT);
  page_listen_to_keys();
  page_load_save();

  const game = rg_game_main();
  let due = performance.now();
  let stopped = false;

  /* One frame of the game: it plays until it waits for the screen, and that frame's boundary
   * follows. A game that stops leaves its last picture up. */
  function play_frame() {
    try {
      if (game.next().done) {
        stopped = true;
        page_present(context, image);
        return;
      }
      page_play_sound();
      rg_frame_begins();
      page_present(context, image);
      if (rg_save_file_is_due()) page_write_save();
      page_read_buttons();
    } catch (error) {
      stopped = true;
      if (!(error instanceof RgStopped)) throw error;
      page_present(context, image);
      if (rg_save_unwritten()) page_write_save();
      if (error.went_wrong) page_say(`The game stopped: ${error.message}`);
    }
  }

  function tick(now) {
    if (stopped) return;
    if (now - due > 250) due = now; /* a page left in the background does not race to catch up */
    while (!stopped && now >= due) {
      play_frame();
      due += PAGE_FRAME_MS;
    }
    window.requestAnimationFrame(tick);
  }
  window.requestAnimationFrame(tick);
}
