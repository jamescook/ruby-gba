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
