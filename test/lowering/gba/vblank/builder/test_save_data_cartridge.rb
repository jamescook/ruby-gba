# frozen_string_literal: true

require "test_helper"
require "stringio"
require "all/vblank/builder/test_save_data"

# Save records on the Advance's cartridge: the same games as test/all/vblank/builder/test_save_data.rb,
# played in the emulator and held to the interpreter (which is game_player on the gba run), down to
# the bytes the cartridge writes into its save memory.
class TestSaveDataCartridge < Minitest::Test
  include SaveDataGames

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
    v.step(2, keys: KEY_START)
    v.step(2)
    assert_equal 7, v.var(:hearts), "loaded back"
  end

  def test_the_console_keeps_three_copies_the_way_the_interpreter_does
    buttons = %i[a up a up a down b up left select]
    store = SaveImage.new
    oracle = files_after(store, *buttons)
    keys = { a: KEY_A, b: KEY_B, up: KEY_UP, down: KEY_DOWN, left: KEY_LEFT, select: KEY_SELECT }
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

  # A list read item by item from several places, among other expressions, is still no
  # expression left unused, so the build's checks pass it and the console reads what the
  # interpreter reads.
  def test_a_kept_list_peeked_from_several_places_builds_and_reads_alike
    store = SaveImage.new
    files_after(store, :up, :a)
    oracle = play(built(&names_peeked), store.dup)
    rom = VBlank.build("PEEKS", console: :gba, out: StringIO.new, err: StringIO.new, &names_peeked)
    v = assert_emulator_loads_rom(rom, frames: 4, save: store, vars: rom.var_addresses)

    readings = %i[first length none total]
    assert_equal [1, 1, 0, 9], readings.map { |name| oracle[name] }
    assert_equal readings.map { |name| oracle[name] }, readings.map { |name| v.var(name) }
  end

  def test_a_load_puts_the_random_numbers_back_on_both_backends
    oracle = play(rolling_after_a_load, SaveImage.new, pressing: presses(*ROLLING), frames: (ROLLING.length * 2) + 4)
    refute_equal 0, oracle[:first]
    assert_equal oracle[:first], oracle[:rolled], "the roll after the load is the roll after the save"

    keys = { a: KEY_A, b: KEY_B, up: KEY_UP, start: KEY_START }
    schedule = presses(*ROLLING).transform_values { |button| keys.fetch(button) }
    rom = assemble_rom(rolling_after_a_load, name: "ROLLBACK")
    v = assert_emulator_loads_rom(rom, frames: (ROLLING.length * 2) + 8, keys: ->(f) { schedule.fetch(f, 0) },
                                       vars: rom.var_addresses)
    assert_equal [oracle[:first], oracle[:rolled]], [v.var(:first), v.var(:rolled)]
  end

  def test_the_console_puts_a_pool_back_the_way_the_interpreter_does
    buttons = %i[a b start left]
    oracle = guards_after(*buttons)
    keys = { a: KEY_A, b: KEY_B, start: KEY_START, left: KEY_LEFT }
    schedule = presses(*buttons).transform_values { |button| keys.fetch(button) }
    rom = assemble_rom(guards_saved, name: "GUARDS")
    v = assert_emulator_loads_rom(rom, frames: (buttons.length * 2) + 10, keys: ->(f) { schedule.fetch(f, 0) },
                                       vars: rom.var_addresses)
    assert_equal oracle[:signature], v.var(:signature)
  end

  def test_the_console_runs_a_record_declared_before_what_it_keeps
    buttons = %i[a up a up up left down b]
    oracle = screen_first_after(SaveImage.new, *buttons)
    keys = { a: KEY_A, b: KEY_B, up: KEY_UP, down: KEY_DOWN, left: KEY_LEFT }
    schedule = presses(*buttons).transform_values { |button| keys.fetch(button) }
    rom = assemble_rom(file_screen_first, name: "FILESFIRST")
    v = assert_emulator_loads_rom(rom, frames: (buttons.length * 2) + 8, keys: ->(f) { schedule.fetch(f, 0) },
                                       vars: rom.var_addresses)

    %i[shown0 shown1 shown2 state0 state1 state2 length0 length1 length2 first1 hearts].each do |name|
      assert_equal oracle[name], v.var(name), name.to_s
    end
  end

  def test_three_full_size_files_and_settings_on_both_backends
    # Three files' buffers are filled as the console starts, so it is given a few frames first.
    schedule = { 4 => KEY_A, 6 => KEY_B, 8 => KEY_START }
    rom = assemble_rom(full_size, name: "FULLSIZE")
    v = assert_emulator_loads_rom(rom, frames: 14, keys: ->(f) { schedule.fetch(f, 0) }, vars: rom.var_addresses)
    assert_equal (1195 & 0x7F) + 5 + 20, v.var(:checked)
  end

  # The console, powered on with the save memory the first build left: the second build finds
  # the files where the interpreter says it will.
  def test_the_console_finds_a_record_that_kept_its_place
    store = saved_by_the_first_build
    rom = assemble_rom(version(settings: %i[speed volume], copies: 4), name: "MOVED")
    v = assert_emulator_loads_rom(rom, frames: 4, save: store, vars: rom.var_addresses)

    assert_equal [42, 43, 0, 0], (0..3).map { |n| v.var(:"shown#{n}") }
  end

  def test_the_console_keeps_records_named_like_the_framework_apart
    store = SaveImage.new
    play(records_named_like_the_framework, store, pressing: { 2 => :a }, frames: 12)
    rom = assemble_rom(records_named_like_the_framework, name: "NAMES")
    v = assert_emulator_loads_rom(rom, frames: 4, save: store, vars: rom.var_addresses)

    assert_equal [10, 11, 12, 13, 14], NAMED_LIKE_THE_FRAMEWORK.map { |name| v.var(:"kept_#{name}") }
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
