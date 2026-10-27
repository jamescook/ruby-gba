# VBlank

**Write a 2D retro game in plain Ruby, and build it for the consoles it was made for — written end to end by AI.**

The name is the pause after every frame, when the screen has finished drawing and it is safe to change the picture. Every machine a game here runs on has one, so the name fits whichever of them a game is built for.

You write Ruby. VBlank turns it into a cartridge that boots on the real console or in any emulator, and the same game can also be a program for a computer or a page in a browser. It began as a way to learn: **you need to know Ruby, not the hardware.** No video memory, no registers, no assembly, no "why is my screen black" — the framework manages the machine and turns the classic mistakes into plain-language errors. It has since grown into a tool for building real games, and those two aims share the same language. The language is about 2D games today: tiles, sprites, layers and a painted screen.

It is also an experiment in AI-native tooling: every line was written by an AI agent, and the toolchain is shaped around giving an agent (and a human) fast, readable feedback while building a game.

![Snake, built with VBlank, running in an emulator](assets/snake.gif)

> A complete Snake written in VBlank. Source: [`examples/snake.rb`](examples/snake.rb).

## Where a game runs

| Target | Status |
|---|---|
| Game Boy Advance | Fairly robust. Every feature works here, and it is what the examples are written for. |
| Game Boy Color | Underway. Much of the language works; what the Color cannot do is refused at build time, in plain words. |
| A program for a computer | Works, built from the game as C. The Mac build is played and tested; Windows and Linux builds are made but not yet run on those systems. |
| A web page | Works, built from the game as JavaScript. One file that opens from a disk or any web server. |
| Super Nintendo | Planned. |

Every game says which consoles it is for, and a build makes a cartridge for each one.

## A first game

```ruby
require "vblank"

Walk = VBlank.game "WALK", consoles: %i[gba gbc] do
  screen :bitmap
  x = var :x, 40
  y = var :y, 40

  game_loop do
    held(:left).then  { x.sub! 1 }
    held(:right).then { x.add! 1 }
    held(:up).then    { y.sub! 1 }
    held(:down).then  { y.add! 1 }

    clear_screen :black
    draw_text "WALK", :center, 8, :white
    draw_rect_at x, y, 8, 8, :yellow
  end
end

Walk.write_if_main
```

```bash
vblank new pong                            # write a starter game to pong.rb
vblank build walk.rb                       # walk.gba and walk.gbc, beside the game
vblank build walk.rb --console gbc         # the Color's cartridge alone
vblank build walk.rb --format=native       # a program for this computer
vblank build walk.rb --format=web          # walk.html
vblank preview walk.rb                     # play it in a browser; every reload rebuilds it
vblank run walk.rb                         # play it in a window, in Ruby
```

`vblank` also plays a game from a script with nobody at the controls (`play`), finds where two builds of a game start to differ (`compare`), and measures where a cartridge's frames go (`profile`). `vblank help` lists every command.

## How it works

**Mistakes become teaching errors.** The worst part of learning an old console is that a mistake rarely says what went wrong — you get a black screen, or garbled pictures, or a crash far from its cause. VBlank checks the game before it builds and says what happened and how to fix it: *drew something but never chose a screen*, *a game loop that never waits for the screen*, *a comparison used as a Ruby `if`*. A serious problem stops the build; a smaller one prints a warning. Fixes are suggested, never made silently.

**One description of the game, many targets.** The language does not write machine code as it goes. Each verb records what the game does, and the whole game is checked before anything is made. A backend then turns that description into its target: an Advance cartridge, a Color cartridge, C, or JavaScript. A Ruby interpreter runs the same description too, and it is the answer every target is tested against. A new console is a new backend, not a new language.

**Add verbs without touching the compiler.** A game can register a module of its own verbs, written in the same verbs it already uses, and from then on they read like the built-in ones. Because such a verb is made only of other verbs, it works on every target the day it is written. Screen shake and fades ship this way: see [`lib/vblank/effects/packs/`](lib/vblank/effects/packs/).

**See where the time went.** `rom.profile` (or `vblank profile game.rb`) shows what the build made and where a running cartridge spent its frames, routine by routine, measured in the emulator rather than estimated. The build uses the same measurement to choose which routines go in the console's fastest memory.

## Testing a game

A game's tests play it through the library's test helper, and each test runs on every target the game is for, compared frame by frame against the interpreter:

```ruby
require "vblank/testing"

class Minitest::Test
  include VBlank::Testing
end

def test_holding_right_walks
  played = game_player.hold(:right).run(Walk.program, frames: 6)
  assert_equal 46, played[:x]
end
```

In the game's Rakefile, `require "vblank/testing/rake_tasks"` and `VBlank::Testing::RakeTasks.new` give it a `rake test` that does this. The comments in [`lib/vblank/testing/`](lib/vblank/testing/) describe the rest.

## Examples

Every file in [`examples/`](examples/) is a complete game or demo that teaches one idea, and its header comment explains the hardware it touches. Build any of them with `ruby examples/<name>.rb`. Good places to start:

- [`pong.rb`](examples/pong.rb) — paddles, a ball, collision, scoring, music and a title menu.
- [`pacman.rb`](examples/pacman.rb) — a tiled maze, sprites, a chasing ghost and a live score; it builds for the Advance and the Color.
- [`breakout.rb`](examples/breakout.rb) — a wall of bricks, lives and scenes on a screen that never tears.
- [`shmup.rb`](examples/shmup.rb) — a game split across files, with a play, game-over and restart flow.
- [`raycaster.rb`](examples/raycaster.rb) — a first-person maze, drawn the Wolfenstein way.

## Using it in a game

Building a cartridge needs only Ruby. Checking or measuring one runs it in an emulator, through the `ruby-gba-emulator` gem, which lives in this repository but is not a dependency, so somebody who only builds cartridges needs no C compiler. Add both to a game's Gemfile in one block:

```ruby
git "https://github.com/jamescook/vblank.git", glob: "{,ruby-gba-emulator/}*.gemspec" do
  gem "vblank"
  gem "ruby-gba-emulator"
end
```

Keep it as one block. Two separate `gem ... github:` lines look the same but are two sources that clone into one folder, and the clone fails.

| To… | you need |
|---|---|
| build a cartridge, or run a game in the interpreter | Ruby |
| build a web page, or `vblank preview` | Ruby, and a browser to play it |
| play a game in a window, `vblank run` | SDL3, and `gem "fiddle"` in the game's Gemfile |
| build a program for a computer | zig 0.17 |
| import a picture from a PNG | ImageMagick (`.aseprite` files are read in Ruby) |
| test a game as JavaScript | node 18 or later |
| check or measure a cartridge | `ruby-gba-emulator`: a C compiler and libmgba |

## Status

Pre-1.0. Full games work end to end on the Game Boy Advance, and the computer and browser builds are checked against it frame by frame. The Game Boy Color is catching up. The proving grounds are ports of real games, each in its own repository, which find most of the gaps still to close: a Wolfenstein 3D port, [ruby-wolf3d](https://github.com/jamescook/ruby-wolf3d), and a port of The Legend of Zelda: The Minish Cap, which is underway and not public yet.
