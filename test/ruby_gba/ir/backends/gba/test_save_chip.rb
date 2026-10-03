# frozen_string_literal: true

require "test_helper"

# WHICH SAVE CHIP A CARTRIDGE WRITES TO, picked from the save memory the program says it has:
# the battery-backed 32K, or a flash chip of 64K or 128K.
#
# The flash tests turn the power off by taking the chip's bytes out of one run and starting a
# second run from them, which is what the player does by switching the console off and on.
class TestSaveChip < Minitest::Test
  include RubyGBA::Console::Hardware

  # The frame A is pressed on. A fresh flash chip has its table of places written at the first
  # power-on, a block wiped and a byte written at a time, and that takes a few frames.
  PRESS = 8

  private def program(save_memory)
    builder = Builder.new(save_memory: save_memory)
    builder.instance_eval do
      screen :bitmap
      save_var :best, 0
      game_loop {}
    end
    builder.finalize_program
    builder.program
  end

  # A game with one save file, which loads it at power-on and saves 7 hearts when A is pressed
  # and 9 when B is. +pad+ bytes in a record declared first push the file's record past them.
  private def saving_game(save_memory, pad: 0)
    RubyGBA.game("FLASHSAV", save_memory: save_memory) do
      screen :bitmap
      hearts = var :hearts, 3
      if pad.positive?
        filler = list :filler, capacity: pad, width: :byte, fast: false
        save_data(:filler) { keep filler }
      end
      file = save_data(:file) { keep hearts }
      file[0].load
      game_loop do
        pressed(:a).then { hearts.set! 7; file[0].save }
        pressed(:b).then { hearts.set! 9; file[0].save }
      end
    end
  end

  private def saving_rom(save_memory, pad: 0)
    saving_game(save_memory, pad: pad).build_rom(out: nil, err: nil, profile: false)
  end

  # The chip after a run where A is pressed on frame +press+, given time for the save to go in.
  private def saved_chip(rom, press: PRESS)
    v = assert_emulator_loads_rom(rom, frames: press + 16, keys: ->(f) { f == press ? KEY_A : 0 })
    v.save_image
  end

  private def hearts_at_power_on(rom, chip, frames: 6)
    assert_emulator_loads_rom(rom, frames: frames, save: chip, vars: rom.var_addresses).var(:hearts)
  end

  def test_a_save_on_64k_of_flash_comes_back_after_the_power_goes_off
    rom = saving_rom(64)
    chip = saved_chip(rom)

    assert_equal 64 * 1024, chip.memory.size
    assert_equal 7, hearts_at_power_on(rom, chip)
  end

  # The filler's halves are six blocks each, which ends it at the first 64K exactly. Reading a
  # record that size back at power-on takes the console a few dozen frames.
  def test_a_save_on_128k_of_flash_comes_back_from_the_second_bank
    rom = saving_rom(128, pad: 20_500)
    chip = saved_chip(rom, press: 48)
    file = chip.table.find { |row| row.key == RubyGBA::IR::SaveLayout.record_key(:file) }

    assert_equal 128 * 1024, chip.memory.size
    assert_operator file.at, :>=, 0x10000, "the file's record is past the first 64K"
    assert_equal 7, hearts_at_power_on(rom, chip, frames: 48)
  end

  # The console and the interpreter, given the same presses, leave the same bytes on the chip.
  def test_the_console_writes_flash_the_way_the_interpreter_does
    rom = saving_rom(64)
    chip = saved_chip(rom)
    store = SaveImage.new(kilobytes: 64)
    Reference.new(save: store).input_each_frame { |f| f == PRESS ? [:a] : [] }.run(saving_game(64).program, frames: 24)

    refute_empty store.written
    assert_equal store.written, chip.written, "the same bytes, and no byte only one of them wrote"
  end

  # The power going off part way through a save leaves the save before it.
  def test_a_save_cut_off_half_way_leaves_the_last_good_save
    rom = saving_rom(64)
    v = assert_emulator_loads_rom(rom, frames: 24, keys: ->(f) { f == PRESS ? KEY_A : 0 })
    before = v.save_image
    v.step(1, keys: KEY_B)
    v.step(1)
    cut = v.save_image
    v.step(4)

    refute_equal before.written, cut.written, "the power went off with the save under way"
    assert_equal 7, hearts_at_power_on(rom, cut)
    assert_equal 9, hearts_at_power_on(rom, v.save_image), "and the save it cut off goes in when let finish"
  end

  # A save memory made without a size is the cartridge's size, as the interpreter takes it.
  def test_a_save_memory_given_no_size_is_the_cartridges
    store = SaveImage.new
    hearts_at_power_on(saving_rom(64), store)

    assert_equal 64, store.memory.kilobytes
  end

  # A game whose record's second half runs across the line between the 128K chip's two banks:
  # writing, checking and reading it back each go from one bank to the other part way. The
  # filler's halves are four blocks each, which puts the file's three-block halves at 0xC000
  # and 0xF000. The first save goes in the first half and the second save across the line.
  def test_a_save_across_the_line_between_banks_comes_back
    rom = RubyGBA.game("FLASHBNK", save_memory: 128) do
      screen :bitmap
      filler = list :filler, capacity: 14_000, width: :byte, fast: false
      save_data(:filler) { keep filler }
      pages = list :pages, capacity: 10_000, width: :byte, fast: false
      hearts = var :hearts, 3
      page = var :page, 0
      file = save_data(:file) { keep pages, hearts }
      file[0].load
      page.set! pages[4500]
      game_loop do
        pressed(:a).then do
          repeat(5000) { |i| pages.push(i & 127) }
          hearts.set! 7
          file[0].save
        end
        pressed(:b).then { hearts.set! 9; file[0].save }
      end
    end.build_rom(out: nil, err: nil, profile: false)
    presses = { 80 => KEY_A, 500 => KEY_B }
    chip = assert_emulator_loads_rom(rom, frames: 900, keys: ->(f) { presses.fetch(f, 0) }).save_image
    file = chip.table.find { |row| row.key == RubyGBA::IR::SaveLayout.record_key(:file) }
    back = assert_emulator_loads_rom(rom, frames: 80, save: chip, vars: rom.var_addresses)

    assert_equal 0xC000, file.at
    assert_equal 9, back.var(:hearts), "the second save, which runs across the line"
    assert_equal 4500 & 127, back.var(:page), "a byte past the line, read back"
  end

  # How many passes of the game loop a 5K save leaves the game in 200 frames, with the save
  # asked for on the first — and whether it went in.
  private def passes_while_saving(save_memory)
    rom = RubyGBA.game("FLASHPAS", save_memory: save_memory) do
      screen :bitmap
      flags = list :flags, capacity: 5000, width: :byte, fast: false
      saving = var :saving, 0
      file = save_data(:file) { keep flags }
      game_loop do
        pressed(:a).then { file[0].save }
        saving.set! 0
        file.saving?.then { saving.set! 1 }
      end
    end.build_rom(out: nil, err: nil, profile: false)
    v = assert_emulator_loads_rom(rom, frames: 30, count_passes: true, vars: rom.var_addresses)
    before = v.passes
    v.step(1, keys: KEY_A)
    v.step(199)
    assert_equal 0, v.var(:saving), "the save went in"
    v.passes - before
  end

  # A half of a 5K record is two blocks of flash, and the game goes on while the chip wipes
  # them, so the save costs no more passes than the same save on battery memory.
  def test_a_save_on_flash_costs_no_more_frames_than_on_battery_memory
    assert_equal passes_while_saving(32), passes_while_saving(64)
  end

  # A half of a 20K record is six blocks, and the chip takes about a ninth of a frame to wipe
  # each. Waiting for all six in one pass would take most of that frame. Each block's wipe is
  # started on one pass and found finished on a later one instead, so no frame of the wipe is
  # anywhere near full. (The pass that asks for the save copies the record aside, which is
  # dear for 20K on any memory, so the frames measured start after it.)
  def test_wiping_a_big_half_of_flash_spreads_over_frames
    rom = RubyGBA.game("FLASHWIP", save_memory: 64) do
      screen :bitmap
      flags = list :flags, capacity: 20_000, width: :byte, fast: false
      file = save_data(:file) { keep flags }
      game_loop { pressed(:a).then { file[0].save } }
    end.build_rom(out: nil, err: nil, profile: false)
    busiest = Dir.mktmpdir("flash-wipe") do |dir|
      path = File.join(dir, "wipe.gba")
      rom.write(path)
      probe = RubyGBA::Diagnostics::Emulator.probe(path)
      probe.step(60)
      probe.step(1, keys: KEY_A)
      worst = 8.times.map { probe.frame_cost.busy_scanlines }.max
      probe.close
      worst
    end

    assert_operator busiest, :<, 100, "a frame of the wipe stays well short of the 228 a frame has"
  end

  def test_a_flash_cartridge_carries_the_marker_for_its_size
    assert_includes saving_rom(64).buffer, "FLASH512_V131"
    assert_includes saving_rom(128).buffer, "FLASH1M_V103"
  end

  # A save_var writes its number straight into save memory each time it changes, and flash
  # cannot take a byte twice without a wipe. A game is refused before it gets here; a program
  # put together by hand is refused on its way to a cartridge.
  def test_a_save_var_on_flash_is_refused_on_its_way_to_a_cartridge
    error = assert_raises(RubyGBA::IR::Backends::GBA::LoweringError) { assemble_rom(program(64)) }

    assert_match(/save_var/, error.message)
    assert_match(/64K/, error.message)
  end

  def test_a_32k_cartridge_carries_the_marker_that_maps_battery_memory
    assert_includes assemble_rom(program(32)).buffer, "SRAM_V123"
  end
end
