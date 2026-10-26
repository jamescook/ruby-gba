# frozen_string_literal: true

require "stringio"

# THE SMALL GAME THE COMPARISON'S TESTS COMPARE, and the long way round to what they expect.
#
# A comparison is tested on two cartridges that differ in one thing put there on purpose, so
# the tests need a game that can be built with a difference of a known kind — a few pixels, a
# few frames, one part of the screen — and a way to find the frame that difference shows on
# that has no comparison in it: the cartridge is played on its own and asked.
#
#   include ComparisonGames
module ComparisonGames
  SPECKS_FROM = 30
  SPECK_X = 100
  SPECK_Y = 100

  # How many pixels the screen has: what a share of a frame is a share of.
  PIXELS = 240 * 160

  # A white box on a coloured ground. The box walks +speed+ pixels a frame while RIGHT is
  # down, and the ground turns red once the game has ticked +turns_red_at+ times. It also
  # counts its paces, +counts_by+ for each frame it walks: a number a script can watch that
  # the picture does not show.
  #
  # Two more things can be changed about it, for a difference of a known size and a known
  # length: the ground stays red for +red_for+ ticks and then goes back, and from tick
  # +SPECKS_FROM+ it draws +specks+ white pixels in a row, far from the box.
  #
  # And one that changes nothing a player could see: +spare_variables+ more variables
  # declared ahead of its own, which moves where each of its own is kept in memory. That
  # is two cartridges that keep the same thing in different places.
  #
  # And one that is how a cartridge somebody else made differs before anything is pressed:
  # +logo_for+ frames of a black screen ahead of the game, on which the game does not tick.
  # Two walkers with different logos are the same game, out of step from power-on.
  def walker(speed: 2, turns_red_at: 100_000, red_for: 100_000, counts_by: 1, specks: 0, spare_variables: 0, logo_for: 0)
    RubyGBA.build("WALKER", console: :gba, out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      spare_variables.times { |spare| var :"spare#{spare}", 0 }
      ticks = var :ticks, 0
      x = var :x, 20
      paces = var :paces, 0
      play = lambda do
        ticks.add! 1
        held(:right).then do
          x.add! speed
          paces.add! counts_by
        end
        ((ticks >= turns_red_at) & (ticks < turns_red_at + red_for)).then { clear_screen :red }.else { clear_screen :blue }
        draw_rect_at x, 60, 8, 8, :white
        (ticks >= SPECKS_FROM).then { specks.times { |speck| pixel SPECK_X + speck, SPECK_Y, :white } }
      end
      next game_loop(&play) if logo_for.zero?

      logo = var :logo, 0
      game_loop do
        (logo < logo_for).then do
          logo.add! 1
          clear_screen :black
        end.else(&play)
      end
    end
  end

  # A GREY SCREEN THE EMULATOR HOLDS AS ONE OF TWO NUMBERS, for the same colour at the five
  # bits of each channel a console shows.
  #
  # The emulator keeps eight bits a channel. A grey of level 17 read straight out of the
  # colour table is 140 to it; a grey of level 16 that the display brightens one step is
  # worked out at eight bits and comes to 139. Both are level 17 once the three bits below
  # are dropped, so the two screens are different bytes and one picture.
  #
  # +specks+ white pixels in a row are drawn on it too, far from any edge: a difference of a
  # known size that IS one at five bits.
  def grey_screen(brightened:, specks: 0)
    RubyGBA.build("GREY", console: :gba, out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      clear_screen(brightened ? rgb(16, 16, 16) : rgb(17, 17, 17))
      specks.times { |speck| pixel SPECK_X + speck, SPECK_Y, :white }
      fade :white, 7 if brightened
      game_loop {}
    end
  end

  # A lead-in for any walker: let frames go by until its ground is up, which is the first
  # frame of the game itself, however long a logo came before it.
  def past_the_logo
    RubyGBA.playthrough "past the logo" do
      wait_until("the ground is blue") { |game| game.blue?(0, 0) }
    end
  end

  # Whether a cartridge has drawn its specks. White with blue under it, because the whole
  # screen is white before a game's first frame.
  def specks_showing?(game) = game.white?(SPECK_X, SPECK_Y) && game.blue?(SPECK_X, SPECK_Y + 1)

  def walk_right
    RubyGBA.playthrough "wait, then walk right" do
      wait frames: 10
      moment :standing
      hold :right, frames: 20
      moment :walked
      wait frames: 30
    end
  end

  # A CARTRIDGE PLAYED ON ITS OWN, a frame at a time, with the buttons a tape says — the long
  # way round, with no comparison in it. The block is handed the running cartridge after
  # each frame and the number of that frame, counted from 1.
  def each_frame_of(cartridge, tape)
    game = RubyGBA::Diagnostics::Verifier.new(cartridge, frames: 0, vars: cartridge.var_addresses)
    tape.steps.flat_map { |step| [step] * step.frames }.each.with_index(1) do |step, frame|
      yield game.step(1, keys: RubyGBA::Playthroughs::Playthrough.key_mask(step.buttons)), frame
    end
  end

  # The first frame something is true of a cartridge while a tape is played on it.
  def first_frame(cartridge, tape)
    each_frame_of(cartridge, tape) { |game, frame| return frame if yield(game) }
    nil
  end

  # Every frame something is true of a cartridge while a tape is played on it.
  def frames_where(cartridge, tape)
    [].tap { |found| each_frame_of(cartridge, tape) { |game, frame| found << frame if yield(game) } }
  end
end
