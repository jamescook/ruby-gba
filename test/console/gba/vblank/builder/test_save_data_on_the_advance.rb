# frozen_string_literal: true

require "test_helper"

# THE TESTS OF vblank/builder/test_save_data.rb THAT ONLY THE GAME BOY ADVANCE CAN PLAY, kept apart so that the
# Game Boy Color's run never loads them (test/console/gba); the rest are in that file.
# The Advance's cartridge playing these games in the emulator is in
# test/lowering/gba/vblank/builder/test_save_data_on_the_advance_cartridge.rb, and the power cut
# off part way through a save on flash, which only the interpreter can do, in
# test/interpreter/vblank/builder/test_save_data_on_the_advance_interpreter.rb.
#
# SAVE DATA: a record is a group of the game's own state — variables and lists — kept in the
# cartridge's save memory when the game says so, and put back when the game says so. Unlike a
# `save_var`, nothing is written until the game asks: a player who turns the console off
# without saving finds the game as it was when they last saved.
#
# The interpreter's save memory outlives the interpreter: handing the same store to a second
# run is turning the console off and on again.

# The games all three files play, and how they play them.
module SaveDataOnTheAdvanceGames
  include VBlank::Console::Hardware

  private def built(&block)
    builder = VBlank::Builder.new
    builder.instance_eval(&block)
    builder.finalize_program
    builder.program
  end

  private def play(program, store, pressing: {}, frames: 6)
    game_player(save: store).input_each_frame { |f| Array(pressing[f]) }.run(program, frames: frames)
  end

  # ON FLASH A SAVE WIPES BEFORE IT WRITES, and a wipe takes long enough for the power to go
  # off in the middle of it. A wiped block, or half of one, is only ever the older half of a
  # copy, so wherever the power goes off the copy holds the save before or the save after.
  # The save cut is the THIRD, so the half it wipes is one that held a save of its own.
  private def one_file_on_flash
    builder = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(save_memory: 64))
    builder.instance_eval do
      screen :tiled
      hearts = var :hearts, 3
      file = save_data(:file) { keep hearts }
      file[0].load
      game_loop do
        pressed(:a).then { hearts.set! 7; file[0].save }
        pressed(:b).then { hearts.set! 9; file[0].save }
        pressed(:l).then { hearts.set! 11; file[0].save }
      end
    end
    builder.finalize_program
    builder.program
  end

  # A RECORD KEEPS ITS PLACE WHEN THE GAME CHANGES AROUND IT. A game that ships and is then
  # updated — a setting added, the records declared in another order, a fourth file — must
  # find the player's saves where the last build left them. Only a record whose own contents
  # changed reads as empty.
  #
  # Each build below keeps :settings and :file; A saves 42 and 43 into files 0 and 1 and 7
  # into the settings. What each build finds is read without loading.
  private def version(settings: %i[speed], order: %i[settings file], copies: 2, extra: {})
    built do
      screen :tiled
      state = { speed: var(:speed, 1), volume: var(:volume, 5), hearts: var(:hearts, 3) }
      extra.each { |name, capacity| state[name] = list(name, capacity: capacity, width: :byte) }
      declare = {
        settings: -> { save_data(:settings) { keep(*settings.map { |name| state.fetch(name) }) } },
        file: -> { save_data(:file, copies: copies) { keep state[:hearts] } }
      }
      extra.each_key { |name| declare[name] = -> { save_data(name) { keep state.fetch(name) } } }
      records = order.to_h { |name| [name, declare.fetch(name).call] }
      files = records.fetch(:file)
      settings_record = records.fetch(:settings)
      shown = Array.new(4) { |n| var :"shown#{n}", -1 }
      kept_speed = var :kept_speed, -1
      game_loop do
        pressed(:a).then do
          state[:hearts].set! 42
          files[0].save
          state[:hearts].set! 43
          files[1].save if copies > 1
          state[:hearts].set! 44
          files[2].save if copies > 2
          state[:speed].set! 7
          settings_record[0].save
        end
        copies.times { |n| shown[n].set! files[n].peek(state[:hearts]) }
        kept_speed.set! settings_record[0].peek(state[:speed])
      end
    end
  end

  # A game that keeps a big journal in a record named +record+; A writes a page and saves it.
  # The journal takes most of save memory, so a record renamed in a later build can only go
  # where the old one was.
  private def journal_kept_as(record)
    built do
      screen :tiled
      speed = var :speed, 1
      journal = list :journal, capacity: 12_000, width: :byte
      save_data(:settings) { keep speed }
      pages = save_data(record) { keep journal }
      was_empty = var :was_empty, 0
      first_page = var :first_page, 0
      game_loop do
        pressed(:a).then do
          journal.push 9
          pages[0].save
        end
        pages[0].empty?.then { was_empty.set! 1 }
        first_page.set! pages[0].peek(journal)[0]
      end
    end
  end
end

class TestSaveDataOnTheAdvance < Minitest::Test
  include SaveDataOnTheAdvanceGames

  # A record that takes over another's room does not find that record's saves in it: here the
  # renamed record keeps the same things, so an old save left there would pass every check.
  def test_room_a_dropped_record_leaves_holds_nothing_for_the_next
    store = SaveImage.new
    play(journal_kept_as(:journal), store, pressing: { 2 => :a }, frames: 12)
    back = play(journal_kept_as(:diary), store)

    assert_equal [1, 0], [back[:was_empty], back[:first_page]]
  end

  # A record the game no longer declares keeps its place until the room is wanted, and then
  # gives it up: here the first build's journal takes most of save memory, and the second
  # build's atlas fits only in the room the journal leaves.
  def test_a_record_no_longer_declared_gives_its_room_to_a_new_one
    store = SaveImage.new
    play(version(order: %i[settings journal file], extra: { journal: 12_000 }), store, pressing: { 2 => :a }, frames: 12)
    back = play(version(order: %i[settings file atlas], extra: { atlas: 12_000 }), store)

    assert_equal [42, 43, 7], [back[:shown0], back[:shown1], back[:kept_speed]]
  end

  # Room that is free in two pieces, neither big enough on its own: the records that stay are
  # moved together to make one piece, and keep their saves.
  def test_records_are_moved_together_when_the_free_room_is_in_pieces
    store = SaveImage.new
    first = version(order: %i[settings north file south], extra: { north: 5000, south: 5000 })
    play(first, store, pressing: { 2 => :a }, frames: 12)
    back = play(version(order: %i[settings file atlas], extra: { atlas: 10_000 }), store)

    assert_equal [42, 43, 7], [back[:shown0], back[:shown1], back[:kept_speed]]
  end

  # Powered on with what the first build saved, the game finds the records the second build
  # declared in another order, and one that only fits once the others are slid together.
  def test_the_console_reorders_and_slides_records_the_way_the_interpreter_does
    first = version(order: %i[settings north file south], extra: { north: 5000, south: 5000 })
    shown = %i[shown0 shown1 kept_speed]
    [version(order: %i[file settings]),
     version(order: %i[settings file atlas], extra: { atlas: 10_000 })].each do |second|
      store = SaveImage.new
      play(first, store, pressing: { 2 => :a }, frames: 12)
      oracle = play(second, store)

      assert_equal [42, 43, 7], shown.map { |name| oracle[name] }
    end
  end
end
