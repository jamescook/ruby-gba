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
 * L and S for R — the window's keys. A controller works beside them (PAGE_PAD_BUTTONS says which
 * button is which), its left stick as the d-pad too. F fills the screen with the game.
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
    /* With Cmd, Ctrl or Alt it is the browser's shortcut (Cmd+A, Ctrl+S, Alt+Left), not a button. */
    if (event.metaKey || event.ctrlKey || event.altKey) return;
    if (event.code === "KeyF") {
      if (!event.repeat) page_toggle_fullscreen();
      event.preventDefault();
      return;
    }
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
  /* A key let go while the page has not got the keyboard never reaches it, and would be held for
   * ever: so whenever the page loses it, every key is let go. */
  window.addEventListener("blur", () => { page_keys_down = 0; });
  /* A tab behind another gets no frames, so the game stops where it is; its sound is paused with
   * it, rather than playing out what was queued, and goes on when the tab is shown again — unless
   * the game is paused for another reason (page_set_paused). */
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) {
      page_keys_down = 0;
      if (page_audio && page_audio.state === "running") page_audio.suspend();
    } else if (!page_paused && page_audio && page_audio.state === "suspended") {
      page_audio.resume();
    }
  });
}

/* PAUSED WHILE ANOTHER WINDOW HAS THE KEYBOARD: no frames are played and the sound waits, so a
 * player who looks away does not come back to a game that went on without them. The page's
 * checkbox of id "pause" turns it off; the template decides whether the box starts ticked, and a
 * page without one pauses. */
let page_paused = false;

function page_pauses_unfocused() {
  const box = document.getElementById("pause");
  return box ? box.checked : true;
}

function page_set_paused(paused) {
  page_paused = paused;
  if (!page_audio) return;
  if (paused && page_audio.state === "running") page_audio.suspend();
  else if (!paused && !document.hidden && page_audio.state === "suspended") page_audio.resume();
}

function page_listen_to_focus() {
  const unfocused = () => document.hasFocus && !document.hasFocus();
  window.addEventListener("blur", () => { if (page_pauses_unfocused()) page_set_paused(true); });
  window.addEventListener("focus", () => page_set_paused(false));
  const box = document.getElementById("pause");
  if (box) box.addEventListener("change", () => page_set_paused(page_pauses_unfocused() && unfocused()));
  if (page_pauses_unfocused() && unfocused()) page_set_paused(true);
}

/* A controller's buttons, by the numbers the browser's "standard" layout gives them (the layout
 * nearly every controller is reported in), to the console's, a bit each as rg_buttons_read takes
 * them: the bottom face button is A and the right one B, as an Xbox controller labels them, the
 * shoulder buttons are L and R, and the d-pad is the d-pad. */
const PAGE_PAD_BUTTONS = [[0, 0], [1, 1], [8, 2], [9, 3], [15, 4], [14, 5], [12, 6], [13, 7], [5, 8], [4, 9]];

/* How far the left stick goes, out of 1, before it counts as the d-pad. A stick at rest seldom
 * reads exactly 0, and a worn one rests well off it, so a little way counts as nothing. */
const PAGE_STICK_DEAD_ZONE = 0.5;

/* Every console button held on any controller plugged in, the left stick as the d-pad. The
 * browser keeps no events for these: a controller is read as it stands, once a frame. */
function page_pad_buttons() {
  if (!navigator.getGamepads) return 0;
  let held = 0;
  for (const pad of navigator.getGamepads()) {
    if (!pad || !pad.connected) continue;
    for (const [from, to] of PAGE_PAD_BUTTONS) if (pad.buttons[from] && pad.buttons[from].pressed) held |= 1 << to;
    const [x = 0, y = 0] = pad.axes;
    if (x > PAGE_STICK_DEAD_ZONE) held |= 1 << 4;
    if (x < -PAGE_STICK_DEAD_ZONE) held |= 1 << 5;
    if (y < -PAGE_STICK_DEAD_ZONE) held |= 1 << 6;
    if (y > PAGE_STICK_DEAD_ZONE) held |= 1 << 7;
  }
  return held;
}

/* What the page says under the game about controllers, in its element of id "controller" if it
 * has one. A browser tells a page about a controller only once a button on it has been pressed
 * while the page is open, so until then it says how to get one seen. */
const PAGE_NO_CONTROLLER = "To use a controller, connect it and press a button on it.";

function page_say_controllers() {
  const note = document.getElementById("controller");
  if (!note) return;
  const pads = navigator.getGamepads ? Array.from(navigator.getGamepads()).filter((pad) => pad && pad.connected) : [];
  note.textContent = pads.length === 0 ? PAGE_NO_CONTROLLER : `Controller: ${pads.map((pad) => pad.id).join(", ")}.`;
}

function page_listen_to_controllers() {
  page_say_controllers();
  window.addEventListener("gamepadconnected", page_say_controllers);
  window.addEventListener("gamepaddisconnected", page_say_controllers);
}

/* A key that went down and came up again between two frames still counts for the next one. The
 * keyboard and the controllers are one gamepad: a button held on either is held. */
function page_read_buttons() {
  rg_buttons_read(page_keys_down | page_keys_tapped | page_pad_buttons());
  page_keys_tapped = 0;
}

function page_say(text) {
  const said = document.getElementById("said");
  if (!said) return;
  said.textContent = text;
  said.hidden = false;
}

/* THE GAME FILLING THE SCREEN, and back: the F key, or the page's button of id "fullscreen" if it
 * has one. The canvas itself fills it. A browser keeps the shape of what fills the screen, with
 * black either side, and the page's `image-rendering` keeps every pixel square however big. A
 * browser that cannot fill the screen with a canvas (Safari on a phone) has the button hidden.
 * Safari before 16.4 names these with "webkit". */
function page_can_fill_screen(canvas) { return Boolean(canvas.requestFullscreen || canvas.webkitRequestFullscreen); }

function page_toggle_fullscreen() {
  const canvas = document.getElementById("screen");
  let asked;
  if (document.fullscreenElement || document.webkitFullscreenElement) {
    asked = (document.exitFullscreen || document.webkitExitFullscreen).call(document);
  } else if (page_can_fill_screen(canvas)) {
    asked = (canvas.requestFullscreen || canvas.webkitRequestFullscreen).call(canvas);
  }
  /* A browser that says no (a page in a frame not allowed to) leaves the page as it was. */
  if (asked && asked.catch) asked.catch(() => {});
}

function page_offer_fullscreen() {
  const button = document.getElementById("fullscreen");
  if (!button) return;
  if (!page_can_fill_screen(document.getElementById("screen"))) {
    button.hidden = true;
    return;
  }
  button.addEventListener("click", page_toggle_fullscreen);
}

/* A page in a frame on another site starts without the keyboard: a key pressed then goes to the
 * page around it. So until it has the keyboard, it says to click the game (which gives it the
 * keyboard), and once it has, that goes. Words the game left there when it stopped stay. */
const PAGE_CLICK_TO_PLAY = "Click the game to play.";

function page_ask_for_the_keyboard() {
  if (!document.hasFocus || document.hasFocus()) return;
  page_say(PAGE_CLICK_TO_PLAY);
  window.addEventListener("focus", () => {
    const said = document.getElementById("said");
    if (said && said.textContent === PAGE_CLICK_TO_PLAY) said.hidden = true;
  });
}

/* The game starts once the whole page is read. A browser runs a script where it meets it, and a
 * template is free to put the game above the parts the script looks for (the button, the notes),
 * which are not there yet when the script first runs. */
function rg_driver_start() {
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", page_start, { once: true });
  } else {
    page_start();
  }
}

function page_start() {
  rg_active_driver = page_driver;
  const canvas = document.getElementById("screen");
  const context = canvas.getContext("2d");
  const image = context.createImageData(RG_SCREEN_WIDTH, RG_SCREEN_HEIGHT);
  page_listen_to_keys();
  page_listen_to_controllers();
  page_ask_for_the_keyboard();
  page_offer_fullscreen();
  page_listen_to_focus();
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
    if (page_paused) {
      due = now + PAGE_FRAME_MS; /* and when the pause ends, the game goes on from where it stood */
      window.requestAnimationFrame(tick);
      return;
    }
    if (now - due > 250) due = now; /* a page left in the background does not race to catch up */
    while (!stopped && now >= due) {
      play_frame();
      due += PAGE_FRAME_MS;
    }
    window.requestAnimationFrame(tick);
  }
  window.requestAnimationFrame(tick);
}
