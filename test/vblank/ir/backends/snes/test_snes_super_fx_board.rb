# frozen_string_literal: true

require "digest"
require "test_helper"
require VBlank.root.join("examples/sparks").to_s
require VBlank.root.join("examples/tiles").to_s
require VBlank.root.join("examples/buffered_bounce").to_s

# A Super Nintendo cartridge with a Super FX 2 (`variants: { snes: :superfx }`): its header says
# so, bsnes takes it as that board (the chip's RAM is there, at $70:0000, as the board table
# says), and the game's own code plays on it exactly as on a plain cartridge. A plain cartridge's
# bytes are what they were before the board was made.
class TestSNESSuperFXBoard < Minitest::Test
  W65816 = VBlank::IR::Backends::SNES::W65816
  Linker = VBlank::IR::Backends::SNES::Linker
  SNESROM = VBlank::Cartridge::SNESROM
  H = VBlank::Console::SNESHardware

  # The SHA-256 of each example's plain cartridge. A plain cartridge must not change by a byte
  # because another board exists; a change to the SNES lowering that is meant to change plain
  # cartridges records new digests here, in the same commit.
  PLAIN_DIGESTS = {
    Tiles => "8896dac94b3cc4b54361b5dd2b3745e92ec0b8a527dec85cdca06a4f60726425",
    BufferedBounce => "7dd18a7b16f19b6a4151ae7d2ec91763f29d40be571fd71ae9c53a32743c5df4",
    Sparks => "ec2a3436fb206c423ce597084df7623ca37c219be116aba491804197e958d3a8"
  }.freeze

  def test_a_plain_cartridge_is_byte_for_byte_what_it_was
    PLAIN_DIGESTS.each do |game, digest|
      rom = game::GAME.build_rom(console: :snes, profile: false, out: nil, err: nil)
      assert_equal digest, Digest::SHA256.hexdigest(rom.bytes), "#{game}'s plain cartridge changed"
    end
  end

  def test_the_header_says_super_fx_board
    bytes = Sparks::GAME.build_rom(console: :snes, variant: :superfx, profile: false, out: nil, err: nil).bytes

    assert_equal 0x20, bytes.getbyte(H::MAP_MODE_AT), "LoROM, read slowly"
    assert_equal 0x14, bytes.getbyte(H::CARTRIDGE_TYPE_AT), "ROM, a Super FX and its RAM"
    assert_equal 0x33, bytes.getbyte(H::MAKER_AT), "an extended header"
    assert_equal 6, bytes.getbyte(H::EXPANSION_RAM_AT), "64K of the chip's RAM (1K << 6)"
    assert SNESROM.header?(bytes)
  end

  def test_bsnes_gives_the_chip_its_ram_at_bank_70
    ram = chip_ram_after_writing(0x5A, board: SNESROM::SUPER_FX)
    assert_equal 0x10000, ram.bytesize, "bsnes gave the board the chip's 64K"
    assert_equal 0x5A, ram.getbyte(0)
    assert_empty chip_ram_after_writing(0x5A, board: SNESROM::PLAIN), "a plain cartridge has no chip RAM"
  end

  def test_a_game_plays_on_the_super_fx_board_as_on_the_interpreter
    run = game_player.run(Sparks::GAME.program(console: :snes, variant: :superfx), frames: 60)

    refute_empty run.pool(:spark, :y), "sparks are falling"
  end

  # What the console sees in the chip's RAM after a tiny cartridge stores +byte+ at $70:0000, read
  # back as the emulator's save memory, empty when the cartridge has none.
  private def chip_ram_after_writing(byte, board:)
    asm = W65816.new("boot", home: :first)
    asm.instance_eval do
      label "reset"
      sei
      clc
      xce
      sep 0x20
      lda byte
      sta long(0x700000)
      label "forever"
      bra "forever"
    end
    linked = Linker.new([asm.section]).link
    rom = SNESROM.new(linked.banks, title: "CHIP RAM", vectors: { reset: linked.address_of("reset") & 0xFFFF },
                                    board: board)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "chip.sfc")
      rom.write(path)
      core = VBlank::Diagnostics::Emulator.open_snes(path)
      3.times { core.run_frame }
      core.save_ram
    ensure
      core&.destroy
    end
  end
end
