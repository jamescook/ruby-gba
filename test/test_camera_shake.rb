# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# The camera — moving the visible window over the whole picture — and the screen
# shake built on top of it.
#
# The camera does not redraw anything. The picture stays exactly where it was drawn
# and the WINDOW moves, which is what makes a shake cost almost nothing: a game
# under a shake draws precisely what it drew before. So the thing to assert is that
# the same drawing SHOWS somewhere else while the shake runs, and shows back in its
# original place once it ends.
class TestCameraShake < Minitest::Test
  include GembaSupport

  Builder = RubyGBA::Builder
  Reference = RubyGBA::IR::Backends::Reference
  GBA = RubyGBA::IR::Backends::GBA
  ROM = RubyGBA::ROM

  RED = RubyGBA::Color.resolve(:red)
  BLUE = RubyGBA::Color.resolve(:blue)

  def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.emit_pending_functions
    b.program
  end

  # A blue screen with a red block at (100, 70), and a shake fired on frame 3.
  # Halting after +frames+ lets each test look at one exact moment.
  def shaking_game(frames:, intensity: 4, length: 3)
    program do
      screen :bitmap
      clear_screen :blue
      fill_rect 100, 70, 40, 20, :red
      frame = var :frame, 0
      game_loop do
        frame.add 1
        (frame == 3).then { shake_screen intensity: intensity, frames: length }
        (frame >= frames).then { halt }
      end
    end
  end

  # --- the camera on its own ---

  def test_the_camera_moves_what_is_shown_without_moving_what_was_drawn
    prog = program do
      screen :bitmap
      clear_screen :blue
      fill_rect 100, 70, 40, 20, :red
      camera 10, 0
      halt
    end
    i = Reference.new.run(prog)

    # The block was drawn across x 100..139.
    assert_equal RED, i.screen.stored_pixel(100, 70), "the drawing itself does not move"
    assert_equal RED, i.screen.pixel(90, 70), "with the window 10px right, the block shows 10px left"
    assert_equal BLUE, i.screen.pixel(132, 70),
                 "and its right edge has slid off, so that spot shows what was drawn beyond it"
  end

  def test_a_window_pushed_off_the_picture_shows_the_backdrop
    prog = program do
      screen :bitmap
      clear_screen :blue
      camera 10, 0
      halt
    end
    i = Reference.new.run(prog)

    assert_equal 0, i.screen.pixel(235, 80), "past the drawn picture there is nothing to show"
    assert_equal BLUE, i.screen.pixel(0, 80), "inside it, the drawing still shows"
  end

  # --- the shake ---

  def test_the_picture_is_off_centre_while_the_shake_runs
    i = Reference.new.run(shaking_game(frames: 4))

    refute_equal [0, 0], [i.screen.camera_x, i.screen.camera_y],
                 "the shake should have the camera off centre mid-shake"
  end

  def test_the_shake_alternates_direction_so_it_reads_as_a_jitter
    a = Reference.new.run(shaking_game(frames: 4)).screen.camera_x
    b = Reference.new.run(shaking_game(frames: 5)).screen.camera_x

    assert_equal(-a, b, "consecutive shake frames move opposite ways")
    refute_equal 0, a
  end

  def test_intensity_is_how_far_the_picture_moves
    gentle = Reference.new.run(shaking_game(frames: 4, intensity: 2)).screen.camera_x
    hard = Reference.new.run(shaking_game(frames: 4, intensity: 8)).screen.camera_x

    assert_equal 2, gentle.abs
    assert_equal 8, hard.abs
  end

  # The one that matters most: a shake that does not put the picture back leaves the
  # whole game off centre with a stripe of backdrop down one edge, forever.
  def test_the_picture_goes_back_exactly_where_it_was
    i = Reference.new.run(shaking_game(frames: 12))

    assert_equal 0, i.screen.camera_x
    assert_equal 0, i.screen.camera_y
    assert_equal RED, i.screen.pixel(100, 70), "the block is back in its original place"
  end

  def test_the_shake_lasts_as_long_as_it_was_asked_to
    settled = Reference.new.run(shaking_game(frames: 8, length: 3))
    still_going = Reference.new.run(shaking_game(frames: 5, length: 20))

    assert_equal 0, settled.screen.camera_x, "a 3-frame shake is over well before frame 8"
    refute_equal 0, still_going.screen.camera_x, "a 20-frame shake is not"
  end

  def test_duration_in_seconds_is_the_same_as_the_frames_it_works_out_to
    seconds = program do
      screen :bitmap
      game_loop { shake_screen intensity: 3, duration: 0.2 }
    end
    frames = program do
      screen :bitmap
      game_loop { shake_screen intensity: 3, frames: 12 }
    end

    assert_equal frames.to_h, seconds.to_h, "0.2s at 60fps is 12 frames"
  end

  # --- friendly errors ---

  def test_frames_and_duration_together_is_an_error
    err = assert_raises(ArgumentError) do
      program { screen :bitmap; game_loop { shake_screen intensity: 2, frames: 4, duration: 1 } }
    end
    assert_match(/not both/, err.message)
  end

  def test_a_nonsense_length_is_a_friendly_error
    err = assert_raises(ArgumentError) do
      program { screen :bitmap; game_loop { shake_screen intensity: 2, frames: 0 } }
    end
    assert_match(/positive/, err.message)
  end

  def test_a_nonsense_intensity_is_a_friendly_error
    err = assert_raises(ArgumentError) do
      program { screen :bitmap; game_loop { shake_screen intensity: 0 } }
    end
    assert_match(/positive/, err.message)
  end

  # A tiled screen has no framebuffer to slide, so say so and name what to use.
  def test_the_camera_on_a_tiled_screen_is_a_friendly_error
    prog = program do
      screen :tiled
      image(:t, "#" => :blue) { (["########"] * 8).join("\n") }
      tiles :ground, "#" => :t
      background :field, tiles: :ground, map: (["####"] * 4)
      game_loop { camera 4, 4 }
    end

    err = assert_raises(RubyGBA::IR::Backends::GBA::LoweringError) { GBA.new.lower(prog) }
    assert_match(/scroll_by/, err.message, "it names what to use instead")
  end

  # --- the guardrail ---

  # A shake needs frames to happen on. With no game loop the routine is never
  # reached, so the counter is set and the screen sits perfectly still — silently.
  def test_a_shake_with_no_game_loop_is_caught
    prog = program do
      screen :bitmap
      clear_screen :blue
      shake_screen intensity: 4, frames: 8
      halt
    end

    findings = RubyGBA::Effects::Packs::ScreenShake::NeedsGameLoop.new.detect(prog)

    assert_equal 1, findings.size
    assert_match(/game_loop/, findings.first.message)
    assert_equal :__shake_left, findings.first.node[:var],
                 "it blames the line where shake_screen was written"
  end

  def test_a_shake_inside_a_game_loop_is_not_flagged
    assert_empty RubyGBA::Effects::Packs::ScreenShake::NeedsGameLoop.new.detect(shaking_game(frames: 6))
  end

  def test_a_game_that_never_shakes_is_not_flagged
    prog = program { screen :bitmap; clear_screen :blue; halt }

    assert_empty RubyGBA::Effects::Packs::ScreenShake::NeedsGameLoop.new.detect(prog)
  end

  # --- on the console ---

  # The shake really moves the picture on the hardware, and really puts it back.
  # Two ROMs of the same game stopped at different frames: one mid-shake, one after.
  def test_the_shake_moves_the_picture_on_the_console_and_restores_it
    mid = ROM.assemble(GBA.new.lower(shaking_game(frames: 4, intensity: 6, length: 6)),
                       title: "SHAKE", code: "BSHK", maker: "01")
    done = ROM.assemble(GBA.new.lower(shaking_game(frames: 20, intensity: 6, length: 3)),
                        title: "SHAKE", code: "BSHK", maker: "01")

    during = assert_gemba_loads_rom(mid, frames: 6)
    after = assert_gemba_loads_rom(done, frames: 24)

    # The block was drawn across x 100..139. After the shake it is exactly there.
    assert after.red?(120, 80), "the block should be back where it was drawn, " \
                                "got 0x#{format('%04X', after.pixel_gba(120, 80))}"

    # Two points just outside the block, one past each edge. Settled, both show
    # background. Under a 6px shake the picture has slid one way or the other, so one
    # of them is covered by the block — whichever way this frame happens to lean.
    assert during.red?(97, 80) || during.red?(142, 80),
           "mid-shake the picture should have slid over one of the two edge points"
    refute after.red?(97, 80), "settled, the block covers neither"
    refute after.red?(142, 80)
  end
end
