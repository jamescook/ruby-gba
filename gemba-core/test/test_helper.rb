# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"

# gemba-core's tests build real GBA ROMs with ruby-gba (which lives one level
# up in this repo) and run them through the headless core. That doubles as an
# end-to-end smoke test of the whole stack: DSL → ROM → libmgba → probe.
require_relative "../../lib/ruby_gba"
require_relative "../lib/gemba_core"

module GembaCoreTestSupport
  # Tempfiles are held for the life of the process so the ROM on disk outlives
  # the Probe that loads it (and never gets GC'd out from under a running test).
  ROM_TEMPFILES = []

  # Build a ROM from a ruby-gba DSL block and return the path to it on disk.
  #
  #   path = build_rom("RED") { screen :bitmap; clear_screen :red; game_loop { wait_vblank } }
  #   probe = GembaCore.open(path)
  def build_rom(name = "TEST", code: "TEST", maker: "01", &block)
    rom = RubyGBA.build(name, code: code, maker: maker, &block)
    tf = Tempfile.new([name.downcase, ".gba"])
    tf.binmode
    rom.write(tf.path)
    tf.flush
    ROM_TEMPFILES << tf # keep it alive
    tf.path
  end

  # A plain red full-screen ROM — the workhorse fixture for pixel/read tests.
  def red_rom
    build_rom("RED", code: "TRED") do
      screen :bitmap
      clear_screen :red
      game_loop { wait_vblank }
    end
  end

  # Open a probe on a fresh fixture ROM and hand it to the block, closing it
  # afterward. Returns the block's value.
  def with_probe(path)
    probe = GembaCore.open(path)
    yield probe
  ensure
    probe&.close
  end
end
