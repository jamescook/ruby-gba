# frozen_string_literal: true

require "test_helper"
require "stringio"

# A Game Boy Color cartridge measured as it runs (Diagnostics::GBCProfiler): the frame rate it
# played at, how much of the time it slept, and its frames by routine, its own by the game's names.
class TestGBCProfiler < Minitest::Test
  GAME = VBlank.game("BUSY", consoles: %i[gba gbc]) do
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

  # A SCREEN FADED IN BY STEPPING ITS LISTS, the way a cartridge made for the Color fades: seven
  # lists of the background's, and +sprite_lists+ lists that eight sprites wear, each drawn with the
  # next of sixteen steps every frame, and no tint or fade said. Copying the colours that change is
  # all the frame needs.
  def self.stepped(sprite_lists)
    VBlank.game("STEPPED #{sprite_lists}", consoles: %i[gba gbc]) do
      screen :tiled
      shade = ->(n, s) { [:transparent, *(0..3).map { |c| VBlank::Graphics::Color.rgb((n + s + c) % 32, s * 2, c * 8) }] }
      steps = (0...16).to_a
      quarters = Array.new(64) { |i| 1 + ((i % 8) / 4) + (2 * ((i / 8) / 4)) }
      7.times do |n|
        colors :"bg#{n}", shade.call(n, 0)
        image :"tile#{n}", width: 8, height: 8, colors: :"bg#{n}", places: quarters
        steps.each { |s| colors :"bg#{n}_#{s}", shade.call(n, s) }
      end
      sprite_lists.times do |n|
        colors :"sp#{n}", [:transparent, VBlank::Graphics::Color.rgb(31, n, 0)]
        steps.each { |s| colors :"sp#{n}_#{s}", [:transparent, VBlank::Graphics::Color.rgb(31 - s, n, s)] }
        image :"ball#{n}", width: 8, height: 8, colors: :"sp#{n}", places: Array.new(64, 1)
      end
      tiles :set, (0...7).to_h { |n| [n.to_s, :"tile#{n}"] }
      board = background :board, tiles: :set, map: Array.new(18) { "0123456" * 3 }
      worn = ->(n) { n * sprite_lists / 8 }
      balls = (0...8).map { |n| sprite :"ball#{worn.call(n)}", at: [8 + (n * 16), 120] }
      step = var :step, 0
      game_loop do
        step.set!((step + 1) % 16)
        board.draw_with((0...7).to_h { |n| [:"bg#{n}", steps.map { |s| :"bg#{n}_#{s}" }] }, showing: step)
        balls.each_with_index { |ball, n| ball.draw_with steps.map { |s| :"sp#{worn.call(n)}_#{s}" }, showing: step }
      end
    end
  end

  # Eight sprites two to a list, and eight with a list each: every one of the eight lists is worn on
  # every frame, and each sprite steps into the one its lists held the frame before.
  STEPPED = [stepped(4), stepped(8)].freeze

  def test_a_screen_stepping_its_lists_every_frame_keeps_a_pass_a_frame
    STEPPED.each do |game|
      rom = game.build_rom(console: :gbc, out: StringIO.new, err: StringIO.new, profile: false)
      result = rom.profile(out: StringIO.new, frames: 30)

      assert_in_delta 59.7, result.fps, 2.5, game.title
      assert_equal 0, result.lists_missed, "#{game.title}: every sprite found a list of colours"
    end
  end

  def test_a_scene_to_measure_is_refused_in_plain_words
    error = assert_raises(ArgumentError) { profiled(scene: :title) }

    assert_match(/cannot be told a scene/, error.message)
  end

  # NINE THINGS IN NINE LISTS OF COLOURS ON THE SCREEN AT ONCE: the Color lends its eight lists
  # to the lists on the screen, so one thing finds none free every pass and is drawn in another
  # list's colours. Nothing in the picture says so to the author; the profile does.
  # +on_screen+ of nine kinds of thing, each kind in a list of colours of its own, and one more of
  # the kinds after them at each place of +away+, off the screen.
  def self.crowd(on_screen, away: [])
    VBlank.game("CROWD #{on_screen} #{away.flatten.join(' ')}", consoles: %i[gba gbc]) do
      screen :tiled
      image :ship, width: 8, height: 8, data: Array.new(64, :red), colors: %i[transparent red]
      lists = (0...9).map do |n|
        colors :"kind#{n}", [:transparent, VBlank::Graphics::Color.rgb(n * 3, 31 - (n * 3), 5)]
        :"kind#{n}"
      end
      things = pool :thing, x: 0, y: 0, kind: 0, capacity: 9, image: :ship
      on_screen.times { |n| things.spawn x: 10 + (n * 12), y: 40, kind: n }
      away.each_with_index { |(x, y), n| things.spawn x: x, y: y, kind: on_screen + n }
      game_loop { things.each { |thing| thing.draw_with lists, showing: thing.kind } }
    end
  end

  CROWD = crowd(9)
  FEW = crowd(4)
  # Just past the right edge, far past it, far to the left, far above, and just past the left and
  # top edges, where a thing coming on or going off stands.
  AWAY = [[170, 40], [300, 40], [-100, 40], [40, -100], [-30, 40], [40, -30], [-64, 40]].freeze
  ONE_AWAY = AWAY.map { |place| crowd(8, away: [place]) }.freeze

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
    AWAY.zip(ONE_AWAY).each do |place, game|
      assert_equal 0, lent_profile(game).lists_missed, "a ninth thing at #{place.inspect}"
    end
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
