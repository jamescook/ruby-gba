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
first-person view, walls textured from VSWAP, doors that slide open and shut, pushwalls, all
five kinds of enemy — guard, officer, SS, dog and mutant — that patrol, hear and see you, close
in, and shoot or bite, and can be shot and killed, the things and pickups standing in the rooms,
all four weapons drawn in your hands and shown on the status bar, and the game's sound effects
through the sampled mixer. Without your own copy of the data the cartridge
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
twenty-four faces that watch you, the four guns, the title screen, and both of Wolfenstein's
proportional alphabets. The bar and the menus draw with it; the bar's own labels are cut out of
the plate.

### The bar does not have room for everything the original's has

Wolfenstein's bar carries eight fields across 320 columns; this screen is 240. The pictures and
figures alone come to 192 of those, and the five words above them add 46 more — 238, with two
columns left to divide between nine separations. It does not fit, and no amount of shrinking
makes it: a groove between two fields is two columns wide and has to start on an even one, so a
gap of four is already too narrow to keep clear of the lettering on both sides, and even a gun
drawn half size leaves gaps of two.

So one field goes, and it is **the floor number** — 26 columns for a number that is set when a
floor starts and never moves again, where everything else on the bar answers to what the player
is doing. The weapon takes its place, at the far right where the original puts it, drawn at 36
columns of its 48. That is not a taste either: three quarters is the reduction the whole screen
is already under, 240 of 320. What it costs is detail rather than the point of the field — two
of every three columns and rows are kept, and the four guns stay as far apart from each other as
they were, between a quarter and a half of any pair's pixels differing at either size. The seven
fields and the six gaps then come to exactly 240.

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
this does both. They decide **which enemies are there**: plane 1 holds each kind's eight spawn codes
three times over, once for every game, once from the middle setting up and once for the hardest,
so the first floor stands up ten men on "Can I play, Daddy?" and thirty-two on "I am Death
incarnate!". And they decide **what a shot takes off you** — a quarter of it on the easiest
setting, which is the easiest setting alone: "Don't hurt me." hurts you as much as the hardest
does, and the two easiest bring in exactly the same men. (They also toughen a mutant, and only a
mutant: 45 hit points on the easiest and 65 on the hardest, where everything else is flat.)

The cartridge carries every setting's enemies, because the screen that asks is a long way after
the build. Carrying them costs a frame nothing — one its setting leaves out is never spawned, so
it takes no slot, is never drawn and never thinks. Standing them up costs what you would expect
and it is worth knowing before you pick: on the busiest floor of the first episode the easiest
setting runs at 30 frames a second, the middle one at 29, and the hardest at 20.

**Five kinds of enemy walk the floors**, which is every kind Wolfenstein has short of its
bosses: the brown guard, the officer, the SS, the dog and the mutant. Each is the same shape of
thing — a place, a facing, eight poses, a state table and a mind — with different numbers in it,
and the numbers are what you feel:

| | takes | runs at | fires | leaves | worth |
|---|---|---|---|---|---|
| guard | 25 | 3× its walk | 3 pictures, one shot | half a clip | 100 |
| dog | 1 | 2× its walk, and it walks fast | nothing — it jumps and bites | nothing | 200 |
| officer | 50 | **5×** its walk | 3 pictures, gun up in a third of the time | half a clip | 400 |
| SS | 100 | 4× its walk | 9 pictures, **four** shots a burst | **a machine gun** | 500 |
| mutant | 45–65 | 3× its walk | 4 pictures, two shots, the first before the arm is up | half a clip | 700 |

**The SS is where the machine gun comes from**, which is most of how a player ever gets their
second weapon: the original hands you one off a dead SS when you have not got one, and half a
clip when you have. A dog is the odd one — no gun at all, so it has to reach you, and a barrel
in a corridor stops it dead where a guard shoots over the top. And the mutant is the one kind a
harder game toughens: everyone else holds the same hit points on all four settings.

**FIVE KINDS COST WHAT ONE COSTS.** A state number already says which kind is in it, so every
number a kind decides — its picture, its speed, how it attacks, how it falls, what it leaves —
is a column of a read-only table looked up by that one number. Nothing in the pool remembers a
kind and nothing branches on one. Measured on the same floor with the same ten men on it before
and after, a frame went from 421.3 scanlines to 423.0. What a floor really costs is how many
enemies stand on it, which is the game rather than the machinery.

Not yet there: **the bosses** — Hans, Schabbs, Gretel, Gift, Fat and both Hitlers — which is why
the boss floor at the end of each episode is empty; the tally between floors; and the AdLib music
and the effects Wolfenstein never recorded to raw PCM.

**Every episode your copy holds fits on one cartridge**, which for the registered release is
sixty floors and 16MB. It nearly did not: five kinds of enemy took the pool the floor's enemies
stand in from 78 slots to 145, and a list used to round its capacity up to the next power of
two — so 145 became 256, and the slots nobody planned for came out of the console's 32K of quick
memory. A list is allocated at the size it asks for now (see the framework's `list`), which gave
back 8.5K, and the routine that draws the view is three routines rather than one, so the
placement chooser can keep the parts that fit rather than turning the whole thing down.
