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
    builder.emit_pending_functions
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
    store = {}
    play(one_save, store, pressing: { 2 => :a })
    back = play(one_save, store)

    assert_equal 7, back[:hearts]
    assert_equal [-56], back.list(:items), "a byte slot reads 200 back the way the console does"
    assert_equal 1, back[:was_good]
  end

  def test_nothing_is_kept_until_the_game_saves
    store = {}
    play(one_save, store, pressing: { 2 => :b })
    back = play(one_save, store)

    assert_equal 3, back[:hearts], "the change was never saved"
    assert_equal 0, back[:was_good], "a copy nothing ever saved is not good"
  end

  def test_a_change_after_saving_is_not_kept
    store = {}
    play(one_save, store, pressing: { 2 => :a, 4 => :b })
    assert_equal 7, play(one_save, store)[:hearts]
  end

  def test_loading_puts_back_what_was_saved
    run = play(one_save, {}, pressing: { 2 => :a, 3 => :b, 4 => :l })
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
    store = {}
    files_after(store, :a, :up, :a, :up, :a)
    back = files_after(store)

    assert_equal [10, 11, 12], (0..2).map { |n| back[:"shown#{n}"] }
    assert_equal [2, 2, 2], (0..2).map { |n| back[:"state#{n}"] }
    assert_equal 3, back[:hearts], "reading a copy does not load it"
  end

  def test_loading_a_copy_picked_by_a_worked_out_number
    store = {}
    files_after(store, :a, :up, :a)
    back = files_after(store, :up, :l)

    assert_equal 11, back[:hearts]
    assert_equal [0, 1], back.list(:name), "the list comes back as it was saved"
  end

  def test_an_erased_copy_says_so_and_loads_nothing
    store = {}
    files_after(store, :a, :up, :a, :b)
    back = files_after(store, :up, :l)

    assert_equal [2, 1, 0], (0..2).map { |n| back[:"state#{n}"] }, "good, erased, never saved"
    assert_equal 3, back[:hearts], "an erased copy loads nothing"
  end

  def test_one_copy_can_be_copied_over_another
    store = {}
    files_after(store, :a, :up, :up, :r)
    back = files_after(store)

    assert_equal [10, 0, 10], (0..2).map { |n| back[:"shown#{n}"] }
  end

  def test_reset_puts_the_kept_things_back_as_they_were_declared
    run = files_after({}, :a, :select)

    assert_equal 3, run[:hearts]
    assert_empty run.list(:name)
  end

  def test_a_copy_number_the_record_does_not_have_does_nothing
    store = {}
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
    before = {}
    files_after(before, :a, :up, :a)
    whole = before.merge(bytes: before[:bytes].dup)
    Reference.new(save: whole).input_each_frame { |f| f == 2 ? [:right] : [] }.run(three_files, frames: 4)
    assert_equal 99, files_after(whole)[:shown0], "uncut, the new save is the copy"

    (0..40).each do |cut|
      store = before.merge(bytes: before[:bytes].dup)
      Reference.new(save: store).cut_power_after_saving(cut)
               .input_each_frame { |f| f == 2 ? [:right] : [] }.run(three_files, frames: 4)
      back = files_after(store)

      assert_equal [2, 2], [back[:state0], back[:state1]], "cut after #{cut} bytes"
      assert_includes [10, 99], back[:shown0], "cut after #{cut} bytes"
      assert_equal 11, back[:shown1], "cut after #{cut} bytes"
    end
  end

  # Cut after the header's first two words and four bytes of the body.
  def test_a_first_save_cut_off_half_way_is_damaged
    store = {}
    files_after(store, :up, :up, :a)
    Reference.new(save: store).cut_power_after_saving(12)
             .input_each_frame { |f| f == 2 ? [:a] : [] }.run(three_files, frames: 4)
    back = files_after(store)

    assert_equal [3, 0, 2], (0..2).map { |n| back[:"state#{n}"] }
  end

  def test_the_console_keeps_three_copies_the_way_the_interpreter_does
    buttons = %i[a up a up a down b up r select]
    store = {}
    oracle = files_after(store, *buttons)
    keys = { a: KEY_A, b: KEY_B, up: KEY_UP, down: KEY_DOWN, r: KEY_R, select: KEY_SELECT }
    schedule = presses(*buttons).transform_values { |button| keys.fetch(button) }
    rom = assemble_rom(three_files, name: "FILES3")
    v = assert_emulator_loads_rom(rom, frames: (buttons.length * 2) + 8, keys: ->(f) { schedule.fetch(f, 0) },
                                       vars: rom.var_addresses)

    %i[shown0 shown1 shown2 state0 state1 state2 hearts].each do |name|
      assert_equal oracle[name], v.var(name), name.to_s
    end
    written = store[:bytes].keys.sort
    assert_equal written.map { |at| store[:bytes][at] }, written.map { |at| v.mem8(SRAM_START + at) }
  end

  # The two lay save memory out byte for byte alike, which is what lets a test that cuts the
  # power on the interpreter speak for the console.
  def test_the_console_writes_the_same_bytes_as_the_interpreter
    store = {}
    play(one_save, store, pressing: { 2 => :a })
    rom = assemble_rom(one_save, name: "RECBYTES")
    v = assert_emulator_loads_rom(rom, frames: 3, keys: ->(f) { f == 2 ? KEY_A : 0 })
    v.step(2)

    written = store[:bytes].keys.sort
    refute_empty written
    console = written.map { |at| v.mem8(SRAM_START + at) }
    assert_equal written.map { |at| store[:bytes][at] }, console
  end
end
