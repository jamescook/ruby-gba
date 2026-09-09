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
        # has played, its length, and whether it loops. There are a fixed number of voice
        # slots; `play` fills a free one, the mix drains and retires it (or loops it), and
        # `stop` clears a sample's slots. The mix runs once per DISPLAYED FRAME, from the
        # screen's own interrupt — so playing samples needs a game loop, which is what arms
        # that interrupt.
        #
        # (For now every voice plays at the one mixer rate; a later feature steps each voice
        # at its own pitch. That's why one recorded note can't yet become a whole keyboard.)
        #
        # Owns the whole sampled-audio picture: registering samples as ROM data (asset
        # preparation, so it lives here beside the mix that uses what it prepares) and
        # the mix itself. @samples / @plays_samples are this object's own state, not
        # handed in — nothing outside sampled audio ever reads them.
        class Mixer
          include Constants

          # How many samples can sound at once. A new play past this is dropped (safe and
          # quiet) rather than stealing one already sounding. Matches the interpreter.
          MAX_VOICES = 8

          # The mix routine's inner loop runs once per output sample per voice — thousands
          # of times a frame. From ROM it would stall on a wait state at every instruction
          # fetch, so at boot the routine is copied into IWRAM (zero-wait-state internal RAM)
          # and called there. This is the IWRAM budget reserved for the copy; the build
          # fails if the emitted routine ever outgrows it.
          # KEPT SNUG, because every byte of it is a byte the routines a frame spends its time in
          # do not get — this reservation and the game's own hot code come out of the same 32K.
          # The routine emits at 256 or 264 bytes (two of its immediates are the samples-per-frame
          # count, which takes one instruction or two depending on the number), so this is about
          # half as much again for room to grow into. Outgrow it and the build says so by name
          # rather than running over whatever is next — see #guard_mix_routine_fits!.
          #
          # It was 1024, which is four times what the routine has ever needed, and a real game
          # paid for it: on games/wolf3d the difference was exactly enough to push the routine
          # that draws every guard and every lamp out of the quick memory.
          MIX_ROUTINE_IWRAM_MAX = 384

          # Timer 0 clocks the mixer's output rate (how fast the DMA hands bytes to the sound
          # FIFO). It's the only hardware timer the mixer needs.
          CLOCK_TIMER = 0

          # A voice slot in IWRAM: the sample's address in ROM, how far it has played (a whole
          # sample index), its length, whether it loops, whether it's sounding, its level
          # (0..64), and — for pitch — a 16.16 fixed-point STEP (how many source samples to
          # advance per output sample: 1.0 = 0x10000 plays at the recorded pitch, 2.0 an
          # octave up) plus a FRAC accumulator carrying the leftover fraction between samples.
          SLOT_SRC = 0
          SLOT_POS = 4
          SLOT_LEN = 8
          SLOT_LOOP = 12
          SLOT_ACTIVE = 16
          SLOT_VOL = 20
          SLOT_STEP = 24
          SLOT_FRAC = 28
          SLOT_BYTES = 32

          # The fixed-point shift for STEP/FRAC: 16 fractional bits, so 1.0 == 1 << 16.
          STEP_SHIFT = 16
          STEP_ONE = 1 << STEP_SHIFT

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
          end

          # Does the program play any sample (so the mixer needs bringing up)?
          def plays_samples?
            @plays_samples
          end

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
          # two output buffers in EWRAM and the voice slots in IWRAM. The rate follows the
          # samples, so a single-rate game plays at its recorded pitch. Reserves only timer 0
          # (the sample clock) — the refill rides on the screen's own interrupt, not on a
          # second timer and not on the game loop.
          # What the mixing routine is called, and where it RUNS — which is not where it is
          # stored. It is copied into the console's quick memory at boot, like the divide
          # routines, because it runs over every sample of every sounding voice once a frame
          # and is one of the busiest things in a game that plays sampled sound.
          #
          # That is exactly why a measured profile has to be able to name it: on
          # games/wolf3d, which plays sampled audio, it is about a fifth of the frame, and
          # without this it reads as code nothing can account for.
          ROUTINE = :__mix_routine

          def mix_routine_addresses
            return {} unless @mix_routine_iwram

            size = @emitter.labels.fetch(:__mix_routine_end) - @emitter.labels.fetch(ROUTINE)
            { ROUTINE => @mix_routine_iwram...(@mix_routine_iwram + size) }
          end

          def prepare_mixer(program)
            return unless @plays_samples

            @mixer_rate = common_sample_rate(program)
            @mixer_spf = [(@mixer_rate + MIXER_FPS - 1) / MIXER_FPS, 1].max # samples per frame (ceil)
            @mix_buf0 = ewram_alloc(@mixer_spf)
            @mix_buf1 = ewram_alloc(@mixer_spf)
            @voice_base = @memory.alloc(MAX_VOICES * SLOT_BYTES)
            @mix_routine_iwram = @memory.alloc(MIX_ROUTINE_IWRAM_MAX) # the mix routine is copied here from ROM at boot
            @timers.reserve!(CLOCK_TIMER + 1) # reserve timer 0 only
          end

          # Bring the mixer up at boot: silence the voice slots and both buffers, power on
          # the sound hardware, point the DMA at the first buffer and the sample clock at the
          # mixer rate. From here the DMA plays silence until a voice is added.
          def emit_mixer_boot
            emit_zero_region(@voice_base, MAX_VOICES * SLOT_BYTES) # all voices idle
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
          # ROM address, a fresh play position, its length, and whether it loops. If every
          # slot is busy the play is dropped. Playing is main-thread, like the mix, so the
          # slots are never touched from two places at once.
          def emit_play_sample(node)
            sample = sample_info(node.name)
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
            @emitter.emit(ASM.load_immediate(TMP, 1))
            @emitter.emit(ASM.str_offset(TMP, 0, SLOT_ACTIVE))       # slot.active = 1 (now it sounds)
            @emitter.place_label(done)
          end

          # The 16.16 step for a voice: how many source samples to advance per output sample.
          # It rolls the sample's own rate against the mixer's output rate (so an off-rate
          # clip still sounds right) and the pitch shift (playing at a note other than the
          # sample's recorded one reads it faster or slower). At least 1, so it never stalls.
          def voice_step(node, sample)
            ratio = 1.0
            if node.pitch
              notes = RubyGBA::Music::NOTE_FREQUENCIES
              ratio = notes.fetch(node.pitch).to_f / notes.fetch(sample.note || :C4)
            end
            step = (sample.rate.to_f / @mixer_rate) * ratio
            [(step * STEP_ONE).round, 1].max
          end

          # stop_sample: silence a sample by clearing every voice slot playing it (or every
          # slot, when no sample is named). Just flips each matching slot's "active" off.
          def emit_stop_sample(node = nil)
            name = node && node.name
            @emitter.emit_load_data_address(4, name) if name # r4 = the sample's address to match

            @emitter.emit(ASM.load_immediate(1, @voice_base))            # r1 = slot pointer
            @emitter.emit(ASM.load_immediate(2, @voice_base + (MAX_VOICES * SLOT_BYTES))) # r2 = past the last slot
            @emitter.emit(ASM.load_immediate(3, 0))                      # r3 = the "off" value
            loop_lbl = @emitter.gensym
            skip = @emitter.gensym
            @emitter.place_label(loop_lbl)
            if name
              @emitter.emit(ASM.ldr(0, 1))                               # r0 = slot.src
              @emitter.emit(ASM.cmp_reg(0, 4))                           # slot plays this sample?
              @emitter.emit_branch(:bcond, skip, cond: :ne)              # no -> leave it
            end
            @emitter.emit(ASM.str_offset(3, 1, SLOT_ACTIVE))             # active = 0
            @emitter.place_label(skip)
            @emitter.emit(ASM.add_imm(1, 1, SLOT_BYTES))                 # next slot
            @emitter.emit(ASM.cmp_reg(1, 2))
            @emitter.emit_branch(:bcond, loop_lbl, cond: :lt)
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
          # every one is covered. The voice slots: `play` fills a slot and writes its SOUNDING
          # flag LAST, and `stop` clears that flag FIRST, so a slot half-written by the game is
          # never a slot this will read. Nothing else touches them, and a slot the game sees as
          # free stays free — this can retire a voice but never start one.
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

          def sample_info(name)
            @samples[name] ||
              raise(LoweringError, "play_sample of undefined sample #{name.inspect} — declare it with `sample`")
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
          # range so loud moments don't wrap. Clears to silence, then for each active voice
          # adds its next run of samples, scaled by the voice's volume and stepped through the
          # clip by the voice's fixed-point STEP so a pitched voice reads faster or slower,
          # advancing it and looping or retiring it at its end.
          #
          # The routine is self-contained and position-independent (relative branches, no
          # PC-relative literal loads), so it runs the same from IWRAM as from ROM. The one
          # input, the destination buffer, arrives in r0 and is stashed on the stack so each
          # voice can reset its write pointer to it. It returns with BX LR.
          #
          # Registers held across voices: r3 = clamp floor (-128), r4 = slot pointer,
          # r5 = voices left. Per voice: r2 = output samples left, r6 = read pointer,
          # r7 = write pointer, r8 = play position (whole samples), r9 = length, r10 = step,
          # r11 = fraction accumulator, r12 = volume; r0/r1 scratch (127 is the clamp ceiling).
          def emit_mix_routine
            return unless @plays_samples

            @emitter.emit(ASM.loop_forever) # fall-through guard: the routine is only entered via the call
            @emitter.place_label(:__mix_routine)
            start = @emitter.pos
            @emitter.emit(ASM.push(0))                            # push {r0}: stash the destination buffer at [sp]

            # start from silence: zero the destination (r0 reloaded from the stashed pointer)
            @emitter.emit(ASM.ldr(0, 13))                         # r0 = dest (from [sp])
            @emitter.emit(ASM.load_immediate(1, 0))               # fill byte
            @emitter.emit(ASM.load_immediate(2, @mixer_spf))      # bytes to clear
            zero = @emitter.gensym
            @emitter.place_label(zero)
            @emitter.emit(ASM.strb(1, 0))
            @emitter.emit(ASM.add_imm(0, 0, 1))
            @emitter.emit(ASM.sub_imm(2, 2, 1))
            @emitter.emit(ASM.cmp_imm(2, 0))
            @emitter.emit_branch(:bcond, zero, cond: :ne)

            @emitter.emit(ASM.mvn_imm(3, 127))                    # clamp floor = -128
            @emitter.emit(ASM.load_immediate(4, @voice_base))     # first slot
            @emitter.emit(ASM.load_immediate(5, MAX_VOICES))      # voices to visit

            voice = @emitter.gensym
            next_voice = @emitter.gensym
            @emitter.place_label(voice)
            @emitter.emit(ASM.ldr_offset(0, 4, SLOT_ACTIVE))
            @emitter.emit(ASM.cmp_imm(0, 0))
            @emitter.emit_branch(:bcond, next_voice, cond: :eq)   # idle slot -> skip
            @emitter.emit(ASM.ldr_offset(6, 4, SLOT_SRC))         # r6 = src
            @emitter.emit(ASM.ldr_offset(8, 4, SLOT_POS))         # r8 = play position (whole samples)
            @emitter.emit(ASM.add_reg(6, 6, 8))                   # r6 = read pointer = src + pos
            @emitter.emit(ASM.ldr_offset(9, 4, SLOT_LEN))         # r9 = len
            @emitter.emit(ASM.ldr_offset(10, 4, SLOT_STEP))       # r10 = step (16.16)
            @emitter.emit(ASM.ldr_offset(11, 4, SLOT_FRAC))       # r11 = fraction carried in
            @emitter.emit(ASM.ldr_offset(12, 4, SLOT_VOL))        # r12 = volume gain (0..64)
            @emitter.emit(ASM.ldr(7, 13))                         # r7 = write pointer = dest (from [sp])
            @emitter.emit(ASM.load_immediate(2, @mixer_spf))      # r2 = output samples to fill

            sample = @emitter.gensym
            advance = @emitter.gensym
            wrapped = @emitter.gensym
            retire = @emitter.gensym
            end_voice = @emitter.gensym
            @emitter.place_label(sample)
            @emitter.emit(ASM.ldrsb(0, 6))                        # r0 = the voice's raw sample (signed)
            @emitter.emit(ASM.mul(1, 0, 12))                      # r1 = sample × volume...
            @emitter.emit(ASM.asr_imm(1, 1, VOL_SHIFT))           # ...÷ 64 (so :full is unchanged)
            @emitter.emit(ASM.ldrsb(0, 7))                        # r0 = what's already in the buffer
            @emitter.emit(ASM.add_reg(1, 1, 0))                   # add the scaled sample
            # Saturate r1 into [-128, 127] with no branch: ARM predication does the
            # clamp in the compare's shadow — movgt/movlt only fire when out of range —
            # so the hot per-sample path takes no pipeline flush. r3 holds -128.
            @emitter.emit(ASM.cmp_imm(1, 127))
            @emitter.emit(ASM.mov_imm_cond(:gt, 1, 127))          # r1 > 127  -> 127
            @emitter.emit(ASM.cmp_reg(1, 3))
            @emitter.emit(ASM.mov_reg_cond(:lt, 1, 3))            # r1 < -128 -> -128
            @emitter.emit(ASM.strb(1, 7))                         # write the mixed byte
            @emitter.emit(ASM.add_imm(7, 7, 1))                   # write pointer++

            # advance the play position by STEP: frac += step, move whole samples by the
            # carry (frac >> 16), keep the leftover fraction (frac & 0xFFFF).
            @emitter.emit(ASM.add_reg(11, 11, 10))                # frac += step
            @emitter.emit(ASM.lsr_imm(0, 11, STEP_SHIFT))         # r0 = whole samples to advance
            @emitter.emit(ASM.add_reg(8, 8, 0))                   # pos += that
            @emitter.emit(ASM.add_reg(6, 6, 0))                   # read pointer += that
            @emitter.emit(ASM.lsl_imm(11, 11, STEP_SHIFT))        # drop the whole part...
            @emitter.emit(ASM.lsr_imm(11, 11, STEP_SHIFT))        # ...leaving frac in [0, 0xFFFF]
            @emitter.emit(ASM.cmp_reg(8, 9))                      # pos vs len
            @emitter.emit_branch(:bcond, wrapped, cond: :ge)      # reached (or passed) the end
            @emitter.place_label(advance)
            @emitter.emit(ASM.sub_imm(2, 2, 1))
            @emitter.emit(ASM.cmp_imm(2, 0))
            @emitter.emit_branch(:bcond, sample, cond: :ne)       # more of the buffer to fill
            @emitter.emit_branch(:b, end_voice)

            @emitter.place_label(wrapped)
            @emitter.emit(ASM.ldr_offset(0, 4, SLOT_LOOP))        # loop?
            @emitter.emit(ASM.cmp_imm(0, 0))
            @emitter.emit_branch(:bcond, retire, cond: :eq)
            @emitter.emit(ASM.sub_reg(8, 8, 9))                   # loop: wrap the position back (pos -= len)
            @emitter.emit(ASM.ldr_offset(0, 4, SLOT_SRC))         # ...and re-point the read pointer at src + pos
            @emitter.emit(ASM.add_reg(6, 0, 8))
            @emitter.emit_branch(:b, advance)

            @emitter.place_label(retire)                          # one-shot done: mark idle, stop adding
            @emitter.emit(ASM.load_immediate(0, 0))
            @emitter.emit(ASM.str_offset(0, 4, SLOT_ACTIVE))

            @emitter.place_label(end_voice)
            @emitter.emit(ASM.str_offset(8, 4, SLOT_POS))         # remember how far this voice has played
            @emitter.emit(ASM.str_offset(11, 4, SLOT_FRAC))       # ...and the leftover fraction

            @emitter.place_label(next_voice)
            @emitter.emit(ASM.add_imm(4, 4, SLOT_BYTES))          # next slot
            @emitter.emit(ASM.sub_imm(5, 5, 1))
            @emitter.emit(ASM.cmp_imm(5, 0))
            @emitter.emit_branch(:bcond, voice, cond: :ne)

            @emitter.emit(ASM.add_imm(13, 13, 4))                 # pop the stashed dest (balance the stack)
            @emitter.emit(ASM.return)                             # bx lr -> back to the caller
            @emitter.place_label(:__mix_routine_end)

            size = @emitter.pos - start
            return unless size > MIX_ROUTINE_IWRAM_MAX

            raise LoweringError,
                  "the mix routine is #{size} bytes but only #{MIX_ROUTINE_IWRAM_MAX} are reserved for it " \
                  "(raise MIX_ROUTINE_IWRAM_MAX)"
          end

          private

          # Leave r0 = the address of a free voice slot, or 0 if all MAX_VOICES are busy.
          # Uses r0/r1/r2 only, so the caller's r4 (the sample address) survives.
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

          # A bump allocator for EWRAM (256KB of general work RAM), word-aligned. The mixer's
          # output buffers live here rather than in the smaller, busier IWRAM.
          def ewram_alloc(bytes)
            @next_ewram ||= EWRAM_START
            base = @next_ewram
            @next_ewram += (bytes + 3) & ~3
            base
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
