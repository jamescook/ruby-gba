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
          BLOCK_BYTES = 9
          SHIFT = 11
          HIGH = 7
          LOW = -7
          LOWEST = -8 # the lowest a sample's nibble holds
          HIGHEST = 7 # ...and the highest
          LOOP = 3 # the end of a recording, looped back to its loop point
          END_ONLY = 1 # the end of a recording played once
          ROW = 4  # a table row: start, loop
          MOST_RANGE = 12 # the largest shift a block takes before fullsnes's decoding goes wrong
          BYTE_TO_SAMPLE = 256 # a byte of a game's recording, as the Advance's mix reads it (see #recording)

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

          # THE WAVE VOICE'S WAVEFORMS, which are the game's own: 32 steps of 0 to 15 each (Audio::
          # Sound.wavetable), at the loudness the game plays it (each step already cut down as the
          # Advance cuts it). Each is recorded as it is, a step a sample, less its own average (to the
          # nearest whole step), so the wave swings about nought at every loudness — a quiet wave's
          # steps are small, and taking a fixed eight off them would hold it far under nought, and a
          # muted one would be a flat level that clicks as it starts and stops. Two blocks, looping
          # back to the first, after every recording above, in the order the game's build lists them
          # (DSPWrites.wave_steps).
          FIRST_WAVE = METALLIC + 1

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

          # One of the game's waveforms, +steps+ (32 of 0 to 15), as a looped recording about nought:
          # less its average, or as near it as keeps every step inside what a sample holds (-8..7),
          # which a lopsided waveform at full, a narrow pulse, cannot be centred and still fit. Its
          # steps are never more than 15 apart, so some offset always fits.
          def wave(steps)
            middle = Rational(steps.sum, steps.size).round.clamp(steps.max - HIGH, steps.min - LOWEST)
            looped(steps.map { |step| step - middle })
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

          # A GAME'S OWN RECORDING, +bytes+ (a byte a sample, -128..127), as BRR, and how far into it
          # its loop point is, in bytes. The Advance's mix reads a recording's byte as a sample of
          # sixteen bits times 256; here each is kept as that over two, decoding as the byte times 128
          # (fullsnes: a four-bit sample comes out shifted left by its block's range and right by
          # one), so a recording at its loudest is as loud as a beep at 15. Each block's range is the
          # least that keeps its samples inside four bits (four bits a sample is all the filter
          # nought keeps; fullsnes's other filters, which predict a sample from the two before it,
          # would keep more and are not used).
          #
          # ONE THAT GOES ON reads back +back+ samples at its end (Assets::Sample#loop_length). The
          # DSP loops only by whole blocks from a block's start, so the samples after the loop point
          # are moved round until the loop starts on a block, and the loop is repeated until it fills
          # whole blocks: the same sound, a block or two longer. One played once ends on its last
          # block, the rest of which is silence.
          def recording(bytes, back)
            samples = bytes.unpack("c*")
            return [brr_blocks(samples, ending: END_ONLY), 0] if back.zero?

            intro = samples[0, samples.size - back]
            loop = samples.last(back)
            turn = (BLOCK_SAMPLES - (intro.size % BLOCK_SAMPLES)) % BLOCK_SAMPLES
            intro += loop.cycle.take(turn)
            loop = loop.rotate(turn % back) * (BLOCK_SAMPLES / BLOCK_SAMPLES.gcd(back))
            [brr_blocks(intro, ending: 0) + brr_blocks(loop, ending: LOOP), intro.size / BLOCK_SAMPLES * BLOCK_BYTES]
          end

          # +samples+ (bytes, padded with silence to whole blocks) as BRR blocks, each at the least range
          # that keeps it, the last ending with +ending+.
          def brr_blocks(samples, ending:)
            blocks = samples.each_slice(BLOCK_SAMPLES).map { |block| block + Array.new(BLOCK_SAMPLES - block.size, 0) }
            blocks.each_with_index.flat_map do |block, index|
              wide = block.map { |sample| sample * BYTE_TO_SAMPLE }
              range = (0..MOST_RANGE).find { |r| wide.all? { |value| (value >> r).between?(LOWEST, HIGHEST) } }
              nibbles = wide.map { |value| value >> range }
              [(range << 4) | (index == blocks.size - 1 ? ending : 0)] +
                nibbles.each_slice(2).map { |first, second| ((first & 0xF) << 4) | (second & 0xF) }
            end
          end

          # The table and the recordings after it, as bytes for +at+ in the sound unit's memory: a
          # row for each recording (its start and its loop point) and then the recordings themselves,
          # the game's +waves+ (each 32 steps) and then its own +recordings+ (#recording's pairs) last.
          def image(at, waves = [], recordings = [])
            all = self.recordings.map { |bytes| [bytes, 0] } + waves.map { |steps| [wave(steps), 0] } + recordings
            start = at + (all.size * ROW)
            rows = all.map do |bytes, loop_at|
              row = [start & 0xFF, start >> 8, (start + loop_at) & 0xFF, (start + loop_at) >> 8]
              start += bytes.size
              row
            end
            (rows + all.map(&:first)).flatten
          end
        end
      end
    end
  end
end
