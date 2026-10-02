# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tmpdir"

# WHICH ROUTINES GO IN THE CONSOLE'S QUICK MEMORY, decided by measuring the game.
#
# It is the one choice a build cannot measure its way to on its own: the choice is an input to
# the lowering, so it has to be made before the cartridge it would run exists. So the game is
# built once, run, and built again knowing — and these tests are about that loop closing.
#
# The fixture is built so the answer is unmistakable: the routine doing the work is only
# reachable through a scene the game does not boot into, so a build that measures it and a
# build that guesses cannot land in the same place.
class TestMeasuredPlacement < Minitest::Test
  include EmulatorSupport

  Placement = RubyGBA::IR::Backends::GBA::Placement

  def setup
    require_emulator!
  end

  # The work lives in the second scene. Nothing reaches it by holding a button — a scene is
  # switched by a press, and a held button is one press however long it is held.
  def game_with_work_in_a_later_scene
    RubyGBA.game("MPLC", code: "MPLC", maker: "01") do
      screen :bitmap
      clear_screen :black
      var :state, 0
      var :x, 0

      scene(:title) { add! :x, 1 }
      scene(:playing) { call :the_hot_one }
      func(:the_hot_one) { repeat(3000) { add! :x, 1 } }

      game_loop do
        case_var(:state) do
          when_val 0, :title
          when_val 1, :playing
        end
      end
    end
  end

  def placement_for(profile)
    game_with_work_in_a_later_scene
      .build_rom(out: StringIO.new, err: StringIO.new, profile: profile).built.placement
  end

  def test_a_measured_build_keeps_the_routine_the_game_really_spends_its_frames_in
    placement = placement_for(true)

    assert_equal :measurement, placement.chosen_from
    assert_includes placement.funcs, :the_hot_one,
                    "the work is in a scene the game never boots into, and measuring finds it anyway"
  end

  def test_without_measuring_the_choice_is_made_from_the_shape_and_says_so
    placement = placement_for(false)

    assert_equal :shape, placement.chosen_from
  end

  # The report has to say which of the two happened, because an author cannot tell by reading
  # the list and the difference is a factor of about two and a third on whatever is on it.
  def test_the_report_says_which_answer_it_gave
    %i[measurement shape].each do |expected|
      out = StringIO.new
      rom = game_with_work_in_a_later_scene.build_rom(out: StringIO.new, err: StringIO.new,
                                                      profile: expected == :measurement)
      RubyGBA::Diagnostics::BuildReport.render(rom, out: out)

      if expected == :measurement
        assert_match(/chosen from a measurement/, out.string)
      else
        assert_match(/chosen from the shape of the program/, out.string)
        assert_match(/measures/, out.string, "...and says how to get the measured one")
      end
    end
  end

  # A ROUTINE ON EVERY SCREEN OUTRANKS ONE ON A SINGLE SCREEN THAT DOES LESS IN ALL. The game
  # loop runs on every frame the player ever sees; a menu's routine runs on one screen they see
  # for a moment. Ranking each by its busiest screen weighed the two as though both ran on one,
  # and a file-select screen seen once took the quick memory from the game loop.
  #
  # Here :everywhere does 300 steps on each of four screens and :one_screen 800 on one: less
  # than it on the one screen, and far more than it across the game.
  def game_with_a_routine_on_every_screen
    RubyGBA.game("MPL3", maker: "01") do
      screen :bitmap
      clear_screen :black
      var :state, 0
      var :x, 0
      func(:everywhere) { repeat(300) { add! :x, 1 } }
      func(:one_screen) { repeat(800) { add! :x, 1 } }
      scene(:logos) { add! :x, 1 }
      scene(:title) { add! :x, 1 }
      scene(:files) { call :one_screen }
      scene(:playing) { add! :x, 1 }
      game_loop do
        call :everywhere
        case_var(:state) do
          when_val 0, :logos
          when_val 1, :title
          when_val 2, :files
          when_val 3, :playing
        end
      end
    end
  end

  def test_a_routine_on_every_screen_outranks_one_on_a_single_screen
    rom = game_with_a_routine_on_every_screen.build_rom(out: StringIO.new, err: StringIO.new, profile: false)
    work = RubyGBA::Diagnostics::Profiler.survey_scenes(rom, frames: 10).work
    ranked = RubyGBA::Diagnostics::RoutineProfile.from_work(work).order_by_work(%i[one_screen everywhere])

    assert_equal %i[everywhere one_screen], ranked, "measured: #{work.slice(:everywhere, :one_screen)}"
  end

  # --- a measurement saved and read back ---

  def test_a_saved_measurement_decides_the_next_build
    Dir.mktmpdir do |dir|
      path = File.join(dir, "game.profile.json")
      first = game_with_work_in_a_later_scene.build_rom(out: StringIO.new, err: StringIO.new,
                                                        profile: false)
      RubyGBA::Diagnostics::RoutineProfile.from_work(RubyGBA::Diagnostics::Profiler.survey_scenes(first, frames: 10).work).write(path)

      placement = placement_for(path)

      assert_equal :measurement, placement.chosen_from
      assert_includes placement.funcs, :the_hot_one
    end
  end

  # A profile that has drifted from its game keeps deciding the placement, so the drift is
  # said out loud rather than left to work quietly.
  def test_a_measurement_naming_a_routine_the_game_no_longer_has_says_so
    Dir.mktmpdir do |dir|
      path = File.join(dir, "stale.profile.json")
      RubyGBA::Diagnostics::RoutineProfile.from_work({ a_routine_since_renamed: 5000 }).write(path)

      err = StringIO.new
      game_with_work_in_a_later_scene.build_rom(out: StringIO.new, err: err, profile: path)

      assert_match(/a_routine_since_renamed/, err.string)
      assert_match(/measure the game again/, err.string)
    end
  end

  # ...and the routines the BUILD invents are not drift. One glyph walker per font appears and
  # disappears as a game changes, and saying so every time would train an author to ignore it.
  def test_a_routine_the_build_made_is_not_reported_as_drift
    Dir.mktmpdir do |dir|
      path = File.join(dir, "built.profile.json")
      RubyGBA::Diagnostics::RoutineProfile.from_work({ RubyGBA::Messages::MadeNames.make(:digit_routine, font: :default) => 5000 }).write(path)

      err = StringIO.new
      game_with_work_in_a_later_scene.build_rom(out: StringIO.new, err: err, profile: path)

      refute_match(/out of date/, err.string)
    end
  end

  # --- what an author says wins ---

  # The measurement decides what the framework picks; it never overrules the author. A routine
  # insisted on is placed before anything the chooser wanted, measured or not.
  def test_an_author_still_overrules_the_measurement
    game = RubyGBA.game("MPL2", code: "MPL2", maker: "01") do
      screen :bitmap
      clear_screen :black
      var :x, 0
      func(:never_run, fast: true) { repeat(3000) { add! :x, 1 } }
      game_loop { add! :x, 1 }
    end
    placement = game.build_rom(out: StringIO.new, err: StringIO.new).built.placement

    assert_includes placement.funcs, :never_run,
                    "measured at nothing, and kept anyway because the author asked"
  end

  # A routine measured at almost nothing is not worth the room: moving it costs a longer call
  # at every site, every frame, and gives back only a share of what little it runs.
  def test_a_routine_that_hardly_runs_is_not_worth_the_room
    profile = RubyGBA::Diagnostics::RoutineProfile.from_work({ busy: 5000, idle: 3 })

    assert profile.worth_quick_memory?(:busy)
    refute profile.worth_quick_memory?(:idle)
    assert_equal %i[busy idle], profile.order_by_work(%i[idle busy]), "dearest first"
  end
end
