# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"

# Shared helpers for tests that exercise the emulator in-process. The emulator
# backend (gemba-core, a headless libmgba probe) is reached through
# RubyGBA::Emulator — the one seam — so nothing here names it directly.
#
# Include this in a test class instead of copy-pasting begin/require/rescue
# blocks or per-test availability guards.
module GembaSupport
  # Whether the in-process emulator core can be loaded — for the standalone
  # debug scripts that degrade gracefully. Suite tests use #require_gemba_core!,
  # which fails loud, since gemba-core is required, not optional.
  def self.gem_available?
    RubyGBA::Emulator.available?
  end

  # Ensure the emulator (gemba-core) is available, failing loudly if it isn't.
  # gemba-core is required to verify ROMs, so a missing build is a real error,
  # not a reason to silently skip and pass with the coverage gutted. `rake test`
  # builds it first; run `rake test:mgba` to build it by hand.
  def require_gemba_core!
    RubyGBA::Emulator.load!
  end

  # Lower an IR program to a finished ROM, the way the gemba tests need it — a
  # convenience over repeating ROM.assemble(GBA.new.lower(prog), title:, code:,
  # maker:) in every test. The header fields don't affect rendering, so they
  # default; pass +name+ just to label the ROM.
  def assemble_rom(program, name: "TEST")
    RubyGBA::ROM.assemble(RubyGBA::IR::Backends::GBA.new.lower(program),
                          title: name, code: "TEST", maker: "01")
  end

  # Load +rom+ into the emulator and run it headless for +frames+ frames,
  # asserting it loads and runs without raising. Fails loudly if gemba-core isn't
  # built (it's required). Returns a RubyGBA::Verifier so callers can make pixel
  # assertions on the rendered frame:
  #
  #   v = assert_gemba_loads_rom(rom, frames: 30)
  #   assert v.red?(120, 80)
  def assert_gemba_loads_rom(rom, frames: 10, **opts)
    require_gemba_core!
    verifier = RubyGBA::Verifier.new(rom, frames: frames, **opts)
    verifier.pixel(0, 0) # force the emulator to load the ROM and run the frames
    verifier
  rescue StandardError => e
    flunk "the emulator failed to load/run ROM after #{frames} frames: #{e.class}: #{e.message}"
  end
end
