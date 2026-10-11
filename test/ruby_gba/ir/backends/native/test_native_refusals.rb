# frozen_string_literal: true

require "test_helper"
require "native_comparison"

# What a desktop build refuses, and that it says so in plain words before anything is written.
class TestNativeRefusals < Minitest::Test
  # The native lowering's own tests, which only a native run plays (see TestSuites).
  runs_on :native

  include NativeComparison

  LoweringError = RubyGBA::IR::Backends::Native::LoweringError

  # Bytes of the console's own machine code only mean something on the console.
  def test_raw_machine_code_is_refused_by_name
    program = program_of do
      entry { nop }
    end

    error = assert_raises(LoweringError) { Native.new.lower(program) }
    assert_includes error.message, ":raw"
  end

  # A kind this backend trails on is named, with the part of the work it belongs to.
  def test_a_kind_not_written_yet_is_refused_by_name
    program = program_of do
      best = save_var :best, 0
      game_loop { best.add! 1 }
    end

    error = assert_raises(LoweringError) { Native.new.lower(program) }
    assert_match(/cannot make yet \(saving\)/, error.message)
  end

  # What the desktop's picture cannot draw yet is refused, by name, rather than drawn wrong.
  def test_a_tear_free_screen_is_refused_by_name
    assert_refused_picture(/tear-free screen/) do
      screen :bitmap, tear_free: true
      game_loop { clear_screen :black }
    end
  end

  def test_named_layers_are_refused_by_name
    assert_refused_picture(/stack of named layers/) do
      screen :tiled
      layers :back, :front
      image :dot, "#" => :red do "##\n##\n" end
      layer(:front) { sprite :dot, at: [10, 10] }
      game_loop {}
    end
  end

  def test_a_turning_sprite_is_refused_by_name
    assert_refused_picture(/turns or resizes/) do
      screen :tiled
      image :arrow, "#" => :red do "########\n" * 8 end
      arrow = sprite :arrow, at: [10, 10]
      game_loop { arrow.turn 5 }
    end
  end

  def test_sprites_over_a_picture_that_stays_are_refused_by_name
    assert_refused_picture(/sprites over a picture that is not rebuilt every frame/) do
      screen :tiled
      image :hero, "#" => :red do "########\n" * 8 end
      hero = sprite :hero, at: [10, 10]
      game_loop { hero.move :right }
    end
  end

  # The desktop build checks a game the way the cartridge build does, so a game the console
  # would refuse is refused here too, by the same friendly error.
  def test_a_game_the_cartridge_build_refuses_is_refused_for_the_desktop
    game = RubyGBA.game("REFUSED") do
      game_loop { pixel 10, 10, :red } # drawing with no screen chosen: a black screen on the console
    end

    assert_raises(RubyGBA::ROMError) { Native.new.checked_program(game, err: nil) }
  end

  # A routine nothing calls is left out of the C altogether, so a table only it reads cannot
  # leave an unused table behind for the compiler to stop on.
  def test_a_routine_nothing_calls_leaves_nothing_behind
    program = program_of do
      odd = table :odd, [1, 2, 3]
      n = var :n, 0
      func(:helper) { n.set! odd[n] }
      func(:never) { call :helper }
      game_loop { n.add! 1 }
    end

    assert_native_matches_reference program, frames: 2
  end

  private

  def assert_refused_picture(message, &block)
    error = assert_raises(LoweringError) { Native.new.lower(program_of(&block)) }
    assert_match message, error.message
    assert_match(/desktop build cannot draw yet/, error.message)
  end
end
