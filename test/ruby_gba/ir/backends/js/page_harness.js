/*
 * Plays a web page (runtime/rg_page.js and the game, in the page a template wrote) in node, with a
 * stand-in for each part of the browser it uses: a canvas that keeps the last picture put on it
 * and can fill the screen, a window that hands out key presses, focus and the browser's frame
 * callbacks, a document that can be hidden behind another tab, a sound device that can be paused,
 * and storage that keeps the save. test_js_page.rb drives it, so what runs is the page's own
 * driver and not the windowless one. Of the page's parts the script looks for by id, only those
 * the page's HTML has are there to find — and, as in a browser, which reads a page from the top
 * and runs a script where it meets it, only those above the script while the script first runs.
 * The rest are there once the page has loaded, which the document then says (DOMContentLoaded).
 *
 * The page is named on the command line. Each line read from the input is one step:
 *
 *   down KEY [meta|ctrl|alt] / up KEY   a key going down, with Cmd, Ctrl or Alt held if named,
 *                       or coming up, by the browser's name for it (ArrowRight)
 *   pad connect         a controller plugged in, laid out the standard way (the browser's
 *                       "standard" mapping), which the page is told of
 *   pad disconnect      ...and taken out again
 *   pad press N / pad release N   its button N going down or coming up, by the standard
 *                       layout's numbering (0 the bottom face button, 12 to 15 the d-pad)
 *   pad stick X Y       its left stick pushed to X, Y, each from -1 to 1
 *   blur / focus        the window losing the keyboard to another, and getting it back
 *   hide / show         the page's tab hidden behind another, and shown again
 *   click ID            the page's element of that id clicked
 *   check ID / uncheck ID   the page's checkbox of that id ticked or cleared (each starts as the
 *                       page's HTML says, ticked where it is written "checked")
 *   play N              N of the browser's frames, each a console frame after the one before, so
 *                       the page plays one frame of the game on each; none come while hidden
 *   picture             prints "picture" and every pixel last put on the canvas, as the
 *                       console's fifteen-bit colours
 *   text ID             prints "text ID", then "hidden" if it is, then the words in the page's
 *                       element of that id now, or "text ID (none)" for a page without one
 *   state               prints "state" and what the browser holds now: the sound device
 *                       (none, running or suspended), what fills the screen (none or an id),
 *                       and how many key presses the page kept from the browser
 *
 * Started with "unfocused" after the page, the window starts without the keyboard, as a page in
 * a frame on another site does. At the end it prints "said" and the words the page showed under
 * the canvas, if it showed any.
 */
"use strict";

const fs = require("fs");
const vm = require("vm");

const FRAME_MS = 1000 * 280896 / 2 ** 24;

const html = fs.readFileSync(process.argv[2], "utf8");
const script = html.match(/<script>\n([\s\S]*)<\/script>/)[1];
const ids_in = (text) => new Set(Array.from(text.matchAll(/\bid="([^"]+)"/g), (found) => found[1]));
const at_script = html.indexOf(script);
let ids = ids_in(html.slice(0, at_script));

/* Who is listening for what: the window's own, the document's, and each element's. */
function listening() {
  const heard = {};
  return {
    heard,
    addEventListener(type, listener) { (heard[type] ||= []).push(listener); },
  };
}

function tell(target, type, more = {}) {
  for (const listener of target.heard[type] || []) listener({ preventDefault() { kept += 1; }, ...more });
}

const waiting = [];
const stored = new Map();
let now = 0;
let shown = null;
let kept = 0;
let focused = process.argv[3] !== "unfocused";

function element(id) {
  const checked = new RegExp(`<input[^>]*\\bid="${id}"[^>]*\\bchecked\\b|<input[^>]*\\bchecked\\b[^>]*\\bid="${id}"`).test(html);
  return { id, textContent: "", hidden: id === "said", checked, ...listening() };
}

const elements = Object.fromEntries(["said", "controller", "fullscreen", "pause"].map((id) => [id, element(id)]));
elements.screen = {
  ...element("screen"),
  getContext: () => ({
    createImageData: (width, height) => ({ width, height, data: new Uint8ClampedArray(width * height * 4) }),
    putImageData: (image) => { shown = Uint8ClampedArray.from(image.data); },
  }),
  requestFullscreen() { document.fullscreenElement = this; return Promise.resolve(); },
};

const document = {
  ...listening(),
  hidden: false,
  visibilityState: "visible",
  readyState: "loading",
  fullscreenElement: null,
  getElementById: (id) => (ids.has(id) && elements[id]) || null,
  hasFocus: () => focused,
  exitFullscreen() { document.fullscreenElement = null; return Promise.resolve(); },
};

/* The sound device: made on a page's first key press or click, as a browser allows. */
let audio = null;
class AudioContext {
  constructor() { this.state = "running"; this.currentTime = 0; this.destination = {}; audio = this; }
  resume() { this.state = "running"; return Promise.resolve(); }
  suspend() { this.state = "suspended"; return Promise.resolve(); }
  createBuffer(_channels, length) { return { getChannelData: () => new Float32Array(length) }; }
  createBufferSource() { return { connect() {}, start() {} }; }
}

/* The one controller there can be, in the browser's own shape for one. */
const pads = [null, null, null, null];
const controller = {
  id: "Stand-in Controller (STANDARD GAMEPAD)", index: 0, mapping: "standard", connected: true,
  buttons: Array.from({ length: 17 }, () => ({ pressed: false, value: 0 })),
  axes: [0, 0, 0, 0],
};

const page = {
  ...listening(),
  document,
  AudioContext,
  navigator: { getGamepads: () => pads.slice() },
  performance: { now: () => now },
  atob, btoa, console,
};
page.window = page;
page.requestAnimationFrame = (callback) => { waiting.push(callback); };
page.localStorage = { getItem: (key) => stored.get(key) ?? null, setItem: (key, value) => stored.set(key, value) };

function key(type, code, modifier) {
  tell(page, type, { code, metaKey: modifier === "meta", ctrlKey: modifier === "ctrl", altKey: modifier === "alt" });
}

function pad(action, a, b) {
  if (action === "connect") {
    pads[0] = controller;
    tell(page, "gamepadconnected", { gamepad: controller });
  } else if (action === "disconnect") {
    pads[0] = null;
    tell(page, "gamepaddisconnected", { gamepad: controller });
  } else if (action === "press" || action === "release") {
    controller.buttons[Number(a)] = { pressed: action === "press", value: action === "press" ? 1 : 0 };
  } else if (action === "stick") {
    controller.axes[0] = Number(a);
    controller.axes[1] = Number(b);
  } else {
    throw new Error(`page_harness: no pad step called ${action}`);
  }
}

function visible(shown_now) {
  document.hidden = !shown_now;
  document.visibilityState = shown_now ? "visible" : "hidden";
  tell(document, "visibilitychange");
}

/* A browser gives a hidden page no frames; the time still passes. */
function play(frames) {
  for (let i = 0; i < frames; i++) {
    if (!document.hidden) for (const callback of waiting.splice(0)) callback(now);
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

function text(id) {
  const found = document.getElementById(id);
  if (!found) return `text ${id} (none)`;
  return `text ${id} ${found.hidden ? "hidden " : ""}${found.textContent}`;
}

function state() {
  const filling = document.fullscreenElement ? document.fullscreenElement.id : "none";
  return `state audio=${audio ? audio.state : "none"} fullscreen=${filling} kept=${kept}`;
}

vm.runInNewContext(script, vm.createContext(page));
/* The rest of the page read in: every part there, and the document says it has loaded. */
ids = new Set([...ids, ...ids_in(html.slice(at_script + script.length))]);
document.readyState = "interactive";
tell(document, "DOMContentLoaded");

const printed = [];
for (const line of fs.readFileSync(0, "utf8").split("\n")) {
  const [step, what, ...rest] = line.trim().split(" ");
  if (step === "down") key("keydown", what, rest[0]);
  else if (step === "up") key("keyup", what);
  else if (step === "pad") pad(what, ...rest);
  else if (step === "blur") { focused = false; tell(page, "blur"); }
  else if (step === "focus") { focused = true; tell(page, "focus"); }
  else if (step === "hide") visible(false);
  else if (step === "show") visible(true);
  else if (step === "click") { tell(elements[what], "click"); tell(page, "pointerdown"); }
  else if (step === "check" || step === "uncheck") { elements[what].checked = step === "check"; tell(elements[what], "change"); }
  else if (step === "play") play(Number(what));
  else if (step === "picture") printed.push(`picture ${picture()}`);
  else if (step === "text") printed.push(text(what));
  else if (step === "state") printed.push(state());
  else if (step) throw new Error(`page_harness: no step called ${step}`);
}
if (ids.has("said") && !elements.said.hidden) printed.push(`said ${elements.said.textContent}`);
fs.writeSync(1, `${printed.join("\n")}\n`);
