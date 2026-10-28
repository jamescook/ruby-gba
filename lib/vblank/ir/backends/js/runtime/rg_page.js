/*
 * The runtime in a browser: the picture in a <canvas>, the keyboard and any controller as the
 * gamepad, the sound through Web Audio, and the save memory kept between visits. The native
 * runtime's window (rg_sdl.c) does the same with SDL, and the frame goes the same way here: the
 * frame's sound is played, the next frame begins, its picture is shown, and its buttons are read.
 *
 * A browser cannot be made to wait inside a script, so the game is asked for one frame at a time
 * (the game's generator, see Printer), whenever the browser is about to draw — about sixty times a
 * second, more on a faster monitor, so a frame of the game is played only once a sixtieth of a
 * second has gone by since the last.
 *
 * THIS FILE IS INSIDE createGame(host) (see JS#factory), so each game made has all of it — and
 * every game's state — to itself. Everything it uses that a page might want otherwise comes from
 * +host+, and everything left out is what a page of its own would want:
 *
 *   canvas             where the picture goes: the one thing a host must give
 *   keys               false to leave the keyboard alone (true)
 *   keyTarget          what to hear keys on (the window); a canvas given tabindex="0" keeps two
 *                      games on one page from hearing each other
 *   keyMap             { browser key code: button name } in place of PAGE_KEYS
 *   gamepads           false to leave controllers alone (true)
 *   storage            where the save is kept: anything with getItem and setItem (the browser's
 *                      localStorage), or null to keep nothing
 *   saveKey            the name it is kept under ("vblank-save:" and the game's title)
 *   audio              false for no sound, or a Web Audio context of the host's (one made on the
 *                      first key or click, as a browser allows)
 *   fullscreenKey      the key that fills the screen ("KeyF"), or null for none
 *   fullscreenElement  what fills the screen (the canvas): a part of the page holding the canvas
 *                      and whatever else has to come with it, such as buttons on the screen
 *   pauseWhenUnfocused false to play on while another window has the keyboard (true)
 *   autostart          false to wait for start() (true)
 *   data               for a game built with its data separate (--data=separate): where its data
 *                      file is (beside the script or module, or beside the page), or its bytes
 *                      already in hand as an ArrayBuffer or Uint8Array
 *   onMessage(kind, text)   what the game would say: "controller" (which are connected),
 *                      "keyboard" (to click the game, or null once it has the keyboard) and
 *                      "stopped" (why a game that went wrong stopped)
 *
 * and createGame gives back the game to steer: start, pause, resume, stop, press and release a
 * button by name (a press counts for the next frame even if it is released before then, as a
 * tapped key does), readSave and writeSave, setPauseWhenUnfocused, toggleFullscreen, canFillScreen,
 * paused, title,
 * finished — a promise that settles with { wentWrong, message } when the game stops — and ready,
 * which settles once the game has what it needs to play its first frame (its data file).
 */

const PAGE_FRAME_MS = 1000 * 280896 / 2 ** 24; /* the console's frame: 280,896 ticks of its clock */

/* The console's buttons by name, in the order rg_buttons_read takes them, a bit each. */
const PAGE_BUTTONS = ["a", "b", "select", "start", "right", "left", "up", "down", "r", "l"];

/* The window's keys: the arrows, X for A, Z for B, Enter for Start, Backspace or right Shift for
 * Select, A for L and S for R. */
const PAGE_KEYS = { KeyX: "a", KeyZ: "b", Backspace: "select", ShiftRight: "select", Enter: "start",
  ArrowRight: "right", ArrowLeft: "left", ArrowUp: "up", ArrowDown: "down", KeyS: "r", KeyA: "l" };

/* A controller's buttons, by the numbers the browser's "standard" layout gives them (the layout
 * nearly every controller is reported in), to the console's: the bottom face button is A and the
 * right one B, as an Xbox controller labels them, the shoulder buttons are L and R, and the d-pad
 * is the d-pad. */
const PAGE_PAD_BUTTONS = [[0, "a"], [1, "b"], [8, "select"], [9, "start"], [15, "right"], [14, "left"], [12, "up"],
  [13, "down"], [5, "r"], [4, "l"]];

/* How far the left stick goes, out of 1, before it counts as the d-pad. A stick at rest seldom
 * reads exactly 0, and a worn one rests well off it, so a little way counts as nothing. */
const PAGE_STICK_DEAD_ZONE = 0.5;

const PAGE_NO_CONTROLLER = "To use a controller, connect it and press a button on it.";
const PAGE_CLICK_TO_PLAY = "Click the game to play.";

function page_bit(name) {
  const at = PAGE_BUTTONS.indexOf(name);
  if (at < 0) throw new Error(`There is no button called ${name}. The buttons are ${PAGE_BUTTONS.join(", ")}.`);
  return 1 << at;
}

/* The browser's own storage for this page, or null where it keeps none (a page opened in some
 * browsers' private windows says no when asked). */
function page_default_storage() {
  try {
    return typeof localStorage === "undefined" ? null : localStorage;
  } catch (error) {
    return null;
  }
}

function page_create(host) {
  if (!host.canvas || !host.canvas.getContext) {
    throw new Error("createGame needs a canvas to draw on: createGame({ canvas: document.querySelector(\"canvas\") }).");
  }
  const canvas = host.canvas;
  const context = canvas.getContext("2d");
  const image = context.createImageData(RG_SCREEN_WIDTH, RG_SCREEN_HEIGHT);
  const say = host.onMessage || (() => {});
  const key_map = host.keyMap || PAGE_KEYS;
  const fullscreen_key = host.fullscreenKey === undefined ? "KeyF" : host.fullscreenKey;
  const storage = host.storage === undefined ? page_default_storage() : host.storage;
  const save_key = host.saveKey || `vblank-save:${rg_title()}`;
  const left_samples = new Int16Array(RG_SOUND_FRAME_MOST);
  const right_samples = new Int16Array(RG_SOUND_FRAME_MOST);
  const page_unfocused = () => typeof document !== "undefined" && document.hasFocus && !document.hasFocus();

  /* Everything the game listens to, so a game that stops can let go of all of it (release_page). */
  const listening = [];
  function listen_to(target, type, listener) {
    target.addEventListener(type, listener);
    listening.push([target, type, listener]);
  }
  function release_page() {
    for (const [target, type, listener] of listening.splice(0)) target.removeEventListener(type, listener);
  }

  let audio = host.audio && host.audio !== true ? host.audio : null;
  let sound_at = 0;
  let keys_down = 0;
  let keys_tapped = 0;
  let pressed_by_caller = 0;
  let tapped_by_caller = 0;
  let pause_when_unfocused = host.pauseWhenUnfocused !== false;
  let paused_by_caller = false;
  let paused_by_focus = false;
  let started = false;
  let stopped = false;
  let finish;
  const finished = new Promise((resolve) => { finish = resolve; });

  rg_active_driver = { dump_variable() {}, dump_list() {}, sound_logged() {} };

  /* --- the save --- */

  function load_save() {
    if (rg_save_size() === 0 || !storage) return;
    try {
      const kept = storage.getItem(save_key);
      if (!kept) return;
      const bytes = Uint8Array.from(atob(kept), (char) => char.charCodeAt(0));
      if (bytes.length === rg_save_size()) rg_save_bytes().set(bytes);
    } catch (error) {
      /* a browser that keeps nothing for this page plays the game from a new cartridge */
    }
  }

  function write_save() {
    if (!storage) return;
    try {
      let text = "";
      for (const byte of rg_save_bytes()) text += String.fromCharCode(byte);
      storage.setItem(save_key, btoa(text));
      rg_save_file_written();
    } catch (error) {
      /* tried again when the save is next due */
    }
  }

  /* --- the picture: fifteen bits a pixel, each channel widened to eight --- */

  function present() {
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

  /* --- the sound --- */

  /* The frame's sound, queued to play straight after the frame before's. A browser plays nothing
   * until somebody has clicked or pressed a key on the page, so until then it is made and
   * dropped, which still moves every voice on. */
  function play_sound() {
    const count = rg_sound_render_frame(left_samples, right_samples);
    if (!audio || audio.state !== "running" || count === 0) return;
    const buffer = audio.createBuffer(2, count, RG_SOUND_RATE);
    const left = buffer.getChannelData(0), right = buffer.getChannelData(1);
    for (let i = 0; i < count; i++) {
      left[i] = left_samples[i] / 32768;
      right[i] = right_samples[i] / 32768;
    }
    const source = audio.createBufferSource();
    source.buffer = buffer;
    source.connect(audio.destination);
    const now = audio.currentTime;
    if (sound_at < now + 0.02 || sound_at > now + 0.25) sound_at = now + 0.05;
    source.start(sound_at);
    sound_at += count / RG_SOUND_RATE;
  }

  function start_sound() {
    if (host.audio === false) return;
    if (!audio && typeof window !== "undefined") {
      const Context = window.AudioContext || window.webkitAudioContext;
      if (Context) audio = new Context();
    }
    /* A device a click made while the game is paused waits with the game. */
    match_sound();
  }

  function tab_hidden() { return typeof document !== "undefined" && document.hidden; }

  /* The sound waits while the game does: paused, or in a tab behind another. */
  function match_sound() {
    if (!audio) return;
    if ((is_paused() || tab_hidden()) && audio.state === "running") audio.suspend();
    else if (!is_paused() && !tab_hidden() && audio.state === "suspended") audio.resume();
  }

  /* --- pausing --- */

  function is_paused() { return paused_by_caller || paused_by_focus; }

  function set_focus_pause(paused) {
    paused_by_focus = paused;
    match_sound();
  }

  /* --- the buttons --- */

  /* Every console button held on any controller plugged in, the left stick as the d-pad. The
   * browser keeps no events for these: a controller is read as it stands, once a frame. */
  function pad_buttons() {
    if (host.gamepads === false || typeof navigator === "undefined" || !navigator.getGamepads) return 0;
    let held = 0;
    for (const pad of navigator.getGamepads()) {
      if (!pad || !pad.connected) continue;
      for (const [from, to] of PAGE_PAD_BUTTONS) if (pad.buttons[from] && pad.buttons[from].pressed) held |= page_bit(to);
      const [x = 0, y = 0] = pad.axes;
      if (x > PAGE_STICK_DEAD_ZONE) held |= page_bit("right");
      if (x < -PAGE_STICK_DEAD_ZONE) held |= page_bit("left");
      if (y < -PAGE_STICK_DEAD_ZONE) held |= page_bit("up");
      if (y > PAGE_STICK_DEAD_ZONE) held |= page_bit("down");
    }
    return held;
  }

  function say_controllers() {
    if (host.gamepads === false || typeof navigator === "undefined") return;
    const pads = navigator.getGamepads ? Array.from(navigator.getGamepads()).filter((pad) => pad && pad.connected) : [];
    say("controller", pads.length === 0 ? PAGE_NO_CONTROLLER : `Controller: ${pads.map((pad) => pad.id).join(", ")}.`);
  }

  /* A key that went down and came up again between two frames still counts for the next one. The
   * keyboard, the controllers and the caller's presses are one gamepad: a button held on any of
   * them is held. */
  function read_buttons() {
    rg_buttons_read(keys_down | keys_tapped | pressed_by_caller | tapped_by_caller | pad_buttons());
    tapped_by_caller = 0;
    keys_tapped = 0;
  }

  /* --- the screen --- */

  /* The canvas fills the screen, unless the host names something holding it. A browser keeps the
   * shape of a canvas that fills the screen, with black either side, and the page's
   * `image-rendering` keeps every pixel square however big. Safari before 16.4 names these with
   * "webkit". */
  const filling = host.fullscreenElement || canvas;
  const can_fill_screen = Boolean(filling.requestFullscreen || filling.webkitRequestFullscreen);

  function toggle_fullscreen() {
    let asked;
    if (document.fullscreenElement || document.webkitFullscreenElement) {
      asked = (document.exitFullscreen || document.webkitExitFullscreen).call(document);
    } else if (can_fill_screen) {
      asked = (filling.requestFullscreen || filling.webkitRequestFullscreen).call(filling);
    }
    /* A browser that says no (a page in a frame not allowed to) leaves the page as it was. */
    if (asked && asked.catch) asked.catch(() => {});
  }

  /* --- listening to the browser --- */

  function listen() {
    if (typeof window === "undefined") return;
    if (host.keys !== false) {
      const target = host.keyTarget || window;
      listen_to(target,"keydown", (event) => {
        start_sound();
        /* With Cmd, Ctrl or Alt it is the browser's shortcut (Cmd+A, Ctrl+S, Alt+Left), not a button. */
        if (event.metaKey || event.ctrlKey || event.altKey) return;
        if (fullscreen_key && event.code === fullscreen_key) {
          if (!event.repeat) toggle_fullscreen();
          event.preventDefault();
          return;
        }
        const button = key_map[event.code];
        if (button === undefined) return;
        keys_down |= page_bit(button);
        keys_tapped |= page_bit(button);
        event.preventDefault();
      });
      listen_to(target,"keyup", (event) => {
        const button = key_map[event.code];
        if (button === undefined) return;
        keys_down &= ~page_bit(button);
        event.preventDefault();
      });
    }
    listen_to(window,"pointerdown", start_sound);
    /* A key let go while the page has not got the keyboard never reaches it, and would be held
     * for ever: so whenever the page loses it, every key is let go — and, unless the host says
     * not, the game pauses, so a player who looks away does not come back to a game that went on
     * without them. */
    listen_to(window,"blur", () => {
      keys_down = 0;
      if (pause_when_unfocused) set_focus_pause(true);
    });
    listen_to(window,"focus", () => {
      set_focus_pause(false);
      say("keyboard", null);
    });
    /* A tab behind another gets no frames, so the game stops where it is; its sound waits with
     * it, rather than playing out what was queued. */
    listen_to(document, "visibilitychange", () => {
      if (tab_hidden()) keys_down = 0;
      match_sound();
    });
    if (host.gamepads !== false) {
      listen_to(window,"gamepadconnected", say_controllers);
      listen_to(window,"gamepaddisconnected", say_controllers);
    }
  }

  /* --- the data file, for a game built with its data separate --- */

  /* A game built with its big tables in a file of their own (JS::Printer#data_file) has them
   * filled in from it (rg_data_fill) before its first frame. It is fetched from beside the script
   * unless the host says where it is, or hands its bytes over. A file that is not there, or that
   * another build of the game wrote, stops the game before it starts. */
  const needs_data = typeof rg_data_fill === "function";

  async function load_data() {
    const source = host.data != null ? host.data : (typeof rg_data_beside === "undefined" ? null : rg_data_beside);
    let bytes;
    if (source instanceof ArrayBuffer) {
      bytes = new Uint8Array(source);
    } else if (ArrayBuffer.isView(source)) {
      bytes = new Uint8Array(source.buffer, source.byteOffset, source.byteLength);
    } else if (typeof source === "string" || (typeof URL !== "undefined" && source instanceof URL)) {
      let response;
      try {
        response = await fetch(source);
      } catch (error) {
        response = { ok: false, statusText: error.message };
      }
      if (!response.ok) {
        throw new Error(`it cannot load its data file ${source} (${response.status || response.statusText}). ` +
                        "Put the data file beside the game, or give its address to createGame as data.");
      }
      bytes = new Uint8Array(await response.arrayBuffer());
    } else {
      throw new Error("it cannot read the data that createGame was given. Give the data file's address, " +
                      "or its bytes as an ArrayBuffer or a Uint8Array.");
    }
    const stamp = Array.from(bytes.subarray(0, RG_DATA_STAMP.length / 2), (byte) => byte.toString(16).padStart(2, "0")).join("");
    if (stamp !== RG_DATA_STAMP) {
      const named = typeof source === "string" ? `${source} ` : "";
      throw new Error(`its data file ${named}is from a different build of the game. Build the game again, ` +
                      "and put the new data file beside it.");
    }
    rg_data_fill(bytes);
  }

  const ready = needs_data ? load_data() : Promise.resolve();
  ready.catch(() => {}); /* said by start, when the game is started */

  /* --- the frames --- */

  const game = rg_game_main();
  let due = 0;

  /* The browser's own clock, in its local time, handed to the cartridge's (rg_clock_reads) as each
   * frame of the game starts, the first among them. A clock keeps real time, so a page paused or
   * left in the background finds the time gone by on the first frame it plays after. */
  function read_browser_clock() {
    const now = new Date();
    rg_clock_reads(now.getFullYear(), now.getMonth() + 1, now.getDate(), now.getHours(), now.getMinutes(), now.getSeconds());
  }

  /* However the game stops, it lets go of the page — its keys go back to the page, F and the
   * window's focus are no longer its business — and its sound stops with it. */
  function stop_with(went_wrong, message) {
    stopped = true;
    release_page();
    if (audio && audio.state === "running") audio.suspend();
    finish({ wentWrong: went_wrong, message });
  }

  /* One frame of the game: it plays until it waits for the screen, and that frame's boundary
   * follows. A game that stops leaves its last picture up. */
  function play_frame() {
    try {
      read_browser_clock();
      if (game.next().done) {
        present();
        stop_with(false, "the game ended");
        return;
      }
      play_sound();
      rg_frame_begins();
      present();
      if (rg_save_file_is_due()) write_save();
      read_buttons();
    } catch (error) {
      if (!(error instanceof RgStopped)) {
        stop_with(true, String(error));
        throw error;
      }
      present();
      if (rg_save_unwritten()) write_save();
      if (error.went_wrong) say("stopped", `The game stopped: ${error.message}`);
      stop_with(error.went_wrong, error.message);
    }
  }

  function tick(now) {
    if (stopped) return;
    if (is_paused()) {
      due = now + PAGE_FRAME_MS; /* and when the pause ends, the game goes on from where it stood */
    } else {
      if (now - due > 250) due = now; /* a page left in the background does not race to catch up */
      while (!stopped && now >= due) {
        play_frame();
        due += PAGE_FRAME_MS;
      }
    }
    if (!stopped) window.requestAnimationFrame(tick);
  }

  function start() {
    if (started) return;
    started = true;
    listen();
    say_controllers();
    /* A page in a frame on another site starts without the keyboard: a key pressed then goes to
     * the page around it, so it says to click the game, and pauses until it has the keyboard. */
    if (page_unfocused()) {
      say("keyboard", PAGE_CLICK_TO_PLAY);
      if (pause_when_unfocused) set_focus_pause(true);
    }
    if (!needs_data) {
      play_from_first_frame();
      return;
    }
    ready.then(play_from_first_frame, (error) => {
      say("stopped", `The game stopped: ${error.message}`);
      stop_with(true, error.message);
    });
  }

  /* Once the game has its data: the save read in, and the first frame asked for. */
  function play_from_first_frame() {
    if (stopped) return;
    load_save();
    due = performance.now();
    window.requestAnimationFrame(tick);
  }

  const handle = {
    title: rg_title(),
    finished,
    ready,
    canFillScreen: can_fill_screen,
    get paused() { return is_paused(); },
    start,
    pause() { paused_by_caller = true; match_sound(); },
    resume() { paused_by_caller = false; match_sound(); },
    stop() {
      if (stopped) return;
      if (rg_save_unwritten()) write_save();
      stop_with(false, "stopped by the page");
    },
    /* The save memory as it stands, a copy, for a page to keep (an "export my save" button). */
    readSave() { return Uint8Array.from(rg_save_bytes()); },
    /* Puts +bytes+ in the save memory (an "import a save" button), and keeps them where the host
     * keeps saves. They must be exactly the save memory's size. */
    writeSave(bytes) {
      if (!bytes || bytes.length !== rg_save_size()) {
        throw new Error(`A save for this game must be ${rg_save_size()} bytes, and this one is ${bytes ? bytes.length : 0}.`);
      }
      rg_save_bytes().set(bytes);
      write_save();
    },
    /* A press let go before the next frame still counts for it, as a key's does: a quick tap on
     * an on-screen pad is over in less than a frame. */
    press(name) {
      pressed_by_caller |= page_bit(name);
      tapped_by_caller |= page_bit(name);
    },
    release(name) { pressed_by_caller &= ~page_bit(name); },
    setPauseWhenUnfocused(on) {
      pause_when_unfocused = on;
      set_focus_pause(on && page_unfocused());
    },
    toggleFullscreen: toggle_fullscreen,
  };
  if (host.autostart !== false) start();
  return handle;
}
