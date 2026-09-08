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
pickups standing in the rooms, all four weapons drawn in your hands, the status bar, and the
game's sound effects through the sampled mixer. Without your own copy of the data the cartridge
still builds; it shows a title screen and says so instead of a floor.

## How you play it

| Button | What it does |
|---|---|
| Up / Down | walk forward and back |
| Left / Right | turn |
| A | open a door, shove a secret wall, pull the lift's lever |
| B | fire what is in your hands |
| L / R | change weapon — back and forward through the ones you are carrying |
| START | pause, which is the main menu with two rows turned over |

**Four weapons, and one button to walk between them.** You start with a knife and a pistol; a
machine gun and a chain gun lie on the floors of the game and each hands you six rounds as well
as itself. The list wraps at both ends, and with nothing left to fire you cannot change at all —
an empty player is stuck with the knife until they find a clip, and the moment they do, the gun
they chose comes back on its own.

All four run the same four frames when you fire, six passes each: raise, fire, follow through,
lower. So a pistol is one press one round however hard you tap, and the way to shoot faster is a
better gun — the machine gun repeats while you hold the button and the chain gun does it twice as
fast. What a shot takes off a man is decided by how far away he is and not by what fired it, so a
chain gun is not a harder-hitting pistol, it is more pistol shots. The knife is the exception,
and it is a reach: about a cell and a half, and past that the swing meets nothing.

Whole episodes: ten floors each, and the lift at the end of one takes you to the next. Step into
the car, face the lever, and pull it. On floor one the lift is behind the elevator door at the
north end of the map, and there is a second, secret one that takes you to the hidden floor.

## How much of the game the cartridge holds

Every episode your copy has, by default — six for the registered release, one for the shareware.
Say otherwise when you are building over and over:

```sh
WOLF3D_EPISODES=1     ruby wolf3d.rb    # just the first
WOLF3D_EPISODES=1,3   ruby wolf3d.rb    # the first and the third
WOLF3D_EPISODES=2-4   ruby wolf3d.rb    # the second to the fourth
```

**Nothing about it reaches the frame rate** — it is ROM and build time and nothing else. Each
floor adds its map, its blocking, its doors, its walls that move, its guards and everything lying
on it, and none of that is work the game does while you play. Measured on the registered release:

| | ROM | build |
|---|---|---|
| all six episodes | 8MB | about a minute |
| one episode | 4MB | about eight seconds |

There are two smaller dials underneath, for measuring rather than for playing. `WOLF3D_FLOORS=N`
keeps only the first N floors of whatever the episodes picked — `WOLF3D_FLOORS=1` is the fastest
build there is, which is what you want while changing something else. `WOLF3D_FROM=N` skips the
first N, because a cartridge boots on the first floor it holds and the only way to read what a
*later* floor costs is to build one that starts there:

```sh
WOLF3D_FROM=1 WOLF3D_FLOORS=1 ruby ../../bin/ruby-gba explain wolf3d.rb
```

Floors differ enormously in what stands on them — the second floor of episode one carries three
times the guards and three times the scenery of the first — so "what does a frame cost" has no
single answer for the game, only one per floor.

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
| The episode list | NEW GAME — on a cartridge holding more than one episode |
| The difficulty screen | NEW GAME, then an episode |
| The game | pick a difficulty |
| The pause menu | START, while playing — it is the main menu with two rows turned over |

Two of those are slow to reach, so the cartridge can be told to boot on any of them. It is a
measuring dial, not a way to play:

```sh
WOLF3D_SCREEN=credits ruby wolf3d.rb
```

The names are `notice`, `title`, `credits`, `menu`, `episodes`, `difficulty` and `playing`.
Asking for `episodes` on a cartridge holding one is a build error that says so.

**The title and the credits drift.** Both were painted 320×200 for a screen this console does
not have. Squeezing them to 240 is what ruins the credits — its writing spans 305 of its 320
columns, so 65 columns come out of the words themselves, and every stroke there is two pixels
wide. So nothing is squeezed across: every column is kept and the *window* walks over the
eighty that do not fit, out and back, over about four fifths of the time the screen is up. Down
the screen there is nothing to lose — 72 of the credits' 200 rows are empty and only 40 need to
go — so the emptiest are taken and the writing is untouched. It moves two pixels at a time
because the double-buffered screen holds two pixels in each of its places and will not take one.

**The episode list shows what the cartridge holds.** A default build has every episode your copy
has, so all of them are pickable; a build trimmed with `WOLF3D_EPISODES` shows the rest greyed
out, which is what the shareware release does. A cartridge holding only one episode does not ask
at all — a list with one pickable row is a question with one answer — so NEW GAME goes straight
to the difficulty screen.

What the menu offers, and what it does not: NEW GAME (END GAME once a game is on), LOAD GAME
greyed until there is somewhere to keep a game, SOUND on or off, and BACK TO DEMO (BACK TO GAME
from a pause). The original's Read This!, View Scores and Control screens are not offered — the
first two have nothing to show yet and the third calibrates a mouse and a joystick.

**How tough you say you are changes the game.** Wolfenstein's four settings decide two things and
this does both. They decide **which guards are there**: plane 1 holds the same four spawn codes
three times over, once for every game, once from the middle setting up and once for the hardest,
so the first floor stands up ten men on "Can I play, Daddy?" and thirty-two on "I am Death
incarnate!". And they decide **what a shot takes off you** — a quarter of it on the easiest
setting, which is the easiest setting alone: "Don't hurt me." hurts you as much as the hardest
does, and the two easiest bring in exactly the same men.

The cartridge carries every setting's guards, because the screen that asks is a long way after
the build. Carrying them costs a frame nothing — a guard his setting leaves out is never spawned,
so he takes no slot, is never drawn and never thinks. Standing them up costs what you would
expect and it is worth knowing before you pick: on the busiest floor of the first episode the
easiest setting runs at 30 frames a second, the middle one at 29, and the hardest at 20.

Not yet there: the tally between floors, the AdLib music and the effects Wolfenstein never
recorded to raw PCM, saving progress across power-off, and the little picture of your weapon
on the status bar — the seven fields already there come to 190 of the screen's 240 columns, and
an eighth takes them past it.

There is also only ONE KIND OF GUARD, the brown one, which is why the SS never drops you a
machine gun the way he does in the original: there are no SS to fall.
