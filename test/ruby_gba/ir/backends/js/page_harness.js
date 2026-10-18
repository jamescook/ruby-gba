/*
 * Plays a web page's script (runtime/rg_page.js and the game) in node, with a stand-in for each
 * part of the browser it uses: a canvas that keeps the last picture put on it, a window that
 * hands out key presses and the browser's frame callbacks, and storage that keeps the save.
 * test_js_page.rb drives it, so what runs is the page's own driver and not the windowless one.
 *
 * The script is named on the command line. Each line read from the input is one step:
 *
 *   down KEY / up KEY   a key going down or coming up, by the browser's name for it (ArrowRight)
 *   pad connect         a controller plugged in, laid out the standard way (the browser's
 *                       "standard" mapping), which the page is told of
 *   pad disconnect      ...and taken out again
 *   pad press N / pad release N   its button N going down or coming up, by the standard
 *                       layout's numbering (0 the bottom face button, 12 to 15 the d-pad)
 *   pad stick X Y       its left stick pushed to X, Y, each from -1 to 1
 *   play N              N of the browser's frames, each a console frame after the one before, so
 *                       the page plays one frame of the game on each
 *   picture             prints "picture" and every pixel last put on the canvas, as the
 *                       console's fifteen-bit colours
 *   text ID             prints "text ID" and the words in the page's element of that id now
 *
 * At the end it prints "said" and the words the page showed under the canvas, if it showed any.
 */
"use strict";

const fs = require("fs");
const vm = require("vm");

const FRAME_MS = 1000 * 280896 / 2 ** 24;

const listeners = {};
const waiting = [];
const stored = new Map();
let now = 0;
let shown = null;
const said = { textContent: "", hidden: true };
const note = { textContent: "", hidden: false };

const canvas = {
  getContext: () => ({
    createImageData: (width, height) => ({ width, height, data: new Uint8ClampedArray(width * height * 4) }),
    putImageData: (image) => { shown = Uint8ClampedArray.from(image.data); },
  }),
};

/* The one controller there can be, in the browser's own shape for one. */
const pads = [null, null, null, null];
const controller = {
  id: "Stand-in Controller (STANDARD GAMEPAD)", index: 0, mapping: "standard", connected: true,
  buttons: Array.from({ length: 17 }, () => ({ pressed: false, value: 0 })),
  axes: [0, 0, 0, 0],
};

const page = {
  window: null,
  document: { getElementById: (id) => ({ screen: canvas, said, controller: note })[id] || null },
  navigator: { getGamepads: () => pads.slice() },
  performance: { now: () => now },
  atob, btoa, console,
};
page.window = page;
page.addEventListener = (type, listener) => { (listeners[type] ||= []).push(listener); };
page.requestAnimationFrame = (callback) => { waiting.push(callback); };
page.localStorage = { getItem: (key) => stored.get(key) ?? null, setItem: (key, value) => stored.set(key, value) };

function press(type, code, more = {}) {
  for (const listener of listeners[type] || []) listener({ code, preventDefault() {}, ...more });
}

function pad(action, a, b) {
  if (action === "connect") {
    pads[0] = controller;
    press("gamepadconnected", undefined, { gamepad: controller });
  } else if (action === "disconnect") {
    pads[0] = null;
    press("gamepaddisconnected", undefined, { gamepad: controller });
  } else if (action === "press" || action === "release") {
    controller.buttons[Number(a)] = { pressed: action === "press", value: action === "press" ? 1 : 0 };
  } else if (action === "stick") {
    controller.axes[0] = Number(a);
    controller.axes[1] = Number(b);
  } else {
    throw new Error(`page_harness: no pad step called ${action}`);
  }
}

function play(frames) {
  for (let i = 0; i < frames; i++) {
    const due = waiting.splice(0);
    for (const callback of due) callback(now);
    now += FRAME_MS;
  }
}

function picture() {
  const colors = [];
  for (let i = 0; i < shown.length; i += 4) {
    colors.push((shown[i] >> 3) | ((shown[i + 1] >> 3) << 5) | ((shown[i + 2] >> 3) << 10));
  }
  return colors.join(",");
}

vm.runInNewContext(fs.readFileSync(process.argv[2], "utf8"), vm.createContext(page));

const printed = [];
for (const line of fs.readFileSync(0, "utf8").split("\n")) {
  const [step, what, ...rest] = line.trim().split(" ");
  if (step === "down") press("keydown", what);
  else if (step === "up") press("keyup", what);
  else if (step === "pad") pad(what, ...rest);
  else if (step === "play") play(Number(what));
  else if (step === "picture") printed.push(`picture ${picture()}`);
  else if (step === "text") printed.push(`text ${what} ${page.document.getElementById(what).textContent}`);
  else if (step) throw new Error(`page_harness: no step called ${step}`);
}
if (!said.hidden) printed.push(`said ${said.textContent}`);
fs.writeSync(1, `${printed.join("\n")}\n`);
