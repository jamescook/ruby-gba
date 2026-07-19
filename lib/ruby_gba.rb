# frozen_string_literal: true

require_relative "ruby_gba/version"
require_relative "ruby_gba/constants"
require_relative "ruby_gba/color"
require_relative "ruby_gba/sound"
require_relative "ruby_gba/asm"
require_relative "ruby_gba/ir"
require_relative "ruby_gba/doctor"
require_relative "ruby_gba/rom"
require_relative "ruby_gba/font"
require_relative "ruby_gba/music"
require_relative "ruby_gba/builder"
require_relative "ruby_gba/inspector"
require_relative "ruby_gba/test_patterns"
require_relative "ruby_gba/verifier"

module RubyGBA
  class ROMError < StandardError; end
  # Build a GBA ROM using the DSL.
  #
  # @param title [String] Game title (up to 12 chars)
  # @param code [String] 4-char game code (e.g. "BTKE")
  # @param maker [String] 2-char maker code (e.g. "01")
  # @param doctor [Boolean] run Doctor validation after build (default: true)
  # @return [RubyGBA::ROM] finalized ROM ready to write
  def self.build(title, code:, maker:, doctor: true, &block)
    rom = ROM.new(title: title, code: code, maker: maker)
    builder = Builder.new(rom)
    catch(:debug_halt) do
      builder.instance_eval(&block)
    end
    unless builder.debug_halted?
      builder.emit_pending_functions
      builder.process_dump_requests
    end
    rom.finalize!(doctor: builder.debug_halted? ? false : doctor)
    rom
  end
end
