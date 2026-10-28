# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        # THE RECORDINGS THE SOUND UNIT PLAYS, in its own format, and the table that says where each
        # starts. The S-DSP plays nothing but recordings, kept in BRR, its packed format (fullsnes,
        # "SNES APU DSP BRR Samples"): blocks of nine bytes, a header byte and sixteen four-bit
        # samples. The header's top four bits are how far each sample is shifted up, the next two
        # a filter (nought: none, each sample as it is), and the low two what comes after the block
        # (nought: the next block; three: back to the loop point, for a recording that goes on).
        #
        # A square wave is the simplest thing to record: 32 samples a wave, high for so many of them
        # and low for the rest, in two blocks, the second looping back to the first. High is +7 and
        # low -7, shifted up 11 (each comes out as 7 * 2^11 / 2), well inside what the DSP can
        # decode without the overflow fullsnes warns of.
        #
        # The table has a four-byte row for each recording, by its source number: where it starts,
        # and where it loops back to, each a 16-bit address in the sound unit's memory.
        module Samples
          # How many of a wave's 32 samples are high, for each width (DSPWrites::SHAPES's order):
          # an eighth, a quarter, a half and three quarters, as the Advance's square voices have them.
          SQUARE_HIGH = [4, 8, 16, 24].freeze

          WAVE_SAMPLES = 32
          BLOCK_SAMPLES = 16
          SHIFT = 11
          HIGH = 7
          LOW = -7
          LOOP = 3 # the end of a recording, looped back to its loop point
          ROW = 4  # a table row: start, loop

          module_function

          # The recordings as BRR bytes, in source-number order.
          def squares = SQUARE_HIGH.map { |high| square(high) }

          # One wave of a square +high+ samples high, as two BRR blocks, the second looping.
          def square(high)
            samples = Array.new(WAVE_SAMPLES) { |i| i < high ? HIGH : LOW }
            samples.each_slice(BLOCK_SAMPLES).each_with_index.flat_map do |block, index|
              flags = index == (WAVE_SAMPLES / BLOCK_SAMPLES) - 1 ? LOOP : 0
              [(SHIFT << 4) | flags] + block.each_slice(2).map { |first, second| ((first & 0xF) << 4) | (second & 0xF) }
            end
          end

          # The table and the recordings after it, as bytes for +at+ in the sound unit's memory: a
          # row for each recording (its start and its loop point, both its first byte) and then the
          # recordings themselves.
          def image(at)
            recordings = squares
            start = at + (recordings.size * ROW)
            rows = recordings.map do |bytes|
              row = [start & 0xFF, start >> 8] * 2
              start += bytes.size
              row
            end
            (rows + recordings).flatten
          end
        end
      end
    end
  end
end
