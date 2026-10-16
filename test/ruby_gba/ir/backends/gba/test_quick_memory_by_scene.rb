# frozen_string_literal: true

require "test_helper"

# QUICK MEMORY CHOSEN PER SCENE, AND SWAPPED AS A SCENE TAKES OVER.
#
# The console's quick memory is 32K, and the routines a game keeps there run about two and a
# third times faster. It used to be chosen once for the whole game and filled once at power-on,
# so a routine one screen ran held its room on every other screen too. Now, when what the game
# wants there does not all fit, each scene gets the room the whole game does not need: its own
# busy routines are copied in as it takes over, and the last scene's go back to running from
# the cartridge.
class TestQuickMemoryByScene < Minitest::Test
  # A game of two screens that each spend their frame in a routine of their own, each about
  # +adds+ additions long. It walks between them by itself: the title until frame 6, play
  # until frame 12, then the title again.
  private def two_screens(adds:, ticked: false)
    builder = Builder.new
    builder.instance_eval do
      timer(:clock, per_second: 60).on_tick { call :play_work } if ticked
      a = var :a, 0
      b = var :b, 0
      t = var :t, 0
      var :where, 0
      func(:title_work) { adds.times { a.add! 1 } }
      func(:play_work) { adds.times { b.add! 1 } }
      scene(:title) { call :title_work }
      scene(:play) { call :play_work }
      game_loop do
        t.add! 1
        (t == 6).then { set! :where, 1 }
        (t == 12).then { set! :where, 0 }
        case_var(:where) do
          when_val 0, :title
          when_val 1, :play
        end
      end
    end
    builder.finalize_program
    builder.program
  end

  # A game whose play screen insists on a routine of about +adds+ additions in the quick memory,
  # and whose file screen saves a record that insists on its save routines there too.
  # With +logos+, the game opens on a screen of logos that has no routines of its own, as a
  # real game does, before the file screen.
  # With +play_first+, the dispatch names play before the file screen.
  private def two_insisting_screens(adds:, logos: false, play_first: false)
    builder = Builder.new
    builder.instance_eval do
      b = var :b, 0
      hearts = var :hearts, 3
      var :where, logos ? 2 : 0
      files = save_data(:file, copies: 1, fast: true) { keep hearts }
      func(:play_work, fast: true) { adds.times { b.add! 1 } }
      scene(:logos) { pressed(:a).then { set! :where, 0 } } if logos
      scene(:files) { pressed(:a).then { files[0].save } }
      scene(:play) { call :play_work }
      game_loop do
        pressed(:start).then { set! :where, 1 }
        case_var(:where) do
          when_val 2, :logos if logos
          when_val 1, :play if play_first
          when_val 0, :files
          when_val 1, :play unless play_first
        end
      end
    end
    builder.finalize_program
    builder.program
  end

  private def placement_of(program)
    backend = GBA.new
    backend.lower(program)
    backend.iwram_report
  end

  # Two routines of about 16K each: one fits, two do not.
  BIG = 1200

  def test_each_scene_keeps_its_own_busy_routine_while_it_is_up
    report = placement_of(two_screens(adds: BIG))

    assert_includes report.scenes.fetch(:title), :title_work
    assert_includes report.scenes.fetch(:play), :play_work
  end

  # A ROUTINE A TIMER REACHES IS IN NO SCENE'S SET, though only play calls it otherwise: a tick
  # can land while the swap is copying, and it would run half a routine.
  def test_a_routine_a_timer_reaches_is_kept_out_of_every_scenes_set
    report = placement_of(two_screens(adds: BIG, ticked: true))

    refute(report.scenes.values.any? { |names| names.include?(:play_work) },
           "play's routine runs on the timer's tick too: #{report.scenes}")
    assert_includes report.scenes.fetch(:title), :title_work
  end

  # A GAME WHOSE ROUTINES ALL FIT SWAPS NOTHING: one set for the whole game, copied in at
  # power-on, is what it always was.
  def test_a_game_whose_routines_all_fit_keeps_one_set
    report = placement_of(two_screens(adds: 100))

    assert_empty report.scenes
    assert_includes report.funcs, :title_work
    assert_includes report.funcs, :play_work
  end

  # TWO WORDS THAT DO NOT FIT TOGETHER, ON TWO SCREENS THAT ARE NEVER UP TOGETHER. Kept for the
  # whole game, play's routine and the file screen's save routines need more room than there is,
  # and that used to stop the build. Each needs it only while its own screen is up.
  def test_two_insisted_routines_of_two_screens_each_get_their_screens_room
    report = placement_of(two_insisting_screens(adds: 1500))

    assert_includes report.scenes.fetch(:play), :play_work
    assert(report.scenes.fetch(:files).any? { |name| name.to_s.start_with?("__save_file__") },
           "the file screen keeps its save routines: #{report.scenes[:files]}")
  end

  # A SCREEN WITH NOTHING OF ITS OWN LEAVES WHAT IS IN, and power-on puts in the first set a
  # screen has. A game checks its saves as it opens, under its logos, and with nothing in the
  # quick memory then that check ran from the cartridge: a pass of a real game's opening ended
  # late, and the opening was a frame behind from there.
  def test_the_logos_run_with_the_file_screens_routines_already_in
    rom = assemble_rom(two_insisting_screens(adds: 1500, logos: true), name: "LOGOS")
    sets = rom.built.scene_sets
    v = assert_emulator_loads_rom(rom, frames: 10)

    assert_equal 1, v.mem32(sets.loaded_at)[sets.scenes.fetch(:files)], "the file screen's set is in under the logos"
  end

  # ...whatever order the dispatch names the scenes in: the save's routines are what the game
  # loop runs under the logos, so theirs is the set that goes in first, not play's.
  def test_the_saves_set_goes_in_first_though_play_is_named_first
    rom = assemble_rom(two_insisting_screens(adds: 1500, logos: true, play_first: true), name: "LOGOS")
    sets = rom.built.scene_sets
    v = assert_emulator_loads_rom(rom, frames: 10)

    assert_equal 1, v.mem32(sets.loaded_at)[sets.scenes.fetch(:files)], "the file screen's set is in under the logos"
  end

  # ...and the save those routines write from the file screen's room is the save the
  # interpreter writes, byte for byte.
  def test_a_save_written_from_the_file_screens_room_is_the_save
    program = two_insisting_screens(adds: 1500)
    console = RubyGBA.playthrough("save on the file screen") do
      wait frames: 10
      press :a
      wait frames: 60
    end.play(assemble_rom(program, name: "SAVES")).save

    oracle = SaveImage.new
    i = Reference.new(save: oracle)
    i.input_each_frame { |frame| frame == 5 ? [:a] : [] }
    i.run(program, frames: 60)

    refute_equal SaveImage.new.to_sav, console.to_sav, "the console wrote a save"
    assert_equal oracle.to_sav, console.to_sav
  end

  # Each routine kept in a scene's set came out no bigger than it was charged, so the room each
  # scene was promised is the room it got.
  def test_no_routine_comes_out_bigger_than_it_was_charged
    backend = GBA.new
    backend.lower(two_screens(adds: BIG))
    short = backend.charged_and_emitted_sizes.select { |_name, (charged, emitted)| charged < emitted }

    assert_empty short, "came out bigger than charged: #{short}"
  end

  # Each pass runs one scene's routine whole, so the two counts add up to the passes times the
  # additions, and play's is exactly its six passes — on the console, through a swap into play,
  # a swap back to the title, and the routines running from wherever they were at the time.
  def test_the_console_runs_each_scenes_routine_whole_across_both_swaps
    rom = assemble_rom(two_screens(adds: BIG), name: "SWAPS")
    v = assert_emulator_loads_rom(rom, frames: 30, vars: rom.var_addresses)
    passes = v.var(:t)

    assert_operator passes, :>, 13, "the console has been back on the title for a while"
    assert_equal BIG * 6, v.var(:b), "play ran its six passes, each whole"
    assert_equal BIG * passes, v.var(:a) + v.var(:b), "every pass ran one scene's routine whole"
  end

  # A SET IS NOT A ROUTINE. Every routine the profile can name is one somebody wrote or the build
  # made; a whole set named as one would take the time of each routine in it, wherever it ran.
  def test_no_scenes_set_is_named_as_a_routine_of_its_own
    rom = assemble_rom(two_screens(adds: BIG), name: "SWAPS")
    named = rom.built.routines.keys

    assert_includes named, :play_work
    assert_empty named.grep(/scene_set/), "a whole set was named as a routine: #{named.grep(/scene_set/)}"
  end

  # Held in either scene, its routine is what the frame spends its time in, and it runs from the
  # quick memory — the place both sets are copied to, named for the set that is in.
  def test_each_scene_runs_its_routine_from_the_quick_memory
    rom = assemble_rom(two_screens(adds: BIG), name: "SWAPS")
    { title: :title_work, play: :play_work }.each do |scene, routine|
      line = RubyGBA::Diagnostics::Profiler.run(rom, scene: scene, frames: 10, picture: false)
                                           .lines.find { |l| l.name == routine }

      refute_nil line, "the #{scene} scene's routine is named in its profile"
      assert_equal :quick_memory, line.where, "and runs from the quick memory while #{scene} is up"
    end
  end
end
