# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "ruby_snes_emulator"

# A Super Nintendo cartridge of 32K made by hand, for a test that needs the console to run
# something: +code+ placed at $8000, where the reset vector points, and a LoROM header at $7FC0
# with a checksum that adds up, so the emulator takes it for what it is.
#
# The header's layout is the one every cartridge of the console carries (fullsnes, "SNES
# Cartridge ROM Header"): a 21-byte title at $FFC0, then the map mode ($20, LoROM), the kind of
# cartridge ($00, ROM alone), its size (2^n kilobytes), its RAM's size, the region, the maker,
# the version, and the checksum's complement and the checksum itself.
module HandMadeCartridge
  module_function

  def bytes(code)
    rom = ("\0".b * 0x8000)
    rom[0, code.size] = code.pack("C*")
    rom[0x7FC0, 21] = "PROBE TEST".ljust(21, " ")
    rom[0x7FD5, 7] = [0x20, 0x00, 0x05, 0x00, 0x01, 0x00, 0x00].pack("C*")
    rom[0x7FFC, 2] = [0x8000].pack("v") # reset, in emulation mode
    rom[0x7FDC, 4] = [0xFFFF, 0x0000].pack("v2")
    sum = rom.sum(16)
    rom[0x7FDC, 4] = [sum ^ 0xFFFF, sum].pack("v2")
    rom
  end

  # Writes the cartridge into +dir+ and gives back its path.
  def write(dir, code)
    path = File.join(dir, "test.sfc")
    File.binwrite(path, bytes(code))
    path
  end
end
