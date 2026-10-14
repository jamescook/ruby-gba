# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require "open3"
require "rbconfig"

# The game played as C, and then the same buttons played on the interpreter, with the run
# stopped at the first frame the two do not agree on (Native::CheckedRun) — which is what a test
# opted into native runs is handed there (CheckedNativeRun, the suite's own name for it), so a
# file's hand-picked checks are backed by every variable and every pixel of every frame.
class TestCheckedRun < Minitest::Test
  # The native lowering's own tests, which only a native run plays (see TestSuites).
  runs_on :native

  include NativeComparison

  CheckedRun = RubyGBA::IR::Backends::Native::CheckedRun
  CannotAnswer = RubyGBA::IR::Backends::Native::HeadlessRun::CannotAnswer
  Moment = CheckedRun::Moment
  LIB = File.expand_path("../../../../../lib", __dir__)

  # A game built on the library plays its own game checked with nothing but the library: no
  # minitest, and nothing from this suite's folder on the load path.
  GAME_OF_ITS_OWN = <<~RUBY
    require "ruby_gba"

    game = RubyGBA.game "CHECKED" do
      x = var :x, 0
      game_loop { held(:right).then { x.add! 1 } }
    end
    run = RubyGBA::IR::Backends::Native::CheckedRun.new.hold(:right).run(game.program, frames: 6)
    puts run[:x]
    puts defined?(Minitest).inspect
  RUBY

  def test_a_game_of_its_own_plays_checked_with_only_the_library
    out, err, status = Open3.capture3(RbConfig.ruby, "-I", LIB, "-", stdin_data: GAME_OF_ITS_OWN)

    assert status.success?, "the game's own process failed:\n#{err}"
    assert_equal %w[6 nil], out.lines(chomp: true), "x after six frames held right, and no minitest loaded"
  end

  def test_a_run_both_agree_on_answers_like_the_native_one
    program = program_of do
      x = var :x, 0
      game_loop { held(:right).then { x.add! 1 } }
    end
    run = CheckedRun.new
    run.input_each_frame { |_frame| run[:x] < 3 ? [:right] : [] }

    assert_equal 3, run.run(program, frames: 8)[:x]
  end

  # A step budget is the interpreter's own measure, so it says how many frames fit in one, and
  # the C plays that many: the answer is the interpreter's for the same budget.
  def test_a_step_budget_plays_the_frames_the_interpreter_fits_in_it
    program = program_of do
      x = var :x, 0
      game_loop { held(:right).then { x.add! 1 } }
    end
    interpreter = Reference.new.hold(:right).run(program, max_steps: 60)

    played = CheckedRun.new.hold(:right).run(program, max_steps: 60)

    assert_operator interpreter[:x], :>, 2, "the budget should hold a few frames"
    assert_equal interpreter[:x], played[:x]
    assert_equal interpreter.frame, CheckedRun.last_frame(played.moments)
  end

  # The interpreter has a held button down from the game's first statement, and the console has
  # its keys from power-on, so a game that reads one before its first frame sees it down.
  def test_a_button_held_for_the_whole_run_is_down_before_the_first_frame
    program = program_of do
      early = var :early, 0
      held(:a).then { early.set! 1 }
      game_loop {}
    end

    played = CheckedRun.new.hold(:a).run(program, frames: 2)

    assert_equal 1, Reference.new.hold(:a).run(program, frames: 2)[:early], "the interpreter's answer"
    assert_equal 1, played[:early]
  end

  # A run whose pictures differ is played again a pixel at a time to say where, and that replay
  # holds the same buttons from power-on.
  def test_the_replay_that_finds_the_pixel_holds_buttons_from_power_on
    program = program_of do
      early = var :early, 0
      held(:a).then { early.set! 1 }
      game_loop {}
    end

    want = reference_snapshots(program, frames: 1, buttons: {}, held: [:a]).last
    got = native_snapshots(program, frames: 1, buttons: {}, mode: :checked, held: [:a]).last

    assert_equal 1, want.variables[:early]
    assert_equal 1, got.variables[:early]
  end

  def test_a_step_budget_on_a_game_that_never_waits_for_the_screen_cannot_be_played
    builder = Builder.new(options: RubyGBA::Cartridge::Options.new(frame_sync: :manual))
    builder.instance_eval do
      x = var :x, 0
      game_loop { x.add! 1 }
    end
    builder.finalize_program
    program = builder.program

    error = assert_raises(CannotAnswer) { CheckedRun.new.run(program, max_steps: 60) }

    assert_match(/before it first waits for the screen/, error.message)
  end

  # A count of frames means nothing to a game with none: the interpreter stops it at its step
  # budget, which the C cannot, so it is said at once rather than left to run.
  def test_a_frame_count_on_a_game_that_never_waits_for_the_screen_cannot_be_played
    builder = Builder.new(options: RubyGBA::Cartridge::Options.new(frame_sync: :manual))
    builder.instance_eval do
      x = var :x, 0
      game_loop { x.add! 1 }
    end
    builder.finalize_program
    program = builder.program

    error = assert_raises(CannotAnswer) { CheckedRun.new.run(program, frames: 4) }

    assert_match(/never waits for the screen/, error.message)
  end

  # A game with no frames that comes to an end by itself is played as it is.
  def test_a_game_with_no_frames_that_ends_is_played
    program = program_of do
      x = var :x, 0
      repeat(5) { x.add! 3 }
    end

    assert_equal 15, CheckedRun.new.run(program, frames: 4)[:x]
  end

  # Watching a run leaves it a checked one: what each_vblank gives back is the checked run
  # itself, so the run a test goes on to make is still compared with the interpreter. The block
  # reads the game as C, at each frame boundary.
  def test_a_watched_run_is_still_a_checked_one
    program = program_of do
      x = var :x, 0
      game_loop { x.add! 2 }
    end
    seen = []
    run = CheckedRun.new

    watched = run.each_vblank { |frame| seen << [frame, run[:x]] }

    assert_same run, watched
    watched.run(program, frames: 3)
    assert_equal [[1, 0], [2, 2], [3, 4]], seen
  end

  # A sprite drawn at +x+ across, showing the picture of its own name.
  def drawn(name, x) = RubyGBA::Diagnostics::DrawnSprite.new(name: name, x: x, y: 40, picture: name)

  def test_the_first_frame_they_disagree_on_is_named_with_what_differs
    agreed = Moment.new(frame: 1, variables: { x: 0 }, picture: 7, sounds: 0, sprites: [])
    want = [agreed, Moment.new(frame: 2, variables: { x: 1 }, picture: 7, sounds: 1, sprites: [drawn(:coin, 8), drawn(:hero, 20)]),
            Moment.new(frame: 3, variables: { x: 2 }, picture: 9, sounds: 1, sprites: [])]
    got = [agreed, Moment.new(frame: 2, variables: { x: 2 }, picture: 8, sounds: 2, sprites: [drawn(:coin, 8), drawn(:hero, 22)]),
           Moment.new(frame: 3, variables: { x: 2 }, picture: 9, sounds: 1, sprites: [])]

    difference = CheckedRun.first_difference(want, got)

    assert_match(/frame 2/, difference)
    assert_match(/x: C has 2, Reference 1/, difference)
    assert_match(/picture/, difference)
    assert_match(/sound log holds 2 entries in the C and 1/, difference)
    assert_match(/sprite 1 of those drawn: C has :hero at \(22, 40\) showing :hero, Reference :hero at \(20, 40\)/, difference)
  end

  # A sprite one of them drew and the other did not is a difference too.
  def test_a_sprite_only_one_of_them_drew_is_named
    want = [Moment.new(frame: 1, variables: {}, picture: 7, sounds: 0, sprites: [drawn(:hero, 20)])]
    got = [Moment.new(frame: 1, variables: {}, picture: 7, sounds: 0, sprites: [])]

    assert_match(/sprite 0 of those drawn: C has none, Reference :hero at \(20, 40\)/,
                 CheckedRun.first_difference(want, got))
  end

  # Every list and pool is compared on every frame, as the variables are.
  def test_a_list_or_a_pool_field_that_differs_is_named
    moment = lambda do |trail, guard_x|
      Moment.new(frame: 1, variables: {}, picture: 7, sounds: 0, sprites: [],
                 collections: { lists: { trail: trail }, pools: { guard: { x: guard_x, hp: [nil, 3] } } })
    end

    difference = CheckedRun.first_difference([moment.call([1, 2], [nil, 3])], [moment.call([1, 3], [nil, 4])])

    assert_match(/list :trail: C has \[1, 3\], Reference \[1, 2\]/, difference)
    assert_match(/pool :guard field :x: C has \[nil, 4\], Reference \[nil, 3\]/, difference)
    refute_match(/:hp/, difference, "a field that agrees is not named")
  end

  def test_runs_that_agree_have_no_difference
    same = [Moment.new(frame: 1, variables: { x: 0 }, picture: 7, sounds: 0, sprites: [drawn(:hero, 20)])]

    assert_nil CheckedRun.first_difference(same, same)
  end

  # A game that saves is replayed on the interpreter from the save memory the C started with. The
  # second run here starts from what the first left, so an interpreter replayed from a new
  # cartridge would count from 5 again and the run would fail.
  def test_a_run_from_save_memory_is_replayed_from_the_same_save_memory
    program = program_of do
      best = save_var :best, 5
      game_loop { best.add! 2 }
    end
    store = SaveImage.new
    CheckedRun.new(save: store).run(program, frames: 3)

    again = CheckedRun.new(save: store).run(program, frames: 2)

    assert_equal 15, again[:best]
    assert_equal 15, store.word(RubyGBA::IR::SaveLayout.save_var_at(0)), "the save memory handed in holds what the run left"
  end

  def test_the_first_byte_of_save_memory_they_disagree_on_is_named
    want = SaveImage.new(kilobytes: 32)
    want.write(0x1004, 7, 1)
    got = SaveImage.new(kilobytes: 32)
    got.write(0x1004, 9, 1)

    assert_match(/save memory at 0x1004: C has 0x09, Reference 0x07/, CheckedRun.save_difference(want, got))
    assert_nil CheckedRun.save_difference(want, want.dup)
  end

  def test_the_first_sound_they_disagree_on_is_named
    difference = CheckedRun.sounds_difference([[:enabled], [:note, :tune, 262]], [[:enabled], [:note, :tune, 294]])

    assert_match(/entry 1 of the sound log: C has \[:note, :tune, 294\], Reference \[:note, :tune, 262\]/, difference)
    assert_nil CheckedRun.sounds_difference([[:enabled]], [[:enabled]])
  end
end
