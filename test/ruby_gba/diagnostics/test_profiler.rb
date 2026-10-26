# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tmpdir"

# `rom.profile` — where a game's frames actually went, measured by running it.
#
# These assert what the report SAYS about a program whose shape is known, not the numbers,
# which move whenever the lowering does. The fixture is built so one routine must dominate and
# another must never run at all, because those are the two answers a profile has to get right:
# it has to point at the work, and it must not invent any.
class TestProfiler < Minitest::Test
  include EmulatorSupport

  # One routine doing nearly all the work, one doing almost none, and one nothing calls.
  private def lopsided_game
    RubyGBA.build("PROF", console: :gba, code: "PROF", maker: "01", err: nil) do
      screen :bitmap
      clear_screen :black
      var :x, 0
      var :y, 0

      func(:the_hot_one) { repeat(2000) { add! :x, 1 } }
      func(:the_cold_one) { add! :y, 1 }
      func(:never_reached) { repeat(2000) { add! :y, 1 } }

      game_loop do
        call :the_hot_one
        call :the_cold_one
      end
    end
  end

  def setup
    require_emulator!
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
    game = RubyGBA.build("PHLD", console: :gba, code: "PHLD", maker: "01") do
      screen :bitmap
      clear_screen :black
      var :x, 0
      func(:only_while_held) { repeat(2000) { add! :x, 1 } }
      game_loop { held(:left).then { call :only_while_held } }
    end

    still = game.profile(out: StringIO.new, frames: 10)
    walking = game.profile(out: StringIO.new, frames: 10, keys: [:left])

    refute_includes still.lines.map(&:name), :only_while_held
    assert_equal :only_while_held, walking.lines.first.name
    assert_equal [:left], walking.keys
  end

  # A COPY RUNS NO INSTRUCTIONS. The console's copy engine stops the processor until it is done,
  # so a routine that starts a whole-screen clear runs a dozen instructions and takes most of a
  # frame. Counted by instructions the sums win; counted by time the clear has to.
  def test_the_time_a_copy_takes_is_charged_to_the_routine_that_starts_it
    game = RubyGBA.build("PCPY", console: :gba, err: nil) do
      screen :bitmap
      var :x, 0
      func(:the_clear) { clear_screen :black }
      func(:the_sums) { repeat(200) { add! :x, 1 } }
      game_loop do
        call :the_clear
        call :the_sums
      end
    end

    lines = game.profile(out: StringIO.new, frames: 10).lines.to_h { |line| [line.name, line] }

    assert_operator lines[:the_sums].share, :>, lines[:the_clear].share,
                    "the sums run more instructions"
    assert_operator lines[:the_clear].time_share, :>, lines[:the_sums].time_share,
                    "the clear takes more of the time, all of it in the copy"
  end

  def test_the_printed_report_gives_each_routine_its_share_of_the_time
    out = StringIO.new
    lopsided_game.profile(out: out, frames: 10)

    assert_match(/func :the_hot_one.*% of the time/, out.string)
  end

  # A game whose every pass waits for the screen to leave the break and then to reach +line+,
  # so each pass ends on that line of the next picture whatever the lowering emits.
  private def game_ending_on_line(line)
    RubyGBA.build("PLIN", console: :gba, err: nil) do
      extend RubyGBA::Builder::Debug
      screen :bitmap
      var :spin, 0
      game_loop do
        repeat(100_000, stop_when: read_scanline < 160) { add! :spin, 1 }
        repeat(100_000, stop_when: read_scanline >= line) { add! :spin, 1 }
      end
    end
  end

  # A PASS THAT ENDS A LINE LATE LOSES A WHOLE PICTURE. The wait at the end of a pass waits for the
  # NEXT break between pictures, so a pass that ends just after one began sleeps until the one
  # after. Measured by rate alone that is a game running at half speed with nothing to say why.
  def test_a_pass_that_ends_just_after_the_break_began_is_reported_with_how_late_it_was
    late = game_ending_on_line(165).profile(out: StringIO.new, frames: 10)

    refute_empty late.late_passes
    assert(late.late_passes.all? { |lines| (5..9).cover?(lines) },
           "each pass had to end about six lines sooner: #{late.late_passes.inspect}")
  end

  def test_the_report_says_a_late_pass_lost_a_whole_picture
    out = StringIO.new
    game_ending_on_line(165).profile(out: out, frames: 10)

    assert_match(/ended after the break between pictures began/, out.string)
    assert_match(/Ending \d+ lines? sooner keeps the picture/, out.string)
  end

  def test_late_passes_come_back_as_data_too
    out = StringIO.new
    game_ending_on_line(165).profile(format: :json, out: out, frames: 10)

    refute_empty JSON.parse(out.string)["late_passes"]
  end

  def test_a_pass_that_ends_before_the_break_is_not_late
    in_time = game_ending_on_line(150).profile(out: StringIO.new, frames: 10)

    assert_empty in_time.late_passes
    assert_in_delta 60.0, in_time.fps, 0.5
  end

  # A game whose setting up waits for the screen to reach each line of +lines+ in turn, so the pass
  # from power-on ends on the last of them whatever the lowering emits. A line in the picture after
  # one in the break is waited for from below it, so the setting up runs on into the next picture.
  private def game_set_up_until(*lines)
    RubyGBA.build("PPON", console: :gba, err: nil) do
      extend RubyGBA::Builder::Debug
      screen :bitmap
      var :spin, 0
      [0, *lines].each_cons(2) do |before, line|
        repeat(100_000, stop_when: read_scanline < 160) { add! :spin, 1 } if line < before
        repeat(100_000, stop_when: read_scanline >= line) { add! :spin, 1 }
      end
      game_loop {}
    end
  end

  # [breaks it ran through, lines before the next break it ended], from a run from power-on.
  private def first_pass_of(game)
    pass = game.profile(out: StringIO.new, frames: 5, settle: 0).power_on_pass
    [pass.missed, pass.ended_before]
  end

  # HOW CLOSE THE FIRST PASS CAME. A game that sets up a little more each time it grows is on time
  # until one day it is not, and a whole picture later when it is; the lines it ended before the
  # break say how near that day is.
  def test_from_power_on_it_says_how_many_lines_before_the_break_the_first_pass_ended
    missed, lines = first_pass_of(game_set_up_until(150))

    assert_equal 0, missed
    assert_includes 6..9, lines
  end

  def test_a_first_pass_that_ended_late_says_how_many_lines_after_the_break_began
    missed, lines = first_pass_of(game_set_up_until(165))

    assert_equal 1, missed
    assert_includes(-9..-5, lines)
  end

  # Setting up that takes more than a frame runs through a break, and then the question is how
  # near it is to running through one more.
  def test_a_first_pass_that_ran_into_the_next_picture_says_the_lines_before_the_next_break
    missed, lines = first_pass_of(game_set_up_until(165, 20))

    assert_equal 1, missed
    assert_includes 136..139, lines
  end

  def test_the_report_says_how_many_lines_the_first_pass_had_to_spare
    out = StringIO.new
    game_set_up_until(150).profile(out: out, frames: 5, settle: 0)

    assert_match(/first pass after power-on ended \d+ lines before the break between pictures/, out.string)
  end

  def test_the_report_says_how_late_the_first_pass_was
    out = StringIO.new
    game_set_up_until(165).profile(out: out, frames: 5, settle: 0)

    assert_match(/first pass after power-on ended \d+ lines into the break between pictures, so the game showed its first picture a picture later\. Ending \d+ lines sooner/, out.string)
  end

  # Setting up that is still running when the measuring stops is said, not left out: "we did not
  # see it end" must never read as "there was nothing to see".
  def test_a_first_pass_that_did_not_end_in_the_frames_measured_says_so
    out = StringIO.new
    result = game_set_up_until(165, 20, 165, 20).profile(out: out, frames: 1, settle: 0)

    refute_predicate result.power_on_pass, :finished?
    assert_match(/first pass after power-on did not end in the 1 frame measured/, out.string)
  end

  def test_the_report_says_how_many_breaks_the_first_pass_ran_through
    out = StringIO.new
    game_set_up_until(165, 20).profile(out: out, frames: 5, settle: 0)

    assert_match(/first pass after power-on ran through 1 break between pictures.*It ended \d+ lines before the next break/, out.string)
  end

  def test_how_many_lines_the_first_pass_had_to_spare_comes_back_as_data_too
    out = StringIO.new
    game_set_up_until(150).profile(format: :json, out: out, frames: 5, settle: 0)
    pass = JSON.parse(out.string)["power_on_pass"]

    assert_equal 0, pass["missed"]
    assert_includes 6..9, pass["ended_before"]
  end

  # Measured after the game has settled, the first pass the run sees began before it did.
  def test_a_run_that_settles_first_says_nothing_about_the_first_pass
    out = StringIO.new
    settled = game_set_up_until(150).profile(out: out, frames: 5, settle: 5)

    assert_nil settled.power_on_pass
    refute_match(/power-on/, out.string)
  end

  # WHAT THE SETTING UP SPENT ITS TIME ON, by name. A loop in setup that fills a list a push at a
  # time is named after the list, and the rest of the setting up has a name of its own, so neither
  # reads as code nothing knows about.
  def test_from_power_on_the_setting_up_and_its_fill_loops_are_named
    game = RubyGBA.build("PPOW", console: :gba, err: nil) do
      screen :bitmap
      held = list :held, capacity: 2000
      repeat(2000) { held.push 1 }
      var :x, 0
      repeat(2000) { add! :x, 1 }
      game_loop {}
    end
    result = game.profile(out: StringIO.new, frames: 5, settle: 0)
    shares = result.lines.to_h { |line| [line.label, line.share] }

    assert_operator shares.fetch("filling list :held a push at a time, before the game loop"), :>, 20.0
    assert_operator shares.fetch("setting the game up, before the game loop"), :>, 10.0
    assert_operator result.unattributed, :<, 5.0, "what ran outside every named routine: #{shares.inspect}"
  end

  def test_an_unknown_format_says_so
    assert_raises(ArgumentError) { lopsided_game.profile(format: :sideways, out: StringIO.new) }
  end

  # --- holding a game in one scene ---

  # A game boots to its title and a held button will not get past one, because a menu reads
  # the press EDGE. So which screen gets measured has to be said rather than played to.
  private def scened_game
    RubyGBA.build("PSCN", console: :gba, code: "PSCN", maker: "01") do
      screen :bitmap
      clear_screen :black
      var :state, 0
      var :x, 0

      scene(:title) { add! :x, 1 }
      scene(:playing) { call :the_work }
      func(:the_work) { repeat(2000) { add! :x, 1 } }

      game_loop do
        case_var(:state) do
          when_val 0, :title
          when_val 1, :playing
        end
      end
    end
  end

  def test_naming_a_scene_measures_that_scene
    rom = scened_game
    booted = rom.profile(out: StringIO.new, frames: 10)
    playing = rom.profile(out: StringIO.new, frames: 10, scene: :playing)

    refute_includes booted.lines.map(&:name), :the_work,
                    "left alone the game sits on its title screen"
    assert_equal :the_work, playing.lines.first.name,
                 "named, it is held in the playing scene and that is what gets measured"
  end

  # WRITING THE SCENE ONCE IS NOT ENOUGH — a game left alone leaves the scene almost at once
  # (a snake with nobody steering dies in a few frames), and then the measuring is of the
  # screen it fell into, under the name of the one that was asked for. So it is held there.
  def test_a_scene_is_held_rather_than_merely_entered
    rom = RubyGBA.build("PHLD2", console: :gba, code: "PHL2", maker: "01") do
      screen :bitmap
      clear_screen :black
      var :state, 1
      var :x, 0

      scene(:busy) { call :the_work; set! :state, 2 } # leaves immediately
      scene(:idle) { add! :x, 1 }
      func(:the_work) { repeat(2000) { add! :x, 1 } }

      game_loop do
        case_var(:state) do
          when_val 1, :busy
          when_val 2, :idle
        end
      end
    end

    held = rom.profile(out: StringIO.new, frames: 10, scene: :busy)
    assert_equal :the_work, held.lines.first.name,
                 "a scene that switches away on its first frame is still what gets measured"
  end

  def test_a_scene_the_game_does_not_have_says_which_it_does
    error = assert_raises(ArgumentError) do
      scened_game.profile(out: StringIO.new, scene: :nowhere)
    end

    assert_match(/no scene called/, error.message)
    assert_match(/:title/, error.message)
  end

  # --- did the picture tear ---

  # The build says a game CAN tear, which is a fact about the screen it chose. Whether one
  # that can DOES is a race between the display's row and the game's, and only running it
  # settles that — so it is measured here rather than priced.
  def test_a_game_that_draws_more_than_fits_is_seen_to_tear
    heavy = RubyGBA.build("PTER", console: :gba, code: "PTER", maker: "01") do
      screen :bitmap
      var :x, 0
      game_loop do
        clear_screen :black
        6.times { |i| fill_rect 0, i * 24, 240, 24, :red }
        add! :x, 1
      end
    end
    result = heavy.profile(out: StringIO.new, frames: 10)

    assert_predicate result.tearing, :torn?
    assert_operator result.tearing.worst, :>, 0, "and it says how many rows showed early"
  end

  def test_a_game_that_keeps_up_is_seen_not_to_tear
    light = RubyGBA.build("PTEL", console: :gba, code: "PTEL", maker: "01") do
      screen :bitmap
      var :x, 0
      game_loop { fill_rect 0, 0, 8, 8, :red; add! :x, 1 }
    end
    result = light.profile(out: StringIO.new, frames: 10)

    refute_predicate result.tearing, :torn?
  end

  # "We did not look" must never read as "nothing was wrong", so a screen that cannot tear
  # reports nothing at all rather than a reassuring zero.
  def test_a_screen_that_cannot_tear_reports_nothing_rather_than_no_tear
    buffered = RubyGBA.build("PTEB", console: :gba, code: "PTEB", maker: "01") do
      screen :bitmap, tear_free: true
      var :x, 0
      game_loop { clear_screen :black; add! :x, 1 }
    end
    out = StringIO.new
    result = buffered.profile(out: out, frames: 10)

    assert_nil result.tearing
    refute_match(/tore|held together/, out.string)
  end

  # --- a moment somebody played to ---

  # The work runs only once a variable is set, and nothing sets it. No held button reaches
  # this and no scene contains it — it is STATE, which is what a saved moment carries and a
  # booted scene does not.
  private def armed_game(bump = 1)
    RubyGBA.build("PSAV", console: :gba, code: "PSAV", maker: "01") do
      screen :bitmap
      clear_screen :black
      armed = var :armed, 0
      var :x, 0
      func(:the_work) { repeat(2000) { add! :x, bump } }
      game_loop { (armed == 1).then { call :the_work } }
    end
  end

  # Play to the moment — here by reaching in and arming it, which is what a player pressing
  # buttons would have done — and save it.
  private def moment_in(rom, dir, name: "moment.state")
    path = File.join(dir, name)
    rom_path = File.join(dir, "#{name}.gba")
    rom.write(rom_path)
    probe = RubyGBA::Diagnostics::Emulator.probe(rom_path)
    begin
      probe.step(12)
      probe.write32(rom.built.var_addresses[:armed], 1)
      probe.step(2)
      probe.save_state(path)
    ensure
      probe.close
    end
    path
  end

  def test_a_saved_moment_is_what_gets_measured
    Dir.mktmpdir do |dir|
      rom = armed_game
      booted = rom.profile(out: StringIO.new, frames: 10)
      resumed = rom.profile(out: StringIO.new, frames: 10, from: moment_in(rom, dir))

      refute_includes booted.lines.map(&:name), :the_work,
                      "nothing arms this game, so booting it measures a game doing nothing"
      assert_equal :the_work, resumed.lines.first.name,
                   "the saved moment carries the state that makes the work run"
    end
  end

  # THE ONE THAT MATTERS MOST. A state holds addresses, and a rebuild moves all of them. Read
  # one anyway and it still produces numbers — about whatever code moved into those addresses.
  # Measuring the wrong thing quietly is worse than refusing to measure.
  def test_a_moment_saved_from_another_build_is_refused
    Dir.mktmpdir do |dir|
      saved = moment_in(armed_game(1), dir)
      rebuilt = armed_game(2) # one number changed, and every address has moved

      error = assert_raises(ArgumentError) do
        rebuilt.profile(out: StringIO.new, frames: 10, from: saved)
      end

      assert_match(/different build/, error.message)
      assert_match(/save it again/, error.message, "...and says what to do about it")
    end
  end

  # ...and the other half of that, which is what keeps the guard from being a nuisance: a
  # build is deterministic, so re-running one costs nobody their saved moments. Only a real
  # change moves the addresses, which is exactly when a moment has stopped meaning anything.
  def test_rebuilding_the_same_game_keeps_a_saved_moment
    Dir.mktmpdir do |dir|
      saved = moment_in(armed_game(1), dir)
      again = armed_game(1) # the same source, built a second time

      result = again.profile(out: StringIO.new, frames: 10, from: saved)
      assert_equal :the_work, result.lines.first.name
    end
  end

  def test_a_moment_that_is_not_there_says_so
    error = assert_raises(ArgumentError) do
      armed_game.profile(out: StringIO.new, from: "/nowhere/boss.state")
    end

    assert_match(/no saved moment/, error.message)
  end

  # A saved moment already says which scene the game was in, so the two ways of reaching a
  # moment would be fighting each other.
  def test_asking_for_a_scene_and_a_moment_at_once_says_so
    Dir.mktmpdir do |dir|
      rom = armed_game
      error = assert_raises(ArgumentError) do
        rom.profile(out: StringIO.new, from: moment_in(rom, dir), scene: :playing)
      end

      assert_match(/not both/, error.message)
    end
  end

  # A profile without this is not reproducible: the same cartridge measured on its title
  # screen and in its boss fight are different numbers about different code, and nothing in
  # the numbers says which you are holding.
  def test_the_report_says_how_the_moment_was_reached
    Dir.mktmpdir do |dir|
      rom = armed_game
      out = StringIO.new
      rom.profile(out: out, frames: 10, from: moment_in(rom, dir))
      assert_match(/from the saved moment in moment\.state/, out.string)

      booted = StringIO.new
      rom.profile(out: booted, frames: 10)
      assert_match(/as the game boots/, booted.string)

      scened = StringIO.new
      scened_game.profile(out: scened, frames: 10, scene: :playing)
      assert_match(/held in the :playing scene/, scened.string)
    end
  end

  def test_how_the_moment_was_reached_comes_back_as_data_too
    Dir.mktmpdir do |dir|
      rom = armed_game
      out = StringIO.new
      rom.profile(format: :json, out: out, frames: 10, from: moment_in(rom, dir))

      reached = JSON.parse(out.string)["reached"]
      assert_equal "state", reached["how"]
      assert_match(/moment\.state/, reached["detail"])
    end
  end

  # A cartridge assembled straight from machine code has no record of where its routines
  # ended up, and they cannot be recovered from the bytes — a routine kept in the console's
  # quick memory was copied there at boot and runs nowhere near where it sits.
  def test_a_cartridge_that_does_not_know_how_it_was_built_says_so
    bare = RubyGBA::Cartridge::ROM.assemble("\x00\x00\x00\xEA".b, title: "BARE", code: "BARE", maker: "01")

    assert_raises(RubyGBA::ROMError) { bare.profile(out: StringIO.new) }
  end
end
