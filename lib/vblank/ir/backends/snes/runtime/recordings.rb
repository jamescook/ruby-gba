# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # THE GAME'S OWN RECORDINGS (`play_sample`, `stop_sample`).
          #
          # The Advance's processor adds every recording a game plays into one stream, sixteen of them
          # at most, and the interpreter does the same sums (Reference::Mixer). The S-DSP needs none of
          # that: each recording plays on a voice of its own, read from the sound unit's memory
          # (Samples.recording). Four of its voices are free beside the four the Advance's own voices
          # take, so the first four of the sixteen places play there — voice 4 for the first, 7 for the
          # fourth — and a recording in a later place is counted and not heard.
          #
          # THE COUNT IS THE INTERPRETER'S. What the game can tell of a recording — the log saying it
          # came round again, its place coming free at its end — follows where it has got to, so each
          # place keeps that as the interpreter's mixer does: how far into the recording, in whole
          # samples and 65536ths, moved on once a frame by the samples a frame reads
          # (Console::SampleClock.on_voices), read back by its loop at its end, or freed.
          #
          # Each play the game writes is a row of the table "recording_plays" (Lowering::Sound): the
          # voice's source number, pitch and volume, the recording's length, how far back it reads at
          # its end (nought for one played once), how far it moves a frame, the number of its entry in
          # the sound log ([:sample, name]) and which recording it is.
          module Recordings
            PLACES = Audio::Sound::MIXER_VOICES
            VOICES_HEARD = 4
            FIRST_VOICE = 4

            # A play's row in the table, in bytes.
            SOURCE = 0
            PITCH = 2
            VOLUME = 4
            LENGTH = 6
            BACK = 10
            ADVANCE = 14
            ADVANCE_FRACTION = 18
            LOGGED = 20
            NAME = 22
            ROW_BYTES = 32

            # A place's state, PLACE_BYTES apart: which recording (its number plus one, nought when the
            # place is free), how far into it (whole samples, two words, and the fraction), and the
            # play's length, read-back, how far a frame and log entry, copied from its row.
            PLACES_STATE = "rt recordings places"
            HELD = 0
            POSITION = 2
            FRACTION = 6
            PLACE_LENGTH = 8
            PLACE_BACK = 12
            PLACE_ADVANCE = 16
            PLACE_ADVANCE_FRACTION = 20
            PLACE_LOGGED = 22
            PLACE_BYTES = 32

            # Where the row being played is, the place it takes, that place's voice's first register,
            # and which recording a stop names (or ALL) and its entry in the log.
            ROW = "rt recordings row"
            PLACE = "rt recordings place"
            REGISTERS = "rt recordings registers"
            STOP_NAME = "rt recordings stop name"
            STOP_LOGGED = "rt recordings stop logged"
            ALL = 0xFFFF

            module_function

            def reserve(memory)
              [ROW, PLACE, REGISTERS, STOP_NAME, STOP_LOGGED].each { |name| memory.reserve(name, 2) }
              memory.reserve(PLACES_STATE, PLACES * PLACE_BYTES)
            end

            def emit(asm, memory)
              at = ->(name, plus = 0) { asm.abs(memory[name], plus) }
              emit_play(asm, at, memory)
              emit_stop(asm, at, memory)
              emit_frame(asm, at, memory)
            end

            # rt_recordings_play(row): the play's entry logged, and the recording in the first free
            # place from its start (Reference::Mixer#start); with none free, nothing more. In one of
            # the first four places it starts on that place's voice.
            def emit_play(asm, at, memory)
              place = ->(field) { asm.abs_y(memory[PLACES_STATE], field) }
              row = ->(field) { asm.long_x("recording_plays", field) }
              asm.label("rt_recordings_play")
              asm.lda(asm.direct(Sound::R0))
              Music.emit_times(asm, ROW_BYTES)
              asm.sta(at.call(ROW))
              asm.tax
              asm.lda(row.call(LOGGED))
              asm.sta(asm.direct(Sound::R0))
              asm.jsl(asm.long("rt_sound_log"))
              asm.ldy(0)
              asm.label("rt_recordings_play_find")
              asm.lda(place.call(HELD))
              asm.beq("rt_recordings_play_found")
              asm.tya
              asm.clc
              asm.adc(PLACE_BYTES)
              asm.tay
              asm.cpy(PLACES * PLACE_BYTES)
              asm.bcc("rt_recordings_play_find")
              asm.rtl # every place busy: dropped, as the mixer drops it
              asm.label("rt_recordings_play_found")
              asm.sty(at.call(PLACE))
              asm.ldx(at.call(ROW))
              asm.lda(row.call(NAME))
              asm.inc
              asm.sta(place.call(HELD))
              asm.lda(0)
              [POSITION, POSITION + 2, FRACTION].each { |field| asm.sta(place.call(field)) }
              { LENGTH => PLACE_LENGTH, LENGTH + 2 => PLACE_LENGTH + 2, BACK => PLACE_BACK, BACK + 2 => PLACE_BACK + 2,
                ADVANCE => PLACE_ADVANCE, ADVANCE + 2 => PLACE_ADVANCE + 2, ADVANCE_FRACTION => PLACE_ADVANCE_FRACTION,
                LOGGED => PLACE_LOGGED }.each do |from, to|
                asm.lda(row.call(from))
                asm.sta(place.call(to))
              end
              # Its voice, for one of the first four places: the voice's registers, and key-on last.
              asm.lda(at.call(PLACE))
              asm.cmp(VOICES_HEARD * PLACE_BYTES)
              asm.bcc("rt_recordings_play_heard")
              asm.rtl
              asm.label("rt_recordings_play_heard")
              emit_registers(asm, at)
              voice = DSPWrites
              { voice::VOLUME_LEFT => VOLUME, voice::VOLUME_RIGHT => VOLUME, voice::PITCH_LOW => PITCH,
                voice::SOURCE => SOURCE }.each do |register, field|
                emit_voice_write(asm, at, register) do
                  asm.ldx(at.call(ROW))
                  asm.lda(row.call(field))
                end
              end
              emit_voice_write(asm, at, voice::PITCH_HIGH) do
                asm.ldx(at.call(ROW))
                asm.lda(row.call(PITCH))
                asm.xba
                asm.and_a(0xFF)
              end
              emit_voice_write(asm, at, voice::ADSR1) { asm.lda(voice::ADSR_OFF) }
              emit_voice_write(asm, at, voice::GAIN) { asm.lda(voice::FIXED_TOP) }
              emit_voice_bit(asm, at)
              asm.sta(asm.direct(Sound::R0))
              asm.stz(asm.direct(Sound::R1))
              asm.jsl(asm.long("rt_sound_key_off_bits")) # its key-off cleared...
              emit_voice_bit(asm, at)
              asm.sta(asm.direct(Sound::R1))
              asm.lda(voice::KEY_ON)
              asm.sta(asm.direct(Sound::R0))
              asm.jsl(asm.long("rt_sound_write")) # ...then key-on
              asm.rtl
            end

            # rt_recordings_stop(name, logged): every place playing recording +name+ (or every place,
            # for ALL) freed, a heard one's voice let go, and [:stop_sample] logged (Reference::Mixer#stop).
            def emit_stop(asm, at, memory)
              place = ->(field) { asm.abs_y(memory[PLACES_STATE], field) }
              asm.label("rt_recordings_stop")
              asm.lda(asm.direct(Sound::R0))
              asm.sta(at.call(STOP_NAME))
              asm.lda(asm.direct(Sound::R1))
              asm.sta(at.call(STOP_LOGGED))
              asm.stz(at.call(PLACE))
              asm.label("rt_recordings_stop_next")
              asm.ldy(at.call(PLACE))
              asm.lda(place.call(HELD))
              asm.beq("rt_recordings_stop_walk")
              asm.dec
              asm.ldx(at.call(STOP_NAME))
              asm.cpx(ALL)
              asm.beq("rt_recordings_stop_it")
              asm.cmp(at.call(STOP_NAME))
              asm.bne("rt_recordings_stop_walk")
              asm.label("rt_recordings_stop_it")
              asm.lda(0)
              asm.sta(place.call(HELD))
              asm.tya
              asm.cmp(VOICES_HEARD * PLACE_BYTES)
              asm.bcs("rt_recordings_stop_walk")
              emit_registers(asm, at)
              emit_voice_bit(asm, at)
              asm.sta(asm.direct(Sound::R0))
              asm.sta(asm.direct(Sound::R1))
              asm.jsl(asm.long("rt_sound_key_off_bits"))
              asm.label("rt_recordings_stop_walk")
              asm.lda(at.call(PLACE))
              asm.clc
              asm.adc(PLACE_BYTES)
              asm.sta(at.call(PLACE))
              asm.cmp(PLACES * PLACE_BYTES)
              asm.bcc("rt_recordings_stop_next")
              asm.lda(at.call(STOP_LOGGED))
              asm.sta(asm.direct(Sound::R0))
              asm.jml(asm.long("rt_sound_log"))
            end

            # rt_recordings_frame: each place playing moved on by a frame (Reference::Mixer#mix_voice):
            # the fraction, then the whole samples and what the fraction carried; past the recording's
            # end, back by its read-back as many times as it takes, logging each time round — or, for one
            # played once, the place freed.
            def emit_frame(asm, at, memory)
              place = ->(field) { asm.abs_y(memory[PLACES_STATE], field) }
              asm.label("rt_recordings_frame")
              asm.ldy(0)
              asm.label("rt_recordings_frame_place")
              asm.lda(place.call(HELD))
              asm.branch_long(:beq, "rt_recordings_frame_next")
              asm.clc
              asm.lda(place.call(FRACTION))
              asm.adc(place.call(PLACE_ADVANCE_FRACTION))
              asm.sta(place.call(FRACTION))
              asm.lda(place.call(POSITION))
              asm.adc(place.call(PLACE_ADVANCE))
              asm.sta(place.call(POSITION))
              asm.lda(place.call(POSITION + 2))
              asm.adc(place.call(PLACE_ADVANCE + 2))
              asm.sta(place.call(POSITION + 2))
              asm.label("rt_recordings_frame_end")
              asm.lda(place.call(POSITION + 2))
              asm.cmp(place.call(PLACE_LENGTH + 2))
              asm.bcc("rt_recordings_frame_next")
              asm.bne("rt_recordings_frame_past")
              asm.lda(place.call(POSITION))
              asm.cmp(place.call(PLACE_LENGTH))
              asm.bcc("rt_recordings_frame_next")
              asm.label("rt_recordings_frame_past")
              asm.lda(place.call(PLACE_BACK))
              asm.ora(place.call(PLACE_BACK + 2))
              asm.bne("rt_recordings_frame_back")
              asm.sta(place.call(HELD)) # played once, and over: A is nought
              asm.bra("rt_recordings_frame_next")
              asm.label("rt_recordings_frame_back")
              asm.sec
              asm.lda(place.call(POSITION))
              asm.sbc(place.call(PLACE_BACK))
              asm.sta(place.call(POSITION))
              asm.lda(place.call(POSITION + 2))
              asm.sbc(place.call(PLACE_BACK + 2))
              asm.sta(place.call(POSITION + 2))
              asm.lda(place.call(PLACE_LOGGED))
              asm.sta(asm.direct(Sound::R0))
              asm.phy
              asm.jsl(asm.long("rt_sound_log"))
              asm.ply
              asm.bra("rt_recordings_frame_end")
              asm.label("rt_recordings_frame_next")
              asm.tya
              asm.clc
              asm.adc(PLACE_BYTES)
              asm.tay
              asm.cpy(PLACES * PLACE_BYTES)
              asm.branch_long(:bcc, "rt_recordings_frame_place")
              asm.rts
            end

            # REGISTERS = the first register of the voice of the place at PLACE (one of the first four).
            def emit_registers(asm, at)
              asm.lda(at.call(PLACE))
              (PLACE_BYTES.bit_length - 1).times { asm.lsr } # the place's number: its offset over PLACE_BYTES
              asm.clc
              asm.adc(FIRST_VOICE)
              4.times { asm.asl }
              asm.sta(at.call(REGISTERS))
            end

            # A = the bit of the voice of the place at PLACE, in KON and KOFF.
            def emit_voice_bit(asm, at)
              asm.lda(at.call(PLACE))
              (PLACE_BYTES.bit_length - 1).times { asm.lsr }
              asm.tax
              asm.lda(1 << FIRST_VOICE)
              asm.label(label = "rt_recordings_bit_#{asm.here}")
              asm.cpx(0)
              asm.beq("#{label}_done")
              asm.asl
              asm.dex
              asm.bra(label)
              asm.label("#{label}_done")
            end

            # One write to register +register+ of the voice at REGISTERS, its value from the block (in A).
            def emit_voice_write(asm, at, register)
              yield
              asm.and_a(0xFF)
              asm.sta(asm.direct(Sound::R1))
              asm.lda(at.call(REGISTERS))
              asm.clc
              asm.adc(register)
              asm.sta(asm.direct(Sound::R0))
              asm.jsl(asm.long("rt_sound_write"))
            end
          end
        end
      end
    end
  end
end
