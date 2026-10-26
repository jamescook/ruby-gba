# frozen_string_literal: true

require "test_helper"
require "differential"

# A LATE PAGE ON THE TEAR-FREE SCREEN, shown at once when the game says so.
#
# The tear-free screen shows a finished page at the next break between pictures. A pass that
# runs a little over its frame misses that break and waits for the one after, so a frame a
# little late costs a whole frame: a game at sixty drops to thirty for it. `late:` lets a game
# show such a page as soon as it is done instead — free in the break between pictures, at the
# cost of a tear part way down one — and `pace:` says what late means for a game that aims at
# fewer than sixty pictures a second.
#
# The passes here are sized by measuring how much work fits in a frame, not by counting
# instructions, so a change that makes the loop or the clear cheaper moves where they end.
# Each size says where it was measured to end.
class TestLatePages < Minitest::Test
  include EmulatorSupport
  include Differential

  ENDS_IN_THE_BREAK = 22_600  # a little over a frame: ends during the break after its frame
  ENDS_NEAR_THE_TOP = 29_700  # ends a few rows down the picture after that break
  AT_THIRTY = 36_800          # most of two frames: a game at thirty
  AT_SIXTY = 17_850           # most of a frame: a game at sixty
  HEAVY = 13_000              # added to a pass at thirty, runs it into a third frame
  SLOW = 12_000               # added to a pass at sixty, runs it a few rows into a second

  private def late_program(work, late: :wait, pace: 60, extra: 0, every: 0)
    b = Builder.new
    b.instance_eval do
      screen :bitmap, tear_free: true, late: late, pace: late == :wait ? 60 : pace
      done = var :done, 0
      passes = var :passes, 0
      game_loop do
        clear_screen :gray
        repeat(work) { done.add! 1 }
        if every.positive?
          passes.add! 1
          ((passes % every) == 0).then { repeat(extra) { done.add! 1 } }
        end
      end
    end
    b.finalize_program
    b.program
  end

  private def profile_of(program, title)
    backend = GBA.new
    machine_code = backend.lower(program)
    rom = VBlank::Cartridge::ROM.assemble(machine_code, title: title, built: backend.build_record(program))
    VBlank::Diagnostics::Profiler.run(rom, frames: 60, picture: false)
  end

  def test_a_late_page_waits_for_the_next_break_unless_the_game_says
    require_emulator!
    result = profile_of(late_program(ENDS_IN_THE_BREAK), "LATEWAIT")

    assert_in_delta 30.0, result.fps, 0.5
    assert_equal 0, result.pages_shown_at_once
  end

  def test_a_late_page_is_shown_at_once_when_the_game_says
    require_emulator!
    result = profile_of(late_program(ENDS_NEAR_THE_TOP, late: :show_now), "LATENOW")

    assert_operator result.fps, :>, 35.0
    assert_operator result.pages_shown_part_way, :>, 0
  end

  # Finished in the break, nothing is being drawn, so the page cannot tear wherever the game
  # allows it to.
  def test_a_page_finished_in_the_break_is_shown_whatever_row_the_game_allows
    require_emulator!
    result = profile_of(late_program(ENDS_IN_THE_BREAK, late: 4), "LATEGAP")

    assert_operator result.fps, :>, 50.0
    assert_equal 0, result.pages_shown_part_way
  end

  # A NUMBER IS A ROW: a page finished while the screen is still drawing above that row is shown
  # at once, where a tear is least seen, and one finished below it waits as before. Here every
  # other page is shown at once: the pass after one starts part way down the picture, so it is
  # not late until the break after the coming one, and waits — two pictures in three frames,
  # where waiting every time is two in four.
  def test_a_page_finished_above_the_row_the_game_names_is_shown_at_once
    require_emulator!
    result = profile_of(late_program(ENDS_NEAR_THE_TOP, late: 80), "LATE80")

    assert_in_delta 40.0, result.fps, 0.5
    assert_operator result.pages_shown_part_way, :>, 0
  end

  def test_a_page_finished_below_the_row_the_game_names_waits
    require_emulator!

    assert_in_delta 30.0, profile_of(late_program(ENDS_NEAR_THE_TOP, late: 4), "LATE4").fps, 0.5
  end

  # PACE SAYS WHAT LATE MEANS. A game going steadily at thirty that says so is on time on every
  # pass, so it never shows a page at once and never tears.
  def test_a_game_on_time_for_its_pace_never_shows_a_page_at_once
    require_emulator!
    result = profile_of(late_program(AT_THIRTY, late: :show_now, pace: 30), "PACE30")

    assert_in_delta 30.0, result.fps, 0.5
    assert_equal 0, result.pages_shown_at_once
  end

  # ...and the heavy pass that runs into a third frame is the one shown at once — here in the
  # break, where nothing tears — so the game keeps thirty where waiting drops it below.
  def test_a_heavy_pass_at_thirty_is_shown_at_once
    require_emulator!
    waiting = profile_of(late_program(AT_THIRTY, extra: HEAVY, every: 4), "HEAVYW")
    showing = profile_of(late_program(AT_THIRTY, late: :show_now, pace: 30, extra: HEAVY, every: 4), "HEAVYS")

    assert_operator waiting.fps, :<, 29.0
    assert_in_delta 30.0, showing.fps, 0.5
    assert_operator showing.pages_shown_at_once, :>, 0
  end

  # ONE TEAR DOES NOT SET OFF ANOTHER. A game at sixty whose every eighth pass runs a little
  # into the next frame: that pass is shown part way down, and the passes after it, which start
  # part way down too, are shown in a break or wait — so it tears on the slow passes and on
  # nothing else, and keeps sixty where waiting drops it below.
  def test_only_the_slow_passes_tear
    require_emulator!
    waiting = profile_of(late_program(AT_SIXTY, extra: SLOW, every: 8), "SLOWW")
    showing = profile_of(late_program(AT_SIXTY, late: :show_now, extra: SLOW, every: 8), "SLOWS")

    assert_operator waiting.fps, :<, 57.0
    assert_in_delta 60.0, showing.fps, 0.5
    assert_operator showing.pages_shown_part_way, :<=, (60 / 8) + 1, "a tear for each slow pass at most"
  end

  # SAID PER SCREEN, SO PER SCENE: a game can show a late page at once while it plays and keep
  # its menu from ever tearing. A scene with no `screen` line of its own does what the game's
  # screen does, however the game reaches it.
  # The game starts in the menu, whose own screen waits, and moves to +stay+ a few frames in —
  # long before anything is measured — so a scene that inherits has something to undo.
  private def two_scene_program(dispatch, stay)
    b = Builder.new
    b.instance_eval do
      screen :bitmap, tear_free: true, late: :show_now
      done = var :done, 0
      scene :menu do
        screen :bitmap, tear_free: true
        clear_screen :gray
        repeat(ENDS_NEAR_THE_TOP) { done.add! 1 }
      end
      scene :play do
        clear_screen :gray
        repeat(ENDS_NEAR_THE_TOP) { done.add! 1 }
      end
      if dispatch == :case_var
        state = var :state, 0
        game_loop do
          after(5) { state.set!(stay == :menu ? 0 : 1) }
          case_var(:state) do
            when_val 0, :menu
            when_val 1, :play
          end
        end
      else
        mode = var :mode, :menu
        game_loop do
          after(5) { mode.set! stay }
          call mode
        end
      end
    end
    b.finalize_program
    b.program
  end

  def test_a_scene_with_no_screen_line_shows_a_late_page_as_the_games_screen_says
    require_emulator!

    assert_operator profile_of(two_scene_program(:case_var, :play), "LATEPLAY").fps, :>, 35.0
  end

  def test_a_scene_the_game_calls_by_name_does_the_same
    require_emulator!

    assert_operator profile_of(two_scene_program(:call, :play), "LATECALL").fps, :>, 35.0
  end

  def test_a_scene_whose_own_screen_waits_still_waits
    require_emulator!

    assert_in_delta 30.0, profile_of(two_scene_program(:case_var, :menu), "LATEMENU").fps, 0.5
  end

  # WHAT IS DRAWN DOES NOT CHANGE, only when it is shown.
  def test_a_page_shown_at_once_is_the_page_the_interpreter_draws
    b = Builder.new
    b.instance_eval do
      screen :bitmap, tear_free: true, late: :show_now
      done = var :done, 0
      game_loop do
        clear_screen :gray
        repeat(ENDS_NEAR_THE_TOP) { done.add! 1 }
        draw_rect_at 10, 10, 20, 30, :red
      end
    end
    b.finalize_program

    assert_backends_agree(b.program, frames: 3, name: "LATEPIC")
  end
end
