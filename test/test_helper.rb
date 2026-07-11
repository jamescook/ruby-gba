# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"

# Shared helpers for tests that exercise the gemba emulator in-process.
#
# Include this in a test class instead of copy-pasting begin/require/rescue
# blocks or per-test availability guards.
module GembaSupport
  # Whether the in-process gemba Core can be loaded. Memoized: the require is
  # attempted once per run.
  def self.gem_available?
    return @gem_available unless @gem_available.nil?
    @gem_available =
      begin
        require "gemba/core"  # Ruby class shell
        require "gemba_ext"   # C extension with the real methods
        true
      rescue LoadError
        false
      end
  end

  # Skip the current test unless the in-process gemba emulator is available.
  def skip_unless_gemba
    skip "gemba not available (gem install gemba)" unless GembaSupport.gem_available?
  end

  # Load +rom+ into gemba and run it headless for +frames+ frames, asserting it
  # loads and runs without raising. Skips when gemba isn't installed. Returns a
  # RubyGBA::Verifier so callers can make pixel assertions on the rendered frame:
  #
  #   v = assert_gemba_loads_rom(rom, frames: 30)
  #   assert v.red?(120, 80)
  def assert_gemba_loads_rom(rom, frames: 10)
    skip_unless_gemba
    verifier = RubyGBA::Verifier.new(rom, frames: frames)
    verifier.pixel(0, 0) # force gemba to load the ROM and run the frames
    verifier
  rescue StandardError => e
    flunk "gemba failed to load/run ROM after #{frames} frames: #{e.class}: #{e.message}"
  end
end
