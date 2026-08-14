# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# DYING: the view turns to face what killed you, and then dots over to red.
#
# Driven straight rather than by standing in front of a guard until he finishes you off, which
# is what test_guards does and which takes two thousand frames of a game to reach one moment.
# Everything here needs is an eye and somewhere the killer stood, so the whole of it — the turn,
# the settle, the fizzle — runs over a plain background where a red pixel means one thing.
class TestDying < Minitest::Test
  include Wolf3DTest

  FP = Wolf3D::FirstPerson
  Dying = Wolf3D::Dying
  ONE = (1 << RubyGBA::Fraction::DEFAULT_BITS).to_f

  # Long enough for the worst turn there can be, the settle, and the whole fizzle.
  FRAMES = Dying::MOST_TURNS + Dying::SETTLE + Dying::FRAMES + 8

  RED = Wolf3D::Palette.game[Dying::INK]
  GROUND = RubyGBA::Color.resolve(:blue)
  BAR = RubyGBA::Color.resolve(:green)

  # A killer standing +away+ cells north of a player who is facing east, so the turn has a
  # quarter of a circle to cover and a side to pick.
  def dying_program(kill_x: 8.5, kill_y: 4.5, tear_free: true)
    RubyGBA.game("DYING", code: "ZDIE", maker: "01") do
      screen :bitmap, tear_free: tear_free
      sin = table :sin, (0...FP::TURN).map { |a| Math.sin(a * 2 * Math::PI / FP::TURN) }
      px = var :px, 8.5
      py = var :py, 8.5
      angle = var :view, 0
      killer = Struct.new(:x, :y).new(var(:kx, kill_x), var(:ky, kill_y))
      settling = var :settling, 0

      dying = Dying.new(build: self, eye: { x: px, y: py, angle: angle, sin: sin })

      once_a_frame { dying.turn }
      game_loop do
        # Both pages want the background before anything is added to it, and a frame paints one
        # of them — so it goes on twice, and only then is the player struck.
        (settling < 2).then do
          clear_screen GROUND
          dma_fill_rect 0, FP::VIEW_H, FP::ACROSS, Wolf3D::StatusBar::HEIGHT, BAR
          settling.add 1
        end.else do
          dying.struck_by(killer)
        end
        dying.draw
      end
    end.program
  end

  def run_it(**) = Reference.new.run(dying_program(**), frames: FRAMES)

  # How much of the view is red, and how much of the bar under it has been touched.
  def redness(pixel)
    view = (0...FP::ACROSS).to_a.product((0...FP::VIEW_H).to_a)
    bar = (0...FP::ACROSS).to_a.product((FP::VIEW_H...FP::DOWN).to_a)
    { view: view.count { |x, y| pixel.call(x, y) == RED } / view.length.to_f,
      untouched_bar: bar.all? { |x, y| pixel.call(x, y) == BAR } }
  end

  # --- the step that scatters -----------------------------------------------------------

  # THE PROMISE THE WHOLE EFFECT RESTS ON, and the one thing about it that is not obvious by
  # reading: stepping by STEP modulo MODULUS reaches every value below MODULUS exactly once. It
  # is what the original's shift register gives and what this has to give in its place, and it
  # is checked by walking the whole sequence rather than by trusting the number theory that
  # picked the two numbers.
  def test_the_step_reaches_every_pixel_of_the_view_exactly_once
    seen = {}
    at = 1
    (Dying::MODULUS - 1).times do
      at = (at * Dying::STEP) % Dying::MODULUS
      seen[at] = true
    end

    assert_equal Dying::MODULUS - 1, seen.size, "every value below the prime, and none twice"
    assert_equal 1, at, "...and back to where it started, so it is one whole cycle"
    assert_operator (1..Dying::PIXELS).count { |n| seen[n] }, :==, Dying::PIXELS,
                    "which covers every pixel of the view"
  end

  # The handful of values past the last pixel would name the row under the view, which is the
  # status bar — so they are folded back into it instead. See Dying#scatter for why that is done
  # with arithmetic rather than by clipping.
  def test_the_values_past_the_last_pixel_are_folded_back_into_the_view
    over = ((Dying::PIXELS + 1)...Dying::MODULUS).map { |n| n - 1 }

    assert_equal [Dying::DOWN], over.map { |spot| spot / Dying::ACROSS }.uniq,
                 "left alone they would land one row below the view"
    assert(over.all? { |spot| (spot % Dying::PIXELS) < Dying::PIXELS },
           "folded, every one of them is a pixel of the view")
  end

  # A frame's worth, twice over, has to finish inside the frames it is given.
  def test_it_is_spread_over_the_frames_it_says
    assert_operator Dying::PER_FRAME * Dying::FRAMES, :>=, Dying::MODULUS - 1
  end

  # --- turning to face what killed you ---------------------------------------------------

  # The killer is due north and the player faces east, so the turn has a quarter of a circle to
  # cover — and going the OTHER way round would be three quarters. Which way it picks is the
  # whole of what the side test is for.
  def test_the_view_ends_up_looking_at_what_killed_you
    ran = Reference.new.run(dying_program, frames: Dying::MOST_TURNS + Dying::SETTLE + 3)
    north = FP::QUARTER * 3

    assert_in_delta north, ran[:view] % FP::TURN, FP::TURN_SPEED * 2,
                    "it should be looking north, give or take the step it stopped on"
  end

  def test_it_turns_the_short_way_round
    # East, and the killer just south of west: the short way is onward, not back.
    ran = Reference.new.run(dying_program(kill_x: 4.5, kill_y: 9.5),
                            frames: Dying::MOST_TURNS + Dying::SETTLE + 3)

    assert_operator ran[:view], :>, 0, "the short way is forward, so the angle should have risen"
  end

  # --- and the view going red ------------------------------------------------------------

  def test_the_whole_view_ends_red
    ran = run_it
    got = redness(->(x, y) { ran.screen.pixel(x, y) })

    assert_in_delta 1.0, got[:view], 0.0001, "every pixel of the view"
  end

  def test_nothing_outside_the_view_is_touched
    ran = run_it

    assert redness(->(x, y) { ran.screen.pixel(x, y) })[:untouched_bar],
           "the bar along the bottom should be exactly as it was drawn"
  end

  # It DOTS over rather than sweeping: half way through, the red is spread across the whole view
  # rather than gathered at one end. Read as the share of red in the top eighth against the
  # bottom eighth of the view — a wipe would put all of it in one of them.
  def test_it_arrives_scattered_rather_than_swept
    part = Reference.new.run(dying_program, frames: Dying::MOST_TURNS + Dying::SETTLE + (Dying::FRAMES / 2))
    band = lambda do |from, to|
      spots = (0...FP::ACROSS).to_a.product((from...to).to_a)
      spots.count { |x, y| part.screen.pixel(x, y) == RED } / spots.length.to_f
    end
    top = band.call(0, FP::VIEW_H / 8)
    bottom = band.call(FP::VIEW_H - (FP::VIEW_H / 8), FP::VIEW_H)

    assert_operator top, :>, 0.2, "the top band should be dotted, not untouched"
    assert_operator bottom, :>, 0.2, "and so should the bottom one"
    assert_in_delta top, bottom, 0.1, "both filling at the same rate is what scattered means"
  end

  # --- what a frame of it costs -------------------------------------------------------------

  # MEASURED ON THE CONSOLE RATHER THAN ARGUED ABOUT, because the estimate cannot answer this
  # one: the fizzle and the view are two arms of the same branch and only ever one of them runs,
  # where the model prices both and adds a share of each. What is wanted is the cost of a frame
  # that is really fizzling.
  #
  # The number to beat is a frame, 228 scanlines. It fits because nothing else is happening —
  # the eighty rays a live frame spends nearly all of itself on are not cast once the world has
  # stopped — and it has to fit twice over, because every dot is drawn on two frames so that
  # both pages of the screen get it.
  def test_a_frame_of_it_fits_in_a_frame
    Dir.mktmpdir do |dir|
      path = File.join(dir, "dying.gba")
      ROM.assemble(GBA.new.lower(dying_program), title: "DYING", code: "ZDIE", maker: "01")
         .write(path)
      probe = RubyGBA::Emulator.probe(path)
      probe.step(Dying::MOST_TURNS + Dying::SETTLE + 6) # ...past the turn and into the dots
      busiest = 20.times.map { RubyGBA::Analyzer.frame_scanlines(probe.frame_cost) }.max
      probe.close

      assert_operator busiest, :<, 228,
                      "a fizzling frame has the whole frame to itself and must still fit in it"
      assert_operator busiest, :>, 10, "...and it is really drawing, not being skipped"
    end
  end

  # --- and on the console ------------------------------------------------------------------

  # THE ONE THAT NEEDS HARDWARE. A tear-free screen is two pages shown in turn, and this effect
  # ADDS to what is already there rather than repainting it — so drawn once, each page would get
  # half the dots and the screen would flicker between two half-finished pictures. Every dot is
  # drawn on two consecutive frames for exactly that reason, and the interpreter cannot see the
  # difference: it models one framebuffer, so it reads the view fully red either way.
  def test_the_console_fills_the_whole_view_too
    program = dying_program
    rom = ROM.assemble(GBA.new.lower(program), title: "DYING", code: "ZDIE", maker: "01")
    gba = RubyGBA::Verifier.new(rom, frames: FRAMES + 8)
    got = redness(->(x, y) { gba.pixel_gba(x, y) })

    assert_in_delta 1.0, got[:view], 0.0001, "every pixel of the view, on whichever page is shown"
    assert got[:untouched_bar], "and the bar under it left alone"
  end
end
