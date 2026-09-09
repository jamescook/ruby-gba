# frozen_string_literal: true

require "test_helper"
require "stringio"

# `rom.profile` — where a game's frames actually went, measured by running it.
#
# These assert what the report SAYS about a program whose shape is known, not the numbers,
# which move whenever the lowering does. The fixture is built so one routine must dominate and
# another must never run at all, because those are the two answers a profile has to get right:
# it has to point at the work, and it must not invent any.
class TestProfiler < Minitest::Test
  include GembaSupport

  # One routine doing nearly all the work, one doing almost none, and one nothing calls.
  def lopsided_game
    RubyGBA.build("PROF", code: "PROF", maker: "01") do
      screen :bitmap
      clear_screen :black
      var :x, 0
      var :y, 0

      func(:the_hot_one) { repeat(2000) { add :x, 1 } }
      func(:the_cold_one) { add :y, 1 }
      func(:never_reached) { repeat(2000) { add :y, 1 } }

      game_loop do
        call :the_hot_one
        call :the_cold_one
      end
    end
  end

  def setup
    require_gemba_core!
  end

  def test_the_routine_doing_the_work_is_the_one_at_the_top
    result = lopsided_game.profile(out: StringIO.new, frames: 10)

    assert_equal :the_hot_one, result.lines.first.name
    assert_operator result.lines.first.share, :>, 90.0,
                    "a routine doing nearly all the work reads as nearly all the work"
  end

  # THE HALF THAT MATTERS AS MUCH. A profile that names something the game never ran is worse
  # than one that misses something, because it sends somebody to the wrong file.
  def test_a_routine_nothing_calls_does_not_appear
    result = lopsided_game.profile(out: StringIO.new, frames: 10)

    refute_includes result.lines.map(&:name), :never_reached
  end

  def test_almost_everything_is_attributed_to_something_named
    result = lopsided_game.profile(out: StringIO.new, frames: 10)

    assert_operator result.unattributed, :<, 5.0,
                    "what ran outside every routine the build knows about is a rounding error"
  end

  def test_it_reports_the_rate_the_console_produced_and_the_room_left_over
    result = lopsided_game.profile(out: StringIO.new, frames: 10)

    assert_in_delta 60.0, result.fps, 0.5
    refute_predicate result, :dropping_frames?
    assert_operator result.idle_share, :>, 0.0
  end

  def test_the_printed_report_names_the_routine_and_the_memory_it_ran_from
    out = StringIO.new
    lopsided_game.profile(out: out, frames: 10)

    assert_match(/func :the_hot_one/, out.string)
    assert_match(/quick memory|cartridge/, out.string)
    assert_match(/frames a second/, out.string)
  end

  def test_the_same_numbers_come_back_as_data
    out = StringIO.new
    lopsided_game.profile(format: :json, out: out, frames: 10)
    json = JSON.parse(out.string)

    assert_equal 10, json["frames"]
    assert_equal "the_hot_one", json["routines"].first["name"]
    assert_operator json["routines"].first["share"], :>, 90.0
  end

  # A game costs what the player makes it cost, so the buttons held have to reach the
  # measured frames — otherwise every reading is of a game standing still.
  def test_the_buttons_it_is_given_are_held_while_it_measures
    game = RubyGBA.build("PHLD", code: "PHLD", maker: "01") do
      screen :bitmap
      clear_screen :black
      var :x, 0
      func(:only_while_held) { repeat(2000) { add :x, 1 } }
      game_loop { held(:left).then { call :only_while_held } }
    end

    still = game.profile(out: StringIO.new, frames: 10)
    walking = game.profile(out: StringIO.new, frames: 10, keys: [:left])

    refute_includes still.lines.map(&:name), :only_while_held
    assert_equal :only_while_held, walking.lines.first.name
    assert_equal [:left], walking.keys
  end

  def test_an_unknown_format_says_so
    assert_raises(ArgumentError) { lopsided_game.profile(format: :sideways, out: StringIO.new) }
  end

  # A cartridge assembled straight from machine code has no record of where its routines
  # ended up, and they cannot be recovered from the bytes — a routine kept in the console's
  # quick memory was copied there at boot and runs nowhere near where it sits.
  def test_a_cartridge_that_does_not_know_how_it_was_built_says_so
    bare = RubyGBA::ROM.assemble("\x00\x00\x00\xEA".b, title: "BARE", code: "BARE", maker: "01")

    assert_raises(RubyGBA::ROMError) { bare.profile(out: StringIO.new) }
  end
end
