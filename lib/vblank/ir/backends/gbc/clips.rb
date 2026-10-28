# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBC
        # THE GAME'S RECORDINGS, as a Color plays them: a bit a sample, eight to a byte.
        #
        # A Color has no hardware that plays recorded sound, and a processor too slow to add one up
        # as the Advance's mixer does. What it has is the wave voice, whose loudness can be set at
        # any moment: full, or nothing. So a recording is played the way the Color's own games play
        # their voice clips — the voice turned full on or full off for each sample, by the timer,
        # thousands of times a second (Runtime::Clips). Each sample is the one bit of whether it
        # stands above the middle or below it. The sound is rough, and the words are clear.
        #
        # THE BITS ARE THE INTERPRETER'S OWN READING. The interpreter's mix reads a recording at
        # the console's sample clock (Console::SampleClock, 133 samples a frame on a Color), a
        # step of the recording at a time, which rolls the rate it was recorded at against the
        # clock's (IR::Mixing.step). The clip is made by taking that same walk through it here,
        # one sample of the clip for each sample the interpreter mixes, so the clip lasts the
        # frames the interpreter's voice does and comes out at the pitch it was recorded at.
        #
        # Each recording the game plays is kept in a bank of the cartridge, a section of its own,
        # and a table always in view says where: its address, its bank, and how many bytes it is.
        class Clips
          # What the recordings are to the author, for a cartridge too full for them.
          RECORDINGS = SM83::Holding.new(what: "the game's recordings",
                                         fix: "make its recordings shorter, or use fewer of them")

          # The table's label, and how many bytes an entry takes: the address, the bank, the count.
          TABLE = "clips"
          ENTRY_BYTES = 5

          # The most bytes one clip is: a bank of the cartridge, which is all one section holds.
          MOST_BYTES = 0x4000

          # One recording the game plays: the number the runtime knows it by, its section's label and
          # its bits.
          Clip = Data.define(:name, :number, :label, :bytes)

          def initialize(program)
            declared = program.walk.select { |node| node.kind == :sample }.to_h { |node| [node.name, node] }
            played = program.walk.select { |node| node.kind == :play_sample }.map(&:name).uniq
            # The Color's clock, whichever console the program names: this is the Color's cartridge.
            @clock = Console::COLOR.sample_clock(Mixing.requested_rate(program)) unless played.empty?
            @clips = played.each_with_index.map do |name, number|
              node = declared.fetch(name) { raise LoweringError, "play_sample of undefined sample #{name.inspect}" }
              Clip.new(name: name, number: number, label: "clip_#{number}", bytes: self.class.packed(samples_at_clock(node)))
            end
            @clips.each { |clip| refuse_too_long!(clip) }
          end

          # The timer's count between two samples (Console::SampleClock#period, in the timer's steps).
          def timer_counts = @clock.period / Console::COLOR.sample_timer_step

          def any? = !@clips.empty?

          # The number the runtime knows recording +name+ by.
          def number(name) = @clips.find { |clip| clip.name == name }.number

          # Whether the game plays recording +name+ anywhere.
          def plays?(name) = @clips.any? { |clip| clip.name == name }

          # The table always in view, and a section in a bank for each clip.
          def sections
            table = SM83.new("clips", home: :fixed, holds: RECORDINGS)
            table.label(TABLE)
            @clips.each do |clip|
              table.data_words(clip.label)
              table.data_bank_of(clip.label)
              table.data_words(clip.bytes.bytesize)
            end
            clips = @clips.map do |clip|
              asm = SM83.new(clip.label, home: :banked, holds: RECORDINGS)
              asm.label(clip.label)
              asm.bytes_of(clip.bytes)
              asm.section
            end
            [table.section, *clips]
          end

          # The samples the interpreter's mix reads of +node+ at the clock, in order, until its voice
          # runs out (IR::Mixing.samples_read), at the note it was recorded at.
          def samples_at_clock(node)
            info = Assets::Sample.of(node)
            step = Mixing.step(info, VBlank::Audio::Music::NOTE_FREQUENCIES.fetch(info.note || :C4), @clock.rate)
            Mixing.samples_read(node.bytes.unpack("c*"), step)
          end

          # +samples+ a bit each, the first in the top bit of the first byte: 1 for a sample at or above
          # the middle. The last byte is filled out with the bits for nought.
          def self.packed(samples)
            bits = samples.map { |sample| sample.negative? ? 0 : 1 }
            bits.each_slice(8).map { |eight| (eight + ([1] * (8 - eight.length))).inject(0) { |byte, bit| (byte << 1) | bit } }
                .pack("C*")
          end

          private

          def refuse_too_long!(clip)
            return if clip.bytes.bytesize <= MOST_BYTES

            seconds = (clip.bytes.bytesize * 8.0 / @clock.rate).round(1)
            most = (MOST_BYTES * 8.0 / @clock.rate).round(1)
            raise LoweringError, "the recording #{clip.name.inspect} plays for #{seconds} seconds, and a Game Boy Color " \
                                 "plays a recording of #{most} seconds at most. To fix this, make the recording shorter."
          end
        end
      end
    end
  end
end
