# frozen_string_literal: true

require "test_helper"
require "stringio"

# The guardrail for a game loop whose body did not fit in the console's quick memory
# (lib/ruby_gba/ir/guardrails/frame_from_cartridge.rb). The loop is where the frame's time
# goes, so leaving it in the cartridge slows the whole game by the factor the quick memory is
# worth — and nothing about the symptom points at the cause, because the cause is the SIZE
# of code in the loop, not the work it does.
class TestFrameFromCartridgeGuardrail < Minitest::Test
  runs_on :reference

  # A loop with a large piece of code in it that seldom runs. +cold_in_a_func+ moves that code
  # into a routine of its own, marked so the chooser leaves it in the cartridge — the fix the
  # warning names.
  def game(cold_in_a_func:)
    err = StringIO.new
    rom = RubyGBA.build("COLD", code: "ZCLD", maker: "01", out: StringIO.new, err: err) do
      screen :bitmap
      spin = var :spin, 0
      cold = lambda { 4000.times { spin.add! 1 } }
      func(:thinking, fast: false) { cold.call } if cold_in_a_func
      game_loop do
        fill_rect 0, 0, 40, 8, :green
        if cold_in_a_func
          (spin == 1).then { call :thinking }
        else
          (spin == 1).then { cold.call }
        end
      end
    end
    [rom, err.string]
  end

  # THE POINT. The loop's body did not fit, so the build says so, in words about the fix
  # rather than about the hardware.
  def test_a_loop_too_big_to_fit_is_told_so_and_told_the_fix
    rom, warnings = game(cold_in_a_func: false)

    refute rom.built.frame_in_quick_memory?, "the premise: the loop's body was left in the cartridge"
    assert_match(/game loop's body did not fit/, warnings)
    assert_match(/runs from the cartridge/, warnings)
    assert_match(/mark it `fast: false`/, warnings, "the fix is one word, and it is said")
    assert_match(/needs [\d.]+K, and [\d.]+K was free/, warnings, "the numbers an author acts on")
    refute_match(/IWRAM/, warnings, "no hardware name")
  end

  # ...and the fix works: with the cold code in a routine of its own the loop fits, is kept,
  # and nothing is said.
  def test_with_the_cold_code_in_its_own_routine_the_loop_fits_and_nothing_is_said
    rom, warnings = game(cold_in_a_func: true)

    assert rom.built.frame_in_quick_memory?, "the loop's body is kept in the quick memory"
    refute_match(/did not fit/, warnings)
  end

  # --- a build that measured its game knows what the loop's own code is worth ---

  # A loop too big to fit, in a game the build runs and measures before it places anything.
  # The loop draws a bar and holds a large piece of code that never runs. The frame's real
  # work is +work+ passes of a sum: written in a routine of its own, which the build keeps in
  # the quick memory, or with +inline+ written in the loop itself. With +scenes+ the game has
  # a title that does nothing and a playing scene that draws a second bar.
  def measured_game(inline:, work: 5000, scenes: false)
    err = StringIO.new
    rom = RubyGBA.build("WORK#{inline ? 'IN' : 'OUT'}#{'S' if scenes}", out: StringIO.new, err: err, profile: true) do
      screen :bitmap
      spin = var :spin, 0
      busy = var :busy, 0
      summing = -> { repeat(work) { busy.add! 3 } }
      func(:sums) { summing.call } unless inline
      if scenes
        var :state, 0
        scene(:title) { busy.add! 1 }
        scene(:playing) { fill_rect 0, 16, 40, 8, :red }
      end
      game_loop do
        fill_rect 0, 0, 40, 8, :green
        inline ? summing.call : call(:sums)
        (spin == 1).then { 4000.times { spin.add! 1 } }
        next unless scenes

        case_var(:state) do
          when_val 0, :title
          when_val 1, :playing
        end
      end
    end
    [rom, err.string]
  end

  # The loop is left in the cartridge, and nearly all of a frame's work runs from the quick
  # memory anyway, because it is in a routine that was kept. Nothing is slow, and there is no
  # code to move out of the loop that would change a frame, so nothing is said.
  def test_a_loop_left_out_is_not_called_slow_when_its_own_code_is_a_sliver_of_the_frame
    rom, warnings = measured_game(inline: false)
    placement = rom.built.placement

    assert_equal :measurement, placement.chosen_from
    assert_includes placement.passed_over.map(&:name), :__frame, "the premise: the loop was wanted and did not fit"
    assert_includes placement.funcs, :sums, "the premise: the frame's work is kept in the quick memory"
    refute_match(/did not fit/, warnings)
    refute_match(/whole frame/, warnings)
  end

  # ...and where the loop's own code IS the frame's work, the measured build still says so, and
  # says what it measured rather than "the whole frame".
  def test_a_measured_loop_that_holds_the_frames_work_is_told_its_share
    rom, warnings = measured_game(inline: true)

    refute rom.built.frame_in_quick_memory?, "the premise: the loop's body was left in the cartridge"
    assert_match(/game loop's body did not fit/, warnings)
    share = warnings[/That code is about (\d+)% of the work of a frame/, 1]

    assert_operator share.to_i, :>, 90, "nearly all of this game's work is the loop's own (#{warnings})"
    assert_match(/mark it `fast: false`/, warnings)
    refute_match(/whole frame/, warnings)
  end

  # In a game with scenes the share is of the scene whose frames do the most, and the warning
  # names it, so it can be read beside `rom.profile` for that scene.
  def test_a_game_with_scenes_is_told_which_scene_the_share_is_of
    _rom, warnings = measured_game(inline: true, scenes: true)

    assert_match(/In the :playing scene, where a frame does the most work, that code is about \d+% of the work/,
                 warnings)
  end

  # WHERE THE LINE IS: a tenth of a frame's work. What the check finds for a loop left out of
  # a 2K gap, given the per cent of the busiest scene's work its own code was measured to do —
  # or nil for a build that measured nothing.
  def findings_for(percent, scene: nil)
    placement = GBA::Placement
    measured = percent && RubyGBA::Diagnostics::RoutineProfile::Share.new(percent: percent, scene: scene)
    over = placement::PassedOver.new(name: placement::FRAME_ROUTINE, bytes: 3584, room: 2048, measured: measured)
    report = placement::Report.new(funcs: [], code_bytes: 0, used_bytes: 0, free_bytes: 2048, total_bytes: 32_768,
                                   sizes: {}, passed_over: [over], chosen_from: percent ? :measurement : :shape)
    build = RubyGBA::IR::Build
    program = build.program(build.screen(:bitmap), build.loop_(build.wait_vblank))
    RubyGBA::IR::Guardrails::Checks::FrameFromCartridge.new(report).detect(program)
  end

  def test_a_loop_doing_under_a_tenth_of_a_frames_work_is_not_warned_about
    assert_empty findings_for(1.0)
    assert_empty findings_for(9.9, scene: :playing)
  end

  # At a tenth it is, with its share — and with both ways out, since in a measured build the
  # room may have gone to costlier routines rather than the loop being too big for any.
  def test_a_loop_doing_a_tenth_of_a_frames_work_is_warned_about_with_its_share
    message = findings_for(10.0).first.message

    assert_match(/That code is about 10% of the work of a frame/, message)
    assert_match(/needs 3\.5K, and 2\.0K was free/, message)
    assert_match(/make the loop's body smaller/, message)
    assert_match(/Or give the loop more room/, message)
    refute_match(/The cause is not the work the loop does/, message, "it has just said how much work that is")
  end

  def test_a_build_that_measured_nothing_still_says_the_whole_frame
    message = findings_for(nil).first.message

    assert_match(/whole frame runs from the cartridge/, message)
    assert_match(/The cause is not the work the loop does/, message)
  end

  # The build report says the same thing about the same routine, by the name a person has for it.
  def test_the_report_names_the_game_loop_rather_than_its_internal_name
    rom, = game(cold_in_a_func: false)
    io = StringIO.new
    RubyGBA::Diagnostics::BuildReport.render(rom, out: io)

    assert_match(/the game loop did not fit/, io.string)
    refute_match(/__frame/, io.string)
  end
end
