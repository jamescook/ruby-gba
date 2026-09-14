# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # The software mixer — several recorded samples sounding at once. The console's
        # sampled-audio hardware plays ONE stream of bytes out of a small buffer; to get
        # background music under a handful of effects (and, later, chords), the CPU adds
        # the samples together itself. Each frame it builds the next little slice of sound
        # by summing every voice that's playing into a buffer, and the sound DMA plays that
        # buffer out. Two buffers take turns (a "double buffer"): the DMA plays one while
        # the CPU fills the other, then they swap — so the DMA never reads a half-written
        # buffer. All of this is hidden behind `play`/`stop`.
        #
        # A "voice" is one sounding sample: where its data is in the cartridge, how far it
        # has played, its length, whether it loops, and how fast it reads the recording (its
        # pitch). There are a fixed number of voice slots; `play` fills a free one, the mix
        # drains and retires it (or loops it), and `stop` clears a sample's slots. The mix runs
        # once per DISPLAYED FRAME, from the screen's own interrupt — so playing samples needs a
        # game loop, which is what arms that interrupt.
        #
        # THE SLOTS ARE SHARED between the game's sounds and the notes of songs and sound effects,
        # each taking one only while it sounds (see #emit_music_voice_routine for who gives way
        # when they run out). A slot's SOUNDING word says whose it is: 0 nobody's, OWNER_GAME the
        # game's, and a recorded part its own mark (Mixer.music_owner, or Mixer.ranked_owner in a
        # game whose sound effects play recordings).
        #
        # Owns the whole sampled-audio picture: registering samples as ROM data (asset
        # preparation, so it lives here beside the mix that uses what it prepares) and
        # the mix itself. @samples / @plays_samples are this object's own state, not
        # handed in — nothing outside sampled audio ever reads them.
        class Mixer
          include Constants

          # How many samples can sound at once — read from {Sound}, where the two backends
          # keep the promises they make to each other, rather than written down again here.
          MAX_VOICES = Sound::MIXER_VOICES

          # The mix routine's inner loop runs once per output sample per voice — thousands
          # of times a frame. From ROM it would stall on a wait state at every instruction
          # fetch, so at boot the routine is copied into IWRAM (zero-wait-state internal RAM)
          # and called there. This is the IWRAM budget reserved for the copy; the build
          # fails if the emitted routine ever outgrows it.
          # KEPT SNUG, because every byte of it is a byte the routines a frame spends its time in
          # do not get — this reservation and the game's own hot code come out of the same 32K.
          # The routine emits at 284 to 300 bytes (three of its immediates are the samples-per-frame
          # count or that count in words, each one instruction or two depending on the number, and a
          # game that shapes a note adds three instructions to slide the gain), so this is about a
          # quarter as much again for room to grow into. Outgrow it and the build
          # says so by name rather than running over whatever is next.
          #
          # It was 1024, which is four times what the routine has ever needed, and a real game
          # paid for it: on the Wolfenstein port the difference was exactly enough to push the routine
          # that draws every guard and every lamp out of the quick memory.
          MIX_ROUTINE_IWRAM_MAX = 384

          # Timer 0 clocks the mixer's output rate (how fast the DMA hands bytes to the sound
          # FIFO).
          CLOCK_TIMER = 0

          # Timer 1 COUNTS those samples: it is chained to timer 0, so it goes up by one every
          # time the sound hardware takes a sample, and nothing else. It raises no interrupt and
          # costs nothing to run. What it is for is the hand-over, which reads it to learn exactly
          # how much of the last buffer the DMA has already taken (see #emit_mixer_handover).
          COUNT_TIMER = 1

          # WHILE THE MIXER FINDS ITS FEET at boot the sample clock runs this fast, in cycles a
          # sample, so the few lots it has to watch go by in a moment instead of a fraction of a
          # second (see #emit_find_lot_grid). Changing the clock's speed afterwards moves nothing
          # the watching found out, because that was counted in samples and not in time.
          CALIBRATION_PERIOD = 512

          # HOW LATE A HAND-OVER CAN BE and still play every lot in its place, in cycles. The
          # screen's interrupt waits for a DMA the game is in the middle of, and the longest one
          # the framework makes while a game runs is a whole-screen clear, about a fifth of a
          # frame. A third leaves room over. Each buffer carries this much sound past its end
          # (see #guard_lots), so this is what it costs: memory, and a copy of it once a frame.
          LATE_ROOM = Timers::FRAME_CYCLES / 3

          # Where the DMA's grid of lots falls against the sample count (0 to 15), found at boot.
          MIX_PHASE = :__mix_phase

          # Which lot, counting every lot the DMA has ever taken, the next hand-over's buffer is
          # meant to start at — kept less one, and shifted up to the top twelve bits so that the
          # counting wraps where the sample count does (see #emit_mixer_handover).
          MIX_LOT = :__mix_lot

          # A voice slot, in EWRAM: the sample's address in ROM, how far it has played (a whole
          # sample index), its length, HOW FAR BACK it goes at the end (0 for a sound that plays
          # once), whether it's sounding, its level (0..64), and — for pitch — a 16.16
          # fixed-point STEP (how many source samples to advance per output sample: 1.0 = 0x10000
          # plays at the recorded pitch, 2.0 an octave up) plus a FRAC accumulator carrying the
          # leftover fraction between frames, kept in its TOP 16 bits so that adding to it
          # overflows exactly when a whole sample is due (see #emit_mix_routine).
          #
          # LOOP IS A DISTANCE AND NOT A FLAG, which is what lets a note be HELD: a piano
          # recorded for half a second and held for two reads round a point part way in rather
          # than starting over, so the attack is heard once and the body of the note goes on for
          # as long as the note does. A sound that loops in the ordinary way goes back by its
          # whole length, which is the same subtraction — so the mix has one case, not two, and
          # it is one instruction shorter than the flag was.
          #
          # A game sound's slot also keeps its TICKET — which play started it, counting up — so
          # the one playing longest can be told apart when a song's note needs its voice. A
          # sound that loops has the top bit set, which makes it later than every sound that
          # plays once, so it is the last to go.
          #
          # THEN THE ENVELOPE, for a voice that has one (see {RubyGBA::Envelope}): the four
          # numbers packed into ENV, where the LEVEL has climbed or fallen to, which PHASE of the
          # note it is in, GAIN — the loudness the mix actually multiplies by, which is VOL
          # scaled by that level — and RAMP, how far the gain moves with each sample. ENV of 0
          # means no envelope at all, and then none of the four is ever read and the gain never
          # moves.
          #
          # THE LEVEL IS WORKED OUT ONCE A FRAME, by the pass before the mix. What the pass hands
          # the mix is not a new gain but a SLIDE to it: how far the gain has to move by the end of
          # the frame, shared out over the frame's samples. A fade that took its steps at the frame
          # boundary would be a staircase, and every step of a staircase is a click — a fast
          # release falls most of the way in its first frame, so the first step is most of the
          # wave. Slid, the gain never moves further in one sample than a sixty-fourth of a frame's
          # worth of change, whatever fade was asked for.
          #
          # SO THE GAIN KEEPS A FRACTION under it (GAIN_FRACTION bits), which a slide needs: a
          # quiet fade moves the gain by far less than one whole step a sample. The mix writes
          # back where the slide left it, and the next frame's slide starts from there, so any
          # rounding in one frame is taken up by the next rather than piling up.
          SLOT_SRC = 0
          SLOT_POS = 4
          SLOT_LEN = 8
          SLOT_LOOP = 12
          SLOT_ACTIVE = 16
          SLOT_VOL = 20
          SLOT_STEP = 24
          SLOT_FRAC = 28
          SLOT_TICKET = 32
          SLOT_ENV = 36
          SLOT_LEVEL = 40
          SLOT_PHASE = 44
          SLOT_GAIN = 48
          SLOT_RAMP = 52
          SLOT_BYTES = 56

          # How many bits of fraction the gain keeps in a game that shapes a note. Sixteen is as
          # many as fit: the gain is at most 64, which with sixteen under it is 22 bits, and a
          # sample is at most 128, which is 8 more — 30, inside the 32 a multiply keeps.
          GAIN_FRACTION = 16

          # The slide is a distance divided by the samples in a frame, and the divide is a
          # multiply by the share one sample gets, out of 1 << (2 * RAMP_SPLIT). The distance is
          # shifted down this far before the multiply and the product this far after, which is
          # what keeps a whole gain's worth of distance inside 32 bits on the way.
          RAMP_SPLIT = 8

          # The link register: where a routine returns to, and the one register the mix borrows
          # past r12 (see #emit_mix_routine).
          LR = 14

          # Which part of a note a voice is in. Climbing, then holding (which covers the fall to
          # the sustain level and the hold there — one test tells them apart, the level against
          # the sustain), then falling away after the note has ended — and then DONE, which is
          # the frame the gain spends sliding the last of the way to nothing. The voice is given
          # back at the END of that frame rather than the start of it, because a voice taken away
          # while its gain is still above nothing is the very click this is here to remove.
          PHASE_CLIMBING = 0
          PHASE_HOLDING = 1
          PHASE_FALLING = 2
          PHASE_DONE = 3

          # Whose a sounding slot is, in its SOUNDING word: the game's, or a song's recorded part.
          OWNER_GAME = 1
          def self.music_owner(lane) = OWNER_GAME + 1 + lane

          # ...and in a game whose sound effects play recordings, whose it is and how it RANKS
          # (IR::Tunes.song_rank), since a note of a song or an effect can then take the voice of
          # one ranked below it. The rank, one more so that every such mark sits above the game's,
          # goes above the part's own number. Comparing two marks shifted down by this many bits
          # compares their ranks, and two parts of one song or one effect rank the same, so never
          # take each other's voice.
          MARK_RANK_SHIFT = 5
          def self.ranked_owner(rank, lane) = ((rank + 1) << MARK_RANK_SHIFT) | lane

          TICKETS = :__mix_tickets # how many sounds the game has started, for the next ticket
          LOOPS_LAST = 0x8000_0000

          # WHAT DID NOT PLAY, counted on the console so a run can be asked about it.
          #
          # A `play` that finds every voice busy is dropped — deliberately, rather than cutting
          # off a sound already sounding — and the console says nothing about it. Nothing on
          # screen does either: the game carries on, one sound quieter than the author wrote.
          # Whether it happens at all depends on play (a burst of explosions, a chord of music
          # under them), so no build can see it; only a run can, and a run is what `rom.profile`
          # reports on.
          #
          # Two words, both written on the drop path and nowhere else, so a game that never
          # runs out of voices pays for none of this beyond the miss branch it already had:
          #
          #   DROPS       — how many plays, and notes of songs and sound effects, found no voice.
          #   DROPS_MUSIC — the most voices SONGS AND EFFECTS held at one of those moments. The count of
          #                 voices SOUNDING needs no counting: a drop means every one of them
          #                 was. What the author cannot know without measuring is how the
          #                 music and the game's own sounds were splitting them, which is the
          #                 half they can do something about.
          DROPS = :__mix_drops
          DROPS_MUSIC = :__mix_drops_music

          # The fixed-point shift for STEP/FRAC: 16 fractional bits, so 1.0 == 1 << 16.
          STEP_SHIFT = 16
          STEP_ONE = 1 << STEP_SHIFT

          # ONE SOUNDING VOICE, read back off a running console: which sample it is playing,
          # how far through it (a whole sample index), how long that sample is, how fast it
          # reads it (16.16 — STEP_ONE is the recorded pitch), whether it loops, its level
          # (0..64), and whose it is — :game, [:song, part] or [effect, part], the same answer the
          # interpreter's Reference#sound_owners gives. Values rather than addresses, so a test
          # asks what is playing and never learns where in memory it is kept.
          Voice = Data.define(:sample, :position, :length, :step, :loop, :volume, :owner)

          # WHERE THE CONSOLE KEEPS WHAT IT IS PLAYING, published by the build so the finished
          # cartridge can be asked about its own sound (see BuildRecord#voices).
          #
          # Nothing about the voices is hardware. The mixer is software this backend emits,
          # and it sums every voice into ONE sound channel before the hardware sees any of it,
          # so the only place the voices exist separately is this table in memory.
          # Reading it is reading what the lowering really did.
          #
          # The decoding lives here, beside the code that writes the table, so the slot layout
          # above is defined in one place and read in one place — a test that wants to know
          # what is sounding says `verifier.voices` and never counts bytes into a slot.
          #
          # +sample_addresses+ maps each sample's name to where it landed in the cartridge,
          # which is how a slot's source address becomes a name again. Two samples with
          # identical bytes may share one address, and then a voice playing either reads back
          # as whichever was declared first.
          # +clock+ is the sample clock the build settled on (Timers.sample_clock), and it
          # belongs here because a voice's STEP is meaningless without it: a step of 1.0 means
          # "read the recording at this rate", so what pitch that comes out at depends on the
          # rate. It is also the one thing about the mixer an author might want to see, which
          # is why `rom.profile` reports it.
          #
          # +effect_marks+ turns the mark on a sound effect's voice back into [effect, part]. A game
          # with any has ranked marks (Mixer.ranked_owner) on its song's voices too.
          VoiceTable = Data.define(:base, :count, :sample_addresses, :clock, :effect_marks) do
            def initialize(effect_marks: {}, **rest) = super

            # The sounding voices, in slot order. The block reads one 32-bit word off the
            # console at the address it is given — the reader is handed in rather than owned,
            # so this can be tested against a plain Hash as easily as against an emulator.
            def read
              names = sample_addresses.invert
              (0...count).filter_map do |slot|
                at = base + (slot * SLOT_BYTES)
                mark = yield(at + SLOT_ACTIVE)
                next if mark.zero?

                Voice.new(sample: names[yield(at + SLOT_SRC)], position: yield(at + SLOT_POS),
                          length: yield(at + SLOT_LEN), step: yield(at + SLOT_STEP),
                          loop: !yield(at + SLOT_LOOP).zero?, volume: yield(at + SLOT_VOL),
                          owner: owner(mark))
              end
            end

            def owner(mark)
              return :game if mark == OWNER_GAME
              return effect_marks.fetch(mark) if effect_marks.key?(mark)
              return [:song, mark & ((1 << MARK_RANK_SHIFT) - 1)] unless effect_marks.empty?

              [:song, mark - Mixer.music_owner(0)]
            end
          end

          # WHERE THE CONSOLE COUNTS WHAT IT COULD NOT PLAY, published by the build the same
          # way the voice table is and for the same reason: the two words are hidden variables,
          # so their addresses exist only in the build and cannot be recovered from the
          # cartridge afterwards.
          #
          # +voices+ is how many there are in all, which is what makes the count mean something
          # — "12 dropped, the music held 9 of the 16" is a sentence; "12 dropped" is a number.
          DropTable = Data.define(:drops_at, :music_at, :voices) do
            # What the console has counted so far. The block reads one 32-bit word off it, the
            # same reader the voice table takes, so this can be read from a running emulator or
            # from a plain Hash.
            def read
              SoundDrops::Reading.new(dropped: yield(drops_at), music_held: yield(music_at),
                                      voices: voices)
            end
          end

          # Volume level names → a 0..64 gain the mix multiplies each sample by (then shifts
          # right by 6, i.e. divides by 64) — so :full leaves a sample unchanged and :half
          # halves it. The same words the other sound verbs use.
          MIX_LEVELS = { full: 64, three_quarter: 48, half: 32, quarter: 16, mute: 0 }.freeze
          VOL_SHIFT = 6 # 2**6 = 64, the :full gain

          # Which of the two output buffers the DMA is playing right now (0 or 1).
          MIX_FRONT = :__mix_front

          attr_reader :mix_buf0, :mix_buf1 # the two output buffers' addresses (a test reads them back)
          attr_reader :voice_base          # the voice slots' base address (a test reads a voice's state)

          def initialize(emitter:, memory:, timers:, primitives:)
            @emitter = emitter
            @memory = memory
            @timers = timers
            @primitives = primitives
            @samples = {}          # name -> { rate:, length: } (a Direct Sound PCM sample)
            @plays_samples = false # does the program play any sample (uses Direct Sound)?
            @music_takes_voices = false # does a song's recorded part start notes in the slots?
            @uses_envelopes = false # does any note in it have a shape (see #emit_envelope_step)?
            @effect_marks = {}      # a sound effect's part's mark -> [effect, part], when its notes rank
          end

          # The output rate the mix runs at, settled by #prepare_mixer.
          attr_reader :mixer_rate

          # Does the program play any sample (so the mixer needs bringing up)?
          def plays_samples?
            @plays_samples
          end

          # What a declared sample is — its rate, length and recorded note — for the music
          # player, which works out each note's step from them.
          def sample_info(name)
            @samples[name] ||
              raise(LoweringError, "play_sample of undefined sample #{name.inspect} — declare it with `sample`")
          end

          # A song's recorded parts start notes in the slots, so the mixer is brought up — and
          # the routine that finds a note its voice goes in the screen's interrupt.
          def music_takes_voices!
            @music_takes_voices = true
            @plays_samples = true
          end

          def music_takes_voices? = @music_takes_voices

          # ...and a sound effect's recorded parts do too, so every mark carries its rank
          # (Mixer.ranked_owner) and a note can take the voice of one ranked below it. +effect_marks+
          # is each effect part's mark, to [effect, part], for reading the voices back.
          def ranks_voices!(effect_marks)
            music_takes_voices!
            @effect_marks = effect_marks
          end

          def ranks_voices? = !@effect_marks.empty?

          # ...and a game that moves the music volume sets a part's note to the new level while it
          # sounds, so it needs to find the voice the note is on.
          def music_follows_level! = @music_follows_level = true

          # The routines that find a song's note a voice, stop it, and find the voice it is on
          # (#emit_music_voice_routines).
          MUSIC_VOICE = :__music_voice
          MUSIC_VOICE_OFF = :__music_voice_off
          MUSIC_VOICE_FIND = :__music_voice_find

          # Register the samples: embed each one's PCM data as a ROM blob and note the
          # program plays sound. #prepare_mixer reserves the timer and memory.
          def prepare_direct_sound(program)
            program.walk.each do |node|
              case node.kind
              when :sample
                @emitter.data_blobs[node.name] = node.bytes # embed the PCM data as a ROM blob
                @samples[node.name] = Assets::Sample.of(node)
              when :play_sample
                @plays_samples = true
              end
            end
          end

          # Decide the mixer's output rate and per-frame buffer size, and reserve its memory:
          # two output buffers and the voice slots in EWRAM, the running totals in IWRAM. The rate follows the
          # samples, so a single-rate game plays at its recorded pitch. Reserves only timer 0
          # (the sample clock) — the refill rides on the screen's own interrupt, not on a
          # second timer and not on the game loop.
          # What the mixing routine is called, and where it RUNS — which is not where it is
          # stored. It is copied into the console's quick memory at boot, like the divide
          # routines, because it runs over every sample of every sounding voice once a frame
          # and is one of the busiest things in a game that plays sampled sound.
          #
          # That is exactly why a measured profile has to be able to name it: on
          # the Wolfenstein port, which plays sampled audio, it is about a fifth of the frame, and
          # without this it reads as code nothing can account for.
          ROUTINE = :__mix_routine

          def mix_routine_addresses
            return {} unless @mix_routine_iwram

            size = @emitter.labels.fetch(:__mix_routine_end) - @emitter.labels.fetch(ROUTINE)
            { ROUTINE => @mix_routine_iwram...(@mix_routine_iwram + size) }
          end

          # Where the voices are kept and where each sample landed, for the build record to
          # carry — or nil for a program that plays no samples and so has no voices at all.
          # Valid after the program is laid out, when every sample's position is known. A
          # sample's run-time address is the same cartridge arithmetic a data load is patched
          # with: base, plus the header, plus where the blob sits.
          def voice_table
            return nil unless @voice_base

            VoiceTable.new(base: @voice_base, count: MAX_VOICES, clock: @sample_clock, effect_marks: @effect_marks,
                           sample_addresses: @samples.keys.to_h do |name|
                             [name, ROM_START + RubyGBA::ROM::ENTRY_OFFSET + @emitter.data_positions.fetch(name)]
                           end)
          end

          # Where the console counts the sounds it could not play, for the build record to
          # carry — or nil for a program that plays no samples, which can lose none.
          def drop_table
            return nil unless @voice_base

            DropTable.new(drops_at: @primitives.var_addr(DROPS),
                          music_at: @primitives.var_addr(DROPS_MUSIC), voices: MAX_VOICES)
          end

          def prepare_mixer(program)
            return unless @plays_samples

            @uses_envelopes = shapes_any_note?(program)

            # The clock and the samples-a-frame are ONE decision, not two: the hardware eats a
            # sample every time this timer overflows, so how many it eats in a frame is fixed
            # by the clock, and that is exactly how many the mix has to write. Asking for both
            # separately is how they came to disagree. See Timers.sample_clock.
            @sample_clock = Timers.sample_clock(common_sample_rate(program))
            @mixer_rate = @sample_clock.rate
            @mixer_spf = @sample_clock.samples_a_frame
            @mix_buf0 = @memory.alloc_roomy(buffer_bytes)
            @mix_buf1 = @memory.alloc_roomy(buffer_bytes)
            # WHAT GOES IN THE QUICK MEMORY is decided by how often the mix touches it. The
            # running total of every voice — a halfword per output sample, read and written
            # again for every voice at every sample — goes there. The voice slots do not: the
            # mix reads a sounding voice's slot once a frame and writes it back once, so they
            # cost the same in the roomy memory, and the room they would have taken is the room
            # the totals need.
            @mix_totals = @memory.alloc(@mixer_spf * 2)
            @voice_base = @memory.alloc_roomy(MAX_VOICES * SLOT_BYTES)
            @mix_routine_iwram = @memory.alloc(MIX_ROUTINE_IWRAM_MAX) # the mix routine is copied here from ROM at boot
            @timers.reserve!(COUNT_TIMER + 1, because: "Sampled sound uses two of them: one to play the " \
                                                       "sound, and one to count how much of it has played.")
          end

          # THE LOTS EACH BUFFER CARRIES PAST ITS END: enough of the next buffer's start to cover
          # a hand-over LATE_ROOM late, rounded up to whole lots.
          def guard_lots
            lot = Timers::DMA_SAMPLES_A_LOT * @sample_clock.period
            (LATE_ROOM + lot - 1) / lot
          end

          # HOW FAR OFF THE NEXT SAMPLE HAS TO BE, in cycles, for the hand-over to read the count
          # and re-arm the DMA before it comes. That is about fifteen instructions, and 512 cycles
          # is several times what they take even from the cartridge at its slowest timing; a
          # clock too fast to leave that much of a sample clear gets three quarters of one
          # instead. It has to stay short of a whole sample, or the wait would never end.
          def count_clearance = [@sample_clock.period * 3 / 4, 512].min

          def lots_a_frame = @mixer_spf / Timers::DMA_SAMPLES_A_LOT

          def buffer_bytes = @mixer_spf + (guard_lots * Timers::DMA_SAMPLES_A_LOT)

          # Bring the mixer up at boot: silence the voice slots and both buffers, power on
          # the sound hardware, point the DMA at the first buffer and the sample clock at the
          # mixer rate. From here the DMA plays silence until a voice is added.
          def emit_mixer_boot
            emit_zero_region(@voice_base, MAX_VOICES * SLOT_BYTES) # all voices idle
            emit_zero_region(@mix_totals, @mixer_spf * 2)          # the totals start at nothing
            emit_zero_region(@mix_buf0, buffer_bytes)              # buffers start silent...
            emit_zero_region(@mix_buf1, buffer_bytes)
            @emitter.emit(ASM.load_immediate(ACC, 0))
            @primitives.store_var(ACC, MIX_FRONT)                  # ...playing buffer 0 first
            # NOTHING HAS BEEN LOST YET, and this has to be said rather than assumed: the
            # console's memory is not zero at power-on, so a counter left unwritten reads as
            # whatever was there and a game that dropped nothing would report rubbish.
            @primitives.store_var(ACC, DROPS)
            @primitives.store_var(ACC, DROPS_MUSIC)
            # A lot half the count away from any the DMA could be on, so the first hand-over
            # finds it out of reach and starts the counting from wherever the DMA really is.
            @emitter.emit(ASM.load_immediate(ACC, 0x8000_0000))
            @primitives.store_var(ACC, MIX_LOT)

            @emitter.write_reg16(REG_SOUNDCNT_X, SOUND_MASTER_ENABLE)   # master sound on
            @emitter.write_reg16(REG_SOUNDCNT_H, direct_sound_a_config) # channel A, full volume, FIFO reset
            @emitter.emit(ASM.load_immediate(ACC, @mix_buf0))
            store_reg_ioreg(ACC, REG_DMA1SAD)                      # DMA source = buffer 0
            @primitives.store_word_immediate(REG_FIFO_A, REG_DMA1DAD) # DMA dest = the sound FIFO
            # ...feeding it continuously, and for now saying so each time it does (see below).
            @primitives.store_word_immediate(dma_fifo_control | DMA_IRQ, REG_DMA1CNT)

            # Timer 1 counts the samples from nothing. It is started first: chained, it waits
            # for timer 0, so it counts every sample timer 0 ever clocks.
            @emitter.write_reg16(@timers.timer_reg_l(COUNT_TIMER), 0)
            @emitter.write_reg16(@timers.timer_reg_h(COUNT_TIMER), TIMER_ENABLE | TIMER_CASCADE)
            @emitter.write_reg16(@timers.timer_reg_l(CLOCK_TIMER), 65_536 - CALIBRATION_PERIOD)
            @emitter.write_reg16(@timers.timer_reg_h(CLOCK_TIMER), TIMER_ENABLE | Timers::FINEST_PRESCALER)

            emit_find_lot_grid

            # Now timer 0 = the sample clock, written as the PERIOD the clock was chosen as rather
            # than by asking for its rate back: going through a rate would divide and truncate
            # a second time, and land a cycle or two off the period a frame divides. The new
            # period is taken up at the next sample, without restarting anything.
            @emitter.write_reg16(@timers.timer_reg_l(CLOCK_TIMER), 65_536 - @sample_clock.period)
            # Back to the start of buffer 0, with the DMA no longer announcing every lot.
            @emitter.emit(ASM.load_immediate(ACC, @mix_buf0))
            store_reg_ioreg(ACC, REG_DMA1SAD)
            emit_rearm_dma

            emit_copy_mix_routine_to_iwram
          end

          # WHERE THE DMA'S LOTS FALL AGAINST THE SAMPLE COUNT — which of every sixteen samples
          # is the one the sound hardware asks for more on. The hand-over needs it to turn a
          # count of samples into a count of lots, and it is the one fact about the sound
          # hardware that cannot be written down ahead of time: the asking follows how full the
          # FIFO is, and a FIFO starting from empty asks a few times out of step before it
          # settles, differently on different hardware. Once settled it never moves.
          #
          # So it is watched. The DMA was told to raise its flag each time it moves a lot; this
          # waits for the flag, reads the sample count at once, and stops at the first two lots
          # exactly sixteen samples apart, which is the grid settled. Interrupts are not armed
          # yet, so nothing else clears the flag, and the count is read long before the next
          # sample: a turn of the loop is a few instructions, and a sample is CALIBRATION_PERIOD
          # cycles.
          #
          # If the flag never comes — which it always does, but a boot that hangs is the one
          # failure nobody can see the cause of — it gives up after a while and takes 0. The sound
          # still plays; a game busy past the end of its frame may click where the guess is wrong.
          def emit_find_lot_grid
            e = @emitter
            wait = e.gensym
            found = e.gensym
            gave_up = e.gensym
            e.emit(ASM.push(4))
            e.emit(ASM.load_immediate(ADDR, REG_IF))
            e.emit(ASM.load_immediate(3, @timers.timer_reg_l(COUNT_TIMER)))
            e.emit(ASM.load_immediate(4, IRQ_DMA1))
            e.emit(ASM.load_immediate(2, 0x10000))     # the last lot's count: none yet
            e.emit(ASM.load_immediate(1, 0x10000))     # turns of the loop before giving up
            e.emit(ASM.store_halfword(4, ADDR))        # clear a flag left from before
            e.place_label(wait)
            e.emit(ASM.subs_imm(1, 1, 1))
            e.emit_branch(:bcond, gave_up, cond: :eq)
            e.emit(ASM.load_halfword(ACC, ADDR))
            e.emit(ASM.tst_imm(ACC, IRQ_DMA1))
            e.emit_branch(:bcond, wait, cond: :eq)     # no lot moved yet
            e.emit(ASM.load_halfword(ACC, 3))          # the count, the moment one did
            e.emit(ASM.store_halfword(4, ADDR))        # and clear its flag for the next
            e.emit(ASM.sub_reg(2, ACC, 2))
            e.emit(ASM.cmp_imm(2, Timers::DMA_SAMPLES_A_LOT))
            e.emit(ASM.mov_reg(2, ACC))
            e.emit_branch(:bcond, wait, cond: :ne)     # not a lot's worth since the last: not settled
            e.emit(ASM.and_imm(ACC, ACC, Timers::DMA_SAMPLES_A_LOT - 1))
            e.emit_branch(:b, found)
            e.place_label(gave_up)
            e.emit(ASM.load_immediate(ACC, 0))
            e.place_label(found)
            e.emit(ASM.pop(4))
            @primitives.store_var(ACC, MIX_PHASE)
          end

          # Copy the mix routine from ROM into IWRAM once, at boot, so its per-sample inner
          # loop runs with no ROM wait states. The routine is position-independent — relative
          # branches, immediates built with MOV/ORR (no PC-relative literal pool) — so it runs
          # correctly from either place, and the ARM7 has no instruction cache, so the copy
          # needs no flush. Copies whole words from the routine's start label up to its end.
          def emit_copy_mix_routine_to_iwram
            @emitter.emit_load_label_address(0, :__mix_routine)      # r0 = routine start in ROM
            @emitter.emit_load_label_address(1, :__mix_routine_end)  # r1 = routine end in ROM
            @emitter.emit(ASM.load_immediate(2, @mix_routine_iwram)) # r2 = IWRAM destination
            copy = @emitter.gensym
            @emitter.place_label(copy)
            @emitter.emit(ASM.ldr(3, 0))                             # r3 = [r0]
            @emitter.emit(ASM.str(3, 2))                             # [r2] = r3
            @emitter.emit(ASM.add_imm(0, 0, 4))
            @emitter.emit(ASM.add_imm(2, 2, 4))
            @emitter.emit(ASM.cmp_reg(0, 1))
            @emitter.emit_branch(:bcond, copy, cond: :lt)            # while r0 < r1
          end

          # play_sample: start a sample sounding by filling a free voice slot with it — its
          # ROM address, a fresh play position, its length, whether it loops, and its ticket.
          # If every slot is busy the play is dropped, rather than cutting off a sound already
          # playing.
          def emit_play_sample(node)
            sample = sample_info(node.name)
            holding_off_interrupts do
              @emitter.emit_load_data_address(4, node.name) # r4 = the sample's address in ROM
              find_free_slot                          # r0 = a free slot's address, or none -> skip
              done = @emitter.gensym
              @emitter.emit(ASM.cmp_imm(0, 0))        # find_free_slot leaves r0 = 0 when full
              @emitter.emit_branch(:bcond, done, cond: :eq)

              @emitter.emit(ASM.str(4, 0))                             # slot.src = address (SLOT_SRC = 0)
              @emitter.emit(ASM.load_immediate(TMP, 0))
              @emitter.emit(ASM.str_offset(TMP, 0, SLOT_POS))          # slot.pos = 0
              @emitter.emit(ASM.load_immediate(TMP, sample.length))
              @emitter.emit(ASM.str_offset(TMP, 0, SLOT_LEN))          # slot.len = length
              @emitter.emit(ASM.load_immediate(TMP, loop_back(node, sample)))
              @emitter.emit(ASM.str_offset(TMP, 0, SLOT_LOOP))         # how far back at the end
              @emitter.emit(ASM.load_immediate(TMP, MIX_LEVELS.fetch(node.volume, MIX_LEVELS[:full])))
              @emitter.emit(ASM.str_offset(TMP, 0, SLOT_VOL))          # slot.volume (0..64 gain)
              emit_start_envelope(0, TMP, sample.envelope) if @uses_envelopes
              @emitter.emit(ASM.load_immediate(TMP, voice_step(node, sample)))
              @emitter.emit(ASM.str_offset(TMP, 0, SLOT_STEP))         # slot.step (pitch + rate, 16.16)
              @emitter.emit(ASM.load_immediate(TMP, 0))
              @emitter.emit(ASM.str_offset(TMP, 0, SLOT_FRAC))         # slot.frac = 0 (fresh)
              @primitives.load_var(2, TICKETS)
              @emitter.emit(ASM.add_imm(2, 2, 1))
              @primitives.store_var(2, TICKETS)                        # the next ticket...
              @emitter.emit(ASM.orr_imm(2, 2, LOOPS_LAST)) if node.loop # ...after every one-shot, if it loops
              @emitter.emit(ASM.str_offset(2, 0, SLOT_TICKET))
              @emitter.emit(ASM.load_immediate(TMP, OWNER_GAME))
              @emitter.emit(ASM.str_offset(TMP, 0, SLOT_ACTIVE))       # slot.active: the game's (now it sounds)
              @emitter.place_label(done)
            end
          end

          # HOW FAR BACK A VOICE GOES when it reaches the end of its recording, or 0 for one that
          # plays once and stops. A sound asked to loop goes back to where the recording holds
          # from — which for a recording with no hold point is its very start, so the ordinary
          # loop is this same subtraction.
          def loop_back(node, sample)
            return 0 unless node.loop

            held = sample.held_by
            held.positive? ? held : sample.length
          end

          # THE FOUR NUMBERS AND WHERE THE NOTE STARTS, written onto a voice that is about to
          # sound. A voice with no envelope writes 0 for the four, which is what tells the pass
          # before the mix to leave it alone — its gain is its loudness and never moves.
          # +slot+ holds the voice's address and +scratch+ is a register free to be clobbered.
          def emit_start_envelope(slot, scratch, envelope)
            shape = envelope && !envelope.plain? ? envelope : nil
            @emitter.emit(ASM.load_immediate(scratch, shape ? shape.packed : 0))
            @emitter.emit(ASM.str_offset(scratch, slot, SLOT_ENV))
            @emitter.emit(ASM.load_immediate(scratch, shape ? 0 : Envelope::FULL))
            @emitter.emit(ASM.str_offset(scratch, slot, SLOT_LEVEL)) # a shaped note climbs from nothing
            @emitter.emit(ASM.load_immediate(scratch, PHASE_CLIMBING))
            @emitter.emit(ASM.str_offset(scratch, slot, SLOT_PHASE))
            # The gain the mix reads, and no slide. A shaped note is climbed by the pass before the
            # first mix, which is the same frame, so nothing of the note is lost by starting it at
            # nothing.
            @emitter.emit(ASM.load_immediate(scratch, 0))
            @emitter.emit(ASM.str_offset(scratch, slot, SLOT_RAMP))
            unless shape
              @emitter.emit(ASM.ldr_offset(scratch, slot, SLOT_VOL))
              @emitter.emit(ASM.lsl_imm(scratch, scratch, GAIN_FRACTION))
            end
            @emitter.emit(ASM.str_offset(scratch, slot, SLOT_GAIN))
          end

          # The 16.16 step for a voice: how many source samples to advance per output sample.
          # It rolls the sample's own rate against the mixer's output rate (so an off-rate
          # clip still sounds right) and the pitch shift (playing at a note other than the
          # sample's recorded one reads it faster or slower). At least 1, so it never stalls.
          def voice_step(node, sample)
            notes = RubyGBA::Music::NOTE_FREQUENCIES
            step_at(sample, notes.fetch(node.pitch || sample.note || :C4))
          end

          # The 16.16 step that sounds +sample+ at +frequency+ Hz — the same sum for a note a game
          # plays and a note a song plays, so the two are in tune with each other.
          def step_at(sample, frequency)
            ratio = frequency.to_f / RubyGBA::Music::NOTE_FREQUENCIES.fetch(sample.note || :C4)
            step = (sample.rate.to_f / @mixer_rate) * ratio
            [(step * STEP_ONE).round, 1].max
          end

          # stop_sample: silence a sample by clearing every voice slot playing it (or every
          # slot, when no sample is named). Just flips each matching slot's "active" off. The
          # game's own sounds only: a note the music is playing is the music's to stop.
          def emit_stop_sample(node = nil)
            name = node && node.name
            holding_off_interrupts do
              @emitter.emit_load_data_address(4, name) if name # r4 = the sample's address to match
              @emitter.emit(ASM.load_immediate(1, @voice_base))                            # r1 = slot pointer
              @emitter.emit(ASM.load_immediate(2, @voice_base + (MAX_VOICES * SLOT_BYTES))) # r2 = past the last
              loop_lbl = @emitter.gensym
              skip = @emitter.gensym
              @emitter.place_label(loop_lbl)
              @emitter.emit(ASM.ldr_offset(0, 1, SLOT_ACTIVE))
              @emitter.emit(ASM.cmp_imm(0, OWNER_GAME))
              @emitter.emit_branch(:bcond, skip, cond: :ne)              # not a sound of the game's
              if name
                @emitter.emit(ASM.ldr(0, 1))                             # r0 = slot.src
                @emitter.emit(ASM.cmp_reg(0, 4))                         # slot plays this sample?
                @emitter.emit_branch(:bcond, skip, cond: :ne)            # no -> leave it
              end
              @emitter.emit(ASM.load_immediate(0, 0))
              @emitter.emit(ASM.str_offset(0, 1, SLOT_ACTIVE))           # active = 0
              @emitter.place_label(skip)
              @emitter.emit(ASM.add_imm(1, 1, SLOT_BYTES))               # next slot
              @emitter.emit(ASM.cmp_reg(1, 2))
              @emitter.emit_branch(:bcond, loop_lbl, cond: :lt)
            end
          end

          # THE GAME TOUCHES THE VOICE TABLE WITH INTERRUPTS HELD OFF. The screen's interrupt can
          # take a voice for a song's note between any two instructions, so a slot `play` has
          # just seen free, or one `stop` has just seen is the game's, could be the song's by the
          # time the game writes to it — and the game would start its sound over a note, or cut
          # the note off. With interrupts held off for the few dozen instructions the game
          # spends in the table, the interrupt waits and then sees it whole. r3 keeps what the
          # master switch was, so it is put back as it was found.
          def holding_off_interrupts
            @emitter.emit(ASM.load_immediate(TMP, REG_IME))
            @emitter.emit(ASM.load_halfword(3, TMP))
            @emitter.emit(ASM.load_immediate(ACC, 0))
            @emitter.emit(ASM.store_halfword(ACC, TMP))
            yield
            @emitter.emit(ASM.load_immediate(TMP, REG_IME))
            @emitter.emit(ASM.store_halfword(3, TMP))
          end

          # A NOTE OF A SONG'S RECORDED PART NEEDS A VOICE — the call the music player makes, from
          # the screen's interrupt, with the part's mark in r8. Leaves the voice in r7.
          def emit_take_music_voice
            @emitter.emit_branch(:bl, MUSIC_VOICE)
          end

          # ...and a part rests, or its tune stops: whichever voice has the part's mark (r8) goes
          # quiet.
          def emit_music_voice_off
            @emitter.emit_branch(:bl, MUSIC_VOICE_OFF)
          end

          # ...and the voice sounding the part's note (r8) is wanted in r7, or 0 when it has none.
          def emit_find_music_voice
            @emitter.emit_branch(:bl, MUSIC_VOICE_FIND)
          end

          # The routines those call, emitted once inside the screen's interrupt.
          def emit_music_voice_routines
            emit_music_voice_routine
            emit_music_voice_off_routine
            emit_music_voice_find_routine if @music_follows_level
          end

          # The voice sounding the part's note (r8's mark) into r7, or 0 when the part has none —
          # its recording ran out and the mix retired it, or it rested. A voice of the part's that
          # is falling away is an earlier note on its way out, not this one, and is passed over:
          # the same reading #emit_music_voice_off_routine makes. Uses r0, r1, r7.
          def emit_music_voice_find_routine
            e = @emitter
            scan = e.gensym
            onward = e.gensym
            done = e.gensym
            e.place_label(MUSIC_VOICE_FIND)
            e.emit(ASM.load_immediate(7, @voice_base))
            e.emit(ASM.load_immediate(1, @voice_base + (MAX_VOICES * SLOT_BYTES)))
            e.place_label(scan)
            e.emit(ASM.ldr_offset(0, 7, SLOT_ACTIVE))
            e.emit(ASM.cmp_reg(0, 8))
            e.emit_branch(:bcond, onward, cond: :ne)
            if @uses_envelopes
              e.emit(ASM.ldr_offset(0, 7, SLOT_PHASE))
              e.emit(ASM.cmp_imm(0, PHASE_FALLING))
              e.emit_branch(:bcond, onward, cond: :hs)
            end
            e.emit_branch(:b, done)
            e.place_label(onward)
            e.emit(ASM.add_imm(7, 7, SLOT_BYTES))
            e.emit(ASM.cmp_reg(7, 1))
            e.emit_branch(:bcond, scan, cond: :lt)
            e.emit(ASM.load_immediate(7, 0))
            e.place_label(done)
            e.emit(ASM.return)
          end

          # Stop the voice sounding the part's note (r8's mark) — or nothing, when the part has
          # none: its last note ran out, and the mix retired it. Uses r0, r1, r7.
          #
          # A SHAPED NOTE IS NOT STOPPED HERE, it is only told to start falling. What ends it is
          # the pass before the mix, when its level has fallen away to nothing — which is the
          # whole point, because a note that stops leaves the speaker wherever the wave was and
          # that jump is a click. A voice with no envelope stops the moment it is told to, as it
          # always did.
          #
          # A voice of the part's that is ALREADY falling is passed over: that is an earlier note
          # on its way out, and the one to let go of is the note sounding now.
          def emit_music_voice_off_routine
            e = @emitter
            scan = e.gensym
            onward = e.gensym
            done = e.gensym
            e.place_label(MUSIC_VOICE_OFF)
            e.emit(ASM.load_immediate(7, @voice_base))
            e.emit(ASM.load_immediate(1, @voice_base + (MAX_VOICES * SLOT_BYTES)))
            e.place_label(scan)
            e.emit(ASM.ldr_offset(0, 7, SLOT_ACTIVE))
            e.emit(ASM.cmp_reg(0, 8))
            e.emit_branch(:bcond, onward, cond: :ne)
            if @uses_envelopes
              stop = e.gensym
              e.emit(ASM.ldr_offset(0, 7, SLOT_PHASE))
              e.emit(ASM.cmp_imm(0, PHASE_FALLING))
              e.emit_branch(:bcond, onward, cond: :hs)        # an earlier note, already on its way out
              e.emit(ASM.ldr_offset(0, 7, SLOT_ENV))
              e.emit(ASM.cmp_imm(0, 0))
              e.emit_branch(:bcond, stop, cond: :eq)          # no envelope: it stops where it is
              e.emit(ASM.load_immediate(0, PHASE_FALLING))
              e.emit(ASM.str_offset(0, 7, SLOT_PHASE))        # ...otherwise it starts falling
              e.emit_branch(:b, done)
              e.place_label(stop)
            end
            e.emit(ASM.load_immediate(0, 0))
            e.emit(ASM.str_offset(0, 7, SLOT_ACTIVE))
            e.emit_branch(:b, done)
            e.place_label(onward)
            e.emit(ASM.add_imm(7, 7, SLOT_BYTES))
            e.emit(ASM.cmp_reg(7, 1))
            e.emit_branch(:bcond, scan, cond: :lt)
            e.place_label(done)
            e.emit(ASM.return)
          end

          # WHICH VOICE A SONG'S NOTE GETS — one routine, placed inside the screen's interrupt
          # (so it moves with it into the quick memory) and called by every recorded part.
          #
          # In one walk over the slots it looks for, in order of preference:
          #
          #   1. the part's own voice, still sounding its last note with no shape to it — the new
          #      note takes it over;
          #   2. the first voice nobody is using;
          #   3. the quietest voice whose note has ended and is falling away (a TAIL, below);
          #   4. with none of those, the voice of the game's sound that has been playing longest —
          #      one that plays once before one that loops, since a loop never ends by itself.
          #      That is the rule for who gives way: a song keeps playing right, and a sound the
          #      game started a while ago is cut short.
          #
          # A PART'S NOTE THAT HAS A SHAPE IS NOT TAKEN OVER. It is told its note has ended, and
          # falls away on the voice it has while the new note takes another. Taking it over would
          # start the new recording from its top on that voice, and the old wave would stop dead
          # wherever it was — which is the click the shape is there to remove, put back one note
          # later. A falling voice is the first thing to give way, being on its way out already,
          # and the quietest of them first, since cutting that one short is the smallest jump.
          #
          # There is always a 4 when there is no 1, 2 or 3 in a game with no sound effect that
          # plays a recording: a part has one note sounding at most, and a song has fewer recorded
          # parts than there are voices, so a table full of voices that are neither free nor
          # falling has a game sound in it. It runs in the interrupt, where the game cannot be in
          # the table — `play` and `stop` hold interrupts off while they are.
          #
          # IN A GAME WHOSE SOUND EFFECTS PLAY RECORDINGS, a voice can be full of song and effect
          # notes, so the rule goes on (see Mixer.ranked_owner):
          #
          #   5. with no game sound either, the voice of the lowest-ranked note ranked below this
          #      one — the first of them, when two rank the same;
          #   6. and with none of those, no voice: r7 is 0, the note is not played, and it is
          #      counted with the sounds that did not play (#emit_note_drop).
          #
          # In: r8 = the part's mark. Out: r7 = the voice. Uses r0, r1, r9-r12 — and, in a game that
          # shapes a note, r2 and r3 as well, and in one that ranks its voices r2-r5, which it keeps
          # on the stack because the player needs them back. Returns through lr, which the
          # interrupt saved.
          def emit_music_voice_routine
            e = @emitter
            done = e.gensym
            scan = e.gensym
            busy = e.gensym
            onward = e.gensym
            ranked = e.gensym
            kept = ranks_voices? ? [2, 3, 4, 5] : @uses_envelopes ? [2, 3] : []
            e.place_label(MUSIC_VOICE)
            e.emit(ASM.push(*kept)) unless kept.empty?
            e.emit(ASM.load_immediate(7, @voice_base))
            e.emit(ASM.load_immediate(1, @voice_base + (MAX_VOICES * SLOT_BYTES)))
            e.emit(ASM.load_immediate(9, 0))                    # the first free voice, none yet
            e.emit(ASM.mvn_imm(11, 0))                          # the oldest ticket so far: none, the largest there is
            e.emit(ASM.load_immediate(10, 0))                   # ...and its voice
            if @uses_envelopes
              e.emit(ASM.mvn_imm(3, 0))                         # the quietest tail so far: none, the loudest there is
              e.emit(ASM.load_immediate(ADDR, 0))               # ...and its voice
            end
            if ranks_voices?
              e.emit(ASM.lsr_imm(5, 8, MARK_RANK_SHIFT))        # the lowest rank so far: none below this note's
              e.emit(ASM.load_immediate(4, 0))                  # ...and its voice
            end
            e.place_label(scan)
            e.emit(ASM.ldr_offset(0, 7, SLOT_ACTIVE))
            e.emit(ASM.cmp_reg(0, 8))
            if @uses_envelopes
              emit_own_voice(onward, done)
            else
              e.emit_branch(:bcond, done, cond: :eq)            # 1. the part's own
            end
            e.emit(ASM.cmp_imm(0, 0))
            e.emit_branch(:bcond, busy, cond: :ne)
            e.emit(ASM.cmp_imm(9, 0))
            e.emit(ASM.mov_reg_cond(:eq, 9, 7))                 # 2. the first free one
            e.emit_branch(:b, onward)
            e.place_label(busy)
            e.emit(ASM.cmp_imm(0, OWNER_GAME))
            other = ranks_voices? ? ranked : onward
            if @uses_envelopes
              emit_tail_candidate(onward, sounding: other)
            else
              e.emit_branch(:bcond, other, cond: :ne)           # another part's
            end
            e.emit(ASM.ldr_offset(0, 7, SLOT_TICKET))
            e.emit(ASM.cmp_reg(0, 11))
            e.emit(ASM.mov_reg_cond(:lo, 11, 0))                # 4. the game sound playing longest
            e.emit(ASM.mov_reg_cond(:lo, 10, 7))
            if ranks_voices?
              e.emit_branch(:b, onward)
              e.place_label(ranked)
              e.emit(ASM.lsr_imm(0, 0, MARK_RANK_SHIFT))
              e.emit(ASM.cmp_reg(0, 5))
              e.emit(ASM.mov_reg_cond(:lo, 5, 0))               # 5. the lowest rank below this note's
              e.emit(ASM.mov_reg_cond(:lo, 4, 7))
            end
            e.place_label(onward)
            e.emit(ASM.add_imm(7, 7, SLOT_BYTES))
            e.emit(ASM.cmp_reg(7, 1))
            e.emit_branch(:bcond, scan, cond: :lt)
            e.emit(ASM.mov_reg(7, 9))
            e.emit(ASM.cmp_imm(7, 0))
            e.emit_branch(:bcond, done, cond: :ne)
            if @uses_envelopes
              e.emit(ASM.mov_reg(7, ADDR))                      # 3. the quietest tail
              e.emit(ASM.cmp_imm(7, 0))
              e.emit_branch(:bcond, done, cond: :ne)
            end
            e.emit(ASM.mov_reg(7, 10))
            if ranks_voices?
              e.emit(ASM.cmp_imm(7, 0))
              e.emit_branch(:bcond, done, cond: :ne)
              e.emit(ASM.mov_reg(7, 4))
              e.emit(ASM.cmp_imm(7, 0))
              e.emit_branch(:bcond, done, cond: :ne)
              emit_note_drop                                    # 6. no voice at all
              e.emit(ASM.load_immediate(7, 0))
            end
            e.place_label(done)
            e.emit(ASM.pop(*kept)) unless kept.empty?
            e.emit(ASM.return)
          end

          # 1, in a game that shapes a note: the part's own voice, with the flags of comparing its
          # mark still up. A sounding note with no shape is taken over; one with a shape is told its
          # note has ended and weighed as a tail like any other; and a voice of the part's that is
          # already falling is a tail already. Anything that is not the part's falls through to
          # the free and busy tests.
          def emit_own_voice(onward, done)
            e = @emitter
            others = e.gensym
            tail = e.gensym
            e.emit_branch(:bcond, others, cond: :ne)
            e.emit(ASM.ldr_offset(2, 7, SLOT_PHASE))
            e.emit(ASM.cmp_imm(2, PHASE_FALLING))
            e.emit_branch(:bcond, tail, cond: :hs)              # an earlier note of the part's, falling
            e.emit(ASM.ldr_offset(2, 7, SLOT_ENV))
            e.emit(ASM.cmp_imm(2, 0))
            e.emit_branch(:bcond, done, cond: :eq)              # no shape: the new note takes it over
            e.emit(ASM.load_immediate(2, PHASE_FALLING))
            e.emit(ASM.str_offset(2, 7, SLOT_PHASE))            # a shape: its note ends, and it falls away
            e.place_label(tail)
            emit_weigh_tail(onward)
            e.place_label(others)
          end

          # 3: another part's voice, with the flags of comparing its mark against the game's still
          # up. The game's own goes on to be weighed by its ticket; another part's is a tail if its
          # note is falling, and otherwise goes on to +sounding+.
          def emit_tail_candidate(onward, sounding:)
            e = @emitter
            game = e.gensym
            e.emit_branch(:bcond, game, cond: :eq)
            e.emit(ASM.ldr_offset(2, 7, SLOT_PHASE))
            e.emit(ASM.cmp_imm(2, PHASE_FALLING))
            e.emit_branch(:bcond, sounding, cond: :lo)          # another part's note, still sounding
            emit_weigh_tail(onward)
            e.place_label(game)
          end

          # Keep the voice in r7 as the quietest tail if it is quieter than the one kept so far —
          # the first of them, when two are as quiet. On to the next voice either way.
          def emit_weigh_tail(onward)
            e = @emitter
            e.emit(ASM.ldr_offset(2, 7, SLOT_LEVEL))
            e.emit(ASM.cmp_reg(2, 3))
            e.emit(ASM.mov_reg_cond(:lo, 3, 2))
            e.emit(ASM.mov_reg_cond(:lo, ADDR, 7))
            e.emit_branch(:b, onward)
          end

          # ONE FRAME OF EVERY SOUNDING NOTE'S SHAPE — the pass that moves each voice's envelope
          # level on, emitted in the screen's own interrupt between the tune's frame and the mix.
          #
          # WHY IT IS HERE AND NOT IN THE MIX. The four numbers move the level once a frame, so
          # working the level out per sample would be the same answer thousands of times over.
          # What the mix does per sample is only the slide toward it — one addition — which this
          # pass works out as the gain the frame should END at, less where the gain is now,
          # shared out over the frame's samples. The dividing is done once, when the game is
          # built: a frame always has the same number of samples, so sharing out is a multiply by
          # a number worked out ahead of time.
          #
          # BETWEEN THE TUNE AND THE MIX, in that order, and both halves matter. After the tune,
          # so a note started this frame has climbed before anything is mixed and none of its
          # attack is lost. Before the mix, so the slice about to be built slides to the level
          # this frame is really at.
          #
          # A NOTE'S FIRST FRAME DOES NOT SLIDE. It starts at the level its attack gives it,
          # the way it always did: the recording starts from its own beginning, so there is no
          # sound before it to be smooth with, and sliding up from nothing would soften the
          # strike of every drum and every plucked string.
          #
          # A voice with no envelope is two instructions: its ENV is 0 and its gain never moves.
          # r4 is the slot, r5 the voices left, r1 the four numbers, r2 the level, r6 the phase,
          # r7 whether this is the note's first frame, r0/r3 scratch — all free here, since the
          # console saves r0-r3 and r12 on the way in and the dispatcher r4-r11.
          def emit_envelope_step
            e = @emitter
            voice = e.gensym
            holding = e.gensym
            falling = e.gensym
            write = e.gensym
            retire = e.gensym
            onward = e.gensym
            e.emit(ASM.load_immediate(4, @voice_base))
            e.emit(ASM.load_immediate(5, MAX_VOICES))

            e.place_label(voice)
            e.emit(ASM.ldr_offset(0, 4, SLOT_ACTIVE))
            e.emit(ASM.cmp_imm(0, 0))
            e.emit_branch(:bcond, onward, cond: :eq)          # nothing sounding here
            e.emit(ASM.ldr_offset(1, 4, SLOT_ENV))
            e.emit(ASM.cmp_imm(1, 0))
            e.emit_branch(:bcond, onward, cond: :eq)          # no envelope: its gain never moves
            e.emit(ASM.ldr_offset(2, 4, SLOT_LEVEL))
            e.emit(ASM.ldr_offset(6, 4, SLOT_PHASE))
            e.emit(ASM.load_immediate(7, 0))                  # not the note's first frame, until it is
            e.emit(ASM.cmp_imm(6, PHASE_DONE))
            e.emit_branch(:bcond, retire, cond: :eq)          # its gain reached nothing last frame
            e.emit(ASM.cmp_imm(6, PHASE_FALLING))
            e.emit_branch(:bcond, falling, cond: :eq)
            e.emit(ASM.cmp_imm(6, PHASE_CLIMBING))
            e.emit_branch(:bcond, holding, cond: :ne)

            # Climbing: the attack is ADDED each frame until the note is as loud as it was asked
            # to be, and then the note is up and holding. A level of nothing here is a note that
            # has only just started, since an attack adds at least one.
            e.emit(ASM.cmp_imm(2, 0))
            e.emit(ASM.mov_imm_cond(:eq, 7, 1))
            e.emit(ASM.and_imm(0, 1, 0xFF))
            e.emit(ASM.add_reg(2, 2, 0))
            e.emit(ASM.cmp_imm(2, Envelope::FULL))
            e.emit(ASM.mov_imm_cond(:ge, 2, Envelope::FULL))
            e.emit(ASM.mov_imm_cond(:ge, 6, PHASE_HOLDING))
            e.emit_branch(:b, write)

            # Holding: the level falls toward the sustain level and stays there. The fall is a
            # MULTIPLY by a fraction, so it slows as it goes — which is what a struck note does.
            e.place_label(holding)
            e.emit(ASM.lsr_imm(3, 1, 16))
            e.emit(ASM.and_imm(3, 3, 0xFF))                   # r3 = the sustain level
            e.emit(ASM.cmp_reg(2, 3))
            e.emit_branch(:bcond, write, cond: :le)           # already there
            e.emit(ASM.lsr_imm(0, 1, 8))
            e.emit(ASM.and_imm(0, 0, 0xFF))                   # r0 = the decay
            e.emit(ASM.mul(2, 0, 2))
            e.emit(ASM.lsr_imm(2, 2, Envelope::SCALE))
            e.emit(ASM.cmp_reg(2, 3))
            e.emit(ASM.mov_reg_cond(:lt, 2, 3))               # never below the sustain level
            e.emit_branch(:b, write)

            # Falling: the note has ended, so the level is multiplied down until there is none of
            # it left. Reaching nothing does not give the voice back on the same frame, and that
            # is deliberate: this frame is still mixed, now at no loudness at all, so what the
            # speaker hears last is silence rather than whatever the wave was doing. THEN the
            # voice goes back. A voice taken away while its gain is still up is the very click
            # all of this is here to remove.
            e.place_label(falling)
            e.emit(ASM.lsr_imm(0, 1, 24))                     # r0 = the release
            e.emit(ASM.mul(2, 0, 2))
            e.emit(ASM.lsr_imm(2, 2, Envelope::SCALE))
            e.emit(ASM.cmp_imm(2, 0))
            e.emit(ASM.mov_imm_cond(:eq, 6, PHASE_DONE))

            e.place_label(write)
            e.emit(ASM.str_offset(2, 4, SLOT_LEVEL))
            e.emit(ASM.str_offset(6, 4, SLOT_PHASE))
            # THE LOUDNESS THE FRAME ENDS AT: what the note asked for, scaled by the level. The
            # level is a byte and the scale is out of 256, so the level's own top bit is added
            # back in: a full 255 counts as 256, exactly the loudness asked for, and nothing
            # counts as nothing — a fade that ended a shade above silence would leave the
            # speaker a shade off the middle, and dropping the voice then is a small click of its
            # own. The gain keeps sixteen bits of fraction, so the product goes up by eight bits
            # more rather than down, and the fraction the level gives is kept.
            e.emit(ASM.ldr_offset(0, 4, SLOT_VOL))
            e.emit(ASM.add_reg_lsr(3, 2, 2, 7))
            e.emit(ASM.mul(0, 3, 0))
            e.emit(ASM.lsl_imm(0, 0, GAIN_FRACTION - Envelope::SCALE))
            e.emit(ASM.cmp_imm(7, 0))
            e.emit(ASM.ldr_offset(3, 4, SLOT_GAIN))           # where the gain is now...
            e.emit(ASM.mov_reg_cond(:ne, 3, 0))               # ...or, on a first frame, already there
            e.emit(ASM.str_offset(3, 4, SLOT_GAIN))
            # ...and the slide to it: how far, shared out over the frame. Shifted down before the
            # multiply and down again after, so the product fits: a whole gain's worth of distance
            # times the share for one sample is more than 32 bits can hold.
            e.emit(ASM.sub_reg(0, 0, 3))
            e.emit(ASM.asr_imm(0, 0, RAMP_SPLIT))
            e.emit(ASM.load_immediate(3, (1 << (2 * RAMP_SPLIT)) / @mixer_spf))
            e.emit(ASM.mul(0, 3, 0))
            e.emit(ASM.asr_imm(0, 0, RAMP_SPLIT))
            e.emit(ASM.str_offset(0, 4, SLOT_RAMP))
            e.emit_branch(:b, onward)

            e.place_label(retire)
            e.emit(ASM.load_immediate(0, 0))
            e.emit(ASM.str_offset(0, 4, SLOT_ACTIVE))

            e.place_label(onward)
            e.emit(ASM.add_imm(4, 4, SLOT_BYTES))
            e.emit(ASM.subs_imm(5, 5, 1))
            e.emit_branch(:bcond, voice, cond: :ne)
          end

          # Does any voice in this program have a shape to its notes? A program with none emits
          # not one instruction of the pass above, and its voices sound exactly as they did.
          def shapes_notes? = @uses_envelopes

          # The slot field the mix takes its loudness from: the one the envelope pass works out,
          # or — for a game that shapes nothing — the note's own loudness, which is the field it
          # has always read.
          def gain_field = @uses_envelopes ? SLOT_GAIN : SLOT_VOL

          # THE HAND-OVER: point the DMA at the buffer the mix filled last frame, so it plays
          # now. Which buffer is which is held in a hidden variable and flipped each frame.
          #
          # WHY IT CANNOT SIMPLY POINT AT THE START. The DMA takes sixteen samples at a time,
          # whenever the sound hardware asks, and the asking falls on a grid the sample clock
          # fixes. Its read position only ever moves forward: this re-arm is the one thing that
          # brings it back to a buffer. So between two re-arms it takes as many lots as grid
          # points fell between them, and that is a frame's worth only if the re-arms are a frame
          # apart to the cycle. They are not. The screen's interrupt is answered at once when the
          # game is asleep at the end of its frame, and late when the game is in the middle of a
          # DMA of its own — a screen clear is one, a fifth of a frame long — which holds every
          # interrupt off until it is done, a different wait every frame. A re-arm that lands a
          # lot later than the last has taken a lot from past the end of the buffer; one that
          # lands a lot earlier has left the buffer's last lot unplayed. Either is a jump.
          #
          # SO THE HAND-OVER COUNTS instead of trusting its timing. Timer 1 counts every sample
          # the hardware has taken, and the grid of lots sits at a known place in that count
          # (MIX_PHASE), so the count says exactly how many lots the DMA has taken, and so which
          # lot it takes next. A hand-over two lots late points the DMA two lots into the new
          # buffer, where the sound meant for that moment is. The two lots taken late came from
          # past the end of the buffer before it, which is why every buffer carries the start of
          # the next one there (see #emit_mixer_fill). Late by anything up to that, the sound
          # comes out whole.
          #
          # One case the count cannot settle by itself: a sample taken between reading the count
          # and re-arming the DMA, which might have been a request answered from either buffer.
          # So the count is read only with #count_clearance to go before the next sample, and a
          # hand-over that finds the next one closer than that waits for it to pass.
          #
          # Which lot a buffer is MEANT to start at is kept from one frame to the next and moves
          # on a frame's worth of lots each time. When the count puts the DMA out of reach of
          # the buffer — the first hand-over of all, one later than the room a buffer carries, or
          # one EARLIER than the hand-over the counting started from — it starts again from where
          # the DMA really is. That hand-over is a jump. Counting started on a late frame is
          # started again by the next prompt one, so a game settles on its prompt hand-overs
          # within its first frames, and after that only a hand-over later than LATE_ROOM jumps.
          #
          # STILL THE FIRST THING IN THE SCREEN'S INTERRUPT, before the tune, the note shapes or
          # the mix, which keeps a game asleep at the end of its frame at the same lot every
          # frame, and a busy one no later than it has to be. The cost is that a sound is heard a
          # frame after it is mixed — every sound alike, so nothing moves against anything else.
          def emit_mixer_handover
            e = @emitter
            play_buf1 = e.gensym
            chosen = e.gensym
            wait = e.gensym
            @primitives.load_var(0, MIX_FRONT)      # r0 = the buffer that was playing
            e.emit(ASM.cmp_imm(0, 0))
            e.emit_branch(:bcond, play_buf1, cond: :eq)
            e.emit(ASM.load_immediate(ACC, 0))
            @primitives.store_var(ACC, MIX_FRONT)
            e.emit(ASM.load_immediate(3, @mix_buf0))
            e.emit_branch(:b, chosen)
            e.place_label(play_buf1)
            e.emit(ASM.load_immediate(ACC, 1))
            @primitives.store_var(ACC, MIX_FRONT)
            e.emit(ASM.load_immediate(3, @mix_buf1))
            e.place_label(chosen)                   # r3 = the buffer to play now

            # Everything the re-arm needs that is not the count, loaded before the count is read,
            # so the gap between the two is as short as it can be. The interrupt dispatcher saves
            # r4-r8 around this.
            @primitives.load_var(2, MIX_PHASE)
            @primitives.load_var(1, MIX_LOT)
            e.emit(ASM.load_immediate(ADDR, @timers.timer_reg_l(CLOCK_TIMER)))
            e.emit(ASM.load_immediate(4, REG_DMA1SAD))
            e.emit(ASM.load_immediate(5, dma_fifo_control))
            e.emit(ASM.load_immediate(6, 0))
            e.emit(ASM.load_immediate(7, 65_536 - count_clearance))

            e.place_label(wait)
            e.emit(ASM.load_halfword(ACC, ADDR))               # timer 0 counts up to the next sample
            e.emit(ASM.cmp_reg(ACC, 7))
            e.emit_branch(:bcond, wait, cond: :hs)            # the next sample is too near: let it pass
            e.emit(ASM.load_halfword_offset(ACC, ADDR, COUNT_TIMER * 4)) # samples taken
            e.emit(ASM.sub_reg(ACC, ACC, 2))
            e.emit(ASM.lsl_imm(ACC, ACC, 16))                 # top twelve bits: lots taken
            e.emit(ASM.sub_reg(8, ACC, 1))
            e.emit(ASM.lsr_imm(8, 8, 20))                     # how far into this buffer the next one is
            e.emit(ASM.cmp_imm(8, guard_lots + 1))
            e.emit(ASM.mov_imm_cond(:hs, 8, 0))               # out of reach: start from its beginning
            e.emit(ASM.lsl_imm(8, 8, 4))
            e.emit(ASM.add_reg(8, 8, 3))
            e.emit(ASM.str(8, 4))                             # the DMA's source
            e.emit(ASM.str_offset(6, 4, REG_DMA1CNT - REG_DMA1SAD)) # off...
            e.emit(ASM.str_offset(5, 4, REG_DMA1CNT - REG_DMA1SAD)) # ...and on, which reloads it

            # Out of reach, this buffer starts at the lot the DMA takes next. Either way the next
            # one starts a frame's worth of lots later.
            e.emit(ASM.lsr_imm(ACC, ACC, 20))
            e.emit(ASM.mov_reg_lsl_cond(:hs, 1, ACC, 20))
            e.emit(ASM.load_immediate(ACC, lots_a_frame << 20))
            e.emit(ASM.add_reg(1, 1, ACC))
            @primitives.store_var(1, MIX_LOT)
          end

          # The per-frame refill: fill the buffer that is NOT playing with the next slice of
          # mixed sound, which the next frame's hand-over plays.
          #
          # EMITTED INSIDE THE SCREEN'S OWN INTERRUPT, not in the game loop, and that is the
          # whole of what keeps sound whole. This fills ONE FRAME of sound, and the
          # hardware plays it on the sample clock — in real time, which has nothing to do with
          # how long a pass of the game loop takes. Called once per pass, a game whose pass
          # spans two frames handed the hardware a frame of sound every two:
          # half of every sound missing, every other slice, for as long as the game
          # was late. Called from the interrupt it is exactly in step with what plays it,
          # whatever the game is doing, with nothing to predict and no deficit to carry.
          #
          # SAFE TO RUN FROM AN INTERRUPT, and both halves of that are worth writing down
          # because neither is obvious. The registers: the mix routine works in r0-r12 and lr,
          # and the dispatcher saves r4-r11 and lr while the BIOS saves r0-r3 and r12, so between
          # them every one is covered. The voice slots: `play` and `stop` hold interrupts off while
          # they are in the table (#holding_off_interrupts), so this never sees one half-written.
          # This can retire a voice but never start one; the music player, earlier in the same
          # interrupt, starts voices, and can take one of the game's (#emit_music_voice_routine).
          #
          # THEN THE START OF WHAT IT MIXED is copied past the end of the buffer now playing, as
          # far as a late hand-over can reach (see #emit_mixer_handover): those lots are the ones
          # the DMA takes from there when the next hand-over is late, and they are the lots that
          # come next.
          def emit_mixer_fill
            mix_buf0 = @emitter.gensym
            done = @emitter.gensym
            @primitives.load_var(0, MIX_FRONT)      # r0 = the buffer now playing
            @emitter.emit(ASM.cmp_imm(0, 0))
            @emitter.emit_branch(:bcond, mix_buf0, cond: :ne)
            emit_call_mix(@mix_buf1)
            emit_copy_guard(from: @mix_buf1, to: @mix_buf0)
            @emitter.emit_branch(:b, done)
            @emitter.place_label(mix_buf0)
            emit_call_mix(@mix_buf0)
            emit_copy_guard(from: @mix_buf0, to: @mix_buf1)
            @emitter.place_label(done)
          end

          # Copy the first guard_lots of +from+ to just past the end of +to+, a word at a time.
          def emit_copy_guard(from:, to:)
            e = @emitter
            copy = e.gensym
            e.emit(ASM.load_immediate(0, from))
            e.emit(ASM.load_immediate(1, to + @mixer_spf))
            e.emit(ASM.load_immediate(2, guard_lots * Timers::DMA_SAMPLES_A_LOT / 4))
            e.place_label(copy)
            e.emit(ASM.ldr(3, 0))
            e.emit(ASM.add_imm(0, 0, 4))
            e.emit(ASM.str_post(3, 1, 4))
            e.emit(ASM.subs_imm(2, 2, 1))
            e.emit_branch(:bcond, copy, cond: :ne)
          end

          # Call the IWRAM mix routine to fill +dest+ (one of the two output buffers) with the
          # next slice of mixed sound. The routine takes the destination buffer in r0, and it
          # lives in the quick memory, too far for a relative branch — so the call goes
          # through a register (see Emit#emit_call_through).
          def emit_call_mix(dest)
            @emitter.emit(ASM.load_immediate(0, dest))                 # r0 = destination buffer (the one param)
            @emitter.emit(ASM.load_immediate(ADDR, @mix_routine_iwram)) # r12 = routine's address in IWRAM
            @emitter.emit_call_through(ADDR)
          end

          # WHICH BITS OF SOUNDCNT_H SEND THE RECORDED SOUND TO THE SPEAKERS: channel A at full
          # volume, out to both, clocked by timer 0. They are asked for from outside because
          # SOUNDCNT_H is a SHARED register — its low bits are the PSG's volume — and whoever
          # writes it whole has to put these back or the recordings stop (see Sound::Registers
          # .enable). Nothing at all for a program that plays no recording.
          def direct_sound_routing
            return 0 unless plays_samples?

            DSOUND_A_VOLUME_FULL | DSOUND_A_LEFT | DSOUND_A_RIGHT | DSOUND_A_TIMER0
          end

          # Channel A's SOUNDCNT_H setup at boot: that routing, the PSG kept at full volume
          # beside it, and A's FIFO reset so playback starts clean. The reset belongs to boot
          # alone — doing it again later would throw away whatever sound was queued.
          def direct_sound_a_config
            PSG_VOLUME_FULL | direct_sound_routing | DSOUND_A_RESET_FIFO
          end

          # The DMA1 control word for feeding the sound FIFO: enabled, 32-bit transfers to a
          # fixed destination (the FIFO register), re-armed after each transfer, started on
          # a FIFO request ("special" timing). The transfer count is fixed by the hardware
          # in this mode, so none is set.
          def dma_fifo_control
            DMA_ENABLE | DMA_REPEAT | DMA_32BIT | DMA_DEST_FIXED | DMA_SPECIAL
          end

          def store_reg_ioreg(reg, address)
            @emitter.emit(ASM.load_immediate(TMP, address))
            @emitter.emit(ASM.str(reg, TMP))
          end

          # (Re)start channel A's DMA from the source last written. The DMA reloads its source
          # only when switched off and on.
          def emit_rearm_dma
            @primitives.store_word_immediate(0, REG_DMA1CNT)                # off
            @primitives.store_word_immediate(dma_fifo_control, REG_DMA1CNT) # on
          end

          # The mix routine, emitted once and copied into IWRAM at boot (see
          # #emit_copy_mix_routine_to_iwram). It fills the destination buffer — one frame of
          # bytes, passed in r0 — with the sum of every sounding voice, clamped to the 8-bit
          # range so loud moments don't wrap.
          #
          # IN TWO PASSES, and that is most of what it costs. First each sounding voice adds
          # its next run of samples — scaled by its volume, stepped through the clip by its
          # fixed-point STEP so a pitched voice reads faster or slower — into a halfword
          # running total per output sample, kept in the quick memory; the voice is advanced,
          # and looped or retired at its end. Then one pass turns each total into the byte the
          # sound hardware plays, clamping it there, and clears the total for next frame.
          #
          # Summing into bytes instead — reading the output back, adding, clamping, writing it
          # out again for every voice — was twice the instructions per voice per sample, most
          # of them going to and from the slower memory the output lives in. A halfword holds
          # any sum there can be (every voice at full level is under 128 each), so clamping
          # once at the end loses nothing, and it is the better mix besides: a loud voice and
          # a loud voice of the other sign cancel, whatever order they were added in.
          #
          # STEPPING takes two instructions, the fraction kept in the top half of a register
          # so that adding the step's fraction overflows exactly when a whole sample is due —
          # the carry out of that add is the extra sample, and the add that moves the read
          # pointer takes it in. Where a voice is is its read pointer, compared against where
          # its recording ends; the whole-sample position the slot keeps is worked back out
          # when the voice is put away.
          #
          # The routine is self-contained and position-independent (relative branches, no
          # PC-relative literal loads), so it runs the same from IWRAM as from ROM. The one
          # input, the destination buffer, arrives in r0 and is stashed on the stack for the
          # last pass. It returns with BX LR.
          #
          # Registers held across voices: r3 = the running totals, r4 = slot pointer, r5 =
          # voices left. Per voice: r2 = output samples left, r6 = read pointer, r7 = the total
          # being added to, r8 = whole samples a step, r9 = where the recording ends, r10 = the
          # step's fraction (top half), r11 = the fraction carried (top half), r12 = volume;
          # r0/r1 scratch. The last pass: r6 = the byte being written, r7 = its total, r4 =
          # -128 (the clamp floor; 127, the ceiling, rides in the instruction), r5 = 0.
          #
          # A GAME THAT SHAPES A NOTE slides each voice's gain across the frame (see SLOT_RAMP),
          # which is one more register than there is — so lr carries the slide, and is kept on
          # the stack beside the destination until the routine returns through it. The gain in
          # r12 then keeps its fraction, and the sample is the multiply's second operand: the
          # console finishes a multiply sooner the smaller that one is, and a sample is a byte.
          def emit_mix_routine
            return unless @plays_samples

            e = @emitter
            e.emit(ASM.loop_forever) # fall-through guard: the routine is only entered via the call
            e.place_label(:__mix_routine)
            start = e.pos
            e.emit(ASM.push(0, *(LR if @uses_envelopes)))    # push {r0}: stash the destination buffer at [sp]
            e.emit(ASM.load_immediate(3, @mix_totals))        # the running totals
            e.emit(ASM.mov_reg(7, 3))                         # (still here after the voices = nothing sounded)
            e.emit(ASM.load_immediate(4, @voice_base))        # first slot
            e.emit(ASM.load_immediate(5, MAX_VOICES))         # voices to visit

            voice = e.gensym
            next_voice = e.gensym
            e.place_label(voice)
            e.emit(ASM.ldr_offset(0, 4, SLOT_ACTIVE))
            e.emit(ASM.cmp_imm(0, 0))
            e.emit_branch(:bcond, next_voice, cond: :eq)      # idle slot -> skip
            e.emit(ASM.ldr_offset(6, 4, SLOT_SRC))            # r6 = where the recording starts
            e.emit(ASM.ldr_offset(9, 4, SLOT_LEN))
            e.emit(ASM.add_reg(9, 6, 9))                      # r9 = where it ends
            e.emit(ASM.ldr_offset(0, 4, SLOT_POS))
            e.emit(ASM.add_reg(6, 6, 0))                      # r6 = read pointer = start + position
            e.emit(ASM.ldr_offset(10, 4, SLOT_STEP))          # the step, 16.16...
            e.emit(ASM.lsr_imm(8, 10, STEP_SHIFT))            # ...r8 = its whole samples
            e.emit(ASM.lsl_imm(10, 10, STEP_SHIFT))           # ...r10 = its fraction, in the top half
            e.emit(ASM.ldr_offset(11, 4, SLOT_FRAC))          # r11 = the fraction carried in (top half)
            e.emit(ASM.ldr_offset(12, 4, gain_field))         # r12 = the gain it is sounding at
            e.emit(ASM.ldr_offset(LR, 4, SLOT_RAMP)) if @uses_envelopes # lr = how far it slides a sample
            e.emit(ASM.mov_reg(7, 3))                         # r7 = the first total
            e.emit(ASM.load_immediate(2, @mixer_spf))         # r2 = output samples to fill

            sample = e.gensym
            advance = e.gensym
            wrapped = e.gensym
            retire = e.gensym
            end_voice = e.gensym
            e.place_label(sample)
            e.emit(ASM.ldrsb(0, 6))                           # r0 = the voice's raw sample (signed)
            if @uses_envelopes
              e.emit(ASM.mul(1, 12, 0))                       # r1 = gain × sample
              e.emit(ASM.ldrsh(0, 7))                         # r0 = the total so far
              e.emit(ASM.add_reg_asr(0, 0, 1, VOL_SHIFT + GAIN_FRACTION)) # ...plus that ÷ 64, fraction and all
              e.emit(ASM.store_halfword_post(0, 7, 2))        # put it back, and on to the next total
              e.emit(ASM.add_reg(12, 12, LR))                 # the gain slides a sample's worth
            else
              e.emit(ASM.mul(1, 0, 12))                       # r1 = sample × volume
              e.emit(ASM.ldrsh(0, 7))                         # r0 = the total so far
              e.emit(ASM.add_reg_asr(0, 0, 1, VOL_SHIFT))     # ...plus sample × volume ÷ 64 (:full is unchanged)
              e.emit(ASM.store_halfword_post(0, 7, 2))        # put it back, and on to the next total
            end
            e.emit(ASM.adds_reg(11, 11, 10))                  # fraction += the step's; a carry is one more sample
            e.emit(ASM.adc_reg(6, 6, 8))                      # read pointer += whole samples + that carry
            e.emit(ASM.cmp_reg(6, 9))
            e.emit_branch(:bcond, wrapped, cond: :ge)         # reached (or passed) the end
            e.place_label(advance)
            e.emit(ASM.subs_imm(2, 2, 1))
            e.emit_branch(:bcond, sample, cond: :ne)          # more of the frame to fill
            e.emit_branch(:b, end_voice)

            e.place_label(wrapped)
            e.emit(ASM.ldr_offset(0, 4, SLOT_LOOP))           # how far back at the end, 0 = play once
            e.emit(ASM.cmp_imm(0, 0))
            e.emit_branch(:bcond, retire, cond: :eq)
            e.emit(ASM.sub_reg(6, 6, 0))                      # back to where it holds from
            e.emit_branch(:b, advance)

            e.place_label(retire)                             # one-shot done: mark idle, stop adding
            e.emit(ASM.load_immediate(0, 0))
            e.emit(ASM.str_offset(0, 4, SLOT_ACTIVE))

            e.place_label(end_voice)
            e.emit(ASM.ldr_offset(0, 4, SLOT_SRC))
            e.emit(ASM.sub_reg(0, 6, 0))
            e.emit(ASM.str_offset(0, 4, SLOT_POS))            # remember how far this voice has played
            e.emit(ASM.str_offset(11, 4, SLOT_FRAC))          # ...and the leftover fraction
            e.emit(ASM.str_offset(12, 4, SLOT_GAIN)) if @uses_envelopes # ...and where its gain slid to

            e.place_label(next_voice)
            e.emit(ASM.add_imm(4, 4, SLOT_BYTES))             # next slot
            e.emit(ASM.subs_imm(5, 5, 1))
            e.emit_branch(:bcond, voice, cond: :ne)

            # NOTHING SOUNDED: every total is still 0, so the frame is silence — written a word
            # at a time, which is a quarter of the stores the totals pass would make. A game is
            # silent more often than not, so this is the frame it has most. (The buffer is
            # whole words long, so rounding up to one writes nothing that is not its own.)
            silent = e.gensym
            e.emit(ASM.pop(6, *(LR if @uses_envelopes)))      # r6 = the destination (and the stack balanced)
            e.emit(ASM.load_immediate(5, 0))
            e.emit(ASM.cmp_reg(7, 3))
            e.emit_branch(:bcond, silent, cond: :eq)

            # Every voice is in the totals. Turn each into the byte the hardware plays, clamped
            # into [-128, 127] with no branch — movgt/movlt only fire when out of range — and
            # leave the total at 0 for next frame.
            e.emit(ASM.mov_reg(7, 3))
            e.emit(ASM.load_immediate(2, @mixer_spf))
            e.emit(ASM.mvn_imm(4, 127))                       # clamp floor = -128
            byte = e.gensym
            e.place_label(byte)
            e.emit(ASM.ldrsh(0, 7))
            e.emit(ASM.cmp_imm(0, 127))
            e.emit(ASM.mov_imm_cond(:gt, 0, 127))             # over 127  -> 127
            e.emit(ASM.cmp_reg(0, 4))
            e.emit(ASM.mov_reg_cond(:lt, 0, 4))               # under -128 -> -128
            e.emit(ASM.strb_post(0, 6, 1))
            e.emit(ASM.store_halfword_post(5, 7, 2))          # the total starts again at nothing
            e.emit(ASM.subs_imm(2, 2, 1))
            e.emit_branch(:bcond, byte, cond: :ne)
            e.emit(ASM.return)                                # bx lr -> back to the caller

            e.place_label(silent)
            e.emit(ASM.load_immediate(2, (@mixer_spf + 3) / 4))
            quiet = e.gensym
            e.place_label(quiet)
            e.emit(ASM.str_post(5, 6, 4))
            e.emit(ASM.subs_imm(2, 2, 1))
            e.emit_branch(:bcond, quiet, cond: :ne)
            e.emit(ASM.return)
            e.place_label(:__mix_routine_end)

            size = @emitter.pos - start
            return unless size > MIX_ROUTINE_IWRAM_MAX

            raise LoweringError,
                  "the mix routine is #{size} bytes but only #{MIX_ROUTINE_IWRAM_MAX} are reserved for it " \
                  "(raise MIX_ROUTINE_IWRAM_MAX)"
          end

          private

          # Leave r0 = the address of a free voice slot, or 0 if every one is busy. Uses r0/r1/r2
          # only, so the caller's r3 and r4 survive.
          def find_free_slot
            @emitter.emit(ASM.load_immediate(1, @voice_base))
            @emitter.emit(ASM.load_immediate(2, @voice_base + (MAX_VOICES * SLOT_BYTES)))
            scan = @emitter.gensym
            found = @emitter.gensym
            miss = @emitter.gensym
            @emitter.place_label(scan)
            @emitter.emit(ASM.ldr_offset(0, 1, SLOT_ACTIVE))
            @emitter.emit(ASM.cmp_imm(0, 0))
            @emitter.emit_branch(:bcond, found, cond: :eq)        # active == 0 -> free
            @emitter.emit(ASM.add_imm(1, 1, SLOT_BYTES))
            @emitter.emit(ASM.cmp_reg(1, 2))
            @emitter.emit_branch(:bcond, scan, cond: :lt)
            emit_find_tail(miss) if @uses_envelopes               # nothing free: a note falling away gives way
            emit_note_drop                                        # nothing at all: write down what was lost
            @emitter.emit(ASM.load_immediate(0, 0))               # none free
            @emitter.emit_branch(:b, miss)
            @emitter.place_label(found)
            @emitter.emit(ASM.mov_reg(0, 1))                      # r0 = the free slot's address
            @emitter.place_label(miss)
          end

          # WITH EVERY VOICE BUSY, A SONG'S NOTE THAT IS FALLING AWAY GIVES WAY to the game's sound,
          # the quietest of them first — the same rule a song's own note keeps
          # (#emit_music_voice_routine). A note falling away is on its way out, and it holds a voice
          # only because a shaped note keeps its voice to fade on; losing the game a sound it
          # would have had without that is not the trade anybody asked for.
          #
          # On the miss path only, so a game with a voice free pays nothing for it. Leaves the
          # voice in r0 and jumps to +taken+, or falls through with none. Uses r0/r1/r2 and r12,
          # the same registers the search already spends.
          def emit_find_tail(taken)
            e = @emitter
            scan = e.gensym
            keep = e.gensym
            onward = e.gensym
            e.emit(ASM.load_immediate(1, @voice_base))
            e.emit(ASM.load_immediate(2, 0))                      # r2 = the quietest so far, none yet
            e.place_label(scan)
            e.emit(ASM.ldr_offset(0, 1, SLOT_ACTIVE))
            e.emit(ASM.cmp_imm(0, OWNER_GAME))
            e.emit_branch(:bcond, onward, cond: :ls)              # free, or one of the game's
            e.emit(ASM.ldr_offset(0, 1, SLOT_PHASE))
            e.emit(ASM.cmp_imm(0, PHASE_FALLING))
            e.emit_branch(:bcond, onward, cond: :lo)              # a song's note, still sounding
            e.emit(ASM.cmp_imm(2, 0))
            e.emit_branch(:bcond, keep, cond: :eq)
            e.emit(ASM.ldr_offset(0, 1, SLOT_LEVEL))
            e.emit(ASM.ldr_offset(ADDR, 2, SLOT_LEVEL))
            e.emit(ASM.cmp_reg(0, ADDR))
            e.emit_branch(:bcond, onward, cond: :hs)              # no quieter than the one kept
            e.place_label(keep)
            e.emit(ASM.mov_reg(2, 1))
            e.place_label(onward)
            e.emit(ASM.add_imm(1, 1, SLOT_BYTES))
            e.emit(ASM.load_immediate(ADDR, @voice_base + (MAX_VOICES * SLOT_BYTES)))
            e.emit(ASM.cmp_reg(1, ADDR))
            e.emit_branch(:bcond, scan, cond: :lt)
            e.emit(ASM.mov_reg(0, 2))
            e.emit(ASM.cmp_imm(0, 0))
            e.emit_branch(:bcond, taken, cond: :ne)
          end

          # A SOUND WAS JUST LOST: add one to the count, and remember how the voices were being
          # split if this is the worst it has been.
          #
          # Emitted on the miss path only, so a game that never runs out of voices pays nothing
          # for it — and a game that does pays it exactly when a sound is already being lost,
          # which is the cheapest moment there is to spend a few dozen instructions.
          #
          # The music's share is counted in a second walk of its own rather than as the search
          # above goes, because that search STOPS at the first free slot: on every play that
          # succeeds it would have counted part of the table and called it the whole. Here the
          # table is known to be full, so the walk is complete by construction.
          #
          # A slot's SOUNDING word is 0 idle, OWNER_GAME the game's, and higher for a part of a
          # song or an effect — so "above OWNER_GAME" is "the music's", in one compare.
          # Uses r0/r1/r2 and r12, the same registers the search already spends.
          def emit_note_drop
            e = @emitter
            scan = e.gensym
            keep = e.gensym
            e.emit(ASM.load_immediate(1, @voice_base))
            e.emit(ASM.load_immediate(ADDR, @voice_base + (MAX_VOICES * SLOT_BYTES)))
            e.emit(ASM.load_immediate(2, 0))                      # r2 = voices a song is holding
            e.place_label(scan)
            e.emit(ASM.ldr_offset(0, 1, SLOT_ACTIVE))
            e.emit(ASM.cmp_imm(0, OWNER_GAME))
            e.emit(ASM.add_imm_cond(:gt, 2, 2, 1))                # a song's mark sits above the game's
            e.emit(ASM.add_imm(1, 1, SLOT_BYTES))
            e.emit(ASM.cmp_reg(1, ADDR))
            e.emit_branch(:bcond, scan, cond: :lt)

            @primitives.load_var(0, DROPS_MUSIC)
            e.emit(ASM.cmp_reg(2, 0))
            e.emit_branch(:bcond, keep, cond: :le)                # not the worst split so far
            @primitives.store_var(2, DROPS_MUSIC)
            e.place_label(keep)
            @primitives.load_var(0, DROPS)
            e.emit(ASM.add_imm(0, 0, 1))
            @primitives.store_var(0, DROPS)
          end

          # Zero +bytes+ bytes of memory starting at +addr+ (voice slots, output buffers).
          def emit_zero_region(addr, bytes)
            @emitter.emit(ASM.load_immediate(0, addr))
            @emitter.emit(ASM.load_immediate(1, 0))
            @emitter.emit(ASM.load_immediate(2, bytes))
            loop_lbl = @emitter.gensym
            @emitter.place_label(loop_lbl)
            @emitter.emit(ASM.strb(1, 0))
            @emitter.emit(ASM.add_imm(0, 0, 1))
            @emitter.emit(ASM.sub_imm(2, 2, 1))
            @emitter.emit(ASM.cmp_imm(2, 0))
            @emitter.emit_branch(:bcond, loop_lbl, cond: :ne)
          end

          # DOES ANYTHING IN THIS PROGRAM SHAPE A NOTE? Asked once, of the whole program, because
          # the answer decides whether a single instruction of the envelope is emitted anywhere —
          # a game that names none is exactly the game it was before any of this existed.
          #
          # Three places can say so: a recording declared with one, a part of a played tune or a
          # sound effect, or one of that part's notes. A tune nobody plays says nothing, the same
          # as it costs nothing everywhere else.
          def shapes_any_note?(program)
            program.walk.any? { |node| node.kind == :sample && node.envelope } ||
              IR::Tunes.played_and_effects(program).any? do |song|
                IR::Tunes.soundings(song).any? { |sounding| sounding.envelope }
              end
          end

          # The output rate to mix at: the rate most of the program's samples were recorded
          # at, so a single-rate game plays at its own pitch. Defaults to the usual rate.
          def common_sample_rate(program)
            rates = program.walk.select { |n| n.kind == :sample }.map { |n| n.rate }
            return RubyGBA::Builder::SampledAudio::DEFAULT_SAMPLE_RATE if rates.empty?

            rates.group_by(&:itself).max_by { |_rate, list| list.size }.first
          end
        end
      end
    end
  end
end
