/*
 * Plays a web page's script (runtime/rg_page.js and the game) in node, with a stand-in for each
 * part of the browser it uses: a canvas that keeps the last picture put on it, a window that
 * hands out key presses and the browser's frame callbacks, and storage that keeps the save.
 * test_js_page.rb drives it, so what runs is the page's own driver and not the windowless one.
 *
 * The script is named on the command line. Each line read from the input is one step:
 *
 *   down KEY / up KEY   a key going down or coming up, by the browser's name for it (ArrowRight)
 *   play N              N of the browser's frames, each a console frame after the one before, so
 *                       the page plays one frame of the game on each
 *   picture             prints "picture" and every pixel last put on the canvas, as the
 *                       console's fifteen-bit colours
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

const canvas = {
  getContext: () => ({
    createImageData: (width, height) => ({ width, height, data: new Uint8ClampedArray(width * height * 4) }),
    putImageData: (image) => { shown = Uint8ClampedArray.from(image.data); },
  }),
};

const page = {
  window: null,
  document: { getElementById: (id) => ({ screen: canvas, said })[id] || null },
  performance: { now: () => now },
  atob, btoa, console,
};
page.window = page;
page.addEventListener = (type, listener) => { (listeners[type] ||= []).push(listener); };
page.requestAnimationFrame = (callback) => { waiting.push(callback); };
page.localStorage = { getItem: (key) => stored.get(key) ?? null, setItem: (key, value) => stored.set(key, value) };

function press(type, code) {
  for (const listener of listeners[type] || []) listener({ code, preventDefault() {} });
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
  const [step, what] = line.trim().split(" ");
  if (step === "down") press("keydown", what);
  else if (step === "up") press("keyup", what);
  else if (step === "play") play(Number(what));
  else if (step === "picture") printed.push(`picture ${picture()}`);
  else if (step) throw new Error(`page_harness: no step called ${step}`);
}
if (!said.hidden) printed.push(`said ${said.textContent}`);
fs.writeSync(1, `${printed.join("\n")}\n`);
