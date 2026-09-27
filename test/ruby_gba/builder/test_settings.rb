# frozen_string_literal: true

require "test_helper"
require "stringio"

# WHAT A GAME IS TOLD WHEN IT IS BUILT. A game that comes in several cuts reads which one with
# `setting`, and the build hands the answer to that one build — so a test can build a one-floor
# cartridge beside a sixty-floor one, on another core at the same moment, and neither sees the
# other's. Before this the only way in was the environment, which the whole process shares.
class TestSettings < Minitest::Test
  # A game whose number of floors is a setting, kept in a variable so a run can read it back.
  CUTS = RubyGBA.game("CUTS", maker: "01") do
    screen :bitmap
    var :floors, setting(:floors, 60)
    var :start, setting(:start, :title) == :title ? 0 : 1
    game_loop { wait_vblank }
  end

  private def floors(**settings) = Reference.new.run(CUTS.program(settings: settings), frames: 1)[:floors]

  def test_a_game_gets_its_default_when_the_build_says_nothing
    assert_equal 60, floors
  end

  def test_a_build_given_a_setting_gets_it_and_no_other_build_does
    assert_equal 1, floors(floors: 1)
    assert_equal 60, floors, "the next build, told nothing, gets the default again"
  end

  # A command line can only give text, so text is read as the kind of thing the default is.
  def test_text_is_read_as_the_kind_of_thing_the_default_is
    assert_equal 3, floors(floors: "3")
    program = CUTS.program(settings: { start: "playing" })
    assert_equal 1, Reference.new.run(program, frames: 1)[:start], "a Symbol default reads text as a name"
  end

  def test_text_that_cannot_be_read_that_way_is_a_friendly_error
    error = assert_raises(ArgumentError) { CUTS.program(settings: { floors: "lots" }) }

    assert_match(/:floors was given "lots"/, error.message)
    assert_match(/same kind of value as its default/, error.message)
  end

  # A name spelled two ways would otherwise build the default and look right.
  def test_a_setting_the_game_does_not_ask_for_is_a_friendly_error
    error = assert_raises(ArgumentError) { CUTS.program(settings: { floor: 1 }) }

    assert_match(/gave the setting :floor, and the game does not ask for it/, error.message)
    assert_match(/:floors, :start/, error.message)
  end

  def test_a_setting_with_no_default_has_to_be_given
    required = RubyGBA.game("NEEDS", maker: "01") do
      screen :bitmap
      var :floors, setting(:floors)
      game_loop { wait_vblank }
    end

    assert_match(/:floors has no default/, assert_raises(ArgumentError) { required.program }.message)
    assert_equal 2, Reference.new.run(required.program(settings: { floors: 2 }), frames: 1)[:floors]
  end

  # The cartridge is built with them too, not only the tree a test runs.
  def test_a_cartridge_is_built_with_its_settings
    rom = CUTS.build_rom(out: StringIO.new, err: StringIO.new, profile: false, settings: { floors: 5 })

    assert_equal 5, Reference.new.run(rom.source_program, frames: 1)[:floors]
  end
end
