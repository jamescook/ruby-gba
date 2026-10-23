# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBC
        # WHAT A RUNNING COLOR CARTRIDGE PLAYED, said in the interpreter's words (Reference#audio):
        # sound switched on, a beep, a hit on the noise voice, the wave voice told to play or stop,
        # a song's notes, and the music stopped.
        #
        # Nothing is added to the cartridge to say so. The emulator records the processor each
        # time it reaches one of the runtime's sound routines (Core#record_arrivals), and what the
        # routine was handed says what it played: rt_sound_writes is handed the table of writes
        # one word of the game makes, and the build kept what each table is to the interpreter;
        # the music player's rt_music_note is handed the note it plays, in the music table the
        # build laid out (GBC::Music#notes), and at rt_music_note_voice it holds the volume the
        # voice is told. rt_music_quiet is every voice of the tune going quiet, which is the
        # interpreter's [:stop_music] when a tune was playing, and rt_music_from_the_top is a tune
        # starting.
        #
        # A song's notes are logged the way the interpreter's player logs a part on one of the
        # console's own voices (Reference::Player#play_song_frame): the note, the voice set, its
        # loudness when the game sets how loud the music is, and what the wave or noise voice is
        # doing.
        #
        # WHERE A PASS'S SOUNDS END. The interpreter moves the music on at the frame boundary after
        # a pass, before anything reads the frame (Reference#advance_frame), so what it has logged
        # at the end of pass N holds that boundary's notes. The cartridge's player plays them in the
        # screen's interrupt while the game waits, so a pass's log is read where the game takes up
        # its next pass, the wait over (rt_wait_vblank_buttons).
        class SoundLog
          # A new music level reaching a voice already sounding (Runtime::Music#emit_relevel), by
          # voice: B holds the voice's new loudness there.
          RELEVELS = (1..Runtime::Music::HELD_VOICES).to_h { |voice| ["rt_music_relevel_voice_#{voice}", voice] }.freeze

          ROUTINES = (%w[rt_sound_writes rt_music_note rt_music_note_voice rt_music_quiet rt_music_from_the_top
                         rt_wait_vblank_buttons] + RELEVELS.keys).freeze

          # +places+ is the build record (GBC::Places).
          def initialize(places)
            code = places.code
            @tables = places.sound_tables.to_h { |label, entry| [code.fetch(label).address, entry] }
            @notes = places.notes.each_with_object({}) do |(label, notes), at|
              start = code.fetch(label).address
              notes.each_with_index { |note, k| at[start + (k * Music::NOTE_BYTES)] = note }
            end
            @routines = ROUTINES.filter_map { |name| [code.fetch(name).address, name] if code.key?(name) }.to_h
            @follows_level = places.music_follows_level
            @entries = []
            @playing = false
            @passes = [] # how many entries the log held as each pass's wait ended
          end

          # Every entry so far, oldest first.
          attr_reader :entries

          # How many entries the log held at the end of pass +pass+ (counted from 1), the music of
          # the frame boundary after it included.
          def size_after_pass(pass) = @passes.fetch(pass - 1)

          # Whether the game makes any sound at all: a game that does not is not watched.
          def any? = !@tables.empty? || !@notes.empty?

          # The instructions the emulator records arrivals at.
          def addresses = @routines.keys

          # Reads +arrivals+ (Core#take_arrivals), oldest first, into the log.
          def read(arrivals)
            arrivals.each do |pc, _af, bc, _de, hl, _sp, _back, handed|
              case @routines[pc]
              when "rt_sound_writes" then @entries << @tables.fetch(handed)
              when "rt_music_note" then note_arrived(@notes.fetch(hl - 2)) # handed past the note's frame
              when "rt_music_note_voice" then voice_told(bc >> 8) if @note
              when "rt_music_quiet"
                @entries << [:stop_music] if @playing
                @playing = false
              when "rt_music_from_the_top" then @playing = true
              when "rt_wait_vblank_buttons" then @passes << @entries.size
              when *RELEVELS.keys then @entries << [:loudness, RELEVELS.fetch(@routines[pc]), bc >> 8]
              end
            end
            self
          end

          private

          # A note's entries, at once for music played at full, or once its loudness is known.
          def note_arrived(note)
            @note = note
            voice_told(nil) unless @follows_level
          end

          def voice_told(volume)
            note = @note
            @note = nil
            @entries << [:note, note.song, note.pitch]
            @entries << [:voice, note.voice, note.song, note.pitch, note.volume]
            @entries << [:loudness, note.voice, note.pitch.zero? ? 0 : volume] if volume
            kind = Tunes.part_kind(note.part)
            @entries << wave_or_noise(kind, note) if %i[wave noise].include?(kind)
          end

          # What the wave or noise voice is doing now, as Reference::Player#log_wave_or_noise says it.
          def wave_or_noise(kind, note)
            part = note.part
            if kind == :wave
              note.pitch.zero? ? [:stop_wave] : [:wave, { shape: part.wave, frequency: note.pitch, volume: part.volume }]
            else
              return [:noise, nil] if note.pitch.zero?

              [:noise, { pitch: note.pitch, decay: part.decay, volume: part.volume, metallic: part.metallic }]
            end
          end
        end
      end
    end
  end
end
