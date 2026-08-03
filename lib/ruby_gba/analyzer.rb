# frozen_string_literal: true

module RubyGBA
  # Measures a built ROM's real per-frame cost on the emulator — the "analyze" half of
  # the cost tooling, opposite the static estimate in {IR::CostModel}. It runs the ROM
  # and reads how many of a frame's ~228 scanlines the CPU actually burns, which is the
  # measured number the static estimate can only guess at.
  module Analyzer
    module_function

    # A full frame is 228 scanlines; work past that can't finish before the next frame,
    # so the frame rate drops. The emulator's busy measurement caps and wobbles as it
    # nears this ceiling, so a reading that high means "saturated", not an exact count.
    FRAME_SCANLINES = 228
    SATURATED = 200       # at or above this, the CPU is effectively maxed for the frame
    SETTLE = 8            # frames to run before reading, so the game reaches steady state

    Result = Data.define(:scanlines) do
      def saturated?
        scanlines >= SATURATED
      end

      def percent
        (scanlines * 100.0 / FRAME_SCANLINES).round
      end
    end

    # Measure +rom_path+ on the emulator. Runs the ROM to a settled frame and reads the
    # busy scanlines a frame burns, taking the smallest of a few reads (the quietest,
    # least-noisy sample). Returns a {Result}.
    def measure(rom_path)
      probe = Emulator.probe(rom_path)
      scanlines = 3.times.map { probe.busy_scanlines(settle: SETTLE) }.min
      Result.new(scanlines: scanlines)
    ensure
      probe&.close
    end
  end
end
