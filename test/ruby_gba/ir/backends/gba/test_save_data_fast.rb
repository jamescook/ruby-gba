# frozen_string_literal: true

require "test_helper"
require "stringio"

# WHERE A RECORD'S SAVE ROUTINES RUN FROM, said by the game: `save_data :file, fast: true`.
#
# A build that measures its game puts in the console's quick memory the routines a real run
# spent its frames in. A run with nobody at the controls never saves, so the routines that
# save are measured at nothing and left in the cartridge — and the passes of a save then run
# at the cartridge's speed, which a game that counts its frames cannot have. Nothing measured
# can see that, so the game says it.
class TestSaveDataFast < Minitest::Test
  include EmulatorSupport

  MadeNames = RubyGBA::Messages::MadeNames

  def setup
    require_emulator!
  end

  # A game that saves a file when A is pressed, and loads it back on B. +fast+ is what it
  # says of the record, and nil is saying nothing.
  #
  # +asks+ is what else it asks of the record, each on a button of its own: :erase, :copy
  # and :reset. +saves+ is false for a game that only ever loads. +work+ is how many steps
  # of other work it does on every pass, for a game that uses most of each frame. +words+
  # are for the cartridge (`save_memory: 64`), and +save_vars+ is how many numbers it also
  # keeps with `save_var`.
  private def saving_game(fast: nil, asks: [], saves: true, work: 0, save_vars: 0, **words)
    said = fast.nil? ? {} : { fast: fast }
    RubyGBA.game("SAVEFAST", **words) do
      screen :bitmap
      hearts = var :hearts, 3
      spin = var :spin, 0
      written = var :written, 0
      best = Array.new(save_vars) { |n| save_var :"best#{n}", 0 }
      bag = list :bag, capacity: 1000, width: :byte, fast: false
      files = save_data(:file, copies: 2, **said) { keep hearts, bag }
      game_loop do
        pressed(:a).then { files[0].save } if saves
        pressed(:b).then { files[0].load }
        pressed(:l).then { files[1].erase } if asks.include?(:erase)
        pressed(:r).then { files.copy 0, to: 1 } if asks.include?(:copy)
        pressed(:select).then { files.reset } if asks.include?(:reset)
        files.finished?.then { written.add! 1 }
        best.each { |one| pressed(:start).then { one.add! 1 } }
        repeat(work) { spin.add! 1 } if work.positive?
        hearts.add! 1
      end
    end
  end

  private def routine(piece, record: :file) = MadeNames.make(:save_record, record: record, piece: piece)
  private def routines(*pieces) = pieces.map { |piece| routine(piece) }

  # The queue's own routines, which every record's writes go through.
  QUEUE = %i[tick step_running finish await_wipe pick_slot end].map { |piece| MadeNames.make(:save_jobs, piece: piece) }.freeze

  private def kept_in_quick_memory(game, profile:)
    game.build_rom(out: StringIO.new, err: StringIO.new, profile: profile).built.placement.funcs
  end

  # THE PREMISE: measured, and saying nothing, the routines that save stay in the cartridge.
  def test_a_measured_build_leaves_the_routines_that_save_in_the_cartridge
    kept = kept_in_quick_memory(saving_game, profile: true)

    assert_empty kept & routines(:save, :step, :scan, :load)
  end

  # THE WORD KEEPS WHAT EVERY PASS OF A SAVE RUNS: the routine that writes a piece of it, the
  # one that looks the copy over when the last piece is in, and the queue's small routines a
  # write goes through on the way.
  def test_a_record_that_says_fast_keeps_the_routines_every_pass_of_a_save_runs
    kept = kept_in_quick_memory(saving_game(fast: true), profile: true)

    assert_empty routines(:step, :scan) - kept, "the record's routines every pass of a save goes through"
    assert_empty QUEUE - kept, "and the queue's, which it goes through on the way"
  end

  # ...AND NOTHING ELSE. A job the game asks for — save, load, erase, copy, put back — runs once,
  # on the pass that asks for it, and is a small part of that pass, so it is left to the build
  # like any other routine. Kept, they came to more than twice what a save's passes need.
  def test_the_jobs_a_game_asks_for_are_left_to_the_build
    kept = kept_in_quick_memory(saving_game(fast: true, asks: %i[erase copy reset]), profile: true)

    assert_empty kept & routines(:save, :load, :erase, :copy, :reset)
  end

  # A game that only loads writes nothing, so nothing of what a write goes through is kept:
  # not the routine that writes a piece, not the one that looks a copy over, not the queue.
  def test_a_record_that_is_only_loaded_keeps_nothing_a_write_uses
    kept = kept_in_quick_memory(saving_game(fast: true, saves: false), profile: true)

    assert_empty kept & (routines(:save, :step, :scan, :load) + QUEUE)
  end

  # ONE RECORD'S WORD IS ABOUT THAT RECORD. A second record that says nothing is left to the
  # measurement, which here leaves its routines in the cartridge.
  def test_one_records_word_does_not_keep_another_records_routines
    game = RubyGBA.game("SAVETWO") do
      screen :bitmap
      hearts = var :hearts, 3
      volume = var :volume, 5
      files = save_data(:file, fast: true) { keep hearts }
      settings = save_data(:settings) { keep volume }
      game_loop do
        pressed(:a).then { files[0].save }
        pressed(:b).then { settings[0].save }
      end
    end
    kept = kept_in_quick_memory(game, profile: true)

    assert_includes kept, routine(:step)
    assert_empty kept & %i[save step scan].map { |piece| routine(piece, record: :settings) }
  end

  # WITHOUT MEASURING, the routines that save are kept by what the frame can reach. A game
  # that would sooner have that room for something else says so, and the queue goes with
  # them.
  def test_a_record_that_says_not_fast_keeps_them_out_where_the_shape_would_keep_them
    by_shape = kept_in_quick_memory(saving_game, profile: false)
    kept_out = kept_in_quick_memory(saving_game(fast: false), profile: false)

    assert_includes by_shape, routine(:step), "the shape of the program keeps the routine that writes a piece"
    assert_empty QUEUE - by_shape, "and the queue's routines"
    assert_empty kept_out & (routines(:save, :step, :scan, :load, :erase, :copy, :reset) + QUEUE)
  end

  # ...WHATEVER ELSE THE CARTRIDGE KEEPS. On flash the `save_var` numbers are kept in a
  # record of the framework's own, which has no word to say, and it does not speak for the
  # game's.
  def test_a_record_that_says_not_fast_keeps_the_queue_out_beside_a_save_var_on_flash
    by_shape = kept_in_quick_memory(saving_game(save_memory: 64, save_vars: 1), profile: false)
    kept_out = kept_in_quick_memory(saving_game(save_memory: 64, save_vars: 1, fast: false), profile: false)

    refute_empty QUEUE & by_shape, "saying nothing, the shape of the program keeps routines of the queue"
    assert_empty QUEUE & kept_out
  end

  # --- what it is for, measured on the console ---

  KEY_A = RubyGBA::Diagnostics::Verifier::KEY_A
  PRESSED_ON = 20
  WATCHED = 30

  # How much other work a pass does, for a game that uses most of each frame: enough that a
  # pass with no save in hand fits its frame with room to spare for a save at the quick
  # memory's speed, and not for one at the cartridge's. It is a number picked for the
  # cartridge the build makes today. A change to how a loop or a save is built can move it,
  # and then the two tests below say which half no longer holds.
  MOST_OF_A_FRAME = 14_000

  # A measured build of +game+, played to the frame before the press that saves.
  private def played_to_the_press(game)
    rom = game.build_rom(out: StringIO.new, err: StringIO.new, profile: true)
    pressing = ->(frame) { frame == PRESSED_ON ? KEY_A : 0 }
    RubyGBA::Diagnostics::Verifier.new(rom, frames: PRESSED_ON, keys: pressing, count_passes: true, vars: rom.var_addresses)
  end

  # The frames, counted from the press that saves, on which the game finished no pass: a
  # pass that did not fit its frame, so the game is a frame behind from there. And how many
  # saves were written in those frames, since a save that never happened loses no frame.
  private def frames_lost_to_a_save(game)
    reader = played_to_the_press(game)
    passed = reader.passes
    lost = (1..WATCHED).reject do
      finished = reader.step.passes - passed
      passed += finished
      finished.positive?
    end
    [lost, reader.var(:written)]
  end

  # THE SAVE COSTS A FRAME FROM THE CARTRIDGE AND NONE FROM THE QUICK MEMORY. The same game,
  # built the measuring way both times; the one thing that differs is the word.
  def test_a_save_loses_a_frame_without_the_word_and_none_with_it
    lost_without, written_without = frames_lost_to_a_save(saving_game(work: MOST_OF_A_FRAME))
    lost_with, written_with = frames_lost_to_a_save(saving_game(work: MOST_OF_A_FRAME, fast: true))

    assert_equal [1, 1], [written_without, written_with], "both wrote the save in the frames watched"
    refute_empty lost_without, "measured and saying nothing, the save runs from the cartridge and a pass runs over"
    assert_empty lost_with
  end

  def test_the_game_keeps_up_when_it_is_not_saving_with_the_word_or_without
    [nil, true].each do |fast|
      rom = saving_game(work: MOST_OF_A_FRAME, fast: fast).build_rom(out: StringIO.new, err: StringIO.new, profile: true)
      reader = RubyGBA::Diagnostics::Verifier.new(rom, frames: PRESSED_ON, count_passes: true)
      before = reader.passes

      assert_equal WATCHED, reader.step(WATCHED).passes - before, "a pass a frame, with no save in hand (fast: #{fast.inspect})"
    end
  end

  # --- what the build says when it cannot ---

  # A list that takes nearly all of the quick memory, so no save routine fits beside it.
  private def game_with_no_room(&saving)
    RubyGBA.game("SAVEFULL") do
      screen :bitmap
      hearts = var :hearts, 3
      hoard = list :hoard, capacity: 6800, fast: true
      files = save_data(:file, fast: true) { keep hearts }
      game_loop do
        hoard.push 1
        instance_exec(files, &saving)
      end
    end
  end

  def test_a_record_whose_routines_do_not_fit_says_which_record_and_what_to_do
    game = game_with_no_room { |files| pressed(:a).then { files[0].save } }
    error = assert_raises(GBA::LoweringError) { game.build_rom(out: StringIO.new, err: StringIO.new, profile: false) }

    assert_match(/save_data :file, fast: true/, error.message)
    assert_match(/quick memory/, error.message)
    assert_match(/remove `fast: true` from the record/, error.message)
  end

  # A game whose game loop is long and which plays a song, so the routine that plays the music
  # does enough to be worth the quick memory too. Its list leaves room there for those two or
  # for the record's save routines, and not for all of them. The lengths are picked for the
  # cartridge the build makes today: a change to how a loop or a save is built can move them,
  # and then the refusals below say so by finding room for all of them.
  #
  # A measured build first builds once without a measurement, and that build cannot tell the
  # music is worth the room, so only the game loop goes ahead of the save routines there.
  # CROWDING_LIST leaves too little room even for that build. CROWDING_THE_MUSIC leaves room
  # for that build and not for the measured one, where the music goes ahead too.
  CROWDING_LIST = 5200
  CROWDING_THE_MUSIC = 4350

  private def game_crowding_its_loop(fast, pile_size: CROWDING_LIST)
    said = fast.nil? ? {} : { fast: fast }
    RubyGBA.game("SAVELOOP") do
      screen :bitmap
      enable_sound
      hearts = var :hearts, 3
      spin = var :spin, 0
      pile = list :pile, capacity: pile_size, fast: true
      files = save_data(:file, copies: 2, **said) { keep hearts }
      song(:tune) do
        tempo 240
        voice(:melody) { 8.times { note :C4, :eighth; note :E4, :eighth } }
        voice(:bass) { 8.times { note :C3, :quarter } }
      end
      play_song :tune
      game_loop do
        pressed(:a).then { files[0].save }
        pile.push 1
        300.times { spin.add! 1 }
      end
    end
  end

  # THE GAME LOOP AND THE MUSIC GO IN AHEAD OF A RECORD'S WORD. Every frame runs them, and a
  # save is a few passes now and then; a game whose word put them in the cartridge ran every
  # frame at the cartridge's speed to save its passes the same. So where they do not all fit,
  # the build says so rather than choose.
  def test_a_record_whose_routines_would_put_the_game_loop_in_the_cartridge_is_refused
    by_measuring = kept_in_quick_memory(game_crowding_its_loop(nil), profile: true)
    error = assert_raises(GBA::LoweringError) { kept_in_quick_memory(game_crowding_its_loop(true), profile: true) }

    assert_empty %i[__frame __interrupt] - by_measuring, "saying nothing, the game loop and the music are kept"
    assert_match(/save_data :file, fast: true/, error.message)
    assert_match(/Every frame runs the game loop, so it goes in first/, error.message)
    assert_match(/remove `fast: true` from the record/, error.message)
  end

  def test_a_record_whose_routines_would_put_the_music_in_the_cartridge_is_refused
    game = game_crowding_its_loop(true, pile_size: CROWDING_THE_MUSIC)
    error = assert_raises(GBA::LoweringError) { kept_in_quick_memory(game, profile: true) }

    assert_match(/Every frame runs the game loop and the routine that plays the music/, error.message)
  end

  # Where there is room for all of them, all of them are kept.
  def test_a_record_with_room_beside_the_game_loop_and_the_music_keeps_all_three
    kept = kept_in_quick_memory(game_crowding_its_loop(true, pile_size: 1), profile: true)

    assert_empty %i[__frame __interrupt] - kept
    assert_empty routines(:step, :scan) - kept
  end

  def test_a_word_that_is_not_true_or_false_is_refused
    [1, "yes", :quick].each do |wrong|
      error = assert_raises(ArgumentError) { saving_game(fast: wrong).program }

      assert_match(/save_data :file/, error.message)
      assert_match(/fast:/, error.message)
      assert_includes error.message, wrong.inspect
    end
  end
end
