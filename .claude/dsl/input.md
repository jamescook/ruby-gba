# DSL reference: Input

The whole story of these verbs. The one-line index is `.claude/rules/dsl-reference.md`.

- `held(:left)` — 1 while down; `pressed(:start)` — 1 on the press edge only. Use with `.then { }`.
- `held(:any)` / `pressed(:any)` — **any button at all**, which is how a game leaves an attract screen, a splash or a cut scene: `pressed(:any).then { mode.set! :title }`. `pressed(:any)` is true on a frame some button went down, the same edge each button has on its own — so A pressed while LEFT is still held counts, and a button held on and on is one press. It is one test against all ten buttons, cheaper than the ten `held` tests joined with `|` it replaces, and none can be left out. `:any` is not a button: a test's `hold(...)` and the command line's held keys refuse it, since holding "any" means nothing.
- Low-level: `if_held(:a) { }` / `if_pressed(:a) { }`. Buttons: `a b select start right left up down r l`.
