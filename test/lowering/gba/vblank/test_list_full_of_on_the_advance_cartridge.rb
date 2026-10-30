# frozen_string_literal: true

require "test_helper"
require "console/gba/vblank/test_list_full_of_on_the_advance"

# `list ..., full_of:` on the Advance's own cartridge: every width starts full, read off the
# running console's variables in the emulator, holding the readings the interpreter holds. The
# game, and what every run that plays the Advance reads, are in
# test/console/gba/vblank/test_list_full_of_on_the_advance.rb (ListFullOfOnTheAdvanceGames).
class TestListFullOfOnTheAdvanceCartridge < Minitest::Test
  include ListFullOfOnTheAdvanceGames

  def test_the_console_starts_every_width_full_as_the_interpreter_does
    rom = VBlank.build("LISTFULL", console: :gba, out: StringIO.new, err: StringIO.new, profile: false, &WIDTHS)
    v = assert_emulator_loads_rom(rom, frames: 4, vars: rom.var_addresses)

    assert_equal EXPECTED, READINGS.map { |name| v.var(name) }, "on the Advance's cartridge"
  end
end
