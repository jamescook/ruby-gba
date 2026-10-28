# frozen_string_literal: true

require_relative "test_helper"

class TestCore < Minitest::Test
  # Native mode, the screen off, colour 0 set to pure red ($001F), $1234 stored in work RAM at
  # $0100, $A5 in video RAM's first word and $42 in the sprite table's first byte, the screen on
  # at full brightness, and round for ever. Each instruction's bytes are from the 65816's opcode
  # table.
  RED_BACKDROP = [
    0x78,             # SEI
    0x18,             # CLC
    0xFB,             # XCE          native mode
    0xA9, 0x80,       # LDA #$80
    0x8D, 0x00, 0x21, # STA $2100    INIDISP: screen off
    0x9C, 0x21, 0x21, # STZ $2121    CGADD: colour 0
    0xA9, 0x1F,       # LDA #$1F
    0x8D, 0x22, 0x21, # STA $2122    CGDATA low: red 31
    0x9C, 0x22, 0x21, # STZ $2122    CGDATA high
    0xA9, 0x34,       # LDA #$34
    0x8D, 0x00, 0x01, # STA $0100
    0xA9, 0x12,       # LDA #$12
    0x8D, 0x01, 0x01, # STA $0101
    0x9C, 0x16, 0x21, # STZ $2116    VMADDL
    0x9C, 0x17, 0x21, # STZ $2117    VMADDH
    0xA9, 0xA5,       # LDA #$A5
    0x8D, 0x18, 0x21, # STA $2118    VMDATAL
    0x9C, 0x02, 0x21, # STZ $2102    OAMADDL
    0x9C, 0x03, 0x21, # STZ $2103    OAMADDH
    0xA9, 0x42,       # LDA #$42
    0x8D, 0x04, 0x21, # STA $2104    OAMDATA: held in a latch until the odd byte comes
    0x8D, 0x04, 0x21, # STA $2104    OAMDATA: both bytes written
    0xA9, 0x0F,       # LDA #$0F
    0x8D, 0x00, 0x21, # STA $2100    INIDISP: screen on, full brightness
    0x80, 0xFE        # BRA -2
  ].freeze

  def setup
    @dir = Dir.mktmpdir
    @core = RubySNESEmulator::Core.new(HandMadeCartridge.write(@dir, RED_BACKDROP))
    3.times { @core.run_frame }
  end

  def teardown
    @core&.destroy
    FileUtils.rm_rf(@dir)
  end

  def test_the_picture_is_the_backdrop_colour
    assert_equal [256, 224], [@core.width, @core.height]
    assert_equal [0x001F], @core.colors.uniq
  end

  def test_work_ram_reads_what_the_cartridge_stored
    assert_equal 0x1234, @core.wram_read16(0x0100)
  end

  def test_colour_memory_reads_what_the_cartridge_wrote
    assert_equal 0x001F, @core.cgram.unpack1("v")
  end

  def test_video_ram_reads_what_the_cartridge_wrote
    assert_equal 0xA5, @core.vram.getbyte(0)
  end

  def test_the_sprite_table_reads_what_the_cartridge_wrote
    assert_equal 544, @core.oam.bytesize
    assert_equal 0x42, @core.oam.getbyte(0)
  end

  def test_the_registers_say_where_the_processor_is
    registers = @core.registers
    assert_includes 0x803B..0x803D, registers.fetch(:pc) & 0xFFFF
    refute registers.fetch(:e), "the cartridge put the processor in native mode"
  end

  def test_two_cores_are_two_consoles
    other = RubySNESEmulator::Core.new(HandMadeCartridge.write(Dir.mktmpdir, RED_BACKDROP.take(3) + [0x80, 0xFE]))
    other.run_frame
    refute_equal 0x1234, other.wram_read16(0x0100)
    assert_equal 0x1234, @core.wram_read16(0x0100)
  ensure
    other&.destroy
  end
end
