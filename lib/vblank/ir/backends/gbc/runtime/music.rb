# frozen_string_literal: true

module VBlank
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
            # ...and how it slides its pitch, in a game where a note does (GBC::Music.note_bytes).
            NOTE_SLIDE = "rt music note slide"
            HELD_VOICES = 3
            # The waveform in the wave voice, 1 up, in a game with sound effects: a song's part and an
            # effect's can each sound in their own, so a note puts its own in when it is not there.
            WAVE_LOADED = "rt music wave loaded"

            # A square part's first register, by voice.
            SQUARE_REGISTERS = { 1 => Console::GBCHardware::NR11, 2 => Console::GBCHardware::NR21 }.freeze

            module_function

            def reserve(memory, effects: [], slides: false, wobbles: false)
              reserve_song_player(memory)
              memory.reserve(WAVE_LOADED, 1) unless effects.empty?
              memory.reserve(NOTE_SLIDE, 1) if slides
              memory.reserve(WOBBLES, WOBBLE_BYTES * WOBBLE_VOICES) if wobbles
              Effects.reserve(memory, effects)
            end

            # A NOTE A VOICE WOBBLES, in a game where a note does, for each of the two square voices
            # and the wave voice (IR::Tunes::Wobble steps it): its depth and speed (Audio::Vibrato#bits'
            # low byte; no depth holds still), the frames still to wait, the frames the swing it is in
            # has left, 1 while that swing is the one above, the steps it moves the pitch by (below
            # nought for the swing below), and the note's own pitch, low byte first. Eight bytes a
            # voice, so a voice's are found by a shift.
            WOBBLES = "rt music wobbles"
            WOBBLE_BYTES = 8
            WOBBLE_VOICES = 3
            WOBBLE_WAIT = 1
            WOBBLE_LEFT = 2
            WOBBLE_RISING = 3
            WOBBLE_STEPS = 4
            WOBBLE_PITCH = 5

            def wobbles?(memory) = memory.reserved?(WOBBLES)

            def reserve_song_player(memory)
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
            # +songs+ says whether the game has any songs at all; +effects+ are its sound effects
            # (GBC::Music#effects), and +by_rank+ the same in the order a frame plays them. +fades+
            # says whether any note says how it fades or swells (GBC::Music#fades?), and +slides+
            # whether any slides its pitch (GBC::Music#slides?). Whether any wobbles is whether its
            # place was reserved (#wobbles?).
            def emit(asm, memory, level:, songs:, effects: [], by_rank: [], fades: false, slides: false)
              sharing = !effects.empty?
              emit_game_side(asm, memory, sharing)
              return emit_no_songs(asm) unless songs

              bytes = GBC::Music.note_bytes(slides, wobbles?(memory))
              emit_tick(asm, memory, level, sharing)
              emit_notes(asm, memory, level, sharing, fades, slides, bytes)
              emit_wobbles(asm, memory) if wobbles?(memory)
              Effects.emit(asm, memory, effects, by_rank, slides: slides, bytes: bytes) if sharing
            end

            # HL = HL × +bytes+, the bytes a note takes (GBC::Music.note_bytes), with DE its number too:
            # a doubling for each of the number's bits after its first and an adding of DE for each
            # that is set — five a note is twice, twice and add. Spends DE's number into HL.
            def emit_times_note_bytes(asm, bytes)
              bytes.to_s(2).chars.drop(1).each do |bit|
                asm.add_hl(:hl)
                asm.add_hl(:de) if bit == "1"
              end
            end

            # The slide of the note whose volume is at HL, kept for rt_voice_write: the byte after the
            # volume, in a game where a note slides. And in one where a note wobbles, the voice set
            # to wobble the note from the two after that (rt_wobble_start). Keeps B and DE.
            def emit_store_slide_and_vibrato(asm, memory, slides)
              if slides
                asm.inc(:hl)
                asm.load(:a, [:hl])
                asm.load([memory[NOTE_SLIDE]], :a)
              end
              return unless wobbles?(memory)

              asm.inc(:hl)
              asm.call("rt_wobble_start")
            end

            # THE WOBBLE, in a game where a note does (Audio::Vibrato says what it is, IR::Tunes::Wobble
            # how it steps, and every backend steps it the same way).
            #
            # rt_wobble_start: the note just written to the part's voice ([PART]) is the one it
            # wobbles — HL at the note's vibrato, DE its tuning — or, saying none, it holds still. The
            # hiss has no pitch to wobble. Keeps BC and DE.
            #
            # rt_wobble_step: every wobbling voice moved on, the voices in order, at the end of the
            # interrupt's frame. Once its wait is over a voice's pitch is written every frame, its
            # note's own moved by its steps and never past the voice's ends, without starting the
            # note again — so a held note the music level started again this frame, at its own
            # pitch, is back where its wobble has it before the frame is heard. A run of the
            # cartridge reads each turn to the other side at rt_wobble_turned_N, where A holds the
            # steps it turns to (GBC::SoundLog).
            def emit_wobbles(asm, memory)
              h = Console::GBCHardware
              asm.label("rt_wobble_start")
              asm.load(:a, [memory[PART]])
              asm.cp_a(WOBBLE_VOICES + 1)
              asm.ret(:nc)
              asm.push(:bc)
              asm.load(:c, [:hl]) # its depth and speed
              asm.inc(:hl)
              asm.load(:b, [:hl]) # its wait
              asm.dec(:a) # HL = this voice's wobble: WOBBLES + its place × WOBBLE_BYTES
              3.times { asm.add_a(:a) }
              asm.add_a(memory[WOBBLES] & 0xFF)
              asm.load(:l, :a)
              asm.load(:a, memory[WOBBLES] >> 8)
              asm.adc_a(0)
              asm.load(:h, :a)
              asm.load(:a, :c)
              asm.load([:hli], :a)
              asm.load(:a, :b)
              asm.load([:hli], :a)
              asm.xor_a(:a)
              3.times { asm.load([:hli], :a) } # nothing left of a swing, none of them yet, no steps
              asm.load(:a, :e)
              asm.load([:hli], :a)
              asm.load(:a, :d)
              asm.and_a(7) # the pitch, without the fade above it
              asm.load([:hl], :a)
              asm.pop(:bc)
              asm.ret

              asm.label("rt_wobble_step")
              pitches = { 1 => [h::NR13, h::NR14], 2 => [h::NR23, h::NR24], 3 => [h::NR33, h::NR34] }
              (1..WOBBLE_VOICES).each do |voice|
                at = memory[WOBBLES] + ((voice - 1) * WOBBLE_BYTES)
                still = "rt_wobble_still_#{voice}"
                waited = "rt_wobble_waited_#{voice}"
                holding = "rt_wobble_holding_#{voice}"
                low, high = pitches.fetch(voice)
                asm.load(:a, [at])
                asm.load(:c, :a) # its depth and speed
                asm.and_a(0x0F)
                asm.jump_relative(:z, still)
                asm.load(:hl, at + WOBBLE_WAIT)
                asm.load(:a, [:hl])
                asm.and_a(:a)
                asm.jump_relative(:z, waited)
                asm.dec([:hl])
                asm.jump_relative(still)

                asm.label(waited)
                asm.inc(:hl) # its swing's frames left
                asm.load(:a, [:hl])
                asm.and_a(:a)
                asm.jump_relative(:nz, holding)
                # The swing ran out: to the other side, above first, for the vibrato's speed in frames.
                asm.load(:a, :c)
                asm.swap(:a)
                asm.and_a(0x0F)
                asm.inc(:a) # the speed is kept less one
                asm.load([:hli], :a)
                asm.load(:a, [:hl])
                asm.xor_a(1)
                asm.load([:hli], :a)
                asm.load(:b, :a) # 1 for the swing above
                asm.load(:a, :c)
                asm.and_a(0x0F) # the depth
                asm.bit(0, :b)
                asm.jump_relative(:z, "rt_wobble_below_#{voice}")
                asm.inc(:a) # above: half the depth, rounded up
                asm.srl(:a)
                asm.jump_relative("rt_wobble_turned_#{voice}")
                asm.label("rt_wobble_below_#{voice}")
                asm.srl(:a) # below: the other half, under nought
                asm.cpl
                asm.inc(:a)
                asm.label("rt_wobble_turned_#{voice}")
                asm.load([:hld], :a)
                asm.dec(:hl) # back at its swing's frames left
                asm.label(holding)
                asm.dec([:hl])
                # Its pitch: the note's own plus its steps, never under nought or over the top.
                asm.inc(:hl)
                asm.inc(:hl)
                asm.load(:a, [:hli]) # the steps
                asm.load(:c, :a)
                asm.load(:b, 0)
                asm.bit(7, :a)
                asm.jump_relative(:z, "rt_wobble_up_#{voice}")
                asm.dec(:b)
                asm.label("rt_wobble_up_#{voice}")
                asm.load(:a, [:hli])
                asm.add_a(:c)
                asm.load(:e, :a)
                asm.load(:a, [:hl])
                asm.adc_a(:b)
                asm.load(:d, :a)
                asm.bit(7, :d)
                asm.jump_relative(:z, "rt_wobble_not_under_#{voice}")
                asm.load(:de, 0)
                asm.label("rt_wobble_not_under_#{voice}")
                asm.load(:a, :d)
                asm.cp_a(8)
                asm.jump_relative(:c, "rt_wobble_within_#{voice}")
                asm.load(:de, 0x07FF)
                asm.label("rt_wobble_within_#{voice}")
                asm.load(:a, :e)
                asm.load_high(low, :a)
                asm.load(:a, :d)
                asm.load_high(high, :a) # no start bit: the note carries on
                asm.label(still)
              end
              asm.ret
            end

            # Voice +voice+ quiet: its volume nothing, and a square or noise voice started again so
            # that it takes it — and, in a game where a note wobbles, wobbling nothing.
            def emit_silence(asm, memory, voice)
              if wobbles?(memory) && voice <= WOBBLE_VOICES
                asm.xor_a(:a)
                asm.load([memory[WOBBLES] + ((voice - 1) * WOBBLE_BYTES)], :a)
              end
              h = Console::GBCHardware
              volume, start = { 1 => [h::NR12, h::NR14], 2 => [h::NR22, h::NR24], 3 => [h::NR30, nil],
                                4 => [h::NR42, h::NR44] }.fetch(voice)
              asm.xor_a(:a)
              asm.load_high(volume, :a)
              return unless start

              asm.load(:a, 0x80)
              asm.load_high(start, :a)
            end

            # rt_music_play(song): start it at the next frame, unless it is the one named
            # already, which carries on. rt_music_stop(): no tune, and the voices quiet.
            def emit_game_side(asm, memory, sharing)
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

              # rt_music_play_now(song): the same, and a tune that is starting takes its first frame
              # here, where the game names it (`this_frame: true`, Reference::Player#start_song_here):
              # the player is run once now, with the interrupt held off, as it would run at the frame.
              # The sound effects are not moved on: they had this frame already.
              asm.label("rt_music_play_now")
              asm.load_hl_sp(2)
              asm.load(:e, [:hl])
              asm.push(:de)
              asm.call("rt_music_play")
              asm.pop(:de)
              asm.load(:a, [memory[START]])
              asm.and_a(:a)
              asm.ret(:z)
              asm.di
              if sharing
                asm.call("rt_music_switch")
                asm.call("rt_music_tune_rank")
                asm.call("rt_music_song_frame")
              else
                asm.call(wobbles?(memory) ? "rt_music_tick_body" : "rt_music_tick") # no wobble moves here
              end
              asm.ei
              asm.ret

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

            # A game with sound effects plays a frame as the interpreter does (Reference::Player#advance):
            # the tune caught up with, the effects that outrank it, its parts, and the other effects.
            def emit_tick(asm, memory, level, sharing)
              h = Console::GBCHardware
              asm.label("rt_music_tick")
              # In a game where a note wobbles, every wobbling voice moves on once the frame's notes
              # are all written (rt_wobble_step), which the steps below end in many places to reach.
              if wobbles?(memory)
                asm.call("rt_music_tick_body")
                asm.jump("rt_wobble_step")
                asm.label("rt_music_tick_body")
              end
              if sharing
                asm.call("rt_music_switch")
                asm.call("rt_music_tune_rank")
                asm.call("rt_sfx_above")
                asm.call("rt_music_song_frame")
                asm.jump("rt_sfx_below")
                asm.label("rt_music_switch")
              end
              asm.load(:a, [memory[START]])
              asm.and_a(:a)
              if sharing
                asm.ret(:z)
              else
                asm.jump_relative(:z, "rt_music_tick_playing")
              end
              asm.xor_a(:a)
              asm.load([memory[START]], :a)
              # The tune named last is the one playing — another named and then this one again in a
              # pass — so it carries on, as Reference::Player#switch_to_wanted_song has it. A stop
              # leaves nothing playing, so a tune named after one starts over.
              asm.load(:a, [memory[NAMED]])
              asm.load(:hl, memory[PLAYING])
              asm.cp_a([:hl])
              if sharing
                asm.ret(:z)
              else
                asm.jump_relative(:z, "rt_music_tick_playing")
              end
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
              # With sound effects, each wave note puts its own waveform in (rt_music_note_wave_on),
              # since writing one now would quiet an effect sounding on the wave voice.
              if sharing
                asm.ret
              else
                asm.call("rt_music_waveform")
              end
              asm.label("rt_music_tick_playing")
              asm.label("rt_music_song_frame")
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

              # Every voice the tune plays on, quiet, and holding nothing. A voice a sound effect holds
              # is the effect's, and is left alone (Reference::Player#silence_song).
              asm.label("rt_music_quiet")
              return emit_quiet_beside_effects(asm, memory) if sharing

              asm.xor_a(:a)
              [h::NR12, h::NR22, h::NR30, h::NR42].each { |register| asm.load_high(register, :a) }
              HELD_VOICES.times { |i| asm.load([memory[HELD] + i], :a) }
              if wobbles?(memory)
                WOBBLE_VOICES.times { |i| asm.load([memory[WOBBLES] + (i * WOBBLE_BYTES)], :a) }
              end
              asm.load(:a, 0x80)
              [h::NR14, h::NR24, h::NR44].each { |register| asm.load_high(register, :a) }
              asm.ret
            end

            def emit_quiet_beside_effects(asm, memory)
              (1..4).each do |voice|
                holder = memory[Effects::HOLDERS] + voice - 1
                asm.load(:a, [holder])
                asm.load(:e, :a)
                asm.load(:d, 0)
                asm.load(:hl, "music_rank_effects")
                asm.add_hl(:de)
                asm.load(:a, [:hl])
                asm.and_a(:a)
                asm.jump_relative(:nz, "rt_music_quiet_kept_#{voice}")
                asm.load([holder], :a)
                asm.load([memory[HELD] + voice - 1], :a) if voice <= HELD_VOICES
                emit_silence(asm, memory, voice)
                asm.label("rt_music_quiet_kept_#{voice}")
              end
              asm.ret
            end

            # One part (HL = its entry, C = its number): each of its notes whose frame has come. With
            # sound effects, a note whose voice a higher rank holds is passed over, unplayed. With
            # +fades+, a note's fade comes out of its tuning's top four bits (GBC::Music::FADE_SHIFT)
            # and goes under its volume. With +slides+, a note on the first square voice writes its
            # slide (the byte after its volume) to the voice's sweep register before it starts.
            def emit_notes(asm, memory, level, sharing, fades, slides, bytes)
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
              asm.load(:h, :d) # HL = where the notes are + the number × a note's bytes
              asm.load(:l, :e)
              emit_times_note_bytes(asm, bytes)
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
              if sharing
                asm.load(:a, [memory[Effects::TUNE_RANK]])
                asm.load(:c, :a)
                asm.call("rt_claim")
                asm.jump_relative(:c, "rt_music_part_passed")
              end
              asm.call("rt_music_note")
              # One note on, and the part done for this frame: a part plays one note a frame, as the
              # interpreter's does (Reference::Player#play_song_frame), so a second note written on
              # the same frame never plays, and holds back the rest of the part.
              asm.label("rt_music_part_passed")
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
              emit_store_slide_and_vibrato(asm, memory, slides)
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
              # rt_voice_write: B = the volume, DE = the tuning, onto the part's voice ([PART]).
              asm.label("rt_voice_write")
              asm.load(:a, [part])
              asm.cp_a(GBC::Music::WAVE_VOICE)
              asm.jump_relative(:z, "rt_music_note_wave")
              asm.cp_a(GBC::Music::NOISE_VOICE)
              asm.jump_relative(:z, "rt_music_note_noise")
              # A square voice: its duty, its volume, its period, and start — and on the first, in a
              # game where a note slides, how this one slides, before it starts.
              if slides
                asm.cp_a(1)
                asm.jump_relative(:nz, "rt_music_note_unslid")
                asm.load(:a, [memory[NOTE_SLIDE]])
                asm.load_high(h::NR10, :a)
                asm.load(:a, 1)
                asm.label("rt_music_note_unslid")
              end
              asm.cp_a(1)
              asm.load(:c, h::NR11 & 0xFF)
              asm.jump_relative(:z, "rt_music_note_square")
              asm.load(:c, h::NR21 & 0xFF)
              asm.label("rt_music_note_square")
              asm.load(:a, [part + 1])
              asm.load_high([:c], :a)
              asm.inc(:c)
              rest_or_volume(asm, "square", fades)
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
              if sharing
                asm.load(:a, [part + 1])
                asm.inc(:a)
                asm.load(:hl, memory[WAVE_LOADED])
                asm.cp_a([:hl])
                asm.call(:nz, "rt_music_wave_load")
              end
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
              rest_or_volume(asm, "noise", fades)
              asm.load(:c, :a)
              if fades
                # A hit that says how it fades has it under its volume already; one that says
                # nothing rings out as its part says. NOISE_SAID_FADE is bit 3 of the tuning's high byte.
                # (A rest has every bit of its tuning set, so it takes this way too, at no volume:
                # silent either way.)
                asm.bit(3, :d)
                asm.jump_relative(:nz, "rt_music_noise_said_fade")
              end
              asm.load(:a, [part + 1])
              asm.and_a(7) # the fade
              asm.or_a(:c)
              if fades
                asm.jump_relative("rt_music_noise_fade_set")
                asm.label("rt_music_noise_said_fade")
                asm.load(:a, :c)
                asm.label("rt_music_noise_fade_set")
              end
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

              emit_wave_load(asm, memory) if sharing
              emit_hold(asm, memory, part, fades, slides)
              emit_relevel(asm, memory, level, fades) if level

              # The volume a voice is told, in its top four bits: none for a rest.
              asm.label("rt_music_wave_levels")
              asm.data_bytes((0..15).map { |volume| WAVE_LEVEL_CODES.fetch(VBlank::Audio::Sound.wave_level(volume)) })
            end

            # The wave voice's loudness for each of Audio::Sound's levels, as its register has it;
            # the Advance's three-quarters, which the Color does not have, is full.
            WAVE_LEVEL_CODES = { mute: 0x00, quarter: 0x60, half: 0x40, three_quarter: 0x20, full: 0x20 }.freeze

            # rt_music_wave_load: A = a waveform's number, 1 up, into the wave voice, with the voice off
            # while it is written. HL = WAVE_LOADED. Keeps B and DE.
            def emit_wave_load(asm, memory)
              h = Console::GBCHardware
              asm.label("rt_music_wave_load")
              asm.load([:hl], :a)
              asm.dec(:a)
              asm.swap(:a) # music_waves + 16 × its number
              asm.push(:de)
              asm.load(:e, :a)
              asm.load(:d, 0)
              asm.load(:hl, "music_waves")
              asm.add_hl(:de)
              asm.pop(:de)
              asm.xor_a(:a)
              asm.load_high(h::NR30, :a)
              asm.load(:c, h::WAVE_RAM & 0xFF)
              asm.label("rt_music_wave_load_byte")
              asm.load(:a, [:hli])
              asm.load_high([:c], :a)
              asm.inc(:c)
              asm.load(:a, :c)
              asm.cp_a((h::WAVE_RAM + 16) & 0xFF)
              asm.jump_relative(:nz, "rt_music_wave_load_byte")
              asm.ret
            end

            # rt_music_hold: the note being played (DE its tuning, NOTE_VOLUME its volume) is what its
            # voice holds now, a rest holding nothing. Keeps B and DE.
            #
            # With +fades+, a note that fades or swells by itself holds nothing either: it is left to
            # it, as a drum hit is (IR::Tunes.changes_by_itself?). The step its voice counts by is bits
            # 4 to 6 of its tuning's high byte (GBC::Music::FADE_SHIFT). With +slides+, so is a note
            # that slides: one whose slide (NOTE_SLIDE) is not nought.
            def emit_hold(asm, memory, part, fades, slides)
              asm.label("rt_music_hold")
              asm.load(:a, :d)
              asm.and_a(:e)
              asm.inc(:a) # nought for a rest
              asm.load(:a, [memory[NOTE_VOLUME]])
              asm.jump_relative(:nz, "rt_music_hold_volume")
              asm.xor_a(:a)
              asm.label("rt_music_hold_volume")
              asm.load(:c, :a)
              if fades
                asm.load(:a, :d)
                asm.and_a(0x70)
                asm.jump_relative(:z, "rt_music_hold_counted")
                asm.load(:c, 0)
                asm.label("rt_music_hold_counted")
              end
              if slides
                asm.load(:a, [memory[NOTE_SLIDE]])
                asm.and_a(:a)
                asm.jump_relative(:z, "rt_music_hold_unslid")
                asm.load(:c, 0)
                asm.label("rt_music_hold_unslid")
              end
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
            def emit_relevel(asm, memory, level, fades)
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
                  # The held note's fade, out of the top of its tuning as a new note's is.
                  emit_fade_under_volume(asm, [memory[TUNINGS] + ((voice - 1) * 2) + 1]) if fades
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

            # A = the volume in A's top four bits with a note's fade under it: the top four bits of
            # its tuning's high byte (GBC::Music::FADE_SHIFT), read from +from+ — D, or where a held
            # note's tuning is kept. B is spent.
            def emit_fade_under_volume(asm, from)
              asm.load(:b, :a)
              asm.load(:a, from)
              asm.swap(:a)
              asm.and_a(0x0F)
              asm.or_a(:b)
            end

            # A = the volume (B) in the top four bits, or nought for a rest (DE = REST). With
            # +fades+, the note's fade under it, out of the top of its tuning (D); B is spent.
            def rest_or_volume(asm, voice, fades)
              asm.load(:a, :d)
              asm.and_a(:e)
              asm.inc(:a)
              asm.jump_relative(:z, "rt_music_#{voice}_rest")
              asm.load(:a, :b)
              asm.swap(:a)
              asm.and_a(0xF0)
              emit_fade_under_volume(asm, :d) if fades
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
