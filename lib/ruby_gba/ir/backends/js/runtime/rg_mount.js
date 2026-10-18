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
 *   fullscreen  a button that fills the screen with the game (hidden where a browser cannot)
 *   touchpad    the console's buttons on the screen, "pad-a" to "pad-select" inside it, each
 *               pressing its button while a finger is on it; shown on a screen a finger points
 *               at, hidden on one a mouse does
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

  /* A finger on a pad button holds its button until it lifts, slides off, or the browser takes
   * the touch back (a scroll, a call coming in). A long press is the game's, not the browser's
   * menu. */
  function mount_touchpad(game, part) {
    const pad = part("touchpad");
    if (!pad) return;
    pad.hidden = !(window.matchMedia && window.matchMedia("(any-pointer: coarse)").matches);
    pad.addEventListener("contextmenu", (event) => event.preventDefault());
    for (const name of ["a", "b", "select", "start", "right", "left", "up", "down", "r", "l"]) {
      const key = part(`pad-${name}`);
      if (!key) continue;
      key.addEventListener("pointerdown", (event) => {
        event.preventDefault();
        game.press(name);
      });
      for (const type of ["pointerup", "pointercancel", "pointerleave"]) key.addEventListener(type, () => game.release(name));
    }
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", mount, { once: true });
  else mount();
}
