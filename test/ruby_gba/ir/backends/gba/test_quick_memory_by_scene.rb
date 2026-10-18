# frozen_string_literal: true

require "test_helper"
require "differential"

# QUICK MEMORY CHOSEN PER SCENE, AND SWAPPED AS A SCENE TAKES OVER.
#
# The console's quick memory is 32K, and the routines a game keeps there run about two and a
# third times faster. It used to be chosen once for the whole game and filled once at power-on,
# so a routine one screen ran held its room on every other screen too. Now, when what the game
# wants there does not all fit, each scene gets the room the whole game does not need: its own
# busy routines are copied in as it takes over, and the last scene's go back to running from
# the cartridge.
class TestQuickMemoryByScene < Minitest::Test
  include Differential

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

  # The same game, whose screen is a variable holding the scene's name, run with `call where`.
  private def two_screens_by_name(adds:)
    builder = Builder.new
    builder.instance_eval do
      a = var :a, 0
      b = var :b, 0
      t = var :t, 0
      where = var :where, :title
      func(:title_work) { adds.times { a.add! 1 } }
      func(:play_work) { adds.times { b.add! 1 } }
      scene(:title) { call :title_work }
      scene(:play) { call :play_work }
      game_loop do
        t.add! 1
        (t == 6).then { where.set! :play }
        (t == 12).then { where.set! :title }
        call where
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

  # Two screens that each run a routine of their own and one they share, each about +adds+
  # additions long.
  private def two_screens_sharing(adds:)
    builder = Builder.new
    builder.instance_eval do
      x = var :x, 0
      var :where, 0
      func(:shared_work) { adds.times { x.add! 1 } }
      func(:title_work) { adds.times { x.add! 2 } }
      func(:play_work) { adds.times { x.add! 3 } }
      scene(:title) do
        call :shared_work
        call :title_work
      end
      scene(:play) do
        call :shared_work
        call :play_work
      end
      game_loop do
        pressed(:a).then { set! :where, 1 }
        case_var(:where) do
          when_val 0, :title
          when_val 1, :play
        end
      end
    end
    builder.finalize_program
    builder.program
  end

  # Two tiled screens that each spend their frame in a routine of their own; play also has a
  # pool of things to draw and scenery on a map too big for the console's grid, both declared
  # in play, so the routines that put the pool in order and bring the map's view along are
  # play's alone. The game loop itself calls one more routine only while play is up. The game
  # walks by itself: the title until frame 3, play until frame 9, then the title again.
  private def two_screens_with_play_scenery(adds:)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:dot, "#" => :yellow) { "########\n" * 8 }
      image(:grass, "#" => :green) { "########\n" * 8 }
      image(:dirt, "#" => :orange, "." => :black) { "####....\n" * 8 }
      tiles :field, "#" => :grass, "." => :dirt
      a = var :a, 0
      b = var :b, 0
      t = var :t, 0
      where = var :where, 0
      func(:title_work) { adds.times { a.add! 1 } }
      func(:play_work) { adds.times { b.add! 1 } }
      func(:play_extra) { (adds / 4).times { b.add! 2 } }
      scene(:title) { call :title_work }
      scene :play do
        ground = background :ground, tiles: :field, map: Array.new(30) { |row| ("#.." * 24)[row % 3, 70] }
        sparks = pool :spark, x: 0, y: 0, capacity: 4, image: :dot
        (sparks.count == 0).then { sparks.spawn(x: 10, y: 10) }
        sparks.each { |spark| spark.x.add! 1 }
        ground.scroll_by 1, 0
        call :play_work
      end
      game_loop do
        t.add! 1
        (t == 3).then { where.set! 1 }
        (t == 9).then { where.set! 0 }
        (where == 1).then { call :play_extra }
        case_var(:where) do
          when_val 0, :title
          when_val 1, :play
        end
      end
    end
    builder.finalize_program
    builder.program
  end

  # Two screens that each spend their frame in a routine of their own, and a game loop that does
  # +extra+ additions of its own while play is up, written in the loop under a test of the
  # scene. The game walks by itself: the title until frame 3, play until frame 9, then the
  # title again.
  private def loop_working_for_play(extra:, work: BIG)
    builder = Builder.new
    builder.instance_eval do
      a = var :a, 0
      b = var :b, 0
      c = var :c, 0
      t = var :t, 0
      where = var :where, 0
      func(:title_work) { work.times { a.add! 1 } }
      func(:play_work) { work.times { b.add! 1 } }
      scene(:title) { call :title_work }
      scene(:play) { call :play_work }
      game_loop do
        t.add! 1
        (t == 3).then { where.set! 1 }
        (t == 9).then { where.set! 0 }
        (where == 1).then { extra.times { c.add! 1 } }
        case_var(:where) do
          when_val 0, :title
          when_val 1, :play
        end
      end
    end
    builder.finalize_program
    builder.program
  end

  # WHAT THE GAME LOOP DOES FOR ONE SCENE IS THAT SCENE'S, not the loop's: the loop is kept for
  # the whole game, in every scene's room, so work written in it for play alone held room on the
  # title too. It goes in play's own set, and the loop is the same size however much there is.
  def test_the_game_loops_work_for_one_scene_goes_in_that_scenes_set
    small = placement_of(loop_working_for_play(extra: 10))
    large = placement_of(loop_working_for_play(extra: 400))
    frame = GBA::Placement::FRAME_ROUTINE

    assert_equal small.sizes.fetch(frame), large.sizes.fetch(frame), "the loop does not grow with play's work"
    assert(large.scenes.fetch(:play).any? { |name| RubyGBA::Messages::MadeNames.read(name)&.first == :scene_loop_work },
           "play keeps its loop work in its own set: #{large.scenes}")
  end

  # ...and the console plays it as the interpreter does, through the swap into play and back.
  def test_the_game_loops_work_for_play_runs_across_both_swaps
    program = loop_working_for_play(extra: 400)
    [2, 4, 6, 10, 12].each { |f| assert_backends_agree(program, frames: f) }
    rom = assemble_rom(program, name: "LOOPWORK")
    v = assert_emulator_loads_rom(rom, frames: 30, vars: rom.var_addresses)

    assert_equal 400 * 6, v.var(:c), "play's loop work ran on each of its six passes, whole"
  end

  # A GAME WHOSE ROUTINES ALL FIT KEEPS ITS LOOP AS IT WAS: a block for one scene made a routine
  # pays a call every frame, and buys nothing where no scene's set is swapped in.
  def test_a_game_whose_routines_all_fit_keeps_its_scene_blocks_in_the_loop
    report = placement_of(loop_working_for_play(extra: 10, work: 100))

    assert_empty report.scenes
    assert_empty(report.sizes.keys.select { |name| RubyGBA::Messages::MadeNames.read(name)&.first == :scene_loop_work })
  end

  # A BLOCK FOR ONE SCENE INSIDE A COUNTED LOOP STAYS WHERE IT IS: the loop keeps its count in a
  # register, and a routine called from inside it would read the count from where the register
  # has not yet put it. What it adds up is what the interpreter adds up.
  def test_a_scene_block_inside_a_counted_loop_reads_the_count
    builder = Builder.new
    builder.instance_eval do
      a = var :a, 0
      b = var :b, 0
      c = var :c, 0
      where = var :where, 1
      func(:title_work) { BIG.times { a.add! 1 } }
      func(:play_work) { BIG.times { b.add! 1 } }
      scene(:title) { call :title_work }
      scene(:play) { call :play_work }
      game_loop do
        repeat(5) { |i| (where == 1).then { c.add! i } }
        case_var(:where) do
          when_val 0, :title
          when_val 1, :play
        end
      end
    end
    builder.finalize_program
    rom = assemble_rom(builder.program, name: "COUNTED")
    v = assert_emulator_loads_rom(rom, frames: 4, vars: rom.var_addresses, count_passes: true)

    assert_equal (0 + 1 + 2 + 3 + 4) * v.passes, v.var(:c)
  end

  # A title with a busy routine of its own, and a play screen with a map too big for the
  # console's grid that insists on a routine of about +adds+ additions in the quick memory.
  private def play_insisting_beside_its_map(adds:)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:grass, "#" => :green) { "########\n" * 8 }
      tiles :field, "#" => :grass
      a = var :a, 0
      b = var :b, 0
      var :where, 0
      func(:title_work) { BIG.times { a.add! 1 } }
      func(:play_work, fast: true) { adds.times { b.add! 1 } }
      scene(:title) { call :title_work }
      scene :play do
        ground = background :ground, tiles: :field, map: Array.new(30) { "#" * 70 }
        ground.scroll_by 1, 0
        call :play_work
      end
      game_loop do
        pressed(:a).then { set! :where, 1 }
        case_var(:where) do
          when_val 0, :title
          when_val 1, :play
        end
      end
    end
    builder.finalize_program
    builder.program
  end

  # The most additions play can insist on and still have the routine in its own share, to
  # within a few: found by halving, from a size that splits the room to one that does not fit.
  private def most_play_can_insist_on
    low = 600
    high = 2000
    while high - low > 4
      middle = (low + high) / 2
      play_keeps_it = begin
        placement_of(play_insisting_beside_its_map(adds: middle)).scenes.fetch(:play, []).include?(:play_work)
      rescue GBA::QuickMemoryFull
        false
      end
      play_keeps_it ? low = middle : high = middle
    end
    low
  end

  private def placement_of(program, routine_profile: nil)
    backend = GBA.new(routine_profile: routine_profile)
    backend.lower(program)
    backend.iwram_report
  end

  # Two routines of about 16K each: one fits, two do not.
  BIG = 1200

  # Words of a list that leave room for the game loop and the save routines, and not for the
  # music as well. Picked for the cartridge the build makes today.
  CROWDING_PILE = 4350

  # Additions in the routine play insists on: enough that it and the file screen's save routines
  # do not fit together in the room kept for the whole game, and each fits its own scene's.
  # Picked for the room the build leaves today.
  PLAY_INSISTS = 1750

  def test_each_scene_keeps_its_own_busy_routine_while_it_is_up
    report = placement_of(two_screens(adds: BIG))

    assert_includes report.scenes.fetch(:title), :title_work
    assert_includes report.scenes.fetch(:play), :play_work
  end

  # A GAME THAT PICKS ITS SCREEN BY NAME (`call where`) splits the room the same way, and the
  # console runs each scene's routine whole across the swaps.
  def test_screens_picked_by_name_each_keep_their_own_busy_routine
    program = two_screens_by_name(adds: BIG)
    report = placement_of(program)
    rom = assemble_rom(program, name: "BYNAME")
    v = assert_emulator_loads_rom(rom, frames: 30, vars: rom.var_addresses)

    assert_includes report.scenes.fetch(:title), :title_work
    assert_includes report.scenes.fetch(:play), :play_work
    assert_equal BIG * 6, v.var(:b), "play ran its six passes, each whole"
    assert_equal BIG * v.var(:t), v.var(:a) + v.var(:b), "every pass ran one scene's routine whole"
  end

  # EACH SCENE'S ROOM GOES TO WHAT A FRAME OF THAT SCENE SPENDS THE MOST IN. A routine both
  # screens run is counted once for each in the measurement added up over every scene, so it
  # reads dearer than either screen's own routine, though a frame of either spends less in it.
  # Kept for the whole game, it would take the room both screens' own routines need.
  def test_each_scenes_room_goes_to_what_a_frame_of_it_spends_most_in
    frame = GBA::Placement::FRAME_ROUTINE
    profile = RubyGBA::Diagnostics::RoutineProfile.new(
      work: { frame => 400, _scene_title: 30, _scene_play: 30, shared_work: 2000, title_work: 1500, play_work: 1500 },
      scenes: { title: { frame => 200, _scene_title: 30, shared_work: 1000, title_work: 1500 },
                play: { frame => 200, _scene_play: 30, shared_work: 1000, play_work: 1500 } }
    )
    report = placement_of(two_screens_sharing(adds: BIG), routine_profile: profile)

    assert_includes report.scenes.fetch(:title, []), :title_work, "kept: #{report.funcs}, sets: #{report.scenes}"
    assert_includes report.scenes.fetch(:play, []), :play_work
    refute_includes report.funcs, :shared_work
  end

  # ...BUT NOT AT THE OTHER SCENES' COST. Here play's own routine is a little busier than the
  # one both screens run, and the title runs nothing of its own: keeping the shared one for the
  # whole game speeds up both screens, where play's own would speed up play a little more and
  # the title not at all.
  def test_a_routine_both_screens_run_keeps_its_room_when_that_is_worth_more
    frame = GBA::Placement::FRAME_ROUTINE
    profile = RubyGBA::Diagnostics::RoutineProfile.new(
      work: { frame => 400, _scene_title: 30, _scene_play: 30, shared_work: 2000, title_work: 0, play_work: 1100 },
      scenes: { title: { frame => 200, _scene_title: 30, shared_work: 1000 },
                play: { frame => 200, _scene_play: 30, shared_work: 1000, play_work: 1100 } }
    )
    report = placement_of(two_screens_sharing(adds: BIG), routine_profile: profile)

    assert_includes report.funcs, :shared_work, "kept: #{report.funcs}, sets: #{report.scenes}"
    refute_includes report.scenes.fetch(:play, []), :play_work
  end

  # WHAT ONLY PLAY RUNS GOES IN PLAY'S SET, though the game loop is what calls it: putting
  # play's pool in order and bringing play's big map along, which the gap after each frame does
  # while play is up, and a routine the game loop calls under its own test that play is up.
  # Kept for the whole game, they take the room every other screen's own routines need.
  def test_routines_the_game_loop_runs_for_one_scene_go_in_that_scenes_set
    report = placement_of(two_screens_with_play_scenery(adds: BIG))
    stacking = RubyGBA::Messages::MadeNames.make(:pool_stacking, pool: :spark)
    view = RubyGBA::Messages::MadeNames.make(:view_along_map, background: :ground)

    [stacking, view, :play_extra].each do |routine|
      refute_includes report.funcs, routine, "kept: #{report.funcs}, sets: #{report.scenes}"
      assert_includes report.scenes.fetch(:play), routine
    end
    assert_includes report.scenes.fetch(:title), :title_work
  end

  # WHAT A SCENE INSISTS ON COMES BEFORE ITS MAP'S VIEW. Play insists on as big a routine as
  # its share holds, which leaves no room for the routine that brings its map along — so that
  # one runs from the cartridge, and the build never refuses what the author asked for because
  # of a routine the build picked.
  def test_what_a_scene_insists_on_goes_in_before_its_maps_view
    report = placement_of(play_insisting_beside_its_map(adds: most_play_can_insist_on))
    view = RubyGBA::Messages::MadeNames.make(:view_along_map, background: :ground)

    assert_includes report.scenes.fetch(:play), :play_work
    refute_includes report.scenes.fetch(:play), view, "the view needs more room than play has left"
  end

  # ...and they draw what the interpreter draws — the pool's thing, the map scrolled along —
  # frame by frame, through the swap into play and the swap back to the title.
  def test_play_scrolls_and_draws_its_pool_across_both_swaps
    program = two_screens_with_play_scenery(adds: BIG)
    [2, 4, 6, 8, 10, 12].each { |f| assert_backends_agree(program, frames: f) }
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
    report = placement_of(two_insisting_screens(adds: PLAY_INSISTS))

    assert_includes report.scenes.fetch(:play), :play_work
    assert(report.scenes.fetch(:files).any? { |name| name.to_s.start_with?("__save_file__") },
           "the file screen keeps its save routines: #{report.scenes[:files]}")
  end

  # A file screen whose record insists on its save routines, and a play screen whose own routine,
  # about +adds+ additions long, the build is free to place. The game plays a song, so the
  # routine that plays the music is worth the quick memory once the game is measured, and a list
  # of +pile+ words fills most of the room — the shape of a real game's build, where data takes
  # most of the quick memory and the game loop and the music want much of the rest.
  private def files_beside_growing_play(adds, pile: CROWDING_PILE)
    RubyGBA.game("GROWING") do
      enable_sound
      b = var :b, 0
      spin = var :spin, 0
      hearts = var :hearts, 3
      var :where, 0
      heap = list :heap, capacity: pile, fast: true
      files = save_data(:file, copies: 1, fast: true) { keep hearts }
      song(:tune) do
        tempo 240
        voice(:melody) { 8.times { note :C4, :eighth; note :E4, :eighth } }
        voice(:bass) { 8.times { note :C3, :quarter } }
      end
      play_song :tune
      func(:play_work) { adds.times { b.add! 1 } }
      scene(:files) { pressed(:a).then { files[0].save } }
      scene(:play) { call :play_work }
      game_loop do
        heap.push 1
        300.times { spin.add! 1 }
        pressed(:start).then { set! :where, 1 }
        case_var(:where) do
          when_val 0, :files
          when_val 1, :play
        end
      end
    end
  end

  # HOWEVER PLAY GROWS, THE FILE SCREEN KEEPS WHAT ITS RECORD INSISTED ON, in the build that
  # measured the game and in the one that did not.
  def test_play_growing_never_takes_the_file_screens_save_routines
    step = RubyGBA::Messages::MadeNames.make(:save_record, record: :file, piece: :step)
    [100, 1500, 3000].product([false, true]).each do |adds, profile|
      placement = files_beside_growing_play(adds).build_rom(out: StringIO.new, err: StringIO.new, profile: profile).built.placement
      kept = placement.funcs + placement.scenes.fetch(:files, [])

      assert_includes kept, step, "play at #{adds} additions, measured: #{profile}"
    end
  end

  # A SCREEN WITH NOTHING OF ITS OWN LEAVES WHAT IS IN, and power-on puts in the first set a
  # screen has. A game checks its saves as it opens, under its logos, and with nothing in the
  # quick memory then that check ran from the cartridge: a pass of a real game's opening ended
  # late, and the opening was a frame behind from there.
  def test_the_logos_run_with_the_file_screens_routines_already_in
    rom = assemble_rom(two_insisting_screens(adds: PLAY_INSISTS, logos: true), name: "LOGOS")
    sets = rom.built.scene_sets
    v = assert_emulator_loads_rom(rom, frames: 10)

    assert_equal 1, v.mem32(sets.loaded_at)[sets.scenes.fetch(:files)], "the file screen's set is in under the logos"
  end

  # ...whatever order the dispatch names the scenes in: the save's routines are what the game
  # loop runs under the logos, so theirs is the set that goes in first, not play's.
  def test_the_saves_set_goes_in_first_though_play_is_named_first
    rom = assemble_rom(two_insisting_screens(adds: PLAY_INSISTS, logos: true, play_first: true), name: "LOGOS")
    sets = rom.built.scene_sets
    v = assert_emulator_loads_rom(rom, frames: 10)

    assert_equal 1, v.mem32(sets.loaded_at)[sets.scenes.fetch(:files)], "the file screen's set is in under the logos"
  end

  # ...and the save those routines write from the file screen's room is the save the
  # interpreter writes, byte for byte.
  def test_a_save_written_from_the_file_screens_room_is_the_save
    program = two_insisting_screens(adds: PLAY_INSISTS)
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
