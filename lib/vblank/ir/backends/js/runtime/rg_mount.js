/*
 * The web build's own page, as a caller of createGame: the page's parts, found by the ids the
 * page template gives them (JS::Page), handed to the game. Outside createGame, so it is not part
 * of any game; the module and the classic script leave it out, and a page of the author's own
 * does what it does here, its own way.
 *
 *   screen      the canvas (the one part a page must have)
 *   controller  says which controllers are connected
 *   said        says why a game stopped, or to click the game to play
 *   pause       a checkbox: ticked, the game pauses while another window has the keyboard
 *   fullscreen  a button that fills the screen with the game (hidden where a browser cannot), or
 *               with the whole page when it has a touchpad, so the pad comes too
 *   touchpad    the console's buttons on the screen: "pad-cross", and "pad-a" to "pad-select",
 *               inside it (mount_touchpad says how they are played); shown while a finger is the
 *               screen's main pointer
 *
 * It starts once the whole page is read. A browser runs a script where it meets it, and a
 * template is free to put the game above the parts looked for here, which are not there yet when
 * the script first runs.
 */

function rg_mount_page(createGame) {
  function mount() {
    const part = (id) => document.getElementById(id);
    const said = part("said");
    const note = part("controller");
    const box = part("pause");
    const button = part("fullscreen");
    let said_kind = null;
    const game = createGame({
      canvas: part("screen"),
      /* With the pad on the page, the whole page fills the screen, so the pad comes with the game. */
      fullscreenElement: part("touchpad") ? document.documentElement : undefined,
      pauseWhenUnfocused: box ? box.checked : true,
      onMessage(kind, text) {
        if (kind === "controller") {
          if (note) note.textContent = text;
        } else if (said && text !== null) {
          said.textContent = text;
          said.hidden = false;
          said_kind = kind;
        } else if (said && said_kind === kind) {
          said.hidden = true; /* what it said has passed, and nothing else was said since */
        }
      },
    });
    if (box) box.addEventListener("change", () => game.setPauseWhenUnfocused(box.checked));
    if (button && !game.canFillScreen) button.hidden = true;
    else if (button) button.addEventListener("click", () => game.toggleFullscreen());
    mount_touchpad(game, part);
  }

  /* THE PAD. Its buttons are the parts whose id starts "pad-", each the console's button of the
   * rest of its name ("pad-a" is A), and "pad-cross" is the cross: one piece, as a console's is,
   * that a thumb rocks round rather than four buttons it has to lift off and put down again.
   *
   * Every finger is followed from when it goes down until it lifts, and holds what it is on now:
   * a finger slid from B to A lets go of B, and one slid off the pad holds nothing. A finger that
   * went down on the cross stays on the cross, and holds the direction it is pushed from the
   * cross's middle, or two between them, as a thumb that slips past the edge still does on a
   * console. A button is held while any finger holds it.
   *
   * The pad captures each finger, so its moves and its lifting come here even off the pad, where a
   * browser would otherwise send them to whatever is under it. A long press is the game's, not
   * the browser's menu.
   *
   * It shows while the screen's main pointer is a finger, as a phone's is, and not on a computer
   * whose screen can be touched but which has a mouse; a tablet given a keyboard says so, and the
   * pad hides. */
  function mount_touchpad(game, part) {
    const pad = part("touchpad");
    if (!pad) return;
    const finger_first = window.matchMedia ? window.matchMedia("(pointer: coarse)") : null;
    const show_pad = () => { pad.hidden = !(finger_first && finger_first.matches); };
    show_pad();
    if (finger_first && finger_first.addEventListener) finger_first.addEventListener("change", show_pad);
    pad.addEventListener("contextmenu", (event) => event.preventDefault());

    const cross = part("pad-cross");
    const keys = Array.from(pad.querySelectorAll('[id^="pad-"]')).filter((key) => key !== cross);
    const fingers = new Map(); /* each finger down, by the browser's number for it: what it holds */
    let held = new Set();

    const inside = (box, x, y) => x >= box.left && x < box.right && y >= box.top && y < box.bottom;

    function buttons_under(finger, x, y) {
      if (finger.on_cross) return cross_directions(cross.getBoundingClientRect(), x, y);
      const key = keys.find((each) => inside(each.getBoundingClientRect(), x, y));
      return key ? [key.id.slice("pad-".length)] : [];
    }

    function hold_what_fingers_hold() {
      const now = new Set();
      for (const finger of fingers.values()) for (const name of finger.holds) now.add(name);
      for (const name of now) if (!held.has(name)) game.press(name);
      for (const name of held) if (!now.has(name)) game.release(name);
      held = now;
    }

    pad.addEventListener("pointerdown", (event) => {
      event.preventDefault();
      if (pad.setPointerCapture) pad.setPointerCapture(event.pointerId);
      const on_cross = Boolean(cross) && inside(cross.getBoundingClientRect(), event.clientX, event.clientY);
      const finger = { on_cross, holds: [] };
      finger.holds = buttons_under(finger, event.clientX, event.clientY);
      fingers.set(event.pointerId, finger);
      hold_what_fingers_hold();
    });
    pad.addEventListener("pointermove", (event) => {
      const finger = fingers.get(event.pointerId);
      if (!finger) return; /* a mouse passing over, with no button down */
      finger.holds = buttons_under(finger, event.clientX, event.clientY);
      hold_what_fingers_hold();
    });
    for (const type of ["pointerup", "pointercancel"]) {
      pad.addEventListener(type, (event) => {
        fingers.delete(event.pointerId);
        hold_what_fingers_hold();
      });
    }
  }

  /* The directions a thumb at (x, y) pushes a cross in +box+: the circle round the middle is cut
   * into eight slices, one for each direction and one for each pair of them between, and a little
   * way round the middle pushes nothing. A browser counts down the screen, so a positive dy is
   * down. */
  const CROSS_SLICES = [["right"], ["right", "down"], ["down"], ["down", "left"], ["left"], ["left", "up"], ["up"],
    ["up", "right"]];
  const CROSS_MIDDLE = 0.25; /* out of the way from the middle to the edge */

  function cross_directions(box, x, y) {
    const dx = (x - (box.left + box.width / 2)) / (box.width / 2);
    const dy = (y - (box.top + box.height / 2)) / (box.height / 2);
    if (Math.hypot(dx, dy) < CROSS_MIDDLE) return [];
    const slice = Math.round(Math.atan2(dy, dx) / (Math.PI / 4));
    return CROSS_SLICES[((slice % 8) + 8) % 8];
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", mount, { once: true });
  else mount();
}
