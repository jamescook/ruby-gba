# frozen_string_literal: true

require "test_helper"
require "stringio"

# A Game Boy Color cartridge measured as it runs (Diagnostics::GBCProfiler): the frame rate it
# played at, how much of the time it slept, and its frames by routine, its own by the game's names.
class TestGBCProfiler < Minitest::Test
  GAME = RubyGBA.game("BUSY", consoles: %i[gba gbc]) do
    total = var :total, 0
    func(:count_up) { repeat(40) { total.add! 3 } }
    game_loop { call :count_up }
  end

  private def profiled(**options)
    rom = GAME.build_rom(console: :gbc, out: StringIO.new, err: StringIO.new, profile: false)
    rom.profile(out: StringIO.new, **options)
  end

  def test_a_light_game_plays_a_pass_a_frame_and_sleeps_most_of_each
    result = profiled(frames: 30)

    assert_in_delta 59.7, result.fps, 2.5
    assert_operator result.idle_share, :>, 0.5
  end

  def test_the_games_own_routines_are_named_as_the_game_names_them
    names = profiled(frames: 30).game.map(&:routine)

    assert_includes names, "count_up"
    assert_includes names, "the game loop"
  end

  def test_a_scene_to_measure_is_refused_in_plain_words
    error = assert_raises(ArgumentError) { profiled(scene: :title) }

    assert_match(/cannot be told a scene/, error.message)
  end

  # NINE THINGS IN NINE LISTS OF COLOURS ON THE SCREEN AT ONCE: the Color lends its eight lists
  # to the lists on the screen, so one thing finds none free every pass and is drawn in another
  # list's colours. Nothing in the picture says so to the author; the profile does.
  CROWD = RubyGBA.game("CROWD", consoles: %i[gba gbc]) do
    screen :tiled
    image :ship, width: 8, height: 8, data: Array.new(64, :red), colors: %i[transparent red]
    lists = (0...9).map do |n|
      colors :"kind#{n}", [:transparent, RubyGBA::Graphics::Color.rgb(n * 3, 31 - (n * 3), 5)]
      :"kind#{n}"
    end
    things = pool :thing, x: 0, y: 0, kind: 0, capacity: 9, image: :ship
    9.times { |n| things.spawn x: 10 + (n * 12), y: 40, kind: n }
    game_loop { things.each { |thing| thing.draw_with lists, showing: thing.kind } }
  end

  def test_a_sprite_that_finds_no_list_free_is_counted
    rom = CROWD.build_rom(console: :gbc, out: StringIO.new, err: StringIO.new, profile: false)
    out = StringIO.new
    result = rom.profile(out: out, frames: 30)

    assert_predicate result.lists_missed, :positive?
    assert_match(/found none of the console's 8 lists of colours free/, out.string)
  end

  def test_a_game_that_lends_no_lists_counts_nothing
    assert_nil profiled(frames: 30).lists_missed
  end

  def test_the_report_says_the_frame_rate_and_the_routines
    rom = GAME.build_rom(console: :gbc, out: StringIO.new, err: StringIO.new, profile: false)
    out = StringIO.new
    rom.profile(out: out, frames: 30)

    assert_match(/passes of the game loop in 30 frames/, out.string)
    assert_match(/Your routines:\n.*count_up/m, out.string)
  end
end
