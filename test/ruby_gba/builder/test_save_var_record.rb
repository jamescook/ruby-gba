# frozen_string_literal: true

require "test_helper"

# A `save_var` ON 64K OR 128K OF SAVE MEMORY, which is flash: the save_vars are kept in a
# record of their own that saves itself a pass after one of them changes, rather than written
# in place as they are on 32K.
class TestSaveVarRecord < Minitest::Test
  include RubyGBA::Console::Hardware

  # The frame A is pressed on: after the first power-on of a fresh chip has written its table.
  PRESS = 8

  # A game whose save_var :best starts at 3 and is set to 7 when A is pressed — or, with
  # +every_frame+, goes up by one every frame. +more+ declares a second save_var after it, the
  # way an update to the game would.
  private def game(every_frame: false, more: false)
    RubyGBA.game("FLASHVAR", save_memory: 64) do
      screen :bitmap
      best = save_var :best, 3
      save_var :wins, 5 if more
      game_loop do
        every_frame ? best.add!(1) : pressed(:a).then { best.set! 7 }
      end
    end
  end

  private def rom_of(game) = game.build_rom(out: nil, err: nil, profile: false)

  # The save memory after A is pressed and the save has had time to go in.
  private def saved_on_interpreter(game)
    store = SaveImage.new(kilobytes: 64)
    Reference.new(save: store).input_each_frame { |f| f == PRESS ? [:a] : [] }.run(game.program, frames: 24)
    store
  end

  def test_a_save_var_comes_back_after_the_power_goes_off
    rom = rom_of(game)
    chip = assert_emulator_loads_rom(rom, frames: PRESS + 16, keys: ->(f) { f == PRESS ? KEY_A : 0 }).save_image
    fresh = assert_emulator_loads_rom(rom, frames: 6, vars: rom.var_addresses)

    assert_equal 3, fresh.var(:best), "a fresh cartridge starts at the default"
    assert_equal 7, assert_emulator_loads_rom(rom, frames: 6, save: chip, vars: rom.var_addresses).var(:best)
  end

  def test_the_console_saves_a_save_var_the_way_the_interpreter_does
    rom = rom_of(game)
    chip = assert_emulator_loads_rom(rom, frames: PRESS + 16, keys: ->(f) { f == PRESS ? KEY_A : 0 }).save_image
    store = saved_on_interpreter(game)

    assert_equal 7, Reference.new(save: store).run(game.program, frames: 2)[:best]
    assert_equal store.written, chip.written
  end

  # An update that adds a save_var finds the one saved before it, and starts the new one at
  # its default.
  def test_an_update_that_adds_a_save_var_keeps_the_saved_one
    store = saved_on_interpreter(game)
    back = Reference.new(save: store).run(game(more: true).program, frames: 2)

    assert_equal 7, back[:best]
    assert_equal 5, back[:wins]
  end

  # How many saves the save_vars' record holds: the newer of its two halves' sequence numbers,
  # each one more than the last save's. A half never written reads as -1.
  private def saves_made(chip)
    row = chip.table.find { |one| one.key == RubyGBA::IR::SaveLayout.record_key(:_save_vars) }
    [0, chip.memory.block].map { |half| chip.word(row.at + half + RubyGBA::IR::SaveLayout::SEQUENCE_AT) }.max
  end

  # A number that changes every frame is saved once in 300 passes, not every frame, so the
  # chip is not wiped sixty times a second. Its last change is saved within 300 passes.
  def test_a_save_var_changing_every_frame_is_saved_once_in_300_passes
    rom = rom_of(game(every_frame: true))
    v = assert_emulator_loads_rom(rom, frames: 400, vars: rom.var_addresses)
    chip = v.save_image
    back = assert_emulator_loads_rom(rom, frames: 6, save: chip, vars: rom.var_addresses)

    assert_equal 2, saves_made(chip), "400 frames of changes: one save at the start, one 300 passes on"
    assert_operator back.var(:best), :>=, v.var(:best) - 300, "the save is no more than 300 passes behind"
  end

  def test_a_save_var_on_flash_in_a_game_with_no_game_loop_is_refused
    message = assert_raises(ArgumentError) do
      RubyGBA.build("FLASHVAR", out: nil, err: nil, save_memory: 64) do
        screen :bitmap
        save_var :best, 0
        halt
      end
    end.message

    assert_match(/no game_loop/, message)
    assert_match(/never saved/, message)
  end
end
