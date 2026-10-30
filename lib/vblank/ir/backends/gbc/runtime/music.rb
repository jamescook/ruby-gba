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
            # A WAVE NOTE HELD ACROSS A RECORDING, in a game that plays one (Runtime::Clips): the
            # recording has the voice while it plays, so the note's tuning and waveform are kept
            # beside what HELD keeps of it, and WAVE_BACK is set as the recording ends, for the next
            # frame to put the note back (rt_music_wave_back) rather than leave it quiet until the
            # part's next note.
            WAVE_TUNING = "rt music wave tuning"
            WAVE_SHAPE = "rt music wave shape"
            WAVE_BACK = "rt music wave back"

            # A square part's first register, by voice.
            SQUARE_REGISTERS = { 1 => Console::GBCHardware::NR11, 2 => Console::GBCHardware::NR21 }.freeze

            module_function

            # SONGS KEPT IN THE CARTRIDGE'S BANKS (GBC::Music#sections): the bank the game's code put
            # in view last (SM83#select_rom_bank notes it here), which the player puts back once it
            # has read a part's notes from that part's own bank — kept at PART_BANK in [PART].
            BANK_NOTED = "rt music bank noted"
            PART_BANK = 6

            def banked?(memory) = memory.reserved?(BANK_NOTED)

            # WHETHER EACH WAVE NOTE PUTS ITS WAVEFORM IN, rather than the tune at its start: in a game
            # whose sound effects or recordings can sound on the wave voice with a waveform of their
            # own (WAVE_LOADED says which is in), so a note after them finds its own gone.
            def reloads_wave?(memory) = memory.reserved?(WAVE_LOADED)

            # Whether a wave note held across a recording is put back as it ends (WAVE_BACK).
            def wave_back?(memory) = memory.reserved?(WAVE_BACK)

            def reserve(memory, effects: [], slides: false, wobbles: false, shapes: false, swells: false, banked: false)
              memory.reserve(BANK_NOTED, 1) if banked
              reserve_song_player(memory, banked)
              memory.reserve(WAVE_LOADED, 1) unless effects.empty? && !Clips.any?(memory)
              if Clips.any?(memory)
                memory.reserve(WAVE_TUNING, 2)
                memory.reserve(WAVE_SHAPE, 1)
                memory.reserve(WAVE_BACK, 1)
              end
              memory.reserve(NOTE_SLIDE, 1) if slides
              memory.reserve(WOBBLES, WOBBLE_BYTES * WOBBLE_VOICES) if wobbles
              memory.reserve(SHAPE_WALKS, SHAPE_BYTES * SHAPE_VOICES) if shapes
              memory.reserve(SWELLS, SWELL_BYTES * SWELL_VOICES) if swells
              Effects.reserve(memory, effects)
            end

            # A SONG'S SWELLING NOTE HELD UNDER THE MUSIC VOLUME, in a game that moves the music volume
            # and has one, for each of the two square voices (IR::Tunes::Swell says how it is counted):
            # 1 while the voice has one, the 64ths of a second each step lasts, how loud the voice has
            # it now, the 256ths of a 64th counted toward its next step (16 bits, low byte first), and
            # 1 while it is still swelling. Six bytes a voice.
            SWELLS = "rt music swells"
            SWELL_BYTES = 6
            SWELL_VOICES = 2
            SWELL_STEP = 1
            SWELL_VOLUME = 2
            SWELL_COUNTED = 3
            SWELL_SWELLING = 5

            def swells?(memory) = memory.reserved?(SWELLS)

            # Voice +voice+ holds no swell for the music volume: it went quiet, or another sound took
            # it. Nothing in a game with none, nor on a voice that is not square.
            def emit_end_swell(asm, memory, voice)
              return unless swells?(memory) && voice <= SWELL_VOICES

              asm.xor_a(:a)
              asm.load([memory[SWELLS] + ((voice - 1) * SWELL_BYTES)], :a)
            end

            # A SQUARE NOTE'S SHAPES, in a game where a square note says them, for each of the two
            # square voices (Audio::Duty says what they are, and Reference::Player#step_shapes how they
            # step): the shapes' bits, the frame of the note it is on, 1 while a note (not a rest)
            # holds there, and the shape it played last frame. Four bytes a voice.
            SHAPE_WALKS = "rt music shapes"
            SHAPE_BYTES = 4
            SHAPE_VOICES = 2
            SHAPE_FRAME = 1
            SHAPE_ON = 2
            SHAPE_LAST = 3

            def shapes?(memory) = memory.reserved?(SHAPE_WALKS)

            # Whether anything moves a voice at the end of each of the player's frames (#emit_tick).
            def steps_each_frame?(memory) = wobbles?(memory) || shapes?(memory) || swells?(memory)

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

            def reserve_song_player(memory, banked)
              memory.reserve(NAMED, 1)
              memory.reserve(PLAYING, 1)
              memory.reserve(START, 1)
              memory.reserve(FRAME, 2)
              memory.reserve(AGAIN, 1)
              memory.reserve(SONG, 2)
              memory.reserve(NEXT, PARTS * 2)
              memory.reserve(PART, banked ? PART_BANK + 1 : PART_BANK)
              memory.reserve(HELD, HELD_VOICES)
              memory.reserve(TUNINGS, 4)
              memory.reserve(DUTIES, 2)
              memory.reserve(LEVEL_SET, 1)
              memory.reserve(NOTE_VOLUME, 1)
            end

            # +level+ is where the game keeps the music's level, or nil for a game that never sets it.
            # +songs+ says whether the game has any songs at all; +effects+ are its sound effects
            # (GBC::Music#effects), and +by_rank+ the same in the order a frame plays them. +fades+
            # says whether any note says how it fades or swells (GBC::Music#fades?), +slides+ whether
            # any slides its pitch (GBC::Music#slides?), and +pans+ whether any plays from one speaker
            # (GBC::Music#pans?). Whether any wobbles is whether its place was reserved (#wobbles?).
            def emit(asm, memory, level:, songs:, effects: [], by_rank: [], fades: false, slides: false, pans: false)
              sharing = !effects.empty?
              emit_game_side(asm, memory, sharing)
              return emit_no_songs(asm) unless songs

              bytes = GBC::Music.note_bytes(slides, pans, shapes?(memory), wobbles?(memory))
              emit_tick(asm, memory, level, sharing)
              emit_notes(asm, memory, level, sharing, fades, slides, pans, bytes)
              emit_wobbles(asm, memory) if wobbles?(memory)
              emit_set_speakers(asm, memory) if pans
              emit_shapes(asm, memory) if shapes?(memory)
              emit_swells(asm, memory) if swells?(memory)
              Effects.emit(asm, memory, effects, by_rank, slides: slides, pans: pans, fades: fades, bytes: bytes) if sharing
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
            # volume, in a game where a note slides. In one where a note plays from one speaker, the
            # voice's speakers set from the byte after that (rt_set_speakers). In one where a square
            # note says its shapes, the note's first shape and its stepping from the byte after that
            # (rt_shape_start). And in one where a note wobbles, the voice set to wobble the note from
            # the two after those (rt_wobble_start). Keeps B and DE.
            def emit_store_slide_speaker_vibrato(asm, memory, slides, pans)
              if slides
                asm.inc(:hl)
                asm.load(:a, [:hl])
                asm.load([memory[NOTE_SLIDE]], :a)
              end
              if pans
                asm.inc(:hl)
                asm.load(:a, [:hl])
                asm.call("rt_set_speakers")
              end
              if shapes?(memory)
                asm.inc(:hl)
                asm.load(:a, [:hl])
                asm.call("rt_shape_start")
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

            # Voice +voice+ steps no shapes: it went quiet, or the game's own sound took it. Nothing
            # in a game where no square note says its shapes, nor on a voice that is not square.
            def emit_end_shapes(asm, memory, voice)
              return unless shapes?(memory) && voice <= SHAPE_VOICES

              asm.xor_a(:a)
              asm.load([memory[SHAPE_WALKS] + ((voice - 1) * SHAPE_BYTES) + SHAPE_ON], :a)
            end

            # A SQUARE NOTE'S SHAPES, in a game where a square note says them.
            #
            # rt_shape_start: A = the note's shapes (Audio::Duty#bits), DE its tuning. On a square
            # voice ([PART]) the note is written in its first shape — the part's tone, which
            # rt_voice_write writes, is that for this note — and steps its shapes from here, unless it
            # is a rest. Keeps BC, DE and HL.
            #
            # rt_shape_step: every square voice holding a note given the shape of the frame it is on,
            # at the end of the interrupt's frame after the wobbles (Reference::Player#step_shapes). A
            # voice's tone is the top two bits of its NR11 or NR21, written alone, so the note is not
            # started again; written every frame, so a held note the music level started again this
            # frame, in its first shape, is back in its frame's before the frame is heard. A run of
            # the cartridge reads each change of shape at rt_shape_changed_N, where A holds the
            # shape's two bits (GBC::SoundLog).
            def emit_shapes(asm, memory)
              h = Console::GBCHardware
              asm.label("rt_shape_start")
              asm.push(:hl)
              asm.push(:bc)
              asm.load(:c, :a) # the shapes
              asm.load(:a, [memory[PART]])
              asm.cp_a(SHAPE_VOICES + 1)
              asm.jump_relative(:nc, "rt_shape_start_done")
              asm.load(:b, :a)
              asm.load(:a, :c)
              asm.and_a(3)
              asm.rrca
              asm.rrca # the first shape, where the register keeps it
              asm.load([memory[PART] + 1], :a)
              asm.load(:a, :b) # HL = this voice's shapes: SHAPE_WALKS + its place × SHAPE_BYTES
              asm.dec(:a)
              asm.add_a(:a)
              asm.add_a(:a)
              asm.add_a(memory[SHAPE_WALKS] & 0xFF)
              asm.load(:l, :a)
              asm.load(:a, memory[SHAPE_WALKS] >> 8)
              asm.adc_a(0)
              asm.load(:h, :a)
              asm.load(:a, :c)
              asm.load([:hli], :a)
              asm.xor_a(:a)
              asm.load([:hli], :a) # its first frame
              asm.load(:a, :d) # a rest's tuning is every bit set
              asm.and_a(:e)
              asm.inc(:a)
              asm.jump_relative(:z, "rt_shape_start_rest")
              asm.load(:a, 1)
              asm.label("rt_shape_start_rest")
              asm.load([:hli], :a)
              asm.load(:a, :c)
              asm.and_a(3)
              asm.load([:hl], :a) # the shape it plays first
              asm.label("rt_shape_start_done")
              asm.pop(:bc)
              asm.pop(:hl)
              asm.ret

              asm.label("rt_shape_step")
              { 1 => h::NR11, 2 => h::NR21 }.each do |voice, register|
                at = memory[SHAPE_WALKS] + ((voice - 1) * SHAPE_BYTES)
                still = "rt_shape_still_#{voice}"
                asm.load(:a, [at + SHAPE_ON])
                asm.and_a(:a)
                asm.jump_relative(:z, still)
                asm.load(:a, [at + SHAPE_FRAME])
                asm.load(:c, :a)
                asm.inc(:a) # it wraps at 256, which four goes into
                asm.load([at + SHAPE_FRAME], :a)
                asm.load(:a, [at])
                asm.load(:b, :a)
                asm.load(:a, :c)
                asm.and_a(3) # the frame's place among the four
                asm.jump_relative(:z, "rt_shape_shifted_#{voice}")
                asm.label("rt_shape_shift_#{voice}")
                asm.srl(:b)
                asm.srl(:b)
                asm.dec(:a)
                asm.jump_relative(:nz, "rt_shape_shift_#{voice}")
                asm.label("rt_shape_shifted_#{voice}")
                asm.load(:a, :b)
                asm.and_a(3) # the frame's shape
                asm.load(:hl, at + SHAPE_LAST)
                asm.cp_a([:hl])
                asm.jump_relative(:z, "rt_shape_same_#{voice}")
                asm.label("rt_shape_changed_#{voice}") # reached only when the shape changes
                asm.load([:hl], :a)
                asm.label("rt_shape_same_#{voice}")
                asm.rrca
                asm.rrca
                asm.load_high(register, :a)
                asm.label(still)
              end
              asm.ret
            end

            # WHICH SPEAKERS A VOICE PLAYS FROM is a pair of switches for each voice in NR51: the four
            # voices' right switches in bits 0 to 3 and their left ones in bits 4 to 7, all on since
            # power-on (Runtime::Boot).
            #
            # rt_set_speakers: A = a note's speaker (Audio::Pan.bits_of), the part's voice ([PART])
            # set to it — the left alone, the right alone, or both — and the other voices' switches
            # left as they are. Keeps BC, DE and HL.
            def emit_set_speakers(asm, memory)
              pan = VBlank::Audio::Pan
              asm.label("rt_set_speakers")
              asm.push(:bc)
              asm.load(:c, :a) # the speaker
              asm.load(:a, [memory[PART]])
              asm.load(:b, :a)
              if Clips.any?(memory) # the wave voice's speakers are a playing recording's (Runtime::Clips)
                asm.cp_a(GBC::Music::WAVE_VOICE)
                asm.jump_relative(:nz, "rt_set_speakers_free")
                Clips.emit_skip_while_recording_plays(asm, "rt_set_speakers_kept")
                asm.label("rt_set_speakers_free")
              end
              asm.load(:a, 0x11) # the first voice's two switches, moved up to this voice's
              asm.label("rt_set_speakers_shift")
              asm.dec(:b)
              asm.jump_relative(:z, "rt_set_speakers_found")
              asm.add_a(:a)
              asm.jump_relative("rt_set_speakers_shift")
              asm.label("rt_set_speakers_found")
              asm.load(:b, :a) # this voice's two switches
              asm.load(:a, :c)
              asm.cp_a(pan::LEFT_BITS)
              asm.load(:a, :b)
              asm.jump_relative(:nz, "rt_set_speakers_not_left")
              asm.and_a(0xF0)
              asm.jump_relative("rt_set_speakers_chosen")
              asm.label("rt_set_speakers_not_left")
              asm.load(:a, :c)
              asm.cp_a(pan::RIGHT_BITS)
              asm.load(:a, :b)
              asm.jump_relative(:nz, "rt_set_speakers_chosen")
              asm.and_a(0x0F)
              asm.label("rt_set_speakers_chosen")
              asm.load(:c, :a) # the switches it is on
              asm.load_high(:a, Console::GBCHardware::NR51)
              asm.or_a(:b)
              asm.xor_a(:b) # this voice's switches off
              asm.or_a(:c)
              asm.load_high(Console::GBCHardware::NR51, :a)
              asm.label("rt_set_speakers_kept") if Clips.any?(memory)
              asm.pop(:bc)
              asm.ret
            end

            # Voice +voice+ quiet: its volume nothing, and a square or noise voice started again so
            # that it takes it — and, in a game where a note wobbles, wobbling nothing.
            def emit_silence(asm, memory, voice)
              if wobbles?(memory) && voice <= WOBBLE_VOICES
                asm.xor_a(:a)
                asm.load([memory[WOBBLES] + ((voice - 1) * WOBBLE_BYTES)], :a)
              end
              emit_end_shapes(asm, memory, voice)
              emit_end_swell(asm, memory, voice)
              h = Console::GBCHardware
              volume, start = { 1 => [h::NR12, h::NR14], 2 => [h::NR22, h::NR24], 3 => [h::NR30, nil],
                                4 => [h::NR42, h::NR44] }.fetch(voice)
              return emit_wave_quiet(asm, memory) if voice == GBC::Music::WAVE_VOICE

              asm.xor_a(:a)
              asm.load_high(volume, :a)
              return unless start

              asm.load(:a, 0x80)
              asm.load_high(start, :a)
            end

            # The wave voice off — but not while a recording plays on it (Runtime::Clips), which is
            # the recording's to end. Keeps every register but A and the flags.
            def emit_wave_quiet(asm, memory)
              past = "rt_wave_quiet_past_#{asm.here}" # emitted in several places, each its own
              Clips.emit_skip_while_recording_plays(asm, past) if Clips.any?(memory)
              asm.xor_a(:a)
              asm.load_high(Console::GBCHardware::NR30, :a)
              asm.label(past)
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
              Clips.emit_timer_let_in_around(asm, memory) do
                if sharing
                  asm.call("rt_music_switch")
                  asm.call("rt_music_tune_rank")
                  asm.call("rt_music_song_frame")
                else
                  asm.call(steps_each_frame?(memory) ? "rt_music_tick_body" : "rt_music_tick") # no wobble or shape moves here
                end
              end
              asm.ei
              asm.ret

              asm.label("rt_music_stop")
              asm.di
              asm.xor_a(:a)
              asm.load([memory[NAMED]], :a)
              asm.load([memory[START]], :a)
              Clips.emit_timer_let_in_around(asm, memory) { asm.call("rt_music_quiet") }
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
              # Once the frame's notes are all written: where a swelling note is held under the music
              # volume, every square voice holding one (rt_swell_step); then, in a game where a note
              # wobbles, every wobbling voice moves on (rt_wobble_step), and then, where a note steps
              # its shapes, every square voice that does (rt_shape_step) — those two putting a note
              # struck again back at its frame's pitch and shape. The steps below end in many places
              # to reach them.
              steps = [("rt_swell_step" if swells?(memory)), ("rt_wobble_step" if wobbles?(memory)),
                       ("rt_shape_step" if shapes?(memory))].compact
              unless steps.empty?
                asm.call("rt_music_tick_body")
                steps[0...-1].each { |step| asm.call(step) }
                asm.jump(steps.last)
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
              # With sound effects or recordings, each wave note puts its own waveform in
              # (rt_music_note_wave_on), since writing one now would quiet what is sounding there.
              if sharing
                asm.ret
              elsif !reloads_wave?(memory)
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
              # ...and a wave note a recording had the voice from, before any new note takes it.
              asm.call("rt_music_wave_back") if wave_back?(memory)
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
              emit_part_bank_in_view(asm, memory) if banked?(memory)
              asm.call("rt_music_part")
              if banked?(memory) # the game's bank back in view
                asm.load(:a, [memory[BANK_NOTED]])
                asm.select_rom_bank_unnoted
              end
              asm.pop(:hl)
              asm.load(:de, GBC::Music.part_entry_bytes(banked?(memory)))
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
              asm.load(:de, GBC::Music.part_entry_bytes(banked?(memory)) - 1)
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
              # is the effect's, and is left alone (Reference::Player#silence_song). So is a recording
              # playing on the wave voice (Runtime::Clips), whose voice is quieted last (#emit_wave_quiet).
              asm.label("rt_music_quiet")
              return emit_quiet_beside_effects(asm, memory) if sharing

              clips = Clips.any?(memory)
              asm.xor_a(:a)
              ([h::NR12, h::NR22, h::NR30, h::NR42] - (clips ? [h::NR30] : [])).each do |register|
                asm.load_high(register, :a)
              end
              HELD_VOICES.times { |i| asm.load([memory[HELD] + i], :a) }
              if wobbles?(memory)
                WOBBLE_VOICES.times { |i| asm.load([memory[WOBBLES] + (i * WOBBLE_BYTES)], :a) }
              end
              if shapes?(memory)
                SHAPE_VOICES.times { |i| asm.load([memory[SHAPE_WALKS] + (i * SHAPE_BYTES) + SHAPE_ON], :a) }
              end
              SWELL_VOICES.times { |i| asm.load([memory[SWELLS] + (i * SWELL_BYTES)], :a) } if swells?(memory)
              asm.load(:a, 0x80)
              [h::NR14, h::NR24, h::NR44].each { |register| asm.load_high(register, :a) }
              emit_wave_quiet(asm, memory) if clips
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

            # The bank the part at HL keeps its notes in (the last byte of its entry,
            # GBC::Music#emit_song) put in view, and kept at PART_BANK, without noting it: the bank
            # noted stays the game's code's, for the player to put back. Keeps BC and HL.
            def emit_part_bank_in_view(asm, memory)
              asm.push(:hl)
              asm.load(:de, GBC::Music::ENTRY_BANK)
              asm.add_hl(:de)
              asm.load(:a, [:hl])
              asm.load([memory[PART] + PART_BANK], :a)
              asm.select_rom_bank_unnoted
              asm.pop(:hl)
            end

            # One part (HL = its entry, C = its number): each of its notes whose frame has come. With
            # sound effects, a note whose voice a higher rank holds is passed over, unplayed. With
            # +fades+, a note's fade comes out of its tuning's top four bits (GBC::Music::FADE_SHIFT)
            # and goes under its volume. With +slides+, a note on the first square voice writes its
            # slide (the byte after its volume) to the voice's sweep register before it starts.
            def emit_notes(asm, memory, level, sharing, fades, slides, pans, bytes)
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
              # A run of the cartridge tells a note by its place, and two banks have notes at one
              # address, so A holds the note's bank as it arrives (GBC::SoundLog).
              asm.load(:a, [part + PART_BANK]) if banked?(memory)
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
              emit_store_slide_speaker_vibrato(asm, memory, slides, pans)
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
              Clips.emit_return_while_recording_plays(asm) if Clips.any?(memory)
              asm.load(:a, :d)
              asm.and_a(:e)
              asm.inc(:a)
              asm.jump_relative(:nz, "rt_music_note_wave_on")
              asm.load_high(h::NR30, :a) # a rest: the voice off
              asm.ret
              asm.label("rt_music_note_wave_on")
              if reloads_wave?(memory)
                asm.load(:a, [part + 1])
                asm.inc(:a)
                asm.load(:hl, memory[WAVE_LOADED])
                asm.cp_a([:hl])
                asm.call(:nz, "rt_music_wave_load")
              end
              # B = the volume, DE = the tuning, the waveform in: the voice on, and the note started.
              asm.label("rt_music_note_wave_sound")
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

              emit_wave_load(asm, memory) if reloads_wave?(memory)
              emit_wave_back(asm, memory, level, sharing) if wave_back?(memory)
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

            # rt_music_wave_back: the wave note a song is holding, sounded again once a recording that
            # had the voice is over (WAVE_BACK) — its waveform put back, at the music's level now, at
            # its own pitch — as a game of the Color's puts its wave table back at a clip's end. Not
            # while another recording has started, nor when a sound effect holds the voice, nor for
            # a rest or a note that fades by itself (HELD keeps nothing for those).
            def emit_wave_back(asm, memory, level, sharing)
              asm.label("rt_music_wave_back")
              asm.load(:a, [memory[WAVE_BACK]])
              asm.and_a(:a)
              asm.ret(:z)
              asm.xor_a(:a)
              asm.load([memory[WAVE_BACK]], :a)
              Clips.emit_return_while_recording_plays(asm)
              if sharing
                asm.load(:a, [memory[Effects::HOLDERS] + GBC::Music::WAVE_VOICE - 1])
                asm.load(:e, :a)
                asm.load(:d, 0)
                asm.load(:hl, "music_rank_effects")
                asm.add_hl(:de)
                asm.load(:a, [:hl])
                asm.and_a(:a)
                asm.ret(:nz)
              end
              asm.load(:a, [memory[HELD] + GBC::Music::WAVE_VOICE - 1])
              asm.and_a(:a)
              asm.ret(:z)
              asm.load(:b, :a)
              if level
                asm.call("rt_music_level")
                asm.call("rt_music_scale")
                asm.load(:b, :a)
              end
              asm.load(:a, [memory[WAVE_TUNING]])
              asm.load(:e, :a)
              asm.load(:a, [memory[WAVE_TUNING] + 1])
              asm.load(:d, :a)
              asm.load(:a, [memory[WAVE_SHAPE]])
              asm.inc(:a)
              asm.load(:hl, memory[WAVE_LOADED])
              asm.call("rt_music_wave_load")
              asm.jump("rt_music_note_wave_sound")
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
                # A swell's start makes the voices' parts long enough to need a long jump.
                swells?(memory) ? asm.jump(:z, "rt_music_hold_#{voice}") : asm.jump_relative(:z, "rt_music_hold_#{voice}")
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
                  emit_start_swell(asm, memory, voice) if swells?(memory)
                elsif wave_back?(memory)
                  asm.load(:a, :e)
                  asm.load([memory[WAVE_TUNING]], :a)
                  asm.load(:a, :d)
                  asm.load([memory[WAVE_TUNING] + 1], :a)
                  asm.load(:a, [part + 1])
                  asm.load([memory[WAVE_SHAPE]], :a)
                end
                asm.ret
              end
            end

            # The note being played on square voice +voice+ (DE its tuning, B the volume the voice is
            # told) counted from here when it swells by itself, so it is held under the music volume
            # (#emit_swells): its fade is the top four bits of its tuning's high byte, 8 of them up
            # and the step under it (GBC::Music::FADE_SHIFT). A rest, or a note that does not swell,
            # holds no swell. Keeps B and DE.
            def emit_start_swell(asm, memory, voice)
              at = memory[SWELLS] + ((voice - 1) * SWELL_BYTES)
              none = "rt_swell_none_#{voice}"
              said = "rt_swell_said_#{voice}"
              asm.load(:a, :d)
              asm.and_a(:e)
              asm.inc(:a) # nought for a rest
              asm.jump_relative(:z, none)
              asm.bit(7, :d)
              asm.jump_relative(:z, none)
              if memory.reserved?(NOTE_SLIDE) # a note that slides is left alone: striking it again starts its slide over
                asm.load(:a, [memory[NOTE_SLIDE]])
                asm.and_a(:a)
                asm.jump_relative(:nz, none)
              end
              asm.load(:a, :d)
              asm.and_a(0x70)
              asm.jump_relative(:z, none)
              asm.swap(:a)
              asm.load([at + SWELL_STEP], :a)
              asm.load(:a, :b)
              asm.load([at + SWELL_VOLUME], :a)
              asm.xor_a(:a)
              asm.load([at + SWELL_COUNTED], :a)
              asm.load([at + SWELL_COUNTED + 1], :a)
              asm.inc(:a)
              asm.load([at + SWELL_SWELLING], :a)
              asm.jump_relative(said)
              asm.label(none)
              asm.xor_a(:a)
              asm.label(said)
              asm.load([at], :a)
            end

            # A SONG'S SWELLING NOTE HELD UNDER THE MUSIC VOLUME, in a game that has one
            # (IR::Tunes::Swell says how it is counted, and every backend counts it alike).
            #
            # rt_swell_step: every square voice holding one, at the end of the interrupt's frame before
            # the wobbles and the shapes (Reference::Player#step_swells). The loudest the music volume lets a note
            # be is 15 times the level the held notes were set at, over 16. A swell that has reached
            # it is struck again there, holding, and one held below it is struck again where it was,
            # swelling on; then a swelling one is counted on a frame — a little over one 64th of a
            # second, 274 256ths of one. A run of the cartridge reads each strike at
            # rt_swell_struck_holding_N, where B holds the volume, and at rt_swell_struck_swelling_N,
            # where C holds the fade
            # as well (GBC::SoundLog).
            def emit_swells(asm, memory)
              h = Console::GBCHardware
              loudest = IR::Tunes::LOUDEST
              asm.label("rt_swell_step")
              asm.load(:a, [memory[LEVEL_SET]])
              asm.xor_a(IR::Tunes::FULL_LEVEL)
              asm.load(:c, :a)
              asm.load(:b, loudest)
              asm.call("rt_music_scale")
              asm.load(:d, :a) # the ceiling
              { 1 => [h::NR11, h::NR12, h::NR13, h::NR14], 2 => [h::NR21, h::NR22, h::NR23, h::NR24] }.each do |voice, registers|
                at = memory[SWELLS] + ((voice - 1) * SWELL_BYTES)
                past = "rt_swell_past_#{voice}"
                held = "rt_swell_kept_#{voice}"
                hold = "rt_swell_hold_#{voice}"
                count = "rt_swell_count_#{voice}"
                climb = "rt_swell_climb_#{voice}"
                asm.load(:a, [at])
                asm.and_a(:a)
                asm.jump(:z, past)
                asm.load(:a, [at + SWELL_SWELLING])
                asm.and_a(:a)
                asm.jump(:z, held)
                asm.load(:a, :d) # swelling: held at the ceiling once it is there, unless that is full
                asm.cp_a(loudest)
                asm.jump(:nc, count)
                asm.load(:a, [at + SWELL_VOLUME])
                asm.cp_a(:d)
                asm.jump(:c, count)
                asm.label(hold)
                asm.load(:a, :d)
                asm.load([at + SWELL_VOLUME], :a)
                asm.xor_a(:a)
                asm.load([at + SWELL_COUNTED], :a)
                asm.load([at + SWELL_COUNTED + 1], :a)
                asm.load([at + SWELL_SWELLING], :a)
                asm.load(:b, :d)
                asm.load(:c, 0)
                asm.label("rt_swell_struck_holding_#{voice}")
                emit_strike_swell(asm, memory, voice, registers)
                asm.jump(past)
                asm.label(held) # held: struck lower as the music falls, swelling on as it comes back
                asm.load(:a, [at + SWELL_VOLUME])
                asm.cp_a(:d)
                asm.jump(:z, past)
                asm.jump(:nc, hold)
                asm.load(:b, :a)
                asm.xor_a(:a)
                asm.load([at + SWELL_COUNTED], :a)
                asm.load([at + SWELL_COUNTED + 1], :a)
                asm.inc(:a)
                asm.load([at + SWELL_SWELLING], :a)
                asm.load(:a, [at + SWELL_STEP])
                asm.or_a(8)
                asm.load(:c, :a)
                asm.label("rt_swell_struck_swelling_#{voice}")
                emit_strike_swell(asm, memory, voice, registers)
                asm.label(count)
                asm.load(:a, [at + SWELL_VOLUME])
                asm.cp_a(loudest)
                asm.jump_relative(:nc, past)
                asm.load(:hl, at + SWELL_COUNTED)
                asm.load(:a, [:hl])
                asm.add_a(IR::Tunes::COUNTED_A_FRAME & 0xFF)
                asm.load([:hli], :a)
                asm.load(:a, [:hl])
                asm.adc_a(IR::Tunes::COUNTED_A_FRAME >> 8)
                asm.load([:hl], :a)
                asm.load(:a, [at + SWELL_STEP])
                asm.load(:e, :a)
                asm.label(climb) # a step is the step's 64ths × 256: its high byte alone
                asm.load(:a, [at + SWELL_COUNTED + 1])
                asm.cp_a(:e)
                asm.jump_relative(:c, past)
                asm.sub_a(:e)
                asm.load([at + SWELL_COUNTED + 1], :a)
                asm.load(:a, [at + SWELL_VOLUME])
                asm.inc(:a)
                asm.load([at + SWELL_VOLUME], :a)
                asm.cp_a(loudest)
                asm.jump_relative(:c, climb)
                asm.label(past)
              end
              asm.ret
            end

            # Square voice +voice+ (its +registers+) struck again with the note it holds: its duty and
            # tuning as kept for a new music level (#emit_hold), at volume B with fade C under it.
            # Keeps D.
            def emit_strike_swell(asm, memory, voice, registers)
              duty, volume, low, high = registers
              asm.load(:a, [memory[DUTIES] + voice - 1])
              asm.load_high(duty, :a)
              asm.load(:a, :b)
              asm.swap(:a)
              asm.and_a(0xF0)
              asm.or_a(:c)
              asm.load_high(volume, :a)
              asm.load(:a, [memory[TUNINGS] + ((voice - 1) * 2)])
              asm.load_high(low, :a)
              asm.load(:a, [memory[TUNINGS] + ((voice - 1) * 2) + 1])
              asm.and_a(7)
              asm.or_a(0x80)
              asm.load_high(high, :a)
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
                  # ...but not under a recording, whose voice it is while it plays (Runtime::Clips).
                  Clips.emit_skip_while_recording_plays(asm, "rt_music_relevel_past_#{voice}") if Clips.any?(memory)
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
