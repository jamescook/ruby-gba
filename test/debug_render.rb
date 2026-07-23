#!/usr/bin/env ruby
# frozen_string_literal: true

# Diagnostic script: builds simple ROMs and dumps their instruction
# bytes to verify ARM encoding is correct.

require_relative "../lib/ruby_gba"
require_relative "test_helper"

def hex_dump(buffer, offset, count)
  count.times.map { |i|
    byte = buffer.getbyte(offset + i)
    byte ? format("%02X", byte) : ".."
  }.each_slice(4).map { |group| group.join }.join(" ")
end

def dump_instructions(buffer, offset, num_instructions)
  num_instructions.times do |i|
    addr = offset + i * 4
    break if addr + 4 > buffer.bytesize
    word = buffer[addr, 4].unpack1("V")
    bytes = buffer[addr, 4].bytes.map { |b| format("%02X", b) }.join(" ")
    puts "  0x#{format('%04X', addr)}: #{bytes}  (0x#{format('%08X', word)})"
  end
end

# ============================================================
# Test A: Just set display mode
# Expected: MOV r0, #3 / ORR r0, r0, #0x0400 / MOV r1, #0x04000000 / STRH r0,[r1] / HALT
# ============================================================
puts "=== Test A: Display mode only ==="
rom = RubyGBA.build("DISPONLY", code: "BTST", maker: "01") do
  screen :bitmap
  halt
end

puts "Code at 0xC0:"
dump_instructions(rom.buffer, 0xC0, 10)
puts
puts RubyGBA::Inspector.from_rom(rom).code_report(max_instructions: 10)
puts

# Verify manually:
# screen :bitmap → value = MODE_3 | BG2_ENABLE = 0x0003 | 0x0400 = 0x0403
# emit_write_reg16(0x04000000, 0x0403)
#   load_immediate(0, 0x0403) →
#     i=0: byte=0x03, rot=0 → MOV r0, #3         = 0xE3A00003
#     i=1: byte=0x04, rot=12 → ORR r0, r0, #0xC04 = 0xE3800C04
#   load_immediate(1, 0x04000000) →
#     encode_rotated_immediate → rot=4, imm8=0x04 → 0xE3A01401 ... wait
#   store_halfword(0, 1) → 0xE1C100B0

puts "Expected:"
puts "  MOV r0, #0x03        → 0xE3A00003"
puts "  ORR r0, r0, #0x0400  → 0xE3800C04"
puts "  MOV r1, #0x04000000  → 0xE3A01404"
puts "  STRH r0, [r1]        → 0xE1C100B0"
puts "  B self (halt)        → 0xEAFFFFFE"
puts

# Wait, let me compute the MOV r1, #0x04000000 encoding properly
# 0x04000000: encode_rotated_immediate finds rot=4, imm8=0x04
# So imm12 = (4 << 8) | 0x04 = 0x0404
# MOV r1, #imm = 0xE3A00000 | (1 << 12) | 0x0404 = 0xE3A01404
# Verify: 0x04 ROR (4*2) = 0x04 ROR 8 = 0x04000000 ✓

# ============================================================
# Test B: Single red pixel at center
# ============================================================
puts "=== Test B: Red pixel at (120, 80) ==="
rom = RubyGBA.build("REDPIX", code: "BTST", maker: "01") do
  screen :bitmap
  pixel 120, 80, :red
  halt
end

puts "Code at 0xC0:"
dump_instructions(rom.buffer, 0xC0, 20)
puts
puts RubyGBA::Inspector.from_rom(rom).code_report(max_instructions: 20)
puts

# pixel address: VRAM_START + (80*240 + 120)*2 = 0x06000000 + 38640 = 0x060096F0
puts "Expected pixel address: 0x#{format('%08X', 0x06000000 + (80 * 240 + 120) * 2)}"
puts "Expected color (red): 0x#{format('%04X', 0x001F)}"
puts

# ============================================================
# Test C: Big visible rectangle (easier to spot)
# ============================================================
puts "=== Test C: Large blue rectangle (80x60 centered) ==="
rom = RubyGBA.build("BIGRECT", code: "BTST", maker: "01") do
  screen :bitmap
  fill_rect 80, 50, 80, 60, :blue
  halt
end

rom.write("/tmp/debug_bigrect.gba")
puts "ROM size: #{rom.size} bytes"
puts "First 6 instructions:"
dump_instructions(rom.buffer, 0xC0, 6)
puts
puts RubyGBA::Inspector.from_rom(rom).code_report(max_instructions: 10)
puts

# ============================================================
# Test D: Multiple large color blocks
# ============================================================
puts "=== Test D: Three large color blocks ==="
rom = RubyGBA.build("BLOCKS", code: "BTST", maker: "01") do
  screen :bitmap
  fill_rect 10, 10, 60, 60, :red
  fill_rect 90, 10, 60, 60, :green
  fill_rect 170, 10, 60, 60, :blue
  halt
end

rom.write("/tmp/debug_blocks.gba")
puts "ROM size: #{rom.size} bytes"
puts "Wrote /tmp/debug_blocks.gba"
puts

# ============================================================
# Run in gemba (in-process)
# ============================================================
if GembaSupport.gem_available?
  ["/tmp/debug_bigrect.gba", "/tmp/debug_blocks.gba"].each do |path|
    puts "Running #{path} in gemba for 100 frames..."
    core = Gemba::Core.new(path)
    100.times { core.run_frame }
    core.destroy
    puts "OK"
    puts "-" * 40
  end
else
  puts "gemba not available — skipping run (gem install gemba)"
end
