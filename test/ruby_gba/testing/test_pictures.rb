# frozen_string_literal: true

require "test_helper"

# The picture check a game includes from the library's test helper (RubyGBA::Testing::Pictures),
# where it differs from what this suite already holds it to through Differential: what a game's
# test sees when the emulator is not there.
class TestPictures < Minitest::Test
  # Swaps the emulator's loader for one that cannot find it, which is the whole process's, so it
  # cannot run beside tests in other Ractors that need the real one.
  runs_on_the_main_ractor!

  include RubyGBA::Testing::Pictures

  # A GAME WITHOUT THE EMULATOR GEM gets a failed test that says what to put in its Gemfile, not an
  # error from inside the library with a backtrace through it.
  def test_without_the_emulator_the_check_fails_saying_what_to_add
    skip "the native run checks the game as C, which needs no emulator" if RubyGBA::Testing.native?

    advice = RubyGBA::Diagnostics::Emulator.send(:missing_advice, "cannot load such file -- ruby_gba_emulator",
                                                 bundled: false)
    program = RubyGBA.game("NOEMU") do
      screen :bitmap
      game_loop { pixel 10, 10, :red }
    end.program

    err = without_the_emulator(advice) do
      assert_raises(Minitest::Assertion) { assert_backends_agree(program, frames: 2) }
    end
    assert_match(/Put this in your Gemfile/, err.message)
    assert_match(/gem "ruby-gba-emulator"/, err.message)
  end

  private

  # Run the block with the emulator's loader raising +advice+ as a missing emulator does, and put
  # the real loader back after.
  def without_the_emulator(advice)
    emulator = RubyGBA::Diagnostics::Emulator
    real = emulator.method(:load!)
    emulator.define_singleton_method(:load!) { raise LoadError, advice }
    yield
  ensure
    emulator.define_singleton_method(:load!, real)
  end
end
