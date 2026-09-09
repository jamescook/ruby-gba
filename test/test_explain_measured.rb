# frozen_string_literal: true

require "test_helper"
require "stringio"

# rom.explain(measured: true): the verdict comes from running the cartridge on the emulator,
# while the breakdown stays the estimate — the one thing that can say WHERE a frame goes.
# Both are asked for at the same seam, and the report says which one the reader is looking
# at, and how to get the other.
class TestExplainMeasured < Minitest::Test
  def a_game
    RubyGBA.build("MEASURE", code: "BMSR", maker: "01", out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      game_loop do
        fill_rect 0, 0, 40, 40, :red
      end
    end
  end

  def a_scened_game
    RubyGBA.build("SCENED", code: "BSCN", maker: "01", out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      var :state, 0
      scene(:title) { clear_screen :blue }
      scene(:play)  { clear_screen :red }
      game_loop do
        wait_vblank
        case_var(:state) do
          when_val 0, :title
          when_val 1, :play
        end
      end
    end
  end

  def a_game_reading_a_button
    RubyGBA.build("HELD", code: "BHLD", maker: "01", out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      var :x, 0
      game_loop do
        held(:left).then { add :x, 1 }
      end
    end
  end

  def explained(rom, **opts)
    io = StringIO.new
    rom.explain(out: io, **opts)
    io.string
  end

  # gemba-core is required here, so the emulator is always built; to see what a reader
  # without one sees, its loader is made to fail for the length of the block.
  def without_the_emulator
    loader = RubyGBA::Emulator.method(:load!)
    swap_loader { raise LoadError, "not built" }
    yield
  ensure
    swap_loader(&loader)
  end

  def swap_loader(&body)
    RubyGBA::Emulator.singleton_class.remove_method(:load!)
    RubyGBA::Emulator.define_singleton_method(:load!, &body)
  end

  # THE POINT: the same call that gives the estimate gives the measured answer, and the
  # measured answer is the verdict.
  def test_asking_for_a_measurement_runs_the_cartridge_and_the_reading_is_the_verdict
    out = explained(a_game, measured: true)

    assert_match(/verdict measured on the emulator/, out)
    assert_match(/measured ~[\d.]+ of 228 scanlines/, out)
    refute_match(/estimate within budget/, out, "the estimate's own verdict gives way to the reading")
  end

  # Not asked for, the verdict is the estimate's own — and the report says how to ask, because
  # a reader who wants to know whether their game fits has no other way to find out.
  def test_not_asking_leaves_the_estimate_and_says_how_to_ask
    out = explained(a_game)

    assert_match(/estimate only/, out)
    assert_match(/measured: true/, out)
    refute_match(/measured ~/, out)
  end

  # Asked for with no emulator to run it on: an answer, not an error. The estimate, and a line
  # saying what the measured one needs — not "ask for it", which is what was just done.
  def test_without_the_emulator_the_estimate_is_the_answer_and_the_report_says_what_it_needs
    out = without_the_emulator { explained(a_game, measured: true) }

    assert_match(/estimate only/, out)
    assert_match(/needs the emulator/, out)
    assert_match(/rake test:mgba/, out, "says what to build")
    refute_match(/measured: true/, out, "it was asked for; asking again is the wrong advice")
    refute_match(/measured ~/, out)
  end

  # A scene is measured by booting straight into it, one reading per scene, and +scenes+
  # narrows it to the ones named.
  def test_a_scene_game_is_measured_scene_by_scene_and_scenes_narrows_it
    both = explained(a_scened_game, measured: true)
    assert_match(/scene :title\s+measured/, both)
    assert_match(/scene :play\s+measured/, both)

    one = explained(a_scened_game, measured: true, scenes: [:play])
    assert_match(/scene :play\s+measured/, one)
    refute_match(/scene :title\s+measured/, one)
  end

  def test_an_unknown_scene_is_a_friendly_error
    error = assert_raises(ArgumentError) { explained(a_scened_game, measured: true, scenes: [:nope]) }
    assert_match(/no scene named nope/, error.message)
    assert_match(/title, play/, error.message, "and names the scenes there are")
  end

  # A game costs what the player makes it cost; +keys+ pins what the player is doing and the
  # reading says so.
  def test_keys_pins_what_is_held_while_measuring_and_the_reading_says_so
    out = explained(a_game_reading_a_button, measured: true, keys: [:left])

    assert_match(/while LEFT is held/, out)
  end

  # scenes: and keys: describe a measurement. Without one they describe nothing, and the
  # error says what to add rather than quietly measuring or quietly ignoring them.
  def test_scenes_and_keys_need_a_measurement_to_apply_to
    error = assert_raises(ArgumentError) { explained(a_game, scenes: [:play]) }
    assert_match(/measured: true/, error.message)

    error = assert_raises(ArgumentError) { explained(a_game, keys: [:left]) }
    assert_match(/measured: true/, error.message)
  end

  def test_measured_takes_true_a_hash_or_nothing
    error = assert_raises(ArgumentError) { explained(a_game, measured: :yes) }
    assert_match(/measured: takes true/, error.message)
  end

  # A reading somebody else took still folds in, in the shape the profiler hands out.
  def test_a_reading_taken_elsewhere_is_the_verdict_too
    reading = RubyGBA::Analyzer::Result.new(scanlines: 30.0)
    out = explained(a_game, measured: { nil => reading.for_report })

    assert_match(/measured ~30\.0 of 228 scanlines/, out)
  end
end
