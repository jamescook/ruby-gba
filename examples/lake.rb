#!/usr/bin/env ruby
# frozen_string_literal: true

# Lake — water that ripples, by giving every row of the picture its own offset.
#
# The console does not keep a finished picture anywhere. It builds the screen one
# horizontal line at a time, top to bottom, and for every single line it asks again where
# each background layer is scrolled to. Nobody says the answer has to be the same each
# time — so give line 100 an offset two pixels left and line 101 two pixels right, and the
# picture BENDS. Slide the pattern down a little every frame and the bend travels. That is
# water. It is also a heat haze over a desert, a reflection in a puddle, and a screen
# melting into a transition.
#
# `water.scroll_each_row { |row| ... }` is the whole feature: the block is handed the row
# (0 at the top of the screen) and gives back how far across that row sits. Here it reads a
# sine table, shifted a little further along each frame, so a wave rolls down toward you.
#
# Two layers make it read. The BACK layer is the scene — sky, sun, hills — and it does not
# bend. The FRONT layer is the water, see-through above the shoreline so the scene shows
# through, and it is the one that bends. Watch the bright pillar under the sun: that is the
# sun's reflection, and a rippling surface is exactly what makes it wobble.
#
# What you never touch: a scroll register, an interrupt, or the fact that the framework has
# to get in between two lines of a picture being drawn to do this at all.
#
# It is not free. Answering per line means being interrupted per line, which `explain`
# prices at about 20 of a frame's 228 scanlines — a tenth of the frame for the effect,
# almost all of it the interruptions rather than the sine lookup. Run
# `ruby-gba build examples/lake.rb --explain` to see it named, and to see that the build
# put the routine those interruptions land in in the console's quick memory, which is worth
# about half of what it used to cost.
#
# Run it to build examples/lake.gba:
#   ruby examples/lake.rb

require_relative "../lib/ruby_gba"

module Lake
  # The map is 32x32 cells of 8x8 pixels; the screen shows 30x20 of them.
  CELLS = 32
  HORIZON = 10       # the cell row the water starts on (y = 80, half way down)
  SUN_COL = 21       # the cell column the sun sits in — and its reflection below

  # How far a row can slide, in pixels, and how long one wave is. 64 rows to a wave over
  # 160 rows of screen means you see two and a half waves at once, which reads as water
  # rather than as one slow bend.
  SWAY = 3
  WAVE_ROWS = 64
  WAVE_SPEED = 1     # rows the pattern travels per frame — 64 frames to a full cycle

  # The scene above the water: sky, a sun, and hills standing on the shoreline. Opaque
  # everywhere, because it is the backmost layer and nothing shows behind it.
  SCENE = (0...CELLS).map do |r|
    (0...CELLS).map do |c|
      if    r >= HORIZON then "~"                  # below the shoreline (the water covers it)
      elsif r == HORIZON - 1 then "="              # the shoreline itself
      elsif r.between?(HORIZON - 3, HORIZON - 2) then "^" # hills
      elsif r == 2 && c == SUN_COL then "o"        # the sun
      else "."                                     # sky
      end
    end.join
  end.freeze

  # The water: see-through above the shoreline so the scene shows, then water below. The
  # hills' reflection sits just under the shore, and the sun's is a bright pillar running
  # all the way down the column the sun is in — the part of the picture the ripple shows
  # off best, because a vertical streak shifted sideways is impossible to miss.
  WATER = (0...CELLS).map do |r|
    (0...CELLS).map do |c|
      if    r < HORIZON then " "                   # see-through — the scene above shows here
      elsif c == SUN_COL then "|"                  # the sun's reflection, a bright pillar
      elsif r.between?(HORIZON, HORIZON + 1) then "v" # the hills' reflection, just under the shore
      else "~"                                     # open water
      end
    end.join
  end.freeze

  GAME = RubyGBA.game("LAKE", code: "BLAK", maker: "01") do
    screen :tiled # tile mode: two background layers the console composites for us

    # --- the scene above the water ---
    image :sky, "." => rgb(14, 21, 31), "'" => rgb(17, 23, 31) do
      <<~ART
        ........
        ....'...
        ........
        ........
        ..'.....
        ........
        ........
        ......'.
      ART
    end
    image :sun, "." => rgb(14, 21, 31), "O" => rgb(31, 30, 12), "o" => rgb(31, 25, 6) do
      <<~ART
        ..oooo..
        .oOOOOo.
        oOOOOOOo
        oOOOOOOo
        oOOOOOOo
        oOOOOOOo
        .oOOOOo.
        ..oooo..
      ART
    end
    image :hill, "#" => rgb(5, 17, 7), "^" => rgb(8, 22, 9) do
      <<~ART
        ^#^##^#^
        ########
        ########
        ########
        ########
        ########
        ########
        ########
      ART
    end
    image :shore, "#" => rgb(26, 24, 15), "." => rgb(22, 20, 12) do
      <<~ART
        ########
        #.#..#.#
        ########
        ##.##.##
        ###.####
        ########
        ##.#.###
        ########
      ART
    end

    # --- the water. Every tile has VERTICAL structure, because a row sliding sideways
    # only shows on an edge that runs down the picture. Flat horizontal bands would slide
    # under themselves and look perfectly still. ---
    image :water, "~" => rgb(6, 11, 24), "-" => rgb(8, 14, 27), "|" => rgb(10, 17, 29) do
      <<~ART
        ~~|~~~~~
        ~~~~~~|~
        ~|~~~~~~
        ~~~~|~~~
        ~~~~~~~|
        ~~|~~~~~
        |~~~~~~~
        ~~~~~|~~
      ART
    end
    # The hills, upside down in the water and drained of colour the way a reflection is.
    image :hill_reflection, "#" => rgb(4, 12, 16), "^" => rgb(5, 15, 19) do
      <<~ART
        ########
        ########
        ########
        ########
        ########
        ########
        ########
        ^#^##^#^
      ART
    end
    # The sun's reflection: a bright column down the water. This is the tile the ripple
    # shows off — bend the rows and the pillar snakes.
    image :glint, "~" => rgb(6, 11, 24), "*" => rgb(28, 27, 17), "+" => rgb(18, 21, 28) do
      <<~ART
        ~~+**+~~
        ~~+**+~~
        ~+****+~
        ~~+**+~~
        ~+****+~
        ~~+**+~~
        ~~+**+~~
        ~+****+~
      ART
    end

    tiles :above, "." => :sky, "o" => :sun, "^" => :hill, "=" => :shore, "~" => :water
    tiles :below, "~" => :water, "v" => :hill_reflection, "|" => :glint

    background :scene, tiles: :above, map: SCENE  # declared first -> the back layer
    water = background :water, tiles: :below, map: WATER # declared second -> in front

    # One wave, as a table of sideways offsets worked out at build time. A table is the
    # right home for it: the block below runs 160 times a frame, so anything it has to
    # work out is paid 160 times, and a lookup is the cheapest thing there is.
    ripple = table :ripple, (0...WAVE_ROWS).map { |i| (Math.sin(i * 2 * Math::PI / WAVE_ROWS) * SWAY).round }

    # How far the wave has travelled. Nothing else in the program moves.
    phase = var :phase, 0

    # THE EFFECT. Every row of the water layer sits a few pixels left or right of where it
    # was drawn, following the wave. Subtracting the phase makes the pattern travel DOWN
    # the screen, toward you, the way real ripples come in. The table is 64 long and a
    # power of two, so an index past its end wraps round instead of having to be tidied up.
    water.scroll_each_row { |row| ripple[(row - phase) % WAVE_ROWS] }

    game_loop do
      # Move the wave along. That is the entire animation — the bend is re-read for every
      # row of every frame, so one variable changing is a whole rippling lake.
      phase.add WAVE_SPEED
    end
  end

  def self.program = GAME.program
  def self.build_rom(**kwargs) = GAME.build_rom(**kwargs)
end

Lake::GAME.write_if_main
