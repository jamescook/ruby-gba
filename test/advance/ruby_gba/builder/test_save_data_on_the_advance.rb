# frozen_string_literal: true

require "test_helper"

# THE TESTS OF ruby_gba/builder/test_save_data.rb THAT ONLY THE GAME BOY ADVANCE CAN PLAY, kept apart so that the
# Game Boy Color's run never loads them (TestSuites::ADVANCE_DIR); the rest are in that file.
#
# SAVE DATA: a record is a group of the game's own state — variables and lists — kept in the
# cartridge's save memory when the game says so, and put back when the game says so. Unlike a
# `save_var`, nothing is written until the game asks: a player who turns the console off
# without saving finds the game as it was when they last saved.
#
# The interpreter's save memory outlives the interpreter: handing the same store to a second
# run is turning the console off and on again.
class TestSaveDataOnTheAdvance < Minitest::Test
  include RubyGBA::Console::Hardware

  private def built(&block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.finalize_program
    builder.program
  end

  # A game with one save: A saves, B changes the hearts without saving, L loads. It loads
  # what is saved as it boots, and keeps whether the copy is good in a variable a test reads.
  private def one_save
    built do
      screen :tiled
      hearts = var :hearts, 3
      items = list :items, capacity: 4, width: :byte
      was_good = var :was_good, 0
      progress = save_data(:progress) { keep hearts, items }
      progress[0].good?.then { was_good.set! 1 }
      progress[0].load
      game_loop do
        pressed(:a).then do
          hearts.set! 7
          items.push 200
          progress[0].save
        end
        pressed(:b).then { hearts.set! 9 }
        pressed(:l).then { progress[0].load }
      end
    end
  end

  private def play(program, store, pressing: {}, frames: 6)
    game_player(save: store).input_each_frame { |f| Array(pressing[f]) }.run(program, frames: frames)
  end

  # THREE SAVE FILES, picked by a number the game works out. Each button does one thing to the
  # file `slot` names: A saves the hearts into it, B erases it, L loads it, R copies file 0
  # over it, SELECT starts a new game (the kept things back as they were declared), and UP
  # and DOWN move the slot. What each file holds is read without loading it.
  private def three_files
    built do
      screen :tiled
      hearts = var :hearts, 3
      name = list :name, capacity: 3, width: :byte
      slot = var :slot, 0
      files = save_data(:file, copies: 3) { keep hearts, name }
      shown = Array.new(3) { |n| var :"shown#{n}", 0 }
      states = Array.new(3) { |n| var :"state#{n}", 0 }
      stray = var :stray, 0
      game_loop do
        pressed(:up).then { slot.add! 1 }
        pressed(:down).then { slot.sub! 1 }
        pressed(:a).then do
          hearts.set! slot + 10
          name.push slot
          files[slot].save
        end
        pressed(:b).then { files[slot].erase }
        pressed(:l).then { files[slot].load }
        pressed(:r).then { files.copy 0, to: slot }
        pressed(:select).then { files.reset }
        pressed(:right).then do
          hearts.set! 99
          files[slot].save
        end
        3.times do |n|
          shown[n].set! files[n].peek(hearts)
          files[n].empty?.then { states[n].set! 0 }
          files[n].erased?.then { states[n].set! 1 }
          files[n].good?.then { states[n].set! 2 }
          files[n].damaged?.then { states[n].set! 3 }
        end
        files[slot + 5].good?.then { stray.set! 1 }
      end
    end
  end

  # Presses one frame apart, so each is its own press.
  private def presses(*buttons) = buttons.each_with_index.to_h { |button, i| [(i * 2) + 2, button] }

  private def files_after(store, *buttons)
    play(three_files, store, pressing: presses(*buttons), frames: (buttons.length * 2) + 4)
  end

  # ON FLASH A SAVE WIPES BEFORE IT WRITES, and a wipe takes long enough for the power to go
  # off in the middle of it. A wiped block, or half of one, is only ever the older half of a
  # copy, so wherever the power goes off the copy holds the save before or the save after.
  # The save cut is the THIRD, so the half it wipes is one that held a save of its own.
  private def one_file_on_flash
    builder = Builder.new(options: RubyGBA::Cartridge::Options.new(save_memory: 64))
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

  def test_a_save_on_flash_cut_off_at_any_point_keeps_the_last_good_one
    program = one_file_on_flash
    before = SaveImage.new(kilobytes: 64)
    game_player(save: before).input_each_frame { |f| { 2 => [:a], 60 => [:b] }.fetch(f, []) }.run(program, frames: 120)
    assert_equal 9, game_player(save: before.dup).run(program, frames: 2)[:hearts], "two saves went in"

    found = (0..80).map do |cut|
      store = before.dup
      game_player(save: store.cut_power_after(cut)).input_each_frame { |f| f == 2 ? [:l] : [] }
               .run(program, frames: 120)
      store.restore_power

      game_player(save: store).run(program, frames: 2)[:hearts].tap do |hearts|
        assert_includes [9, 11], hearts, "cut after #{cut} steps"
      end
    end
    assert_equal [9, 11], found.uniq.sort, "the cuts reach from before the save to after it"
  end

  # A FILE-SELECT SCREEN SHOWS EACH FILE'S NAME, which is a list: read it item by item from the
  # copy, with the game's own list left alone.
  private def names_peeked
    proc do
      screen :tiled
      # A full build refuses a tiled screen with nothing on it.
      image(:dot, "#" => :white) { "########\n" * 8 }
      sprite :dot, at: [0, 0]
      hearts = var :hearts, 3
      name = list :name, capacity: 3, width: :byte
      files = save_data(:file, copies: 3) { keep hearts, name }
      first = var :first, 0
      length = var :length, 0
      none = var :none, 0
      total = var :total, 0
      game_loop do
        total.set! (hearts * 2) + 1
        first.set! files[1].peek(name)[0]
        (first > 0).then { total.add! first }
        length.set! files[1].peek(name).length
        none.set! files[2].peek(name).length
        total.add! length + none
      end
    end
  end

  # THE RANDOM NUMBERS ARE PART OF A SAVE. A game that saves mid-level and loads again must
  # roll what it would have rolled from there — the guard that was going to miss still misses.
  # UP churns the numbers, A saves, B rolls into `rolled`, L loads. Rolled once after the save,
  # churned again, loaded, rolled again: the two rolls are the same number.
  private def rolling_after_a_load
    built do
      screen :tiled
      hearts = var :hearts, 3
      rolled = var :rolled, 0
      first = var :first, 0
      files = save_data(:file) { keep hearts, random_numbers }
      game_loop do
        pressed(:up).then { roll :churned, 1..1000 }
        pressed(:a).then { files[0].save }
        pressed(:b).then do
          rolled.set! rand(1..1000)
          (first == 0).then { first.set! rolled }
        end
        pressed(:l).then { files[0].load }
        pressed(:select).then { files.reset }
      end
    end
  end

  ROLLING = %i[up up up a b up up l b].freeze

  # A POOL IS PART OF A SAVE: every guard, where it was, how hurt, and which slots were free,
  # so a load puts the same guards back in the same slots and the next one spawned lands where
  # it would have. A spawns three and removes the middle one, then saves; B hurts them all,
  # spawns one and removes another; L loads; R spawns one more; SELECT starts a new game.
  # `signature` sums each live guard by its slot, so two pools read the same only when every
  # guard is in the same slot with the same numbers.
  private def guards_saved(keeping: :pool)
    built do
      screen :tiled
      guards = pool :guard, x: 0, hp: 0, capacity: 4
      signature = var :signature, 0
      files = save_data(:file)
      keeping == :pool ? files.keep(guards) : files.keep(guards.field(:hp))
      game_loop do
        pressed(:a).then do
          [[1, 5], [2, 6], [3, 7]].each { |x, hp| guards.spawn(x: x, hp: hp) }
          guards.each { |g| (g.x == 2).then { g.remove } }
          files[0].save
        end
        pressed(:b).then do
          guards.each { |g| g.hp.add! 10 }
          guards.spawn(x: 9, hp: 9)
          guards.each { |g| (g.x == 1).then { g.remove } }
        end
        pressed(:l).then { files[0].load }
        pressed(:r).then { guards.spawn(x: 4, hp: 8) }
        pressed(:select).then { files.reset }
        signature.set! 0
        guards.each { |g| signature.add!((g.index + 1) * ((g.x * 100) + g.hp)) }
      end
    end
  end

  private def guards_after(*buttons, keeping: :pool)
    play(guards_saved(keeping: keeping), SaveImage.new, pressing: presses(*buttons), frames: (buttons.length * 2) + 6)
  end

  private def guards_of(run) = [run.pool(:guard, :x), run.pool(:guard, :hp), run[:guard_count]]

  # A pool whose instances face and flap keeps which way each one faces: A faces the guard
  # left and saves, B faces it right, L loads — and it is drawn facing left again, in the same
  # picture as a game that never pressed B. The flap is slow enough not to step in the run,
  # since a load rightly puts the flap back where the save found it too.
  private def facing_guards
    built do
      screen :tiled
      %i[l1 l2 r1 r2].each { |pose| image(pose, "#" => :white) { "########\n" * 8 } }
      guards = pool :guard, x: 0, y: 0, capacity: 2, rate: 60, facing: { left: %i[l1 l2], right: %i[r1 r2] }
      files = save_data(:file)
      files.keep guards
      guards.spawn(x: 20, y: 20)
      game_loop do
        pressed(:a).then do
          guards.each { |g| g.face :left }
          files[0].save
        end
        pressed(:b).then { guards.each { |g| g.face :right } }
        pressed(:l).then { files[0].load }
      end
    end
  end

  # A FILE SCREEN DECLARED BEFORE THE GAMEPLAY IT SAVES. The record is declared with nothing in
  # it and used straight away — saved, loaded, erased, copied, peeked at by name — and what it
  # keeps is added later, by the code that owns it: the hearts and the name each by a routine
  # of its own, whose body is built after the screen's. The buttons are three_files' buttons,
  # so the two games are played the same way and must come out the same.
  private def file_screen_first
    built do
      screen :tiled
      files = save_data :file, copies: 3
      slot = var :slot, 0
      shown = Array.new(3) { |n| var :"shown#{n}", 0 }
      states = Array.new(3) { |n| var :"state#{n}", 0 }
      lengths = Array.new(3) { |n| var :"length#{n}", 0 }
      firsts = Array.new(3) { |n| var :"first#{n}", 0 }
      name = list :name, capacity: 3, width: :byte # a list is made where it is written
      game_loop do
        pressed(:up).then { slot.add! 1 }
        pressed(:down).then { slot.sub! 1 }
        pressed(:a).then do
          call :play
          files[slot].save
        end
        pressed(:b).then { files[slot].erase }
        pressed(:l).then { files[slot].load }
        pressed(:r).then { files.copy 0, to: slot }
        pressed(:select).then { files.reset }
        3.times do |n|
          shown[n].set! files[n].peek(:hearts)
          lengths[n].set! files[n].peek(:name).length
          firsts[n].set! files[n].peek(:name)[0]
          files[n].good?.then { states[n].set! 2 }
          files[n].erased?.then { states[n].set! 1 }
        end
      end
      func :play do
        hearts = var :hearts, 3
        files.keep hearts
        hearts.set! slot + 10
        call :name_it
      end
      func :name_it do
        files.keep name
        name.push slot
      end
    end
  end

  private def screen_first_after(store, *buttons)
    play(file_screen_first, store, pressing: presses(*buttons), frames: (buttons.length * 2) + 4)
  end

  # A WHOLE GAME'S PROGRESS: three files of 1204 bytes each — a thousand and more flags packed
  # into a list — beside a small settings record of its own. A saves file 2 and the settings,
  # B scrambles the flags, L loads file 2 back.
  private def full_size
    built do
      screen :tiled
      flags = list :flags, capacity: 1196, width: :byte
      hearts = var :hearts, 3
      speed = var :speed, 1
      files = save_data(:file, copies: 3) { keep hearts, flags }
      settings = save_data(:settings) { keep speed }
      checked = var :checked, 0
      settings[0].load
      game_loop do
        pressed(:a).then do
          repeat(1196) { |i| flags.push i & 0x7F }
          hearts.set! 20
          speed.set! 3
          files[2].save
          settings[0].save
        end
        pressed(:b).then { repeat(1196) { |i| flags[i] = 0 } }
        pressed(:l).then do
          files[2].load
          checked.set! flags[1195] + flags[5] + hearts
        end
      end
    end
  end

  # A SAVE RUNS IN THE BACKGROUND. A full-size file is written a piece at a time over several
  # passes of the game loop, so the game never stands still for it, and `saving?` holds from
  # the moment it is asked for until the last piece is in. A copy made good at power-on shows
  # the save arrived whole.
  private def a_big_save
    built do
      screen :bitmap
      flags = list :flags, capacity: 1196, width: :byte
      files = save_data(:file) { keep flags }
      was_good = var :was_good, 0
      saving_passes = var :saving_passes, 0
      files[0].good?.then { was_good.set! 1 }
      files[0].load
      game_loop do
        pressed(:a).then do
          repeat(1196) { |i| flags.push i & 0x7F }
          files[0].save
        end
        files.saving?.then { saving_passes.add! 1 }
      end
    end
  end

  # THE SAVE HOLDS THE MOMENT IT WAS ASKED FOR. The game goes on while a big save is written,
  # and what it changes on the passes after — hearts down, a flag cleared — is not in the save.
  private def changes_while_saving
    built do
      screen :bitmap
      flags = list :flags, capacity: 1196, width: :byte
      hearts = var :hearts, 3
      files = save_data(:file) { keep hearts, flags }
      files[0].load
      game_loop do
        pressed(:a).then do
          repeat(1196) { |i| flags.push 5 }
          hearts.set! 12
          files[0].save
        end
        files.saving?.then do
          hearts.sub! 1
          flags[1195] = 0
        end
      end
    end
  end

  # WHAT A SAVE ASKED FOR WHILE ANOTHER IS IN HAND DOES, which the record says with `when_busy:`.
  # A saves 10 and then 20 into the same copy, in one pass, and counts the passes `saving?` held.
  private def two_saves(when_busy)
    built do
      screen :bitmap
      flags = list :flags, capacity: 1196, width: :byte
      hearts = var :hearts, 3
      files = save_data(:file, when_busy: when_busy) { keep hearts, flags }
      saving_passes = var :saving_passes, 0
      refused = var :refused, 0
      files[0].load
      game_loop do
        pressed(:a).then do
          hearts.set! 10
          files[0].save
          hearts.set! 20
          files[0].save
          files.failed?.then { refused.set! 1 }
        end
        files.saving?.then { saving_passes.add! 1 }
      end
    end
  end

  private def after_two_saves(when_busy)
    store = SaveImage.new
    run = play(two_saves(when_busy), store, pressing: { 2 => :a }, frames: 30)
    [run, play(two_saves(when_busy), store, frames: 2)]
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

  private def saved_by_the_first_build
    SaveImage.new.tap { |store| play(version, store, pressing: { 2 => :a }, frames: 12) }
  end

  # A record that takes over another's room does not find that record's saves in it: here the
  # renamed record keeps the same things, so an old save left there would pass every check.
  def test_room_a_dropped_record_leaves_holds_nothing_for_the_next
    store = SaveImage.new
    play(journal_kept_as(:journal), store, pressing: { 2 => :a }, frames: 12)
    back = play(journal_kept_as(:diary), store)

    assert_equal [1, 0], [back[:was_empty], back[:first_page]]
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

  # The console, powered on with what the first build saved, finds the records the second build
  # declared in another order, and one that only fits once the others are slid together — and
  # leaves save memory byte for byte as the interpreter does. Sliding records together is the
  # slow one: the console takes eight frames over it at power-on, once, and clearing the
  # bigger record's buffers a few more, so the run is given sixteen.
  def test_the_console_reorders_and_slides_records_the_way_the_interpreter_does
    first = version(order: %i[settings north file south], extra: { north: 5000, south: 5000 })
    [version(order: %i[file settings]),
     version(order: %i[settings file atlas], extra: { atlas: 10_000 })].each_with_index do |second, n|
      store = SaveImage.new
      play(first, store, pressing: { 2 => :a }, frames: 12)
      before = store.dup
      oracle = play(second, store)
      rom = assemble_rom(second, name: "SLIDE#{n}")
      v = assert_emulator_loads_rom(rom, frames: 16, save: before, vars: rom.var_addresses)
      shown = %i[shown0 shown1 kept_speed]

      assert_equal [42, 43, 7], shown.map { |name| v.var(name) }
      assert_equal shown.map { |name| oracle[name] }, shown.map { |name| v.var(name) }
      written = store.written.keys.sort
      assert_equal written.map { |at| store.read(at, 1) }, written.map { |at| v.mem8(SRAM_START + at) }
    end
  end

  # A RECORD NAMED LIKE THE FRAMEWORK'S OWN SAVE MACHINERY — the table saying where each
  # record lives (:table, and the :places it works them out in) and the queue that writes
  # saves a piece at a time (:jobs) — is a record like any other. Each keeps a number of its
  # own, with a plain record before and after them, and every one has to come back holding
  # its own number after the power goes off.
  NAMED_LIKE_THE_FRAMEWORK = %i[first places jobs table last].freeze

  private def records_named_like_the_framework
    built do
      screen :tiled
      records = NAMED_LIKE_THE_FRAMEWORK.each_with_index.map do |name, n|
        kept = var :"kept_#{name}", 0
        [kept, save_data(name) { keep kept }, 10 + n]
      end
      records.each { |_kept, record, _number| record[0].load }
      game_loop do
        pressed(:a).then do
          records.each do |kept, record, number|
            kept.set! number
            record[0].save
          end
        end
      end
    end
  end

  # --- what a save puts in save memory, byte by byte ---
  #
  # Everything above asks the game whether its saves came back. These read save memory itself,
  # because what keeps a save safe is WHERE each part goes and in WHAT ORDER it is written, and
  # a mistake in either can still read back right until the power goes off at the wrong moment.

  Layout = RubyGBA::IR::SaveLayout

  # A record of a variable and a list of half-words, saved with A.
  private def header_and_body
    built do
      screen :tiled
      hearts = var :hearts, 0
      items = list :items, capacity: 3, width: :half
      file = save_data(:file) { keep hearts, items }
      game_loop do
        pressed(:a).then do
          hearts.set! 7
          items.push 300
          items.push(-2)
          file[0].save
        end
      end
    end
  end

  # The body is a word for the hearts, then the list: its length in a word and three half-word
  # slots — 4 + 4 + 6 bytes.
  HEADER_AND_BODY_BODY = 14

  # Where the first half holding a marker starts, at or after +from+.
  private def half_with_marker(store, from)
    (from...(Layout::START + Layout::SIZE)).step(4).find { |at| store.word(at) == Layout::MARKER } or
      flunk("no half with the marker after #{from}")
  end

  # --- friendly errors ---

  private def refused(&block)
    assert_raises(ArgumentError) { built { screen :tiled; instance_eval(&block) } }.message
  end

end
