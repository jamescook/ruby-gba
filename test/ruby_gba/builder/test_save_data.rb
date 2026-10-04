# frozen_string_literal: true

require "test_helper"

# SAVE DATA: a record is a group of the game's own state — variables and lists — kept in the
# cartridge's save memory when the game says so, and put back when the game says so. Unlike a
# `save_var`, nothing is written until the game asks: a player who turns the console off
# without saving finds the game as it was when they last saved.
#
# The interpreter's save memory outlives the interpreter: handing the same store to a second
# run is turning the console off and on again.
class TestSaveData < Minitest::Test
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
    Reference.new(save: store).input_each_frame { |f| Array(pressing[f]) }.run(program, frames: frames)
  end

  def test_a_saved_record_comes_back_after_the_power_goes_off
    store = SaveImage.new
    play(one_save, store, pressing: { 2 => :a })
    back = play(one_save, store)

    assert_equal 7, back[:hearts]
    assert_equal [-56], back.list(:items), "a byte slot reads 200 back the way the console does"
    assert_equal 1, back[:was_good]
  end

  def test_nothing_is_kept_until_the_game_saves
    store = SaveImage.new
    play(one_save, store, pressing: { 2 => :b })
    back = play(one_save, store)

    assert_equal 3, back[:hearts], "the change was never saved"
    assert_equal 0, back[:was_good], "a copy nothing ever saved is not good"
  end

  def test_a_change_after_saving_is_not_kept
    store = SaveImage.new
    play(one_save, store, pressing: { 2 => :a, 4 => :b })
    assert_equal 7, play(one_save, store)[:hearts]
  end

  def test_loading_puts_back_what_was_saved
    run = play(one_save, SaveImage.new, pressing: { 2 => :a, 3 => :b, 4 => :l })
    assert_equal 7, run[:hearts]
  end

  # The console, in one run: save, change the hearts, load them back — and the interpreter
  # given the same presses agrees.
  def test_the_console_saves_and_loads_the_same_way
    presses = { 2 => KEY_A }
    rom = assemble_rom(one_save, name: "RECORD")
    v = assert_emulator_loads_rom(rom, frames: 3, keys: ->(f) { presses.fetch(f, 0) }, vars: rom.var_addresses)
    assert_equal 7, v.var(:hearts), "saved"
    v.step(2, keys: KEY_B)
    v.step(2)
    assert_equal 9, v.var(:hearts), "changed without saving"
    v.step(2, keys: KEY_L)
    v.step(2)
    assert_equal 7, v.var(:hearts), "loaded back"
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

  def test_each_copy_keeps_its_own_save_and_can_be_read_without_loading
    store = SaveImage.new
    files_after(store, :a, :up, :a, :up, :a)
    back = files_after(store)

    assert_equal [10, 11, 12], (0..2).map { |n| back[:"shown#{n}"] }
    assert_equal [2, 2, 2], (0..2).map { |n| back[:"state#{n}"] }
    assert_equal 3, back[:hearts], "reading a copy does not load it"
  end

  def test_loading_a_copy_picked_by_a_worked_out_number
    store = SaveImage.new
    files_after(store, :a, :up, :a)
    back = files_after(store, :up, :l)

    assert_equal 11, back[:hearts]
    assert_equal [0, 1], back.list(:name), "the list comes back as it was saved"
  end

  def test_an_erased_copy_says_so_and_loads_nothing
    store = SaveImage.new
    files_after(store, :a, :up, :a, :b)
    back = files_after(store, :up, :l)

    assert_equal [2, 1, 0], (0..2).map { |n| back[:"state#{n}"] }, "good, erased, never saved"
    assert_equal 3, back[:hearts], "an erased copy loads nothing"
  end

  def test_one_copy_can_be_copied_over_another
    store = SaveImage.new
    files_after(store, :a, :up, :up, :r)
    back = files_after(store)

    assert_equal [10, 0, 10], (0..2).map { |n| back[:"shown#{n}"] }
  end

  def test_reset_puts_the_kept_things_back_as_they_were_declared
    run = files_after(SaveImage.new, :a, :select)

    assert_equal 3, run[:hearts]
    assert_empty run.list(:name)
  end

  def test_a_copy_number_the_record_does_not_have_does_nothing
    store = SaveImage.new
    files_after(store, :down, :a)
    back = files_after(store)

    assert_equal [0, 0, 0], (0..2).map { |n| back[:"state#{n}"] }, "copy -1 is none of them"
    assert_equal 0, back[:stray]
  end

  # THE POWER GOING OFF IN THE MIDDLE OF A SAVE. The copy that was being written keeps its last
  # good save, and a copy that had none is damaged; the other copies are not touched.
  # RIGHT saves 99 over copy 0, which holds 10. The power goes off after each number of bytes
  # that save can write, in turn: at every one, copy 0 is either the old save or the new one —
  # never damaged, never a mixture — and copy 1 is untouched.
  def test_a_save_cut_off_at_any_point_keeps_the_last_good_one
    before = SaveImage.new
    files_after(before, :a, :up, :a)
    whole = before.dup
    Reference.new(save: whole).input_each_frame { |f| f == 2 ? [:right] : [] }.run(three_files, frames: 4)
    assert_equal 99, files_after(whole)[:shown0], "uncut, the new save is the copy"

    (0..40).each do |cut|
      store = before.dup
      Reference.new(save: store.cut_power_after(cut))
               .input_each_frame { |f| f == 2 ? [:right] : [] }.run(three_files, frames: 4)
      back = files_after(store)

      assert_equal [2, 2], [back[:state0], back[:state1]], "cut after #{cut} bytes"
      assert_includes [10, 99], back[:shown0], "cut after #{cut} bytes"
      assert_equal 11, back[:shown1], "cut after #{cut} bytes"
    end
  end

  # Cut after the header's first two words and four bytes of the body.
  def test_a_first_save_cut_off_half_way_is_damaged
    store = SaveImage.new
    files_after(store, :up, :up, :a)
    Reference.new(save: store.cut_power_after(12))
             .input_each_frame { |f| f == 2 ? [:a] : [] }.run(three_files, frames: 4)
    back = files_after(store)

    assert_equal [3, 0, 2], (0..2).map { |n| back[:"state#{n}"] }
  end

  def test_the_console_keeps_three_copies_the_way_the_interpreter_does
    buttons = %i[a up a up a down b up r select]
    store = SaveImage.new
    oracle = files_after(store, *buttons)
    keys = { a: KEY_A, b: KEY_B, up: KEY_UP, down: KEY_DOWN, r: KEY_R, select: KEY_SELECT }
    schedule = presses(*buttons).transform_values { |button| keys.fetch(button) }
    rom = assemble_rom(three_files, name: "FILES3")
    v = assert_emulator_loads_rom(rom, frames: (buttons.length * 2) + 8, keys: ->(f) { schedule.fetch(f, 0) },
                                       vars: rom.var_addresses)

    %i[shown0 shown1 shown2 state0 state1 state2 hearts].each do |name|
      assert_equal oracle[name], v.var(name), name.to_s
    end
    written = store.written.keys.sort
    assert_equal written.map { |at| store.read(at, 1) }, written.map { |at| v.mem8(SRAM_START + at) }
  end

  # A FILE-SELECT SCREEN SHOWS EACH FILE'S NAME, which is a list: read it item by item from the
  # copy, with the game's own list left alone.
  def test_a_kept_list_can_be_read_from_a_copy_without_loading_it
    store = SaveImage.new
    files_after(store, :up, :a) # copy 1 holds the name [1]
    program = built do
      screen :tiled
      hearts = var :hearts, 3
      name = list :name, capacity: 3, width: :byte
      files = save_data(:file, copies: 3) { keep hearts, name }
      first = var :first, 0
      length = var :length, 0
      none = var :none, 0
      game_loop do
        first.set! files[1].peek(name)[0]
        length.set! files[1].peek(name).length
        none.set! files[2].peek(name).length
      end
    end
    run = play(program, store)

    assert_equal [1, 1, 0], [run[:first], run[:length], run[:none]]
    assert_empty run.list(:name)
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

  def test_a_load_puts_the_random_numbers_back_on_both_backends
    oracle = play(rolling_after_a_load, SaveImage.new, pressing: presses(*ROLLING), frames: (ROLLING.length * 2) + 4)
    refute_equal 0, oracle[:first]
    assert_equal oracle[:first], oracle[:rolled], "the roll after the load is the roll after the save"

    keys = { a: KEY_A, b: KEY_B, up: KEY_UP, l: KEY_L }
    schedule = presses(*ROLLING).transform_values { |button| keys.fetch(button) }
    rom = assemble_rom(rolling_after_a_load, name: "ROLLBACK")
    v = assert_emulator_loads_rom(rom, frames: (ROLLING.length * 2) + 8, keys: ->(f) { schedule.fetch(f, 0) },
                                       vars: rom.var_addresses)
    assert_equal [oracle[:first], oracle[:rolled]], [v.var(:first), v.var(:rolled)]
  end

  # A new game is not a replay: putting the kept things back leaves the numbers rolling on.
  def test_a_reset_leaves_the_random_numbers_rolling_on
    run = play(rolling_after_a_load, SaveImage.new, pressing: presses(:b, :select, :b), frames: 10)
    refute_equal run[:first], run[:rolled]
  end

  def test_keeping_the_random_numbers_in_two_records_is_a_friendly_error
    message = refused do
      save_data(:f) { keep random_numbers }
      save_data(:g) { keep random_numbers }
    end
    assert_match(/save_data :g keeps the random numbers, and save_data :f keeps them too/, message)
  end

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

  def test_a_load_puts_a_pool_back_slot_for_slot
    undisturbed = guards_after(:a, :r)
    loaded = guards_after(:a, :b, :l, :r)

    assert_equal undisturbed.pool(:guard, :x), loaded.pool(:guard, :x)
    assert_equal undisturbed.pool(:guard, :hp), loaded.pool(:guard, :hp)
    assert_equal 3, loaded.pool(:guard, :x).compact.length
    assert_equal undisturbed[:signature], loaded[:signature]
  end

  def test_the_console_puts_a_pool_back_the_way_the_interpreter_does
    buttons = %i[a b l r]
    oracle = guards_after(*buttons)
    keys = { a: KEY_A, b: KEY_B, l: KEY_L, r: KEY_R }
    schedule = presses(*buttons).transform_values { |button| keys.fetch(button) }
    rom = assemble_rom(guards_saved, name: "GUARDS")
    v = assert_emulator_loads_rom(rom, frames: (buttons.length * 2) + 10, keys: ->(f) { schedule.fetch(f, 0) },
                                       vars: rom.var_addresses)
    assert_equal oracle[:signature], v.var(:signature)
  end

  # A new game empties the pool, and the pool still works afterwards.
  def test_a_reset_empties_a_kept_pool_and_it_still_spawns
    run = guards_after(:a, :select, :r)
    assert_equal [4], run.pool(:guard, :x).compact
    assert_equal [8], run.pool(:guard, :hp).compact
  end

  # One field kept on its own comes back; the rest of the pool is left as the game has it.
  def test_one_field_of_a_pool_can_be_kept_on_its_own
    run = guards_after(:a, :b, :l, keeping: :field)
    hurt_again = guards_after(:a, :b, keeping: :field)

    assert_equal hurt_again.pool(:guard, :x), run.pool(:guard, :x), "where they stand is not kept"
    saved_hp = guards_after(:a, keeping: :field).pool(:guard, :hp)
    live = run.pool(:guard, :x).each_index.select { |slot| saved_hp[slot] && run.pool(:guard, :x)[slot] }
    assert_equal live.map { |slot| saved_hp[slot] }, live.map { |slot| run.pool(:guard, :hp)[slot] }
  end

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

  def test_a_load_puts_back_which_way_each_pooled_thing_faces
    undisturbed = play(facing_guards, SaveImage.new, pressing: presses(:a), frames: 11)
    loaded = play(facing_guards, SaveImage.new, pressing: presses(:a, :b, :l), frames: 11)

    assert_equal undisturbed.sprites(:guard).map(&:picture), loaded.sprites(:guard).map(&:picture)
    assert_equal :l1, loaded.sprites(:guard).first.picture
  end

  def test_a_pool_kept_twice_is_a_friendly_error
    message = refused { g = pool :guard, hp: 0, capacity: 4; save_data(:f).keep(g); save_data(:h).keep(g) }
    assert_match(/save_data :h keeps pool :guard, and save_data :f keeps it too/, message)

    message = refused { g = pool :guard, hp: 0, capacity: 4; save_data(:f).keep(g); save_data(:h).keep(g.field(:hp)) }
    assert_match(/save_data :h keeps field :hp of pool :guard, and save_data :f keeps it too/, message)
  end

  def test_a_field_a_pool_does_not_have_is_a_friendly_error
    message = refused { g = pool :guard, hp: 0, capacity: 4; save_data(:f).keep(g.field(:armour)) }
    assert_match(/pool :guard has no field :armour/, message)
    assert_match(/It has :hp/, message)
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

  def test_a_record_declared_before_what_it_keeps_saves_loads_and_peeks
    store = SaveImage.new
    screen_first_after(store, :a, :up, :a)
    back = screen_first_after(store)

    assert_equal [10, 11, 0], (0..2).map { |n| back[:"shown#{n}"] }
    assert_equal [1, 2, 0], (0..2).map { |n| back[:"length#{n}"] }
    assert_equal [0, 0, 0], (0..2).map { |n| back[:"first#{n}"] }
    assert_equal [2, 2, 0], (0..2).map { |n| back[:"state#{n}"] }

    loaded = screen_first_after(store, :up, :l)
    assert_equal 11, loaded[:hearts]
    assert_equal [0, 1], loaded.list(:name)
  end

  def test_a_record_declared_before_what_it_keeps_erases_copies_and_resets
    store = SaveImage.new
    screen_first_after(store, :a, :up, :up, :r, :down, :b)
    back = screen_first_after(store)

    assert_equal [10, 0, 10], (0..2).map { |n| back[:"shown#{n}"] }
    assert_equal [2, 1, 2], (0..2).map { |n| back[:"state#{n}"] }
    assert_equal 3, screen_first_after(SaveImage.new, :a, :select)[:hearts]
  end

  # Keeping the same things in the same order, a record filled in later is the same record as
  # one written with a block — so saves made by either build load in the other.
  def test_a_record_filled_in_later_reads_saves_the_block_form_made
    store = SaveImage.new
    files_after(store, :a, :up, :a)
    back = screen_first_after(store)

    assert_equal [10, 11, 0], (0..2).map { |n| back[:"shown#{n}"] }
  end

  def test_the_console_runs_a_record_declared_before_what_it_keeps
    buttons = %i[a up a up up r down b]
    oracle = screen_first_after(SaveImage.new, *buttons)
    keys = { a: KEY_A, b: KEY_B, up: KEY_UP, down: KEY_DOWN, r: KEY_R }
    schedule = presses(*buttons).transform_values { |button| keys.fetch(button) }
    rom = assemble_rom(file_screen_first, name: "FILESFIRST")
    v = assert_emulator_loads_rom(rom, frames: (buttons.length * 2) + 8, keys: ->(f) { schedule.fetch(f, 0) },
                                       vars: rom.var_addresses)

    %i[shown0 shown1 shown2 state0 state1 state2 length0 length1 length2 first1 hearts].each do |name|
      assert_equal oracle[name], v.var(name), name.to_s
    end
  end

  # A SAVE SAYS WHETHER IT WORKED. `saving?` holds from the moment one is asked for until it is
  # written, and then `failed?` holds when what was written did not read back.
  def test_a_save_says_it_worked
    run = files_after(SaveImage.new, :a)
    outcome = built do
      screen :tiled
      hearts = var :hearts, 3
      files = save_data(:file) { keep hearts }
      worked = var :worked, 0
      busy_at_first = var :busy_at_first, 0
      busy = var :busy, 0
      files[0].save
      files.saving?.then { busy_at_first.set! 1 }
      game_loop do
        files.saving?.then { busy.set! 1 }.else { busy.set! 0 }
        files.failed?.then { worked.set! 2 }.else { worked.set! 1 }
      end
    end
    after = play(outcome, SaveImage.new)

    assert_equal [1, 0, 1], [after[:busy_at_first], after[:busy], after[:worked]]
    assert_equal 10, run[:hearts]
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

  def test_three_full_size_files_and_settings_on_both_backends
    store = SaveImage.new
    play(full_size, store, pressing: { 2 => :a, 4 => :b, 6 => :l }, frames: 16)
    back = play(full_size, store, pressing: { 2 => :l }, frames: 4)
    assert_equal 3, back[:speed], "the settings record is kept apart from the files"
    assert_equal (1195 & 0x7F) + 5 + 20, back[:checked]

    # Three files' buffers are filled as the console starts, so it is given a few frames first.
    schedule = { 4 => KEY_A, 6 => KEY_B, 8 => KEY_L }
    rom = assemble_rom(full_size, name: "FULLSIZE")
    v = assert_emulator_loads_rom(rom, frames: 14, keys: ->(f) { schedule.fetch(f, 0) }, vars: rom.var_addresses)
    assert_equal (1195 & 0x7F) + 5 + 20, v.var(:checked)
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

  def test_a_big_save_runs_over_several_passes_while_the_game_goes_on
    store = SaveImage.new
    run = play(a_big_save, store, pressing: { 2 => :a }, frames: 30)
    assert_includes 3..10, run[:saving_passes], "the save spreads over a handful of passes"

    back = play(a_big_save, store, frames: 2)
    assert_equal 1, back[:was_good], "and arrives whole"
    assert_equal [1195 & 0x7F, 1196], [back.list(:flags).last, back.list(:flags).length]
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

  def test_a_save_holds_the_moment_it_was_asked_for
    store = SaveImage.new
    run = play(changes_while_saving, store, pressing: { 2 => :a }, frames: 20)
    assert_operator run[:hearts], :<, 12, "the game went on changing things while it saved"

    back = play(changes_while_saving, store, frames: 2)
    assert_equal [12, 5], [back[:hearts], back.list(:flags).last]
  end

  # READING A COPY FINISHES ITS SAVE FIRST. A peek on the line after a save — a file screen
  # shown straight after saving — reads what was just saved, not what was there before.
  def test_reading_a_copy_straight_after_saving_it_reads_the_save
    program = built do
      screen :bitmap
      flags = list :flags, capacity: 1196, width: :byte
      hearts = var :hearts, 3
      files = save_data(:file) { keep hearts, flags }
      seen = var :seen, 0
      game_loop do
        pressed(:a).then do
          hearts.set! 12
          files[0].save
          seen.set! files[0].peek(hearts)
        end
      end
    end
    assert_equal 12, play(program, SaveImage.new, pressing: { 2 => :a })[:seen]
  end

  # THE POWER GOING OFF BETWEEN TWO PASSES OF A SAVE. A big save of 99 over a good save of 12
  # is cut after every so many bytes, across the passes it is written over: each time, the next
  # power-on finds the copy either as it was or as it was saved — never damaged, never a mix.
  def test_a_save_cut_off_between_passes_keeps_the_last_good_one
    before = SaveImage.new
    play(changes_while_saving, before, pressing: { 2 => :a }, frames: 20)
    resave = built do
      screen :bitmap
      flags = list :flags, capacity: 1196, width: :byte
      hearts = var :hearts, 3
      files = save_data(:file) { keep hearts, flags }
      files[0].load
      game_loop do
        pressed(:a).then do
          hearts.set! 99
          files[0].save
        end
      end
    end
    (0..1300).step(37) do |cut|
      store = before.dup
      Reference.new(save: store.cut_power_after(cut))
               .input_each_frame { |f| f == 2 ? [:a] : [] }.run(resave, frames: 20)
      back = play(changes_while_saving, store, frames: 2)

      assert_includes [12, 99], back[:hearts], "cut after #{cut} bytes"
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

  def test_a_second_save_waits_its_turn_by_default
    run, back = after_two_saves(:wait)
    assert_equal [20, 0], [back[:hearts], run[:refused]]
  end

  def test_a_newer_save_can_replace_the_one_not_yet_written
    waited, = after_two_saves(:wait)
    run, back = after_two_saves(:replace)
    assert_equal 20, back[:hearts]
    assert_operator run[:saving_passes], :<, waited[:saving_passes], "only one save was written"
  end

  # `finished?` holds for the one pass after a job of the record is written — once a save, so a
  # game can show "Saved!" on it — and never while one is still being written.
  def test_a_record_says_on_one_pass_that_its_save_just_finished
    program = built do
      screen :bitmap
      flags = list :flags, capacity: 1196, width: :byte
      files = save_data(:file) { keep flags }
      finished_passes = var :finished_passes, 0
      overlap = var :overlap, 0
      game_loop do
        pressed(:a).then { files[0].save }
        pressed(:b).then do
          files[0].save
          files[0].erase
        end
        files.finished?.then { finished_passes.add! 1 }
        (files.finished? & files.saving?).then { overlap.set! 1 }
      end
    end
    once = play(program, SaveImage.new, pressing: { 2 => :a }, frames: 20)
    twice = play(program, SaveImage.new, pressing: { 2 => :b }, frames: 30)

    assert_equal [1, 0], [once[:finished_passes], once[:overlap]]
    assert_equal 2, twice[:finished_passes], "each of two jobs says so when it is written"
  end

  def test_a_save_asked_for_while_busy_can_be_refused
    run, back = after_two_saves(:refuse)
    assert_equal [10, 1], [back[:hearts], run[:refused]]
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

  def test_a_record_keeps_its_saves_when_one_declared_before_it_grows
    back = play(version(settings: %i[speed volume]), saved_by_the_first_build)

    assert_equal [42, 43], [back[:shown0], back[:shown1]], "the files are where they were"
    assert_equal 0, back[:kept_speed], "the settings changed, so their old save reads as empty"
  end

  def test_records_declared_in_another_order_keep_their_saves
    back = play(version(order: %i[file settings]), saved_by_the_first_build)

    assert_equal [42, 43, 7], [back[:shown0], back[:shown1], back[:kept_speed]]
  end

  def test_a_record_given_more_copies_keeps_the_ones_it_had
    back = play(version(copies: 4), saved_by_the_first_build)

    assert_equal [42, 43, 0, 0], (0..3).map { |n| back[:"shown#{n}"] }
    assert_equal 7, back[:kept_speed]
  end

  def test_a_record_given_fewer_copies_keeps_the_ones_that_are_left
    back = play(version(copies: 1), saved_by_the_first_build)

    assert_equal [42, 7], [back[:shown0], back[:kept_speed]]
  end

  # A copy one build dropped is gone: a later build that has that copy again finds it empty,
  # not holding what was saved there before it was dropped.
  def test_a_copy_given_back_after_it_was_dropped_is_empty
    store = SaveImage.new
    play(version(copies: 3), store, pressing: { 2 => :a }, frames: 12)
    play(version(copies: 2), store)
    back = play(version(copies: 3), store)

    assert_equal [42, 43, 0], [back[:shown0], back[:shown1], back[:shown2]]
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

  # The power going off while the new build moves the files into their bigger place: at every
  # point, the next power-on still finds both files.
  def test_moving_a_record_cut_off_at_any_point_loses_nothing
    before = saved_by_the_first_build
    bigger = version(copies: 4)
    (0..400).step(3) do |cut|
      store = before.dup
      Reference.new(save: store.cut_power_after(cut)).run(bigger, frames: 2)
      back = play(bigger, store)

      assert_equal [42, 43, 7], [back[:shown0], back[:shown1], back[:kept_speed]], "cut after #{cut} bytes"
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

  # The console, powered on with the save memory the first build left: the second build finds
  # the files where the interpreter says it will.
  def test_the_console_finds_a_record_that_kept_its_place
    store = saved_by_the_first_build
    rom = assemble_rom(version(settings: %i[speed volume], copies: 4), name: "MOVED")
    v = assert_emulator_loads_rom(rom, frames: 4, save: store, vars: rom.var_addresses)

    assert_equal [42, 43, 0, 0], (0..3).map { |n| v.var(:"shown#{n}") }
  end

  # The console, powered on with what the first build saved, finds the records the second build
  # declared in another order, and one that only fits once the others are slid together — and
  # leaves save memory byte for byte as the interpreter does. Sliding records together is the
  # slow one: the console takes eight frames over it at power-on, once, so the run is given
  # twelve.
  def test_the_console_reorders_and_slides_records_the_way_the_interpreter_does
    first = version(order: %i[settings north file south], extra: { north: 5000, south: 5000 })
    [version(order: %i[file settings]),
     version(order: %i[settings file atlas], extra: { atlas: 10_000 })].each_with_index do |second, n|
      store = SaveImage.new
      play(first, store, pressing: { 2 => :a }, frames: 12)
      before = store.dup
      oracle = play(second, store)
      rom = assemble_rom(second, name: "SLIDE#{n}")
      v = assert_emulator_loads_rom(rom, frames: 12, save: before, vars: rom.var_addresses)
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

  def test_records_named_like_the_framework_keep_their_own_saves
    store = SaveImage.new
    play(records_named_like_the_framework, store, pressing: { 2 => :a }, frames: 12)
    back = play(records_named_like_the_framework, store)

    assert_equal [10, 11, 12, 13, 14], NAMED_LIKE_THE_FRAMEWORK.map { |name| back[:"kept_#{name}"] }
  end

  def test_the_console_keeps_records_named_like_the_framework_apart
    store = SaveImage.new
    play(records_named_like_the_framework, store, pressing: { 2 => :a }, frames: 12)
    rom = assemble_rom(records_named_like_the_framework, name: "NAMES")
    v = assert_emulator_loads_rom(rom, frames: 4, save: store, vars: rom.var_addresses)

    assert_equal [10, 11, 12, 13, 14], NAMED_LIKE_THE_FRAMEWORK.map { |name| v.var(:"kept_#{name}") }
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

  def test_a_saved_half_holds_its_header_and_body_where_the_layout_says
    store = SaveImage.new
    play(header_and_body, store, pressing: { 2 => :a }, frames: 12)
    half = half_with_marker(store, Layout::PACKED.data_start)
    body = store.read_bytes(half + Layout::HEADER, HEADER_AND_BODY_BODY)

    assert_equal 1, store.word(half + Layout::SEQUENCE_AT), "the first save of a copy"
    assert_equal Layout::SAVED, store.word(half + Layout::KIND_AT)
    assert_equal Layout.checksum(body), store.word(half + Layout::CHECKSUM_AT)
    assert_equal [7, 0, 0, 0], body[0, 4], "the hearts, first, as a word"
    assert_equal [2, 0, 0, 0], body[4, 4], "then the list's length"
    assert_equal [300 & 0xFF, 300 >> 8, 0xFE, 0xFF], body[8, 4], "then its items, a half-word each"
  end

  # The table of places is written the other way — whole, at power-on — and holds to the
  # same header.
  def test_the_table_of_places_holds_the_same_header
    store = SaveImage.new
    play(header_and_body, store)
    table = Layout::PACKED.table_at
    body_bytes = Layout::TABLE_COLUMNS.length * (4 + (Layout::TABLE_ROWS * 4))

    assert_equal Layout::MARKER, store.word(table)
    assert_equal Layout::SAVED, store.word(table + Layout::KIND_AT)
    assert_equal Layout.checksum(store.read_bytes(table + Layout::HEADER, body_bytes)),
                 store.word(table + Layout::CHECKSUM_AT)
  end

  # THE ORDER, read off a power cut at each step: the marker and the shape first, then the body,
  # then the sequence and the kind, and the checksum last of all — so until that last word is
  # in, the half cannot pass for good.
  def test_a_save_is_written_marker_first_and_checksum_last
    fresh = SaveImage.new
    play(header_and_body, fresh) # the table of places is written at the first power-on
    steps = { 8 => :opened, 8 + HEADER_AND_BODY_BODY => :body, 8 + HEADER_AND_BODY_BODY + 8 => :stamped }
    steps.each do |cut, step|
      store = fresh.dup
      Reference.new(save: store.cut_power_after(cut))
               .input_each_frame { |f| f == 2 ? [:a] : [] }.run(header_and_body, frames: 12)
      half = half_with_marker(store, Layout::PACKED.data_start)
      body = store.read_bytes(half + Layout::HEADER, HEADER_AND_BODY_BODY)

      refute_equal 0, store.word(half + Layout::SHAPE_AT), "#{step}: the shape goes in with the marker"
      # A word not written yet is four bytes of 0xFF, which is what a fresh chip holds.
      assert_equal step == :opened ? [0xFF] * 4 : [7, 0, 0, 0], body[0, 4], "#{step}: the body"
      assert_equal step == :stamped ? 1 : -1, store.word(half + Layout::SEQUENCE_AT), "#{step}: the sequence"
      assert_equal(-1, store.word(half + Layout::CHECKSUM_AT), "#{step}: no checksum yet")
    end
  end

  # --- friendly errors ---

  private def refused(&block)
    assert_raises(ArgumentError) { built { screen :tiled; instance_eval(&block) } }.message
  end

  def test_what_a_record_cannot_keep_is_a_friendly_error
    assert_match(/a number worked out from other things/, refused { hearts = var :hearts, 3; save_data(:f) { keep hearts + 1 } })
    assert_match(/`var` and `list`/, refused { save_data(:f) { keep 5 } })
    assert_match(/is a `save_var`/, refused { best = save_var :best, 0; save_data(:f) { keep best } })
    assert_match(/save_data :g keeps it too|keeps it\s+too/,
                 refused { h = var :h, 0; save_data(:f) { keep h }; save_data(:g) { keep h } })
  end

  def test_a_record_that_does_not_fit_is_a_friendly_error
    message = refused { big = list :big, capacity: 5000; save_data(:f, copies: 4) { keep big } }
    assert_match(/does not fit in save memory/, message)
    assert_match(/use fewer copies/, message)
  end

  # A name that could run into the framework's own names, or into another record's, is
  # refused rather than quietly sharing a place with them.
  def test_a_name_that_cannot_name_a_record_is_a_friendly_error
    [:_hidden, :"two__words", :trailing_, :"has space", :"9lives"].each do |name|
      message = refused { h = var :h, 0; save_data(name) { keep h } }
      assert_match(/cannot name a record/, message, name.inspect)
      assert_match(/:high_scores/, message, "it shows a name that works")
    end
  end

  def test_an_unknown_when_busy_is_a_friendly_error
    message = refused { h = var :h, 0; save_data(:f, when_busy: :queue) { keep h } }
    assert_match(/`when_busy: :queue`/, message)
    assert_match(/:wait \(the default/, message)
  end

  def test_more_records_than_the_table_has_rows_for_is_a_friendly_error
    message = refused { 17.times { |n| h = var :"h#{n}", 0; save_data(:"r#{n}") { keep h } } }
    assert_match(/is record 17, and a game can have 16/, message)
  end

  def test_a_copy_the_record_does_not_have_is_a_friendly_error
    assert_match(/has 3 copies, counted from 0, so it has no copy 3/,
                 refused { h = var :h, 0; save_data(:f, copies: 3) { keep h }[3].save })
    assert_match(/`copies: 0`/, refused { h = var :h, 0; save_data(:f, copies: 0) { keep h } })
    assert_match(/does not keep :lives/,
                 refused { h = var :h, 0; lives = var :lives, 3; save_data(:f) { keep h }[0].peek(lives) })
  end

  def test_a_record_that_ends_the_build_keeping_nothing_is_a_friendly_error
    message = refused { files = save_data :file; game_loop { files[0].save } }
    assert_match(/save_data :file keeps nothing/, message)
    assert_match(/`files.keep hearts`|\.keep/, message)
  end

  # A peek written before the record says what it keeps is checked once it does.
  def test_a_peek_at_something_never_kept_is_a_friendly_error
    message = refused do
      files = save_data :file
      shown = var :shown, 0
      game_loop { shown.set! files[0].peek(:lives) }
      h = var :h, 0
      files.keep h
    end
    assert_match(/does not keep :lives/, message)
    assert_match(/It keeps :h/, message)
  end

  def test_a_peek_read_the_wrong_way_for_what_is_kept_is_a_friendly_error
    as_number = refused do
      files = save_data :file
      shown = var :shown, 0
      game_loop { shown.set! files[0].peek(:name) }
      files.keep list(:name, capacity: 3)
    end
    assert_match(/keeps :name as a list/, as_number)
    assert_match(/peek\(:name\)\[i\]/, as_number)

    as_list = refused do
      files = save_data :file
      shown = var :shown, 0
      game_loop { shown.set! files[0].peek(:hearts).length }
      files.keep var(:hearts, 3)
    end
    assert_match(/keeps :hearts as a variable/, as_list)
  end

  def test_keeping_after_the_build_is_settled_is_a_friendly_error
    builder = Builder.new
    files = nil
    builder.instance_eval do
      screen :tiled
      hearts = var :hearts, 3
      files = save_data(:file) { keep hearts }
    end
    builder.finalize_program
    lives = builder.instance_eval { var :lives, 3 }
    message = assert_raises(ArgumentError) { files.keep lives }.message
    assert_match(/save_data :file is already laid out/, message)
  end

  def test_what_a_record_cannot_keep_is_refused_when_kept_later_too
    assert_match(/is a `save_var`/, refused { files = save_data(:f); files.keep save_var(:best, 0) })
    assert_match(/keeps it\s+too/,
                 refused { h = var :h, 0; save_data(:f).keep h; save_data(:g) { keep h } })
  end

  # The two lay save memory out byte for byte alike, which is what lets a test that cuts the
  # power on the interpreter speak for the console.
  def test_the_console_writes_the_same_bytes_as_the_interpreter
    store = SaveImage.new
    play(one_save, store, pressing: { 2 => :a })
    rom = assemble_rom(one_save, name: "RECBYTES")
    v = assert_emulator_loads_rom(rom, frames: 3, keys: ->(f) { f == 2 ? KEY_A : 0 })
    v.step(2)

    written = store.written.keys.sort
    refute_empty written
    console = written.map { |at| v.mem8(SRAM_START + at) }
    assert_equal written.map { |at| store.read(at, 1) }, console
  end
end
