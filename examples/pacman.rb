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
# Run into a pellet to eat it (it reappears elsewhere and your count climbs); let the
# ghost touch you and Pac jumps back to the middle. The room is open — Pac is kept
# inside its walls. (Corridor mazes with wall collision, and an on-screen score, are
# tiled features still ahead; this example grows as they land.)
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
  # transparent. He's the disc of radius R with a triangular wedge — the mouth —
  # bitten out on the side he faces, so the field shows through it.
  def self.pacman_art(dir)
    (0...SIZE).map do |y|
      (0...SIZE).map do |x|
        dx = x - R
        dy = y - R
        in_disc = (dx * dx) + (dy * dy) <= R * R
        in_disc && !in_mouth?(dx, dy, dir) ? "Y" : "."
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
  GAME = proc do
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

    # --- Pac-Man, one yellow pose per direction ---
    DIRS.each do |dir|
      image(:"pac_#{dir}", "." => :transparent, "Y" => :yellow) { Pacman.pacman_art(dir) }
    end
    pac = sprite :pac, at: START,
                       facing: { right: :pac_right, left: :pac_left, up: :pac_up, down: :pac_down }

    # --- the pellets: a sprite each, scattered on the floor ---
    image(:pellet, "." => :transparent, "o" => :white) { PELLET_ART }
    pellets = PELLET_SPOTS.map { |px, py| sprite :pellet, at: [px, py] }
    eaten = var :eaten, 0 # how many pellets Pac-Man has swallowed

    # --- the ghost ---
    image(:ghost, "." => :transparent, "R" => :red, "W" => :white) { GHOST_ART }
    ghost = sprite :ghost, at: GHOST_START
    caught = var :caught, 0 # how many times the ghost has caught Pac

    game_loop do
      wait_vblank # the framework draws the sprites here, in the safe window

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

  def self.build_rom(out: $stdout, err: $stderr)
    RubyGBA.build("PACMAN", code: "BPAC", maker: "01", out: out, err: err, &GAME)
  end

  def self.program
    builder = RubyGBA::Builder.new
    builder.instance_eval(&GAME)
    builder.emit_pending_functions
    builder.program
  end
end

if __FILE__ == $PROGRAM_NAME
  rom = Pacman.build_rom
  output = File.join(__dir__, "pacman.gba")
  rom.write(output)
  puts "Built pacman.gba (#{rom.size} bytes)"

  # Set EXPLAIN=1 to print the per-frame draw/sound-cost breakdown for the ROM.
  rom.explain if ENV["EXPLAIN"]
end
