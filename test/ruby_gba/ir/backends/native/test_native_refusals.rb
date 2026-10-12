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

  # Sound the desktop cannot play yet is refused by name, rather than left out of what it plays.
  def test_a_sound_not_played_yet_is_refused_by_name
    program = program_of do
      enable_sound
      game_loop { noise :explosion }
    end

    error = assert_raises(LoweringError) { Native.new.lower(program) }
    assert_match(/:noise.*cannot make yet \(sound\)/, error.message)
  end

  def test_a_song_part_off_the_square_wave_is_refused_by_name
    program = program_of do
      enable_sound
      song(:tune) do
        voice(:pad, plays: :wave) { note :C4, :quarter }
      end
      play_song :tune
      game_loop {}
    end

    error = assert_raises(LoweringError) { Native.new.lower(program) }
    assert_match(/song :tune.*wave voice/, error.message)
  end

  # What the desktop's picture cannot draw yet is refused, by name, rather than drawn wrong.
  #
  # A frame that ends while drawing is held inside an area: the interpreter reads the screen
  # through that area then, and the desktop build reads all of it.
  def test_a_frame_that_ends_inside_a_held_area_is_refused_by_name
    assert_refused_picture(/frame that ends inside an `inside` block/) do
      screen :bitmap
      clear_screen :blue
      n = var :n, 0
      inside(40, 30, 100, 60) { game_loop { n.add! 1 } }
    end
  end

  def test_a_see_through_layer_is_refused_by_name
    assert_refused_picture(/see-through layer/) do
      screen :tiled
      layers :back, :front
      image :dot, "#" => :red do "########\n" * 8 end
      layer(:front, transparency: 40) { sprite :dot, at: [10, 10] }
      game_loop {}
    end
  end

  # Two scenes may each declare a background by the same name; the desktop build would draw the
  # second one's map for both.
  def test_two_backgrounds_with_one_name_are_refused_by_name
    assert_refused_picture(/two backgrounds with one name \(room\)/) do
      screen :tiled
      var :state, 0
      image :brick, "#" => :red do "########\n" * 8 end
      tiles :wall, "#" => :brick
      scene(:first) { background :room, tiles: :wall, map: ["##  "] }
      scene(:second) { background :room, tiles: :wall, map: ["  ##"] }
      game_loop do
        case_var :state do
          when_val 0, :first
          when_val 1, :second
        end
      end
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
