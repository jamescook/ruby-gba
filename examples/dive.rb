#!/usr/bin/env ruby
# frozen_string_literal: true

# Dive — swim down, watch the air go, and get back up before it does.
#
# Nearly every example here shows one feature working. This one is a game where several
# of the awkward ones have to work TOGETHER, because a game is where they meet.
#
#   examples/dive/title.rb — the surface seen from below: a turning disc of sunlight
#   examples/dive/sea.rb   — the wall, the rocks, and the water you swim behind
#   examples/dive/diver.rb — the swimmer, and the bubbles that come off them
#   examples/dive/fish.rb  — one picture, six species, a different set of colours each
#   examples/dive/gauge.rb — the air, and the panel that shows how much is left
#
# Run it to build examples/dive.gba:
#   ruby examples/dive.rb

require_relative "../lib/ruby_gba"
require_relative "dive/title"
require_relative "dive/sea"
require_relative "dive/diver"
require_relative "dive/fish"
require_relative "dive/gauge"

module Dive
  # The colours the whole game is drawn in, named in one place so the parts agree about
  # them instead of each spelling out its own triple.
  module Ink
    RGB = RubyGBA::Graphics::Color

    SURFACE      = RGB.rgb(3, 9, 20)    # open water up near the top
    SURFACE_SPOT = RGB.rgb(4, 11, 23)
    SHAFT        = RGB.rgb(13, 21, 31)  # a shaft of sunlight falling through it
    SHAFT_EDGE   = RGB.rgb(7, 15, 26)
    SUN          = RGB.rgb(31, 30, 16)  # the disc itself
    SUN_WEDGE    = RGB.rgb(27, 21, 6)   # ...and the darker segments that show it turning

    SKY          = RGB.rgb(16, 24, 31)  # the air above the sea
    SKY_HIGH     = RGB.rgb(21, 27, 31)
    WALL         = RGB.rgb(2, 5, 11)    # the far cliff, almost out of the light
    WALL_FLECK   = RGB.rgb(3, 7, 14)
    ROCK         = RGB.rgb(5, 8, 12)    # the near rocks
    ROCK_LIT     = RGB.rgb(8, 12, 16)
    KELP         = RGB.rgb(3, 16, 9)    # and the kelp standing in them
    KELP_DARK    = RGB.rgb(1, 10, 6)
    WATER        = RGB.rgb(4, 11, 25)   # the sheet the diver swims behind
    WATER_LIT    = RGB.rgb(7, 15, 29)
    WATER_SKIN   = RGB.rgb(19, 28, 31)  # the line where the air stops

    FISH_BODY    = RGB.rgb(22, 22, 26)  # the fish as drawn, before a species recolours it
    FISH_EYE     = RGB.rgb(31, 31, 31)

    # The six species, each a body colour and an eye colour. One picture is drawn with
    # each of these in turn, so a shoal costs the art of a single fish.
    SHOAL = {
      perch: [RGB.rgb(24, 18, 8), RGB.rgb(31, 28, 18)],
      gold: [RGB.rgb(31, 23, 4), RGB.rgb(31, 31, 20)],
      ember: [RGB.rgb(29, 9, 3), RGB.rgb(31, 22, 12)],
      slate: [RGB.rgb(9, 15, 22), RGB.rgb(22, 27, 31)],
      plum: [RGB.rgb(19, 6, 22), RGB.rgb(30, 20, 31)],
      moss: [RGB.rgb(6, 20, 11), RGB.rgb(22, 31, 24)],
    }.freeze

    SUIT         = RGB.rgb(30, 5, 4)    # the diver's wetsuit
    MASK         = RGB.rgb(24, 30, 31)  # the glass of their mask
    TANK         = RGB.rgb(21, 21, 24)  # the air on their back
    BUBBLE       = RGB.rgb(17, 26, 31)  # and what comes off it
    BUBBLE_LIT   = RGB.rgb(29, 31, 31)

    PANEL        = RGB.rgb(11, 11, 14)  # the gauge's casing
    PANEL_LIT    = RGB.rgb(17, 17, 20)
    AIR          = RGB.rgb(2, 29, 10)   # a bar of air still in the tank
    AIR_DARK     = RGB.rgb(1, 18, 6)
    SPENT        = RGB.rgb(7, 6, 6)     # ...and one used up
    SPENT_DARK   = RGB.rgb(4, 3, 3)
  end

  TITLE = 0
  PLAY = 1
  OVER = 2

  # How long the world takes to go dark once the air is gone.
  BLACKOUT = 30

  # HOW FAR DOWN YOU ARE, in pixels of rock passing you — one number for the whole of it,
  # which is what keeps the picture honest. Zero is the top of the sea. Below zero is the
  # diver climbing out of it, which is the only part of the swim the WORLD does not move
  # for: there is no more sea above to scroll, so the diver rises off their resting place
  # on screen and their head comes out of the water.
  SINK = 2
  DEEPEST = 336 # the sea is 512 pixels deep and the screen shows 160 of it
  RISE = 30     # far enough that the head clears the surface and the body does not

  # Past halfway down you are breathing twice as hard, which is what makes the bottom
  # somewhere you visit rather than somewhere you sit.
  HARD_WORK = DEEPEST / 2

  # With your head out the tank fills faster than any depth empties it, so getting back up
  # is always worth it.
  BREATH = 6

  GAME = RubyGBA.game("DIVE") do
    screen :tiled

    # The stack, back to front. One line saying what is in front of what, for a picture
    # whose parts are declared in different files and different scenes — and the line
    # where :surface comes after everything that moves, which is what puts the water in
    # FRONT of the diver.
    layers :shafts_far, :shafts_near, :sun, :name, :deep, :reef, :swimmers, :surface, :panel, :over

    var :state, TITLE
    fresh = var :fresh, 1           # 1 asks the dive to start over from the top
    blacking_out = var :blacking_out, 0 # 1 while the world is going dark

    # Each scene declares its own backgrounds, and that is what lets the two screens have
    # different arrangements of the console's layers: the title turns one, so it gets two
    # that scroll beside it, and the dive turns nothing, so it gets four. Nothing below
    # says a word about either.
    scene :title do
      title = Title.new(self)
      title.update
      pressed(:start).then { set! :state, PLAY }
    end

    scene :play do
      sea = Sea.new(self)
      diver = Diver.new(self)
      fish = Fish.new(self)
      gauge = Gauge.new(self)
      down = var :down, 0    # where you are: below nought is the sea, above it is the air
      depth = var :depth, 0  # how much sea is above you, which is what the scenery follows
      sank = var :sank, 0    # ...and how much of it went past you this frame

      # Back to the surface with a full tank, asked for by the title or by the screen the
      # last dive ended on. Neither of those knows what has to be put back, which is the
      # point of asking here.
      (fresh == 1).then do
        down.set!(-RISE)
        diver.reset
        gauge.reset
        fresh.set! 0
      end

      held(:down).then { down.add! SINK }
      held(:up).then { down.sub! SINK }
      down.clamp!(-RISE, DEEPEST)

      # One number, read two ways. The sea scrolls by however much of it is above you,
      # which stops at nought; the diver climbs by however far past the top you have gone,
      # which is nought until you get there. So the two never fight over the same pixel.
      #
      # And how far that moved THIS frame, which is what the fish undo to stay where they
      # were in the water while you go past them.
      sank.set! down.clamp(0, DEEPEST) - depth
      depth.set! down.clamp(0, DEEPEST)
      sea.follow(depth)
      diver.update(down.clamp(-RISE, 0), sea.surface_on_screen(depth))
      fish.update(sank, sea.surface_on_screen(depth))

      gauge.spend 1
      (down > HARD_WORK).then { gauge.spend 1 }
      (down < 0).then { gauge.refill BREATH } # breathing, with your head out
      gauge.update

      # OUT OF AIR. The world goes dark, and the scene waits for it to actually arrive
      # before handing over — fading out leaves the screen black on purpose, so whatever
      # is drawn next is invisible until something lifts it. Reading `fade_level` is what
      # waits: 0 is the picture as drawn and 100 is nothing but the colour.
      #
      # This fade names no layer, and that is deliberate rather than a simplification.
      # Placing a fade at a depth is the one thing only the display's blend unit can do,
      # and seeing through a layer is the other — it does one at a time. A plain fade
      # moves the COLOURS instead, which reaches everything that draws from them, so the
      # water goes on showing the diver all the way down into the dark. Ask for a placed
      # one here and the water turns solid until the fade lifts, and the build says so.
      (gauge.empty? & (blacking_out == 0)).then do
        fade_out :black, frames: BLACKOUT
        blacking_out.set! 1
      end
      (blacking_out == 1).then do
        (fade_level == 100).then do
          set! :state, OVER
          fade_in frames: BLACKOUT
          blacking_out.set! 0
        end
      end
    end

    # The screen the dive ends on: its own words, on screen only while this scene is, and
    # nothing else at all — the dive's four layers belong to the dive.
    scene :over do
      layer :over do
        draw_text "OUT OF AIR", :center, 64, :white
        draw_text "PRESS START", :center, 88, :white, font: :tiny
      end
      pressed(:start).then do
        fresh.set! 1
        set! :state, PLAY
      end
    end

    game_loop do
      case_var :state do
        when_val TITLE, :title
        when_val PLAY, :play
        when_val OVER, :over
      end
    end
  end

  def self.program = GAME.program
  def self.build_rom(**kwargs) = GAME.build_rom(**kwargs)
end

Dive::GAME.write_if_main
