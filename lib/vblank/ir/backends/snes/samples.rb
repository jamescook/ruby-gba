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
        # A square wave is the simplest thing to record: so many samples a wave, high for some of them
        # and low for the rest, looping back to the start. High is +7 and low -7, shifted up 11 (each
        # comes out as 7 * 2^11 / 2), well inside what the DSP can decode without the overflow
        # fullsnes warns of.
        #
        # EACH WIDTH IS RECORDED TWICE. The pitch register reads a recording at most four times as
        # fast as the DSP plays (fullsnes, "SNES APU DSP BRR Pitch": $3FFF is the fastest), so a
        # wave of 32 samples tops out near 4000 Hz. A wave of 32 holds its width finely, an eighth
        # of it high being four samples; a wave of 8 reaches 16000 Hz, the highest note the DSP's
        # 32000 samples a second can make at all, and holds an eighth as one sample. A note is
        # played on the long one when it can be, and the short one above that (DSPWrites).
        #
        # The table has a four-byte row for each recording, by its source number: where it starts,
        # and where it loops back to, each a 16-bit address in the sound unit's memory.
        module Samples
          # The widths, in the order of their source numbers: an eighth, a quarter, a half and three
          # quarters of each wave high, as the Advance's square voices have them (Audio::Sound's
          # SQUARE_HIGH_EIGHTHS), :square being another name for a half.
          WIDTHS = { eighth: 1, quarter: 2, half: 4, three_quarter: 6 }.freeze
          NAMES = { square: :half }.freeze

          # The two lengths of wave, in samples: the long one for most notes, the short for high ones.
          LONG_WAVE = 32
          SHORT_WAVE = 8

          BLOCK_SAMPLES = 16
          SHIFT = 11
          HIGH = 7
          LOW = -7
          LOOP = 3 # the end of a recording, looped back to its loop point
          ROW = 4  # a table row: start, loop

          module_function

          # THE METALLIC RATTLE. The Advance's noise voice can step a register of seven bits instead of
          # fifteen, whose pattern comes round every 127 steps: a tighter, more tonal noise. The S-DSP's
          # noise generator has no such mode, so the pattern is recorded, a sample a step, high where
          # a 1 falls out of the register (GBATEK, "GBA Sound Channel 4": X = X SHR 1, and on a 1, X =
          # X XOR $60, from $40). 127 does not divide into blocks of sixteen, so the recording is the
          # pattern sixteen times over, 127 whole blocks, the last looping back to the first.
          METALLIC_STEPS = 127
          METALLIC_START = 0x40
          METALLIC_TAP = 0x60

          # Its source number: after the long and the short square recordings.
          METALLIC = WIDTHS.size * 2

          # The source number of the recording of +width+, a wave of +wave+ samples: the long waves
          # first, then the short ones.
          def source(width, wave)
            index = WIDTHS.keys.index(NAMES.fetch(width, width)) or raise ArgumentError, "no square width #{width.inspect}"
            wave == LONG_WAVE ? index : WIDTHS.size + index
          end

          # The recordings as BRR bytes, in source-number order.
          def recordings
            [LONG_WAVE, SHORT_WAVE].flat_map { |wave| WIDTHS.values.map { |eighths| square(wave, eighths) } } + [metallic]
          end

          # Square waves of +wave+ samples, +eighths+ eighths of each high, filling whole BRR blocks
          # (a short wave is repeated to fill one), the last block looping back to the first.
          def square(wave, eighths)
            high = wave * eighths / 8
            looped(Array.new([wave, BLOCK_SAMPLES].max) { |i| (i % wave) < high ? HIGH : LOW })
          end

          # The seven-bit noise pattern, sixteen times round.
          def metallic
            x = METALLIC_START
            steps = Array.new(METALLIC_STEPS) do
              out = x & 1
              x >>= 1
              x ^= METALLIC_TAP if out == 1
              out == 1 ? HIGH : LOW
            end
            looped(steps * BLOCK_SAMPLES)
          end

          # +samples+ (a whole number of blocks' worth, each -8..7) as BRR blocks, the last looping
          # back to the first.
          def looped(samples)
            blocks = samples.each_slice(BLOCK_SAMPLES).to_a
            blocks.each_with_index.flat_map do |block, index|
              flags = index == blocks.size - 1 ? LOOP : 0
              [(SHIFT << 4) | flags] + block.each_slice(2).map { |first, second| ((first & 0xF) << 4) | (second & 0xF) }
            end
          end

          # The table and the recordings after it, as bytes for +at+ in the sound unit's memory: a
          # row for each recording (its start and its loop point, both its first byte) and then the
          # recordings themselves.
          def image(at)
            all = recordings
            start = at + (all.size * ROW)
            rows = all.map do |bytes|
              row = [start & 0xFF, start >> 8] * 2
              start += bytes.size
              row
            end
            (rows + all).flatten
          end
        end
      end
    end
  end
end
