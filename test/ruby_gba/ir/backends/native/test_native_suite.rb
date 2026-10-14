# frozen_string_literal: true

require "test_helper"
require "differential"
require "stringio"

# Names only the native lowering, so it fails if anything but `rake test:native` runs it. Every
# test in this folder names only native too, and `rake test` loads them all: this is the one that
# says so the day the filter stops working. Its other side is test/test_suites.rb.
class TestNativeSuite < Minitest::Test
  runs_on :native

  include Differential

  def test_a_class_that_names_only_native_runs_only_on_a_native_run
    assert_equal :native, TestSuites::LOWERING,
                 "a test class that said `runs_on :native` alone ran on a #{TestSuites::LOWERING} run"
  end

  # A file opted into native runs keeps its tests of the cartridge, which skip themselves here.
  def test_a_test_of_the_cartridge_skips_itself_on_a_native_run_and_says_why
    skipped = assert_raises(Minitest::Skip) { require_emulator! }

    assert_match(/emulator/, skipped.message)
  end

  # A test that asks whether the console draws what the interpreter draws has no console to ask
  # here. So on a native run the same line asks it of the game as C: the same program and the
  # same held buttons, compared with the interpreter on every frame.
  def test_a_whole_picture_comparison_is_made_of_the_game_as_c_on_a_native_run
    builder = Builder.new
    builder.instance_eval do
      screen :bitmap
      x = var :x, 0
      game_loop do
        clear_screen :black
        draw_rect_at x, 20, 2, 2, :green
        held(:right).then { x.add! 1 }
      end
    end
    builder.finalize_program

    played = assert_backends_agree(builder.program, frames: 4, keys: [:right])

    assert_kind_of CheckedNativeRun, played
    assert_equal 4, played[:x], "the buttons were held on all four frames, so the game moved four times"
  end

  # The classes a native run leaves to the interpreter print nothing as it goes, so it ends by
  # counting every class each way.
  def test_a_native_run_ends_by_counting_the_classes_each_way
    said = StringIO.new

    NativeSkips.new(said).report

    assert_match(/^\s*\d+  on both lowerings$/, said.string)
    assert_match(/^\s*[1-9]\d*  on the native lowering alone$/, said.string, "this class is one of them")
    assert_match(/^\s*\d+  on the interpreter alone, so not played here/, said.string)
  end

  # ...and a test that asks something native cannot answer yet says so, with its reason.
  def test_a_test_native_cannot_play_yet_skips_with_its_reason
    skipped = assert_raises(Minitest::Skip) { skip_on_native "reads the sprites by name" }

    assert_match(/reads the sprites by name/, skipped.message)
  end
end
