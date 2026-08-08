# frozen_string_literal: true

require "tempfile"
require_relative "../../gemba-core/lib/gemba_core"

module RubyGBA
  module Calibration
    # The one place calibration touches the emulator: a ROM in, scanlines out.
    #
    # Everything else in here builds ROMs or does arithmetic, so putting the emulator behind
    # one small object is what lets the rest be tested without it (see {FakeMeasurer}).
    #
    # TWO CLOCKS, because a frame's work happens in two places. #busy is the cycles the CPU
    # actually executed. #stall is the time a transfer engine held the CPU frozen while it
    # copied — real work in the frame that the CPU never executed, so the busy count cannot
    # see it. A weight wants whichever of those its op spends its cost in, and #total for an
    # op that spends it in both.
    #
    # Each reading is taken three times and the SMALLEST kept. A frame that overruns wobbles
    # (the reading saturates near 228 and then depends on where the previous frame left off),
    # so the minimum is the one closest to the clean sub-frame cost — and the warnings below
    # say when a reading is close enough to the ceiling that no amount of re-reading helps.
    class Measurer
      FRAME_SCANLINES = 228
      NEAR_CEILING = 200 # a reading this high is not safely inside one frame any more
      WOBBLE = 1.0       # spread between re-reads that says the frame is not settling
      READS = 3

      def initialize(settle: 8, warn_to: $stderr)
        @settle = settle
        @warn_to = warn_to
        @roms = [] # tempfiles, kept alive until this measurer is done with
      end

      # Scanlines of CPU the frame burns.
      def busy(name, rom)
        smallest(name, rom) { |probe| probe.busy_scanlines(settle: @settle) }
      end

      # Scanlines the CPU spent frozen while a transfer engine worked.
      def stall(name, rom)
        smallest(name, rom) { |probe| probe.frame_cost(settle: @settle).dma_scanlines }
      end

      # Both, added: everything the frame cost whether the CPU executed it or waited on it.
      # One probe rather than two, so it costs the same as either alone.
      def total(name, rom)
        with_probe(name, rom) do |probe|
          least(name, READS.times.map { probe.busy_scanlines(settle: @settle) }) +
            READS.times.map { probe.frame_cost(settle: @settle).dma_scanlines }.min
        end
      end

      private

      def smallest(name, rom, &read)
        with_probe(name, rom) { |probe| least(name, READS.times.map { read.call(probe) }) }
      end

      def least(name, reads)
        if reads.max - reads.min > WOBBLE
          @warn_to.puts "  ! #{name}: unstable reads #{reads.map { |r| r.round(1) }} (frame overflow?)"
        end
        if reads.min > NEAR_CEILING
          @warn_to.puts "  ! #{name}: #{reads.min.round(1)} scanlines — near the #{FRAME_SCANLINES} frame ceiling"
        end
        reads.min
      end

      def with_probe(name, rom)
        file = Tempfile.new([name.downcase, ".gba"])
        file.binmode
        rom.write(file.path)
        file.flush
        @roms << file # a closed tempfile is deleted, and the probe still holds the path
        probe = GembaCore.open(file.path)
        begin
          yield probe
        ensure
          probe.close
        end
      end
    end
  end
end
