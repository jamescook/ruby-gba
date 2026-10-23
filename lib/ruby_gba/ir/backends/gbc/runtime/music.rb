# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBC
        module Runtime
          # THE MUSIC PLAYER, which runs in the frame's interrupt — once for every frame the
          # screen shows, however long the game's passes take — as the Advance's does: the game
          # only names a tune (rt_music_play) or stops it (rt_music_stop), and the player
          # walks each part's notes (GBC::Music) a frame at a time, writing each note into its
          # voice's registers as its frame comes.
          #
          # How loud a note sounds is its own volume times the music's level — the game's
          # `music_volume`, kept in a variable of the game's (IR::Tunes::LEVEL) — read as the note
          # starts. A game that never says how loud the music is plays it at full.
          #
          # It runs between any two instructions of the game, so it keeps every register, uses
          # nothing the game's code uses, and reads only the part of the cartridge always in view.
          module Music
            NAMED = "rt music named" # the tune the game named last, 1 up (0 for none)
            PLAYING = "rt music playing" # the tune playing, 1 up
            START = "rt music start" # 1 when the named tune is to start at the next frame
            FRAME = "rt music frame" # 16 bits: the frame of the tune about to play
            AGAIN = "rt music again" # 1 once the tune has come round
            SONG = "rt music song" # where the playing tune is in the music table
            NEXT = "rt music next" # each part's next note, 16 bits each
            PART = "rt music part" # the part being played: its voice, its tone, how many notes, where they are
            PARTS = 4
            # WHAT EACH VOICE IS HOLDING, for a new music level to reach it: the volume its note was
            # written at (0 for a rest), for the two square voices and the wave voice; and for the
            # two square voices, which take a volume only as a note starts and so are sounded again,
            # the note's tuning and duty. A drum hit on the noise voice rings and fades by itself,
            # so it is not held. LEVEL_SET is the level the held notes were set at, kept as the
            # level with its 16s bit turned over, so a memory that starts at nought says full.
            HELD = "rt music held"
            TUNINGS = "rt music tunings"
            DUTIES = "rt music duties"
            LEVEL_SET = "rt music level set"
            NOTE_VOLUME = "rt music note volume" # the note being played's volume, as written
            HELD_VOICES = 3

            # A square part's first register, by voice.
            SQUARE_REGISTERS = { 1 => Console::GBCHardware::NR11, 2 => Console::GBCHardware::NR21 }.freeze

            module_function

            def reserve(memory)
              memory.reserve(NAMED, 1)
              memory.reserve(PLAYING, 1)
              memory.reserve(START, 1)
              memory.reserve(FRAME, 2)
              memory.reserve(AGAIN, 1)
              memory.reserve(SONG, 2)
              memory.reserve(NEXT, PARTS * 2)
              memory.reserve(PART, 6)
              memory.reserve(HELD, HELD_VOICES)
              memory.reserve(TUNINGS, 4)
              memory.reserve(DUTIES, 2)
              memory.reserve(LEVEL_SET, 1)
              memory.reserve(NOTE_VOLUME, 1)
            end

            # +level+ is where the game keeps the music's level, or nil for a game that never sets it.
            # +songs+ says whether the game has any songs at all.
            def emit(asm, memory, level:, songs:)
              emit_game_side(asm, memory)
              return emit_no_songs(asm) unless songs

              emit_tick(asm, memory, level)
              emit_notes(asm, memory, level)
            end

            # rt_music_play(song): start it at the next frame, unless it is the one named
            # already, which carries on. rt_music_stop(): no tune, and the voices quiet.
            def emit_game_side(asm, memory)
              asm.label("rt_music_play")
              asm.load_hl_sp(2)
              asm.load(:a, [:hl])
              asm.inc(:a)
              asm.load(:hl, memory[NAMED])
              asm.cp_a([:hl])
              asm.ret(:z)
              asm.di # the player must not read the two halves of this
              asm.load([:hl], :a)
              asm.load(:a, 1)
              asm.load([memory[START]], :a)
              asm.reti

              asm.label("rt_music_stop")
              asm.di
              asm.xor_a(:a)
              asm.load([memory[NAMED]], :a)
              asm.load([memory[START]], :a)
              asm.call("rt_music_quiet")
              asm.xor_a(:a)
              asm.load([memory[PLAYING]], :a)
              asm.reti
            end

            def emit_no_songs(asm)
              asm.label("rt_music_tick")
              asm.label("rt_music_quiet")
              asm.ret
            end

            def emit_tick(asm, memory, level)
              h = Console::GBCHardware
              asm.label("rt_music_tick")
              asm.load(:a, [memory[START]])
              asm.and_a(:a)
              asm.jump_relative(:z, "rt_music_tick_playing")
              asm.xor_a(:a)
              asm.load([memory[START]], :a)
              asm.call("rt_music_quiet")
              asm.load(:a, [memory[NAMED]])
              asm.load([memory[PLAYING]], :a)
              asm.and_a(:a)
              asm.ret(:z)
              asm.dec(:a) # where the tune is: music_songs + 2 × its number
              asm.add_a(:a)
              asm.load(:l, :a)
              asm.load(:h, 0)
              asm.load(:de, "music_songs")
              asm.add_hl(:de)
              asm.load(:a, [:hli])
              asm.load([memory[SONG]], :a)
              asm.load(:a, [:hl])
              asm.load([memory[SONG] + 1], :a)
              asm.load(:hl, memory[FRAME])
              asm.xor_a(:a)
              asm.load([:hli], :a)
              asm.load([:hl], :a)
              asm.call("rt_music_from_the_top")
              asm.load(:a, 0)
              asm.load_high(h::NR10, :a) # no sweep on the first square voice
              asm.call("rt_music_waveform")
              asm.label("rt_music_tick_playing")
              asm.load(:a, [memory[PLAYING]])
              asm.and_a(:a)
              asm.ret(:z)
              # A new level reaches the notes already sounding before any new note is played, which
              # is the order the interpreter does it in (Reference::Player#play_song_frame).
              asm.call("rt_music_relevel") if level
              # Every part: each note whose frame this is.
              asm.call("rt_music_song")
              asm.inc(:hl)
              asm.inc(:hl)
              asm.inc(:hl)
              asm.inc(:hl)
              asm.inc(:hl)
              asm.load(:b, [:hl]) # how many parts
              asm.inc(:hl)
              asm.load(:c, 0)
              asm.label("rt_music_tick_part")
              asm.load(:a, :b)
              asm.and_a(:a)
              asm.jump_relative(:z, "rt_music_tick_parts_done")
              asm.push(:bc)
              asm.push(:hl)
              asm.call("rt_music_part")
              asm.pop(:hl)
              asm.load(:de, 10)
              asm.add_hl(:de)
              asm.pop(:bc)
              asm.inc(:c)
              asm.dec(:b)
              asm.jump_relative("rt_music_tick_part")
              asm.label("rt_music_tick_parts_done")
              # The next frame; at the end, round to the loop point, or quiet for a tune that ends.
              asm.load(:hl, memory[FRAME])
              asm.inc([:hl])
              asm.jump_relative(:nz, "rt_music_tick_counted")
              asm.inc(:hl)
              asm.inc([:hl])
              asm.label("rt_music_tick_counted")
              asm.call("rt_music_song")
              asm.load(:a, [memory[FRAME]])
              asm.cp_a([:hl])
              asm.ret(:nz)
              asm.inc(:hl)
              asm.load(:a, [memory[FRAME] + 1])
              asm.cp_a([:hl])
              asm.ret(:nz)
              asm.inc(:hl)
              asm.load(:e, [:hl])
              asm.inc(:hl)
              asm.load(:d, [:hl])
              asm.inc(:hl)
              asm.load(:a, [:hl])
              asm.and_a(:a)
              asm.jump_relative(:z, "rt_music_tick_round")
              asm.call("rt_music_quiet") # a tune that plays once: over
              asm.xor_a(:a)
              asm.load([memory[PLAYING]], :a)
              asm.ret
              asm.label("rt_music_tick_round")
              asm.load(:a, :e)
              asm.load([memory[FRAME]], :a)
              asm.load(:a, :d)
              asm.load([memory[FRAME] + 1], :a)
              asm.load(:a, 1)
              asm.load([memory[AGAIN]], :a)
              asm.jump("rt_music_next_cleared")

              # HL = the playing tune's place in the music table.
              asm.label("rt_music_song")
              asm.load(:a, [memory[SONG]])
              asm.load(:l, :a)
              asm.load(:a, [memory[SONG] + 1])
              asm.load(:h, :a)
              asm.ret

              asm.label("rt_music_from_the_top")
              asm.xor_a(:a)
              asm.load([memory[AGAIN]], :a)
              asm.label("rt_music_next_cleared")
              asm.xor_a(:a)
              asm.load(:hl, memory[NEXT])
              (PARTS * 2).times { asm.load([:hli], :a) }
              asm.ret

              # The wave part's waveform into the wave voice, with the voice off while it is written.
              asm.label("rt_music_waveform")
              asm.call("rt_music_song")
              5.times { asm.inc(:hl) }
              asm.load(:b, [:hl])
              asm.inc(:hl)
              asm.label("rt_music_waveform_part")
              asm.load(:a, :b)
              asm.and_a(:a)
              asm.ret(:z)
              asm.load(:a, [:hli])
              asm.cp_a(GBC::Music::WAVE_VOICE)
              asm.jump_relative(:z, "rt_music_waveform_found")
              asm.load(:de, 9)
              asm.add_hl(:de)
              asm.dec(:b)
              asm.jump_relative("rt_music_waveform_part")
              asm.label("rt_music_waveform_found")
              asm.load(:a, [:hl]) # its waveform: music_waves + 16 × its number
              asm.swap(:a)
              asm.load(:e, :a)
              asm.load(:d, 0)
              asm.load(:hl, "music_waves")
              asm.add_hl(:de)
              asm.xor_a(:a)
              asm.load_high(h::NR30, :a)
              asm.load(:c, h::WAVE_RAM & 0xFF)
              asm.label("rt_music_waveform_byte")
              asm.load(:a, [:hli])
              asm.load_high([:c], :a)
              asm.inc(:c)
              asm.load(:a, :c)
              asm.cp_a((h::WAVE_RAM + 16) & 0xFF)
              asm.jump_relative(:nz, "rt_music_waveform_byte")
              asm.ret

              # Every voice the tune plays on, quiet, and holding nothing.
              asm.label("rt_music_quiet")
              asm.xor_a(:a)
              [h::NR12, h::NR22, h::NR30, h::NR42].each { |register| asm.load_high(register, :a) }
              HELD_VOICES.times { |i| asm.load([memory[HELD] + i], :a) }
              asm.load(:a, 0x80)
              [h::NR14, h::NR24, h::NR44].each { |register| asm.load_high(register, :a) }
              asm.ret
            end

            # One part (HL = its entry, C = its number): each of its notes whose frame has come.
            def emit_notes(asm, memory, level)
              h = Console::GBCHardware
              part = memory[PART]
              asm.label("rt_music_part")
              asm.load(:a, [:hli])
              asm.load([part], :a) # the voice
              asm.load(:a, [:hli])
              asm.load([part + 1], :a) # the tone
              asm.load(:a, [memory[AGAIN]])
              asm.and_a(:a)
              asm.jump_relative(:z, "rt_music_part_pass")
              asm.inc(:hl)
              asm.inc(:hl)
              asm.label("rt_music_part_pass")
              asm.load(:a, [:hli])
              asm.load([part + 2], :a) # how many notes this time round
              asm.load(:a, [:hld])
              asm.load([part + 3], :a)
              4.times { asm.inc(:hl) }
              asm.load(:a, [:hli])
              asm.load([part + 4], :a) # where they are
              asm.load(:a, [:hl])
              asm.load([part + 5], :a)
              asm.load(:a, :c) # HL = this part's next note's number
              asm.add_a(:a)
              asm.add_a(memory[NEXT] & 0xFF)
              asm.load(:l, :a)
              asm.load(:a, memory[NEXT] >> 8)
              asm.adc_a(0)
              asm.load(:h, :a)
              asm.label("rt_music_part_note")
              asm.load(:a, [:hli])
              asm.load(:e, :a)
              asm.load(:a, [:hld])
              asm.load(:d, :a) # DE = the next note's number
              asm.load(:a, [part + 2])
              asm.cp_a(:e)
              asm.jump_relative(:nz, "rt_music_part_more")
              asm.load(:a, [part + 3])
              asm.cp_a(:d)
              asm.ret(:z) # no more notes this time round
              asm.label("rt_music_part_more")
              asm.push(:hl)
              asm.load(:h, :d) # HL = where the notes are + 5 × the number
              asm.load(:l, :e)
              asm.add_hl(:hl)
              asm.add_hl(:hl)
              asm.add_hl(:de)
              asm.load(:a, [part + 4])
              asm.load(:e, :a)
              asm.load(:a, [part + 5])
              asm.load(:d, :a)
              asm.add_hl(:de)
              # Its frame not come yet: done for this frame.
              asm.load(:a, [memory[FRAME]])
              asm.cp_a([:hl])
              asm.jump_relative(:nz, "rt_music_part_later")
              asm.inc(:hl)
              asm.load(:a, [memory[FRAME] + 1])
              asm.cp_a([:hl])
              asm.jump_relative(:nz, "rt_music_part_later")
              asm.inc(:hl)
              asm.call("rt_music_note")
              # One note on, and the part done for this frame: a part plays one note a frame, as the
              # interpreter's does (Reference::Player#play_song_frame), so a second note written on
              # the same frame never plays, and holds back the rest of the part.
              asm.pop(:hl)
              asm.inc([:hl])
              asm.ret(:nz)
              asm.inc(:hl)
              asm.inc([:hl])
              asm.ret
              asm.label("rt_music_part_later")
              asm.pop(:hl)
              asm.ret

              # The note at HL — its tuning, then its volume — on the part's voice.
              asm.label("rt_music_note")
              asm.load(:a, [:hli])
              asm.load(:e, :a)
              asm.load(:a, [:hli])
              asm.load(:d, :a)
              asm.load(:b, [:hl]) # its volume, times the music's level over 16
              asm.load(:a, :b)
              asm.load([memory[NOTE_VOLUME]], :a)
              if level
                asm.call("rt_music_level")
                asm.call("rt_music_scale")
                asm.load(:b, :a)
              end
              # B = the volume the voice is told, DE = its tuning. A run of the cartridge reads the
              # note's loudness here (GBC::SoundLog).
              asm.label("rt_music_note_voice")
              asm.call("rt_music_hold")
              asm.load(:a, [part])
              asm.cp_a(GBC::Music::WAVE_VOICE)
              asm.jump_relative(:z, "rt_music_note_wave")
              asm.cp_a(GBC::Music::NOISE_VOICE)
              asm.jump_relative(:z, "rt_music_note_noise")
              # A square voice: its duty, its volume, its period, and start.
              asm.cp_a(1)
              asm.load(:c, h::NR11 & 0xFF)
              asm.jump_relative(:z, "rt_music_note_square")
              asm.load(:c, h::NR21 & 0xFF)
              asm.label("rt_music_note_square")
              asm.load(:a, [part + 1])
              asm.load_high([:c], :a)
              asm.inc(:c)
              rest_or_volume(asm, "square")
              asm.load_high([:c], :a)
              asm.inc(:c)
              asm.load(:a, :e)
              asm.load_high([:c], :a)
              asm.inc(:c)
              asm.load(:a, :d)
              asm.and_a(7)
              asm.or_a(0x80)
              asm.load_high([:c], :a)
              asm.ret

              asm.label("rt_music_note_wave")
              asm.load(:a, :d)
              asm.and_a(:e)
              asm.inc(:a)
              asm.jump_relative(:nz, "rt_music_note_wave_on")
              asm.load_high(h::NR30, :a) # a rest: the voice off
              asm.ret
              asm.label("rt_music_note_wave_on")
              asm.load(:a, 0x80)
              asm.load_high(h::NR30, :a)
              asm.load(:a, :b)
              asm.load(:hl, "rt_music_wave_levels")
              asm.add_a(:l)
              asm.load(:l, :a)
              asm.load(:a, :h)
              asm.adc_a(0)
              asm.load(:h, :a)
              asm.load(:a, [:hl])
              asm.load_high(h::NR32, :a)
              asm.load(:a, :e)
              asm.load_high(h::NR33, :a)
              asm.load(:a, :d)
              asm.and_a(7)
              asm.or_a(0x80)
              asm.load_high(h::NR34, :a)
              asm.ret

              asm.label("rt_music_note_noise")
              rest_or_volume(asm, "noise")
              asm.load(:c, :a)
              asm.load(:a, [part + 1])
              asm.and_a(7) # the fade
              asm.or_a(:c)
              asm.load_high(h::NR42, :a)
              asm.load(:a, [part + 1])
              asm.and_a(0x80) # the metallic hiss
              asm.rrca
              asm.rrca
              asm.rrca
              asm.rrca
              asm.or_a(:e)
              asm.load_high(h::NR43, :a)
              asm.load(:a, 0x80)
              asm.load_high(h::NR44, :a)
              asm.ret

              emit_hold(asm, memory, part)
              emit_relevel(asm, memory, level) if level

              # The volume a voice is told, in its top four bits: none for a rest.
              asm.label("rt_music_wave_levels")
              asm.data_bytes((0..15).map { |volume| WAVE_LEVEL_CODES.fetch(RubyGBA::Audio::Sound.wave_level(volume)) })
            end

            # The wave voice's loudness for each of Audio::Sound's levels, as its register has it;
            # the Advance's three-quarters, which the Color does not have, is full.
            WAVE_LEVEL_CODES = { mute: 0x00, quarter: 0x60, half: 0x40, three_quarter: 0x20, full: 0x20 }.freeze

            # rt_music_hold: the note being played (DE its tuning, NOTE_VOLUME its volume) is what its
            # voice holds now, a rest holding nothing. Keeps B and DE.
            def emit_hold(asm, memory, part)
              asm.label("rt_music_hold")
              asm.load(:a, :d)
              asm.and_a(:e)
              asm.inc(:a) # nought for a rest
              asm.load(:a, [memory[NOTE_VOLUME]])
              asm.jump_relative(:nz, "rt_music_hold_volume")
              asm.xor_a(:a)
              asm.label("rt_music_hold_volume")
              asm.load(:c, :a)
              asm.load(:a, [part])
              (1..HELD_VOICES).each do |voice|
                asm.cp_a(voice)
                asm.jump_relative(:z, "rt_music_hold_#{voice}")
              end
              asm.ret
              (1..HELD_VOICES).each do |voice|
                asm.label("rt_music_hold_#{voice}")
                asm.load(:a, :c)
                asm.load([memory[HELD] + voice - 1], :a)
                if voice < GBC::Music::WAVE_VOICE
                  asm.load(:a, :e)
                  asm.load([memory[TUNINGS] + ((voice - 1) * 2)], :a)
                  asm.load(:a, :d)
                  asm.load([memory[TUNINGS] + ((voice - 1) * 2) + 1], :a)
                  asm.load(:a, [part + 1])
                  asm.load([memory[DUTIES] + voice - 1], :a)
                end
                asm.ret
              end
            end

            # THE MUSIC LEVEL MOVED: every voice holding a note takes the new level, as
            # Reference::Player#apply_music_volume does. A square voice takes a volume only as a note
            # starts, so its note is started again at the new volume; the wave voice takes one while
            # it plays. A run of the cartridge reads each voice's new loudness at
            # rt_music_relevel_voice_N (GBC::SoundLog).
            #
            # rt_music_level: C = the level the game keeps, below nought taken as nought and above 16
            # as 16. rt_music_scale: A = the volume B times the level C, over 16; keeps BC.
            def emit_relevel(asm, memory, level)
              h = Console::GBCHardware
              asm.label("rt_music_level")
              asm.load(:a, [level + 3])
              asm.bit(7, :a)
              asm.load(:c, 0)
              asm.ret(:nz)
              asm.load(:hl, level + 1)
              asm.or_a([:hl])
              asm.inc(:hl)
              asm.or_a([:hl])
              asm.load(:c, IR::Tunes::FULL_LEVEL)
              asm.ret(:nz)
              asm.load(:a, [level])
              asm.cp_a(IR::Tunes::FULL_LEVEL)
              asm.ret(:nc)
              asm.load(:c, :a)
              asm.ret

              asm.label("rt_music_scale")
              asm.push(:bc)
              asm.xor_a(:a)
              asm.inc(:c)
              asm.jump_relative("rt_music_scale_next")
              asm.label("rt_music_scale_add")
              asm.add_a(:b)
              asm.label("rt_music_scale_next")
              asm.dec(:c)
              asm.jump_relative(:nz, "rt_music_scale_add")
              asm.swap(:a)
              asm.and_a(0x0F)
              asm.pop(:bc)
              asm.ret

              asm.label("rt_music_relevel")
              asm.call("rt_music_level")
              asm.load(:a, [memory[LEVEL_SET]])
              asm.xor_a(IR::Tunes::FULL_LEVEL)
              asm.cp_a(:c)
              asm.ret(:z)
              asm.load(:a, :c)
              asm.xor_a(IR::Tunes::FULL_LEVEL)
              asm.load([memory[LEVEL_SET]], :a)
              squares = { 1 => [h::NR11, h::NR12, h::NR13, h::NR14], 2 => [h::NR21, h::NR22, h::NR23, h::NR24] }
              (1..HELD_VOICES).each do |voice|
                asm.load(:a, [memory[HELD] + voice - 1])
                asm.and_a(:a)
                asm.jump_relative(:z, "rt_music_relevel_past_#{voice}")
                asm.load(:b, :a)
                asm.call("rt_music_scale")
                asm.load(:b, :a)
                asm.label("rt_music_relevel_voice_#{voice}")
                if (registers = squares[voice])
                  duty, volume, low, high = registers
                  asm.load(:a, [memory[DUTIES] + voice - 1])
                  asm.load_high(duty, :a)
                  asm.load(:a, :b)
                  asm.swap(:a)
                  asm.and_a(0xF0)
                  asm.load_high(volume, :a)
                  asm.load(:a, [memory[TUNINGS] + ((voice - 1) * 2)])
                  asm.load_high(low, :a)
                  asm.load(:a, [memory[TUNINGS] + ((voice - 1) * 2) + 1])
                  asm.and_a(7)
                  asm.or_a(0x80)
                  asm.load_high(high, :a)
                else
                  asm.load(:a, :b)
                  asm.load(:hl, "rt_music_wave_levels")
                  asm.add_a(:l)
                  asm.load(:l, :a)
                  asm.load(:a, :h)
                  asm.adc_a(0)
                  asm.load(:h, :a)
                  asm.load(:a, [:hl])
                  asm.load_high(h::NR32, :a)
                end
                asm.label("rt_music_relevel_past_#{voice}")
              end
              asm.ret
            end

            # A = the volume (B) in the top four bits, or nought for a rest (DE = REST).
            def rest_or_volume(asm, voice)
              asm.load(:a, :d)
              asm.and_a(:e)
              asm.inc(:a)
              asm.jump_relative(:z, "rt_music_#{voice}_rest")
              asm.load(:a, :b)
              asm.swap(:a)
              asm.and_a(0xF0)
              asm.jump_relative("rt_music_#{voice}_said")
              asm.label("rt_music_#{voice}_rest")
              asm.xor_a(:a)
              asm.label("rt_music_#{voice}_said")
            end
          end
        end
      end
    end
  end
end
