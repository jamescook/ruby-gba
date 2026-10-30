# What each verb does on a Game Boy Color

2026-10-18

**The question.** The Game Boy Color is a much smaller machine than the Advance. Some of what a
game can write carries straight over; some has no hardware there at all. What does the build do
with each verb, what does it say, and how does a game say it is meant for both consoles?

**The answer per verb is in code**, `Console::GBCFeatures::ANSWERS`
(`lib/vblank/console/gbc_features.rb`), where the build checks read it and the DSL reference
shows it beside each verb. `test/all/vblank/console/test_gbc_features.rb` fails for a verb with no
answer, so a new verb cannot reach a Game Boy Color undecided. This note is the policy behind the
table.

## The machine

| | Advance | Color |
|---|---|---|
| screen | 240×160 | 160×144 |
| picture | a painted screen, or tiled with up to four layers, one of them able to turn | tiled only: one background layer (and a window over it) |
| sprites | 128, shapes up to 64×64, turn and resize | 40, 8×8 or 8×16, ten on any one row |
| colours | 16 lists of 16 for backgrounds, the same for sprites | 8 lists of 4 for backgrounds, 8 of 3 and see-through for sprites |
| effects | blending, fades on the display, mosaic, windows | none of them; colours can be rewritten between frames |
| sound | the four voices, plus recordings mixed into two more | the four voices only |
| buttons | ten | eight: no L or R |
| work memory | 32K quick and 256K roomy | 8K (32K in banks) |

## Three answers

- **Works.** The same game, played the same way, frame for frame. The checked run holds the
  cartridge to the interpreter on every pass, so this is a promise the test suite keeps.
- **Degrades.** The build goes on and says once, in plain words, what will look different and
  why. The difference is a defined one, and the interpreter makes the same one when it plays the
  game for a Game Boy Color, so the checked run still agrees pixel for pixel. The cases:
  - a turning or resizing background (`screen :rotozoom`, `rotate`, `scale`) is shown as a plain
    background, unturned at its own size — the epic's own example;
  - a turning or resizing sprite (`scale`, `face_angle`, `turn`, `pulse`) is shown upright at its
    own size;
  - `pixelate` and its walks leave the picture sharp, while `pixelate_size` still walks, so a
    scene waiting on it changes on the same frame;
  - `scroll_each_row` leaves the rows unbent;
  - `debug_halt` stops the game without cutting the cartridge short, and `dump_func` prints
    nothing, since there is no ARM to list.
- **Refused.** The build stops before anything is made, saying what the game asked for and what
  to use instead. A feature is refused rather than degraded when what would be left is not the
  game any more: a recording that plays as silence (`sample`, `instrument`, a song part on a
  recording), a light that never falls (`spotlight`, the iris), a layer seen through another
  (`transparency:`), a fade held to part of the screen (`inside:`, `outside:`), the raw ARM of
  `entry`, the shoulder buttons, a second background showing at once, a painted screen with more
  than four colours on it, and `camera` over a painted picture larger than the screen.

The north star decides between the last two: this is a teaching tool, so the console never shows a
silent black screen where the author expected something. When the machine cannot do a thing and
there is no honest lesser version of it, the author hears it while building, with the alternative
named, and not while playing.

## The painted screen

A Game Boy Color has no screen to paint pixels into, and Pong — the first game this lowering
builds — paints its rally. So a painted screen **works**, at a stated cost, rather than being
refused: the build paints into a set of tiles that cover the screen one tile per cell, and only the
cells that changed are copied to the console between frames. Every cell shares one list of four
colours, which is why a painted screen holds four colours at once; the build counts the colours a
game paints with (every fill, every picture blitted, every letter) and refuses a game that paints
with more, naming them. A fade or a tint rewrites those four, as it rewrites every other list.

## A game says which consoles it is for

`VBlank.game "PONG", consoles: %i[gba gbc] do ... end`. Without it a game is built for the Advance
alone, and building it for a Game Boy Color is refused in plain words. That is deliberate: a game
laid out for 240×160 and shown on 160×144 loses a third of its picture, and no warning makes that
right. Saying `consoles:` is the author's statement that the game reads the screen it is given —
`screen_width` and `screen_height` in the game's block, rather than 240 and 160 written in — which
is the subject of the next decision (one game, two screen sizes).

A game for both is checked once per console: the build checks what it checks today, and then, for
a Game Boy Color, the answers above.
