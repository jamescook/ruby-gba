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
        # A RECORDING PLAYED AT ANOTHER NOTE (`pitch:`) is read faster or slower by the interpreter, so
        # it is a clip of its own here, taken by the same walk at that note's step: a clip for each
        # recording and note the game plays.
        #
        # A RECORDING THAT LOOPS goes back to where it holds from (`holds_from`, or its start) at its
        # end, and the interpreter logs it each time round (Reference::Mixer#mix_voice). The timer
        # goes back to the byte of the clip the interpreter's walk is at there. Which frame it goes
        # round on is worked out apart from the sound, a frame at a time, by the same sum the
        # interpreter's walk does (Runtime::Clips#emit_lap), so the log says it on the same pass.
        #
        # Each clip is kept in a bank of the cartridge, a section of its own, and a table always in
        # view says where: its address, its bank, how many bytes it is, and which recording it is;
        # where the game loops one, where it goes back to and how many bytes are left from there,
        # and the three numbers of its laps (Laps).
        class Clips
          # What the recordings are to the author, for a cartridge too full for them.
          RECORDINGS = SM83::Holding.new(what: "the game's recordings",
                                         fix: "make its recordings shorter, or use fewer of them")

          # The table's label, and how many bytes an entry takes: the address, the bank, the count
          # and the recording; and in a game that loops one, the place it goes back to, the count
          # from there and its laps.
          TABLE = "clips"
          ENTRY_BYTES = 6
          LOOPING_ENTRY_BYTES = 6 + 4 + (3 * 5)

          # A LAP'S THREE NUMBERS, each five bytes, low byte first, in 65536ths of a sample of the
          # recording, as the interpreter's walk counts where it is (Sound::STEP_SHIFT): how far it
          # is from the end, less one, as it starts; how far it goes in a frame; and how far it goes
          # back at the end. The first falls below nought as the walk reaches the end.
          Laps = Data.define(:to_end, :a_frame, :back)
          LAP_BYTES = 5

          # The most bytes one clip is: a bank of the cartridge, which is all one section holds.
          MOST_BYTES = 0x4000

          # One recording at one note the game plays it at: the number its entry in the table has,
          # the number of the recording, its section's label, its bits, the byte it goes back to
          # when it loops, and its laps.
          Clip = Data.define(:name, :note, :number, :recording, :label, :bytes, :hold_byte, :laps)

          def initialize(program)
            declared = program.walk.select { |node| node.kind == :sample }.to_h { |node| [node.name, node] }
            plays = program.walk.select { |node| node.kind == :play_sample }
            @loops = plays.any?(&:loop)
            # The Color's clock, whichever console the program names: this is the Color's cartridge.
            @clock = Console::COLOR.sample_clock(Mixing.requested_rate(program)) unless plays.empty?
            @recordings = plays.map(&:name).uniq
            @own_notes = declared.transform_values { |sample| Assets::Sample.of(sample).note || :C4 }
            played = plays.map do |node|
              sample = declared.fetch(node.name) { raise LoweringError, "play_sample of undefined sample #{node.name.inspect}" }
              [sample, node.pitch || @own_notes.fetch(node.name)]
            end
            @clips = played.uniq { |sample, note| [sample.name, note] }.each_with_index.map do |(sample, note), number|
              clip_of(sample, note, number)
            end
            @clips.each { |clip| refuse_too_long!(clip) }
          end

          # The timer's count between two samples (Console::SampleClock#period, in the timer's steps).
          def timer_counts = @clock.period / Console::COLOR.sample_timer_step

          def any? = !@clips.empty?

          # Whether the game loops any recording: only then is a lap counted.
          def loops? = @loops

          # How many bytes an entry of the table takes.
          def entry_bytes = @loops ? LOOPING_ENTRY_BYTES : ENTRY_BYTES

          # The entry of the table for recording +name+ played at +pitch+ (its own note, for nil).
          def entry(name, pitch)
            note = pitch || @own_notes.fetch(name)
            @clips.find { |clip| clip.name == name && clip.note == note }.number
          end

          # The number the runtime knows recording +name+ by, at whichever note.
          def recording(name) = @recordings.index(name)

          # Each recording's name, by its number.
          def recordings = @recordings

          # Whether the game plays recording +name+ anywhere.
          def plays?(name) = @recordings.include?(name)

          # The table always in view, and a section in a bank for each clip.
          def sections
            table = SM83.new("clips", home: :fixed, holds: RECORDINGS)
            table.label(TABLE)
            @clips.each do |clip|
              table.data_words(clip.label)
              table.data_bank_of(clip.label)
              table.data_words(clip.bytes.bytesize)
              table.data_bytes(clip.recording)
              next unless @loops

              table.data_words("#{clip.label}_hold")
              table.data_words(clip.bytes.bytesize - clip.hold_byte)
              clip.laps.to_h.each_value { |number| table.data_bytes(Array.new(LAP_BYTES) { |k| (number >> (8 * k)) & 0xFF }) }
            end
            clips = @clips.map do |clip|
              asm = SM83.new(clip.label, home: :banked, holds: RECORDINGS)
              asm.label(clip.label)
              asm.bytes_of(clip.bytes.byteslice(0, clip.hold_byte))
              asm.label("#{clip.label}_hold")
              asm.bytes_of(clip.bytes.byteslice(clip.hold_byte..))
              asm.section
            end
            [table.section, *clips]
          end

          # +samples+ a bit each, the first in the top bit of the first byte: 1 for a sample at or above
          # the middle. The last byte is filled out with the bits for nought.
          def self.packed(samples)
            bits = samples.map { |sample| sample.negative? ? 0 : 1 }
            bits.each_slice(8).map { |eight| (eight + ([1] * (8 - eight.length))).inject(0) { |byte, bit| (byte << 1) | bit } }
                .pack("C*")
          end

          private

          # Recording +sample+ at +note+ as a clip: the samples the interpreter's mix reads of it at the
          # clock, in order, until its voice runs out (IR::Mixing.samples_read), a bit each. A loop
          # goes back the length it holds over, or the whole of it, as the interpreter's does
          # (Reference::Mixer#start); the clip goes back to the byte holding the first sample the walk
          # reads there.
          def clip_of(sample, note, number)
            info = Assets::Sample.of(sample)
            data = sample.bytes.unpack("c*")
            step = Mixing.step(info, VBlank::Audio::Music::NOTE_FREQUENCIES.fetch(note), @clock.rate)
            samples = Mixing.samples_read(data, step)
            back = info.loop_length.positive? ? info.loop_length : info.length
            hold = Mixing.samples_read(data.first(info.length - back), step).length
            shift = VBlank::Audio::Sound::STEP_SHIFT
            laps = Laps.new(to_end: (info.length << shift) - 1, a_frame: @clock.samples_a_frame * step, back: back << shift)
            Clip.new(name: sample.name, note: note, number: number, recording: @recordings.index(sample.name),
                     label: "clip_#{number}", bytes: self.class.packed(samples), hold_byte: hold / 8, laps: laps)
          end

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
