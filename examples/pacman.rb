#!/usr/bin/env ruby
# frozen_string_literal: true

# Pac-Man — the tiled-mode showcase. Steer Pac-Man around a tiled room with the
# D-pad: he turns to face the way he's going, eats the pellets, and is chased by a
# ghost. It's the counterpart to examples/breakout.rb (which showcases the
# bitmap-mode engine): this puts the whole TILE + HARDWARE-SPRITE stack together the
# way a real console game does.
#
# What it shows off, all through the friendly DSL and never a hardware register:
#   * a TILED BACKGROUND — the room, drawn from two 8x8 tiles and a character map;
#     the console repaints it every frame for free.
#   * HARDWARE SPRITES — because the screen is `:tiled`, Pac, the pellets, and the
#     ghost are drawn by the console's sprite hardware and composited over the room.
#     No screen clearing, no trails — moving one is just changing its position.
#   * FACING — Pac-Man is a `sprite` given a POSE per direction via `facing:`, so
#     `pac.move :left` slides him left AND turns him to face left in one call. On a
#     tiled screen the console swaps which of his uploaded pictures it draws.
#   * COLLISION — Pac, the pellets, and the ghost are all sprites, so each knows its
#     own rectangle: `pac.overlaps?(pellet)` and `ghost.overlaps?(pac)` need no boxes.
#   * SOUND — a waka when Pac eats, a buzz when the ghost catches him.
#
# Run into a pellet to eat it (it reappears elsewhere and the SCORE climbs); let the
# ghost touch you and Pac jumps back to the middle. The room is open — Pac is kept
# inside its walls. (Corridor mazes with wall collision are a tiled feature still
# ahead; this example grows as they land.)
#
# The four Pac poses are generated, not hand-drawn: a yellow disc with a wedge — the
# mouth — bitten out on the side he faces. Turning to an arbitrary angle would need
# the console's affine hardware, a different feature.
#
# Run it to build examples/pacman.gba:
#   ruby examples/pacman.rb

require_relative "../lib/ruby_gba"

module Pacman
  SPEED = 2
  SIZE  = 16          # a 16x16 Pac-Man (sprite sizes are built from 8x8 tiles)
  R     = SIZE / 2    # radius (and the centre offset)
  DIRS  = %i[right left up down].freeze

  # The room's floor, in pixels: inside the one-tile wall border (8..231 across,
  # 8..151 down). Pac and the pellets are kept within it.
  FLOOR_X = (8..(240 - 8 - SIZE)).freeze
  FLOOR_Y = (8..(160 - 8 - SIZE)).freeze
  PELLET_SPOTS = [[112, 40], [48, 40], [184, 40], [48, 112], [184, 112]].freeze
  START = [(240 - SIZE) / 2, (160 - SIZE) / 2].freeze
  GHOST_START = [24, 24].freeze

  # A bordered room that fills the screen: a wall around the edge, floor inside.
  ROOM = (["#" * 30] + Array.new(18, "##{'.' * 28}#") + ["#" * 30]).freeze

  # Pac-Man facing +dir+, as ASCII art: 'Y' is a lit (yellow) body pixel, '.' is
  # transparent. He's the disc of radius R. With his mouth open, a triangular wedge —
  # the mouth — is bitten out on the side he faces, so the field shows through it; with
  # his mouth shut he is a full disc. Alternating the two frames is the chomp. The game
  # does not call this at run time; assets/gen_pacman_sheet.rb bakes it into
  # pacman_sheet.png, which the game imports with `facing_from:` (see below).
  def self.pacman_art(dir, open: true)
    (0...SIZE).map do |y|
      (0...SIZE).map do |x|
        dx = x - R
        dy = y - R
        in_disc = (dx * dx) + (dy * dy) <= R * R
        bite = open && in_mouth?(dx, dy, dir)
        in_disc && !bite ? "Y" : "."
      end.join
    end.join("\n")
  end

  # The mouth is a right-angle wedge opening toward +dir+ from the centre.
  def self.in_mouth?(dx, dy, dir)
    case dir
    when :right then dx.positive? && dx > dy.abs
    when :left  then dx.negative? && -dx > dy.abs
    when :up    then dy.negative? && -dy > dx.abs
    when :down  then dy.positive? && dy > dx.abs
    end
  end

  # A little 8x8 pellet (a white dot with transparent corners).
  PELLET_ART = <<~ART
    ........
    ........
    ..oooo..
    ..oooo..
    ..oooo..
    ..oooo..
    ........
    ........
  ART

  # A 16x16 ghost: a red dome with two white eyes and a ragged skirt.
  GHOST_ART = <<~ART
    ....RRRRRRRR....
    ..RRRRRRRRRRRR..
    .RRRRRRRRRRRRRR.
    RRRRRRRRRRRRRRRR
    RRRRRRRRRRRRRRRR
    RRRWWWRRRRWWWRRR
    RRRWWWRRRRWWWRRR
    RRRWWWRRRRWWWRRR
    RRRRRRRRRRRRRRRR
    RRRRRRRRRRRRRRRR
    RRRRRRRRRRRRRRRR
    RRRRRRRRRRRRRRRR
    RRRRRRRRRRRRRRRR
    RRRRRRRRRRRRRRRR
    RRRR..RRRR..RRRR
    RR....RR....RR..
  ART

  # The game as a block the builder runs, so a test can drive the exact program that
  # ships — the headless interpreter runs THIS, the console runs the ROM.
  GAME = RubyGBA.game("PACMAN", code: "BPAC", maker: "01") do
    screen :tiled # tile mode: a background layer for the room + hardware sprites on top
    enable_sound
    define_sound :waka,   frequency: 660, duty: :half, decay: :fast
    define_sound :caught, frequency: 90,  duty: :half, decay: :slow, volume: 12
    seed 1 # so each eaten pellet reappears somewhere new, the same way every run

    # --- the room, out of two 8x8 tiles and a map ---
    image :wall, "#" => :gray, "." => rgb(9, 9, 9) do
      <<~ART
        ########
        #......#
        ########
        ...####.
        ########
        .####...
        ########
        #......#
      ART
    end
    image :floor, "." => rgb(4, 4, 8), "o" => rgb(8, 8, 12) do
      <<~ART
        ........
        ..o.....
        ........
        .....o..
        ........
        ...o....
        ........
        ......o.
      ART
    end
    tiles :dungeon, "#" => :wall, "." => :floor
    background :room, tiles: :dungeon, map: ROOM

    # --- Pac-Man: a two-frame chomp per direction, imported from a sprite sheet ---
    # pacman_sheet.png is a grid — one row per direction (in DIRS order), two columns
    # (mouth open, then a shut full disc) — baked from the pacman_art formula below by
    # assets/gen_pacman_sheet.rb. `facing_from:` slices it back into per-direction frames,
    # so Pac chomps whichever way he faces: this is the way a real game brings in art,
    # from a file rather than typed inline. (Re-run the generator if you change the
    # formula.)
    pac = sprite :pac, at: START, rate: 6,
                       facing_from: "assets/pacman_sheet.png", tile: SIZE,
                       dirs: DIRS, transparent: true

    # --- the pellets: a sprite each, scattered on the floor ---
    image(:pellet, "." => :transparent, "o" => :white) { PELLET_ART }
    pellets = PELLET_SPOTS.map { |px, py| sprite :pellet, at: [px, py] }
    eaten = var :eaten, 0 # how many pellets Pac-Man has swallowed

    # --- the ghost ---
    image(:ghost, "." => :transparent, "R" => :red, "W" => :white) { GHOST_ART }
    ghost = sprite :ghost, at: GHOST_START
    caught = var :caught, 0 # how many times the ghost has caught Pac

    # --- the score, right on the screen ---
    # A tiled screen has no framebuffer to paint text into, so draw_text / draw_number
    # draw each character as a little sprite the console lays over the game. You declare
    # them ONCE here (like a sprite); the number then follows :eaten and repaints itself
    # every frame — there's nothing to redraw inside the loop.
    draw_text "SCORE", 8, 4, :white
    draw_number :eaten, 46, 4, :white, digits: 3

    game_loop do
      # Hold a direction: Pac moves that way AND turns to face it — one call each.
      held(:left).then  { pac.move :left,  by: SPEED }
      held(:right).then { pac.move :right, by: SPEED }
      held(:up).then    { pac.move :up,    by: SPEED }
      held(:down).then  { pac.move :down,  by: SPEED }
      pac.x.clamp FLOOR_X.min, FLOOR_X.max # keep him inside the walls
      pac.y.clamp FLOOR_Y.min, FLOOR_Y.max

      # Eat a pellet Pac is touching. Both are sprites, so each knows its rectangle —
      # no boxes: just ask whether they overlap. On a bite, count it, waka, and send
      # the pellet somewhere new on the floor.
      pellets.each do |pellet|
        pac.overlaps?(pellet).then do
          eaten.add 1
          beep :waka
          pellet.move_to rand(FLOOR_X), rand(FLOOR_Y)
        end
      end

      # The ghost creeps toward Pac each frame.
      (ghost.x < pac.x).then { ghost.move :right }
      (ghost.x > pac.x).then { ghost.move :left }
      (ghost.y < pac.y).then { ghost.move :down }
      (ghost.y > pac.y).then { ghost.move :up }

      # Caught! Buzz, count it, and reset the chase — Pac back to the middle and the
      # ghost back to its corner, so it doesn't sit on top of Pac buzzing every frame.
      ghost.overlaps?(pac).then do
        beep :caught
        caught.add 1
        pac.move_to(*START)
        ghost.move_to(*GHOST_START)
      end
    end
  end

  def self.program = GAME.program
  def self.build_rom(**kwargs) = GAME.build_rom(**kwargs)
end

Pacman::GAME.write_if_main
