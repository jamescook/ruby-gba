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
        # THE SLOTS ARE SHARED between the game's sounds and the music's notes, each taking one
        # only while it sounds (see #emit_music_voice_routine for who gives way when they run
        # out). A slot's SOUNDING word says whose it is: 0 nobody's, OWNER_GAME the game's, and
        # a song's recorded part its own mark (Mixer.music_owner).
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
          # The routine emits at 288 to 300 bytes (three of its immediates are the samples-per-frame
          # count or that count in words, each one instruction or two depending on the number), so
          # this is about a quarter as much again for room to grow into. Outgrow it and the build
          # says so by name rather than running over whatever is next.
          #
          # It was 1024, which is four times what the routine has ever needed, and a real game
          # paid for it: on the Wolfenstein port the difference was exactly enough to push the routine
          # that draws every guard and every lamp out of the quick memory.
          MIX_ROUTINE_IWRAM_MAX = 384

          # Timer 0 clocks the mixer's output rate (how fast the DMA hands bytes to the sound
          # FIFO). It's the only hardware timer the mixer needs.
          CLOCK_TIMER = 0

          # A voice slot, in EWRAM: the sample's address in ROM, how far it has played (a whole
          # sample index), its length, whether it loops, whether it's sounding, its level
          # (0..64), and — for pitch — a 16.16 fixed-point STEP (how many source samples to
          # advance per output sample: 1.0 = 0x10000 plays at the recorded pitch, 2.0 an
          # octave up) plus a FRAC accumulator carrying the leftover fraction between frames,
          # kept in its TOP 16 bits so that adding to it overflows exactly when a whole
          # sample is due (see #emit_mix_routine).
          # A game sound's slot also keeps its TICKET — which play started it, counting up — so
          # the one playing longest can be told apart when a song's note needs its voice. A
          # sound that loops has the top bit set, which makes it later than every sound that
          # plays once, so it is the last to go.
          SLOT_SRC = 0
          SLOT_POS = 4
          SLOT_LEN = 8
          SLOT_LOOP = 12
          SLOT_ACTIVE = 16
          SLOT_VOL = 20
          SLOT_STEP = 24
          SLOT_FRAC = 28
          SLOT_TICKET = 32
          SLOT_BYTES = 36

          # Whose a sounding slot is, in its SOUNDING word: the game's, or a song's recorded part.
          OWNER_GAME = 1
          def self.music_owner(lane) = OWNER_GAME + 1 + lane

          TICKETS = :__mix_tickets # how many sounds the game has started, for the next ticket
          LOOPS_LAST = 0x8000_0000

          # The fixed-point shift for STEP/FRAC: 16 fractional bits, so 1.0 == 1 << 16.
          STEP_SHIFT = 16
          STEP_ONE = 1 << STEP_SHIFT

          # ONE SOUNDING VOICE, read back off a running console: which sample it is playing,
          # how far through it (a whole sample index), how long that sample is, how fast it
          # reads it (16.16 — STEP_ONE is the recorded pitch), whether it loops, and its level
          # (0..64). Values rather than addresses, so a test asks what is playing and never
          # learns where in memory it is kept.
          Voice = Data.define(:sample, :position, :length, :step, :loop, :volume)

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
          VoiceTable = Data.define(:base, :count, :sample_addresses) do
            # The sounding voices, in slot order. The block reads one 32-bit word off the
            # console at the address it is given — the reader is handed in rather than owned,
            # so this can be tested against a plain Hash as easily as against an emulator.
            def read
              names = sample_addresses.invert
              (0...count).filter_map do |slot|
                at = base + (slot * SLOT_BYTES)
                next if yield(at + SLOT_ACTIVE).zero?

                Voice.new(sample: names[yield(at + SLOT_SRC)], position: yield(at + SLOT_POS),
                          length: yield(at + SLOT_LEN), step: yield(at + SLOT_STEP),
                          loop: !yield(at + SLOT_LOOP).zero?, volume: yield(at + SLOT_VOL))
              end
            end
          end

          # Volume level names → a 0..64 gain the mix multiplies each sample by (then shifts
          # right by 6, i.e. divides by 64) — so :full leaves a sample unchanged and :half
          # halves it. The same words the other sound verbs use.
          MIX_LEVELS = { full: 64, three_quarter: 48, half: 32, quarter: 16, mute: 0 }.freeze
          VOL_SHIFT = 6 # 2**6 = 64, the :full gain

          # The frame rate the mixer refills at — one slice of sound per displayed frame.
          MIXER_FPS = 60

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

          # The routines that find a song's note a voice, and stop it (#emit_music_voice_routines).
          MUSIC_VOICE = :__music_voice
          MUSIC_VOICE_OFF = :__music_voice_off

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

            VoiceTable.new(base: @voice_base, count: MAX_VOICES,
                           sample_addresses: @samples.keys.to_h do |name|
                             [name, ROM_START + RubyGBA::ROM::ENTRY_OFFSET + @emitter.data_positions.fetch(name)]
                           end)
          end

          def prepare_mixer(program)
            return unless @plays_samples

            @mixer_rate = common_sample_rate(program)
            @mixer_spf = [(@mixer_rate + MIXER_FPS - 1) / MIXER_FPS, 1].max # samples per frame (ceil)
            @mix_buf0 = @memory.alloc_roomy(@mixer_spf)
            @mix_buf1 = @memory.alloc_roomy(@mixer_spf)
            # WHAT GOES IN THE QUICK MEMORY is decided by how often the mix touches it. The
            # running total of every voice — a halfword per output sample, read and written
            # again for every voice at every sample — goes there. The voice slots do not: the
            # mix reads a sounding voice's slot once a frame and writes it back once, so they
            # cost the same in the roomy memory, and the room they would have taken is the room
            # the totals need.
            @mix_totals = @memory.alloc(@mixer_spf * 2)
            @voice_base = @memory.alloc_roomy(MAX_VOICES * SLOT_BYTES)
            @mix_routine_iwram = @memory.alloc(MIX_ROUTINE_IWRAM_MAX) # the mix routine is copied here from ROM at boot
            @timers.reserve!(CLOCK_TIMER + 1) # reserve timer 0 only
          end

          # Bring the mixer up at boot: silence the voice slots and both buffers, power on
          # the sound hardware, point the DMA at the first buffer and the sample clock at the
          # mixer rate. From here the DMA plays silence until a voice is added.
          def emit_mixer_boot
            emit_zero_region(@voice_base, MAX_VOICES * SLOT_BYTES) # all voices idle
            emit_zero_region(@mix_totals, @mixer_spf * 2)          # the totals start at nothing
            emit_zero_region(@mix_buf0, @mixer_spf)                # buffers start silent...
            emit_zero_region(@mix_buf1, @mixer_spf)
            @emitter.emit(ASM.load_immediate(ACC, 0))
            @primitives.store_var(ACC, MIX_FRONT)                  # ...playing buffer 0 first

            @emitter.write_reg16(REG_SOUNDCNT_X, SOUND_MASTER_ENABLE)   # master sound on
            @emitter.write_reg16(REG_SOUNDCNT_H, direct_sound_a_config) # channel A, full volume, FIFO reset
            @emitter.emit(ASM.load_immediate(ACC, @mix_buf0))
            store_reg_ioreg(ACC, REG_DMA1SAD)                      # DMA source = buffer 0
            @primitives.store_word_immediate(REG_FIFO_A, REG_DMA1DAD)       # DMA dest = the sound FIFO
            @primitives.store_word_immediate(dma_fifo_control, REG_DMA1CNT) # feed the FIFO continuously

            prescaler, reload = @timers.timer_config(@mixer_rate)  # timer 0 = the mixer's sample rate
            @emitter.write_reg16(@timers.timer_reg_l(CLOCK_TIMER), reload)
            @emitter.write_reg16(@timers.timer_reg_h(CLOCK_TIMER), TIMER_ENABLE | prescaler)

            emit_copy_mix_routine_to_iwram
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
              @emitter.emit(ASM.load_immediate(TMP, node.loop ? 1 : 0))
              @emitter.emit(ASM.str_offset(TMP, 0, SLOT_LOOP))         # slot.loop
              @emitter.emit(ASM.load_immediate(TMP, MIX_LEVELS.fetch(node.volume, MIX_LEVELS[:full])))
              @emitter.emit(ASM.str_offset(TMP, 0, SLOT_VOL))          # slot.volume (0..64 gain)
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

          # The two routines those call, emitted once inside the screen's interrupt.
          def emit_music_voice_routines
            emit_music_voice_routine
            emit_music_voice_off_routine
          end

          # Stop the voice with the part's mark (r8) — or nothing, when the part has none: its last
          # note ran out, and the mix retired it. A part never has two, since a note of its own
          # takes over the voice it already has. Uses r0, r1, r7.
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
          #   1. the part's own voice, still sounding its last note — the new note takes it over;
          #   2. the first voice nobody is using;
          #   3. with none free, the voice of the game's sound that has been playing longest —
          #      one that plays once before one that loops, since a loop never ends by itself.
          #      That is the rule for who gives way: a song keeps playing right, and a sound the
          #      game started a while ago is cut short.
          #
          # There is always a 3 when there is no 1 or 2: a part holds one voice at most, and a
          # song has fewer recorded parts than there are voices, so a table full with no voice of
          # this part's has a game sound in it. It runs in the interrupt, where the game cannot
          # be in the table — `play` and `stop` hold interrupts off while they are.
          #
          # In: r8 = the part's mark. Out: r7 = the voice. Uses r0, r1, r9-r11, and returns
          # through lr, which the interrupt saved.
          def emit_music_voice_routine
            e = @emitter
            done = e.gensym
            scan = e.gensym
            busy = e.gensym
            onward = e.gensym
            e.place_label(MUSIC_VOICE)
            e.emit(ASM.load_immediate(7, @voice_base))
            e.emit(ASM.load_immediate(1, @voice_base + (MAX_VOICES * SLOT_BYTES)))
            e.emit(ASM.load_immediate(9, 0))                    # the first free voice, none yet
            e.emit(ASM.mvn_imm(11, 0))                          # the oldest ticket so far: none, the largest there is
            e.emit(ASM.load_immediate(10, 0))                   # ...and its voice
            e.place_label(scan)
            e.emit(ASM.ldr_offset(0, 7, SLOT_ACTIVE))
            e.emit(ASM.cmp_reg(0, 8))
            e.emit_branch(:bcond, done, cond: :eq)              # 1. the part's own
            e.emit(ASM.cmp_imm(0, 0))
            e.emit_branch(:bcond, busy, cond: :ne)
            e.emit(ASM.cmp_imm(9, 0))
            e.emit(ASM.mov_reg_cond(:eq, 9, 7))                 # 2. the first free one
            e.emit_branch(:b, onward)
            e.place_label(busy)
            e.emit(ASM.cmp_imm(0, OWNER_GAME))
            e.emit_branch(:bcond, onward, cond: :ne)            # another part's: never taken
            e.emit(ASM.ldr_offset(0, 7, SLOT_TICKET))
            e.emit(ASM.cmp_reg(0, 11))
            e.emit(ASM.mov_reg_cond(:lo, 11, 0))                # 3. the game sound playing longest
            e.emit(ASM.mov_reg_cond(:lo, 10, 7))
            e.place_label(onward)
            e.emit(ASM.add_imm(7, 7, SLOT_BYTES))
            e.emit(ASM.cmp_reg(7, 1))
            e.emit_branch(:bcond, scan, cond: :lt)
            e.emit(ASM.mov_reg(7, 9))
            e.emit(ASM.cmp_imm(7, 0))
            e.emit_branch(:bcond, done, cond: :ne)
            e.emit(ASM.mov_reg(7, 10))
            e.place_label(done)
            e.emit(ASM.return)
          end

          # The per-frame refill: fill the buffer that is NOT playing with the next slice of
          # mixed sound, then swap — point the DMA at the freshly filled buffer so it plays
          # next. Which buffer is which is held in a hidden variable and flipped each frame.
          #
          # EMITTED INSIDE THE SCREEN'S OWN INTERRUPT, not in the game loop, and that is the
          # whole of what keeps sound whole. This fills ONE SIXTIETH OF A SECOND, and the
          # hardware plays it on the sample clock — in real time, which has nothing to do with
          # how long a pass of the game loop takes. Called once per pass, a game whose pass
          # spans two frames handed the hardware a sixtieth of a second of sound every
          # thirtieth: half of every sound missing, every other slice, for as long as the game
          # was late. Called from the interrupt it is exactly in step with what plays it,
          # whatever the game is doing, with nothing to predict and no deficit to carry.
          #
          # SAFE TO RUN FROM AN INTERRUPT, and both halves of that are worth writing down
          # because neither is obvious. The registers: the mix routine works in r0-r12, and the
          # dispatcher saves r4-r11 and lr while the BIOS saves r0-r3 and r12, so between them
          # every one is covered. The voice slots: `play` and `stop` hold interrupts off while
          # they are in the table (#holding_off_interrupts), so this never sees one half-written.
          # This can retire a voice but never start one; the music player, earlier in the same
          # interrupt, starts voices, and can take one of the game's (#emit_music_voice_routine).
          def emit_mixer_tick
            @primitives.load_var(0, MIX_FRONT)      # r0 = the buffer now playing (front)
            @emitter.emit(ASM.cmp_imm(0, 0))
            play_buf1 = @emitter.gensym
            done = @emitter.gensym
            @emitter.emit_branch(:bcond, play_buf1, cond: :ne)
            # front == 0 -> mix into buffer 1, then play buffer 1
            emit_call_mix(@mix_buf1)
            @emitter.emit(ASM.load_immediate(ACC, 1))
            @primitives.store_var(ACC, MIX_FRONT)
            emit_rearm_dma(@mix_buf1)
            @emitter.emit_branch(:b, done)
            @emitter.place_label(play_buf1)
            # front == 1 -> mix into buffer 0, then play buffer 0
            emit_call_mix(@mix_buf0)
            @emitter.emit(ASM.load_immediate(ACC, 0))
            @primitives.store_var(ACC, MIX_FRONT)
            emit_rearm_dma(@mix_buf0)
            @emitter.place_label(done)
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

          # Channel A's SOUNDCNT_H setup: PSG kept at full volume, A at full volume out to
          # both speakers, clocked by timer 0, and its FIFO reset so playback starts clean.
          def direct_sound_a_config
            PSG_VOLUME_FULL | DSOUND_A_VOLUME_FULL | DSOUND_A_LEFT | DSOUND_A_RIGHT |
              DSOUND_A_TIMER0 | DSOUND_A_RESET_FIFO
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

          # Point channel A's DMA at +buffer+ and (re)start it. The DMA reloads its source
          # only when switched off and on, so a swap is: stop, set the source, start.
          def emit_rearm_dma(buffer)
            @primitives.store_word_immediate(0, REG_DMA1CNT)                # off
            @emitter.emit(ASM.load_immediate(ACC, buffer))
            store_reg_ioreg(ACC, REG_DMA1SAD)                               # source = the freshly mixed buffer
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
          def emit_mix_routine
            return unless @plays_samples

            e = @emitter
            e.emit(ASM.loop_forever) # fall-through guard: the routine is only entered via the call
            e.place_label(:__mix_routine)
            start = e.pos
            e.emit(ASM.push(0))                               # push {r0}: stash the destination buffer at [sp]
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
            e.emit(ASM.ldr_offset(12, 4, SLOT_VOL))           # r12 = volume gain (0..64)
            e.emit(ASM.mov_reg(7, 3))                         # r7 = the first total
            e.emit(ASM.load_immediate(2, @mixer_spf))         # r2 = output samples to fill

            sample = e.gensym
            advance = e.gensym
            wrapped = e.gensym
            retire = e.gensym
            end_voice = e.gensym
            e.place_label(sample)
            e.emit(ASM.ldrsb(0, 6))                           # r0 = the voice's raw sample (signed)
            e.emit(ASM.mul(1, 0, 12))                         # r1 = sample × volume
            e.emit(ASM.ldrsh(0, 7))                           # r0 = the total so far
            e.emit(ASM.add_reg_asr(0, 0, 1, VOL_SHIFT))       # ...plus sample × volume ÷ 64 (:full is unchanged)
            e.emit(ASM.store_halfword_post(0, 7, 2))          # put it back, and on to the next total
            e.emit(ASM.adds_reg(11, 11, 10))                  # fraction += the step's; a carry is one more sample
            e.emit(ASM.adc_reg(6, 6, 8))                      # read pointer += whole samples + that carry
            e.emit(ASM.cmp_reg(6, 9))
            e.emit_branch(:bcond, wrapped, cond: :ge)         # reached (or passed) the end
            e.place_label(advance)
            e.emit(ASM.subs_imm(2, 2, 1))
            e.emit_branch(:bcond, sample, cond: :ne)          # more of the frame to fill
            e.emit_branch(:b, end_voice)

            e.place_label(wrapped)
            e.emit(ASM.ldr_offset(0, 4, SLOT_LOOP))           # loop?
            e.emit(ASM.cmp_imm(0, 0))
            e.emit_branch(:bcond, retire, cond: :eq)
            e.emit(ASM.ldr_offset(0, 4, SLOT_LEN))
            e.emit(ASM.sub_reg(6, 6, 0))                      # loop: back by the recording's length
            e.emit_branch(:b, advance)

            e.place_label(retire)                             # one-shot done: mark idle, stop adding
            e.emit(ASM.load_immediate(0, 0))
            e.emit(ASM.str_offset(0, 4, SLOT_ACTIVE))

            e.place_label(end_voice)
            e.emit(ASM.ldr_offset(0, 4, SLOT_SRC))
            e.emit(ASM.sub_reg(0, 6, 0))
            e.emit(ASM.str_offset(0, 4, SLOT_POS))            # remember how far this voice has played
            e.emit(ASM.str_offset(11, 4, SLOT_FRAC))          # ...and the leftover fraction

            e.place_label(next_voice)
            e.emit(ASM.add_imm(4, 4, SLOT_BYTES))             # next slot
            e.emit(ASM.subs_imm(5, 5, 1))
            e.emit_branch(:bcond, voice, cond: :ne)

            # NOTHING SOUNDED: every total is still 0, so the frame is silence — written a word
            # at a time, which is a quarter of the stores the totals pass would make. A game is
            # silent more often than not, so this is the frame it has most. (The buffer is
            # whole words long, so rounding up to one writes nothing that is not its own.)
            silent = e.gensym
            e.emit(ASM.pop(6))                                # r6 = the destination (and the stack balanced)
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
            @emitter.emit(ASM.load_immediate(0, 0))               # none free
            @emitter.emit_branch(:b, miss)
            @emitter.place_label(found)
            @emitter.emit(ASM.mov_reg(0, 1))                      # r0 = the free slot's address
            @emitter.place_label(miss)
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
