# frozen_string_literal: true

require "test_helper"
require "console/gba/vblank/builder/test_save_data_on_the_advance"

# Save records moved between builds, on the Advance's cartridge in the emulator, held to the
# interpreter (game_player on the gba run) down to the bytes in save memory. What the games do
# on every run that plays the Advance is in
# test/console/gba/vblank/builder/test_save_data_on_the_advance.rb.
class TestSaveDataOnTheAdvanceCartridge < Minitest::Test
  include SaveDataOnTheAdvanceGames

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
end
