# Wolfenstein 3D

Wolfenstein 3D, built with [ruby-gba](../../README.md).

This is a game that *depends on* the framework, not another example inside it. It requires
`ruby_gba` the way anyone outside this repository would.

## You need your own copy of the game

None of Wolfenstein's data is freely licensed, so none of it is in this repository. You supply
it and the build is pointed at it. Any of these work:

| Set | Files | Where it comes from |
|---|---|---|
| Shareware | `*.WL1` | free to download; episode one |
| Registered | `*.WL6` | the GOG release, or an original disk; all six episodes |
| Spear of Destiny | `*.SOD` | the GOG release ships this too |

The build reads the files you own. It never copies them into the repository, and the converted
output is ignored by git.

## Build it

```sh
cd games/wolf3d
rake build          # or: ruby wolf3d.rb — writes wolf3d.gba beside this README
```

## Test it

```sh
cd games/wolf3d
rake test:parallel                  # the suite, across processes
rake test TEST=test/test_maps.rb    # one file
```

The framework's own suite does not run this one and knows nothing about it. That is
deliberate in both directions: most of what this checks needs game data nobody can
redistribute, so it would fail on every machine but yours — and a library should not have to
know the names of the games built on it. Tests that need the data skip and say so; the rest
always run.

It lives in this repository only because ruby-gba is pre-1.0 and the two move together. A
separate repository would mean a version bump for every experiment.

## What works so far

A floor of the real game, read from your own copy of the data and playable in an emulator: the
first-person view, walls textured from VSWAP, doors that slide open and shut, pushwalls, guards
that patrol, hear and see you, close in, and shoot — and can be shot and killed — the things and
pickups standing in the rooms, the status bar, and the game's sound effects through the sampled
mixer. Without your own copy of the data the cartridge still builds; it shows a title screen and
says so instead of a floor.

A whole episode: ten floors, and the lift at the end of each one takes you to the next. Step into
the car, face the lever, and pull it. On floor one the lift is behind the elevator door at the
north end of the map, and there is a second, secret one that takes you to the hidden floor.

How many floors the cartridge holds is a build-time choice, ten by default:

```sh
WOLF3D_FLOORS=3 ruby wolf3d.rb    # a shorter build, for trying something out
```

Nothing about it reaches the frame rate; it is ROM and build time. Ten floors is a 4MB cartridge
and about eight seconds to build.

The art in VGAGRAPH is read now — the status bar's steel plate, the numerals it counts in, the
twenty-four faces that watch you, the title screen, and both of Wolfenstein's proportional
alphabets. The bar and the menus draw with it; the bar's own labels are cut out of the plate.

## The menus

The cartridge boots the way the game does: the rating box, then a loop of still screens — the
title, the credits, round again — that any button breaks out of into the menu. There is no
"press start" anywhere in Wolfenstein, and there is none here.

| Screen | How you reach it |
|---|---|
| The rating box | at boot |
| The title screen | wait 5 seconds, or `WOLF3D_SCREEN=title` |
| The credits | wait 20 seconds, or `WOLF3D_SCREEN=credits` |
| The main menu | any button, from any of those |
| The episode list | NEW GAME — **only on a cartridge holding more than one episode** |
| The difficulty screen | NEW GAME, then an episode |
| The game | pick a difficulty |
| The pause menu | START, while playing — it is the main menu with two rows turned over |

Two of those are slow to reach and one does not exist on a default build, so the cartridge can
be told to boot on any of them. It is a measuring dial like `WOLF3D_FLOORS`, not a way to play:

```sh
WOLF3D_SCREEN=credits ruby wolf3d.rb              # boots on the credits
WOLF3D_FLOORS=20 WOLF3D_SCREEN=episodes ruby wolf3d.rb   # two episodes, and the list to pick between them
```

The names are `notice`, `title`, `credits`, `menu`, `episodes`, `difficulty` and `playing`.

**The title and the credits drift.** Both were painted 320×200 for a screen this console does
not have. Squeezing them to 240 is what ruins the credits — its writing spans 305 of its 320
columns, so 65 columns come out of the words themselves, and every stroke there is two pixels
wide. So nothing is squeezed across: every column is kept and the *window* walks over the
eighty that do not fit, out and back, over about four fifths of the time the screen is up. Down
the screen there is nothing to lose — 72 of the credits' 200 rows are empty and only 40 need to
go — so the emptiest are taken and the writing is untouched. It moves two pixels at a time
because the double-buffered screen holds two pixels in each of its places and will not take one.

**The episode list needs more than one episode on the cartridge.** A default build ships ten
floors, which is episode one, and a list with one pickable row is a question with one answer —
so NEW GAME goes straight to the difficulty screen. Build with `WOLF3D_FLOORS=20` for two
episodes (sixty for all six), and the list appears with the episodes you did not build greyed
out, which is what the shareware release does.

What the menu offers, and what it does not: NEW GAME (END GAME once a game is on), LOAD GAME
greyed until there is somewhere to keep a game, SOUND on or off, and BACK TO DEMO (BACK TO GAME
from a pause). The original's Read This!, View Scores and Control screens are not offered — the
first two have nothing to show yet and the third calibrates a mouse and a joystick.

Not yet there: the tally between floors, the AdLib music and the effects Wolfenstein never
recorded to raw PCM, a difficulty that changes which guards a floor holds rather than being
written down and unread, and saving progress across power-off.
