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
rake test
```

The framework's own `rake test` does not run this suite and knows nothing about it. That is
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

Not yet there: the game's own menus and lettering (still packed inside VGAGRAPH, undecoded), the
AdLib music and the effects Wolfenstein never recorded to raw PCM, a difficulty picked at the
title screen rather than baked into the build, what happens at the end of a floor, and saving
progress across power-off.
