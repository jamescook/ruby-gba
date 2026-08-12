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
# Three layers make it read. The BACK layer is the scene — sky, sun, hills — and it does not
# bend. The MIDDLE layer is the water, see-through above the shoreline so the scene shows
# through, and it is the one that bends. Watch the bright pillar under the sun: that is the
# sun's reflection, and a rippling surface is exactly what makes it wobble.
#
# And a THIRD layer of jellyfish drifts across the lake, half see-through:
#
#     layer(:swimmers, transparency: 55) { ... }
#
# That is the whole of it. A layer says how much of what is BEHIND it shows through, 0
# solid and 100 invisible, and it says it where the layer is opened. Nothing is redrawn
# and nothing is worked out per pixel — the console mixes the two as it draws each line —
# so a see-through layer costs the same as a solid one however much is on screen. Watch
# the water through a bell: the ripple keeps travelling through it, because what you are
# seeing IS the water, mixed in rather than copied.
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

  # The jellyfish. Each one is 16x16, drifts right at its own speed, and wraps round to
  # the left edge when it leaves — so the lake never empties. Their y is the wave's own
  # offset added to a resting depth, which is what makes them bob on the same swell that
  # ripples the water rather than on a rhythm of their own.
  SCREEN_W = 240
  JELLY_SIZE = 16
  SEE_THROUGH = 55   # how much of the water shows through a bell, 0 solid to 100 invisible
  DRIFT = [[20, 96, 1],    # x it starts at, the depth it rests at, pixels a frame
           [110, 124, 2],
           [190, 108, 1]].freeze

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

    # A jellyfish: a bell with tentacles under it, and nothing else — the dots are
    # see-through, so the lake shows around it as well as through it.
    image :jelly, "." => :transparent, "o" => rgb(26, 18, 29), "O" => rgb(31, 26, 31),
                  "t" => rgb(22, 14, 26) do
      <<~ART
        ......oooo......
        ....oooOOOooo...
        ...oOOOOOOOOo...
        ..oOOOOOOOOOOo..
        .oOOOOOOOOOOOOo.
        .oOOOOOOOOOOOOo.
        oOOOOOOOOOOOOOOo
        oOOOOOOOOOOOOOOo
        .oOOOOOOOOOOOOo.
        ..oooooooooooo..
        ...t..t..t..t...
        ...t..t..t..t...
        ..t...t...t..t..
        ..t...t....t.t..
        .t....t....t.t..
        .t....t.....t...
      ART
    end

    tiles :above, "." => :sky, "o" => :sun, "^" => :hill, "=" => :shore, "~" => :water
    tiles :below, "~" => :water, "v" => :hill_reflection, "|" => :glint

    layers :shore, :surface, :swimmers # the stack, back to front

    layer(:shore) { background :scene, tiles: :above, map: SCENE }
    water = layer(:surface) { background :water, tiles: :below, map: WATER }

    # The one see-through layer. A game has one, and this is the better use for it: a
    # sheet of glass lying still over a picture is easy to mistake for a paler picture,
    # where a jellyfish drifting across the ripples — with the wave pattern travelling
    # through its bell — cannot be mistaken for anything else.
    jellyfish = layer(:swimmers, transparency: SEE_THROUGH) do
      DRIFT.map { |x, depth, speed| [sprite(:jelly, at: [x, depth]), depth, speed] }
    end

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

      # ...and the jellyfish drift on it. Each one reads the SAME wave table the water
      # bends by, so they rise and fall on the swell they are floating in.
      jellyfish.each do |jelly, depth, speed|
        jelly.x.add speed
        (jelly.x > SCREEN_W).then { jelly.x.set(-JELLY_SIZE) }
        jelly.y.set(ripple[(jelly.x + phase) % WAVE_ROWS] + depth)
      end
    end
  end

  def self.program = GAME.program
  def self.build_rom(**kwargs) = GAME.build_rom(**kwargs)
end

Lake::GAME.write_if_main
