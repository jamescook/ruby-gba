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
  # +on_screen+ of nine kinds of thing, each kind in a list of colours of its own, and +off_screen+
  # more of the kinds after them, standing far past the screen's right edge.
  def self.crowd(on_screen, off_screen: 0)
    RubyGBA.game("CROWD #{on_screen} #{off_screen}", consoles: %i[gba gbc]) do
      screen :tiled
      image :ship, width: 8, height: 8, data: Array.new(64, :red), colors: %i[transparent red]
      lists = (0...9).map do |n|
        colors :"kind#{n}", [:transparent, RubyGBA::Graphics::Color.rgb(n * 3, 31 - (n * 3), 5)]
        :"kind#{n}"
      end
      things = pool :thing, x: 0, y: 0, kind: 0, capacity: 9, image: :ship
      on_screen.times { |n| things.spawn x: 10 + (n * 12), y: 40, kind: n }
      off_screen.times { |n| things.spawn x: 300, y: 40, kind: on_screen + n }
      game_loop { things.each { |thing| thing.draw_with lists, showing: thing.kind } }
    end
  end

  CROWD = crowd(9)
  FEW = crowd(4)
  ONE_AWAY = crowd(8, off_screen: 1)

  private def lent_profile(game, out: StringIO.new)
    game.build_rom(console: :gbc, out: StringIO.new, err: StringIO.new, profile: false).profile(out: out, frames: 30)
  end

  def test_a_sprite_that_finds_no_list_free_is_counted
    out = StringIO.new
    result = lent_profile(CROWD, out: out)

    assert_predicate result.lists_missed, :positive?
    assert_match(/found none of the console's eight lists of colours free/, out.string)
  end

  # Nine lists, four of them worn on the screen: the console lends its eight, and every thing
  # finds one.
  def test_a_game_that_lends_lists_and_fits_counts_no_miss
    out = StringIO.new
    result = lent_profile(FEW, out: out)

    assert_equal 0, result.lists_missed
    refute_match(/lists of colours free/, out.string)
  end

  # Eight lists on the screen and a ninth thing far off it: the one off the screen draws nothing,
  # so it takes none of the eight from the things on it.
  def test_a_thing_off_the_screen_takes_no_list_from_one_on_it
    assert_equal 0, lent_profile(ONE_AWAY).lists_missed
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
