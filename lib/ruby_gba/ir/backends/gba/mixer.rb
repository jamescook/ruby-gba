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
        # `stop` clears a sample's slots. The mix runs once per frame, right after the
        # program waits for vblank — so playing samples needs a game loop.
        #
        # (For now every voice plays at the one mixer rate; a later feature steps each voice
        # at its own pitch. That's why one recorded note can't yet become a whole keyboard.)
        module Mixer
          include Constants

          # How many samples can sound at once. A new play past this is dropped (safe and
          # quiet) rather than stealing one already sounding. Matches the interpreter.
          MAX_VOICES = 8

          # Timer 0 clocks the mixer's output rate (how fast the DMA hands bytes to the sound
          # FIFO). It's the only hardware timer the mixer needs.
          CLOCK_TIMER = 0

          # A voice slot is six words in IWRAM: the sample's address in ROM, how far it has
          # played (a byte offset), its length, whether it loops, whether it's sounding, and
          # its level (0..64, applied as it's mixed).
          SLOT_SRC = 0
          SLOT_POS = 4
          SLOT_LEN = 8
          SLOT_LOOP = 12
          SLOT_ACTIVE = 16
          SLOT_VOL = 20
          SLOT_BYTES = 24

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

          # Decide the mixer's output rate and per-frame buffer size, and reserve its memory:
          # two output buffers in EWRAM and the voice slots in IWRAM. The rate follows the
          # samples, so a single-rate game plays at its recorded pitch. Reserves only timer 0
          # (the sample clock) — the refill is driven by the frame loop, not another timer.
          def prepare_mixer(program)
            return unless @plays_samples

            @mixer_rate = common_sample_rate(program)
            @mixer_spf = [(@mixer_rate + MIXER_FPS - 1) / MIXER_FPS, 1].max # samples per frame (ceil)
            @mix_buf0 = ewram_alloc(@mixer_spf)
            @mix_buf1 = ewram_alloc(@mixer_spf)
            @voice_base = @next_var
            @next_var += MAX_VOICES * SLOT_BYTES
            @next_hw_timer = CLOCK_TIMER + 1 # reserve timer 0 only
          end

          # Bring the mixer up at boot: silence the voice slots and both buffers, power on
          # the sound hardware, point the DMA at the first buffer and the sample clock at the
          # mixer rate. From here the DMA plays silence until a voice is added.
          def emit_mixer_boot
            emit_zero_region(@voice_base, MAX_VOICES * SLOT_BYTES) # all voices idle
            emit_zero_region(@mix_buf0, @mixer_spf)                # buffers start silent...
            emit_zero_region(@mix_buf1, @mixer_spf)
            emit(ASM.load_immediate(ACC, 0))
            store_var(ACC, MIX_FRONT)                              # ...playing buffer 0 first

            write_reg16(REG_SOUNDCNT_X, SOUND_MASTER_ENABLE)       # master sound on
            write_reg16(REG_SOUNDCNT_H, direct_sound_a_config)     # channel A, full volume, FIFO reset
            emit(ASM.load_immediate(ACC, @mix_buf0))
            store_reg_ioreg(ACC, REG_DMA1SAD)                      # DMA source = buffer 0
            store_word_immediate(REG_FIFO_A, REG_DMA1DAD)          # DMA dest = the sound FIFO
            store_word_immediate(dma_fifo_control, REG_DMA1CNT)    # feed the FIFO continuously

            prescaler, reload = timer_config(@mixer_rate)          # timer 0 = the mixer's sample rate
            write_reg16(timer_reg_l(CLOCK_TIMER), reload)
            write_reg16(timer_reg_h(CLOCK_TIMER), TIMER_ENABLE | prescaler)
          end

          # play_sample: start a sample sounding by filling a free voice slot with it — its
          # ROM address, a fresh play position, its length, and whether it loops. If every
          # slot is busy the play is dropped. Playing is main-thread, like the mix, so the
          # slots are never touched from two places at once.
          def emit_play_sample(node)
            sample = sample_info(node[:name])
            emit_load_data_address(4, node[:name]) # r4 = the sample's address in ROM
            slot = find_free_slot                  # r0 = a free slot's address, or none -> skip
            done = gensym
            emit(ASM.cmp_imm(0, 0))                 # find_free_slot leaves r0 = 0 when full
            emit_branch(:bcond, done, cond: :eq)

            emit(ASM.str(4, 0))                             # slot.src = address (SLOT_SRC = 0)
            emit(ASM.load_immediate(TMP, 0))
            emit(ASM.str_offset(TMP, 0, SLOT_POS))          # slot.pos = 0
            emit(ASM.load_immediate(TMP, sample[:length]))
            emit(ASM.str_offset(TMP, 0, SLOT_LEN))          # slot.len = length
            emit(ASM.load_immediate(TMP, node[:loop] ? 1 : 0))
            emit(ASM.str_offset(TMP, 0, SLOT_LOOP))         # slot.loop
            emit(ASM.load_immediate(TMP, MIX_LEVELS.fetch(node[:volume], MIX_LEVELS[:full])))
            emit(ASM.str_offset(TMP, 0, SLOT_VOL))          # slot.volume (0..64 gain)
            emit(ASM.load_immediate(TMP, 1))
            emit(ASM.str_offset(TMP, 0, SLOT_ACTIVE))       # slot.active = 1 (now it sounds)
            place_label(done)
          end

          # stop_sample: silence a sample by clearing every voice slot playing it (or every
          # slot, when no sample is named). Just flips each matching slot's "active" off.
          def emit_stop_sample(node = nil)
            name = node && node[:name]
            emit_load_data_address(4, name) if name # r4 = the sample's address to match

            emit(ASM.load_immediate(1, @voice_base))            # r1 = slot pointer
            emit(ASM.load_immediate(2, @voice_base + (MAX_VOICES * SLOT_BYTES))) # r2 = past the last slot
            emit(ASM.load_immediate(3, 0))                      # r3 = the "off" value
            loop_lbl = gensym
            skip = gensym
            place_label(loop_lbl)
            if name
              emit(ASM.ldr(0, 1))                               # r0 = slot.src
              emit(ASM.cmp_reg(0, 4))                           # slot plays this sample?
              emit_branch(:bcond, skip, cond: :ne)              # no -> leave it
            end
            emit(ASM.str_offset(3, 1, SLOT_ACTIVE))             # active = 0
            place_label(skip)
            emit(ASM.add_imm(1, 1, SLOT_BYTES))                 # next slot
            emit(ASM.cmp_reg(1, 2))
            emit_branch(:bcond, loop_lbl, cond: :lt)
          end

          # The per-frame refill (emitted right after wait_vblank): fill the buffer that is
          # NOT playing with the next slice of mixed sound, then swap — point the DMA at the
          # freshly filled buffer so it plays next. Which buffer is which is held in a hidden
          # variable and flipped each frame.
          def emit_mixer_tick
            load_var(0, MIX_FRONT)          # r0 = the buffer now playing (front)
            emit(ASM.cmp_imm(0, 0))
            play_buf1 = gensym
            done = gensym
            emit_branch(:bcond, play_buf1, cond: :ne)
            # front == 0 -> mix into buffer 1, then play buffer 1
            emit_mix_into(@mix_buf1)
            emit(ASM.load_immediate(ACC, 1))
            store_var(ACC, MIX_FRONT)
            emit_rearm_dma(@mix_buf1)
            emit_branch(:b, done)
            place_label(play_buf1)
            # front == 1 -> mix into buffer 0, then play buffer 0
            emit_mix_into(@mix_buf0)
            emit(ASM.load_immediate(ACC, 0))
            store_var(ACC, MIX_FRONT)
            emit_rearm_dma(@mix_buf0)
            place_label(done)
          end

          private

          # Point channel A's DMA at +buffer+ and (re)start it. The DMA reloads its source
          # only when switched off and on, so a swap is: stop, set the source, start.
          def emit_rearm_dma(buffer)
            store_word_immediate(0, REG_DMA1CNT)                # off
            emit(ASM.load_immediate(ACC, buffer))
            store_reg_ioreg(ACC, REG_DMA1SAD)                   # source = the freshly mixed buffer
            store_word_immediate(dma_fifo_control, REG_DMA1CNT) # on
          end

          # Fill +dest+ (one frame of bytes) with the sum of every sounding voice, clamped to
          # the 8-bit range so loud moments don't wrap around. Clears to silence, then adds
          # each active voice's next run of samples, advancing that voice and looping or
          # retiring it at its end. Runs on the main thread with every register free.
          #
          # Registers: r2/r3 hold the clamp limits; r4 walks the voice slots, r5 counts them
          # down; per voice r6=read pointer, r7=write pointer, r8=position, r9=length,
          # r10=loop flag, r11=samples-left; r0/r1 are scratch.
          def emit_mix_into(dest)
            emit_zero_region(dest, @mixer_spf)            # start from silence
            emit(ASM.load_immediate(2, 127))             # clamp ceiling
            emit(ASM.mvn_imm(3, 127))                    # clamp floor = -128
            emit(ASM.load_immediate(4, @voice_base))     # first slot
            emit(ASM.load_immediate(5, MAX_VOICES))      # voices to visit

            voice = gensym
            next_voice = gensym
            place_label(voice)
            emit(ASM.ldr_offset(0, 4, SLOT_ACTIVE))
            emit(ASM.cmp_imm(0, 0))
            emit_branch(:bcond, next_voice, cond: :eq)   # idle slot -> skip
            emit(ASM.ldr_offset(6, 4, SLOT_SRC))         # r6 = src
            emit(ASM.ldr_offset(8, 4, SLOT_POS))         # r8 = pos
            emit(ASM.add_reg(6, 6, 8))                   # r6 = read pointer = src + pos
            emit(ASM.ldr_offset(9, 4, SLOT_LEN))         # r9 = len
            emit(ASM.ldr_offset(10, 4, SLOT_LOOP))       # r10 = loop flag
            emit(ASM.ldr_offset(12, 4, SLOT_VOL))        # r12 = volume gain (0..64)
            emit(ASM.load_immediate(7, dest))            # r7 = write pointer = start of dest
            emit(ASM.load_immediate(11, @mixer_spf))     # r11 = samples to add

            sample = gensym
            wrapped = gensym
            retire = gensym
            end_voice = gensym
            place_label(sample)
            emit(ASM.ldrsb(0, 6))                        # r0 = the voice's raw sample (signed)
            emit(ASM.mul(1, 0, 12))                      # r1 = sample × volume...
            emit(ASM.asr_imm(1, 1, VOL_SHIFT))           # ...÷ 64 (so :full is unchanged)
            emit(ASM.ldrsb(0, 7))                        # r0 = what's already in the buffer
            emit(ASM.add_reg(1, 1, 0))                   # add the scaled sample
            # clamp r1 into [-128, 127]
            skip_hi = gensym
            skip_lo = gensym
            emit(ASM.cmp_reg(1, 2))
            emit_branch(:bcond, skip_hi, cond: :le)
            emit(ASM.mov_reg(1, 2))
            place_label(skip_hi)
            emit(ASM.cmp_reg(1, 3))
            emit_branch(:bcond, skip_lo, cond: :ge)
            emit(ASM.mov_reg(1, 3))
            place_label(skip_lo)
            emit(ASM.strb(1, 7))                         # write the mixed byte
            emit(ASM.add_imm(6, 6, 1))                   # read pointer++
            emit(ASM.add_imm(7, 7, 1))                   # write pointer++
            emit(ASM.add_imm(8, 8, 1))                   # pos++
            emit(ASM.cmp_reg(8, 9))                      # pos vs len
            emit_branch(:bcond, wrapped, cond: :ge)      # reached the end of the clip
            emit(ASM.sub_imm(11, 11, 1))
            emit(ASM.cmp_imm(11, 0))
            emit_branch(:bcond, sample, cond: :ne)       # more of the buffer to fill
            emit_branch(:b, end_voice)

            place_label(wrapped)
            emit(ASM.cmp_imm(10, 0))                     # loop?
            emit_branch(:bcond, retire, cond: :eq)
            emit(ASM.load_immediate(8, 0))               # loop: back to the start
            emit(ASM.ldr_offset(6, 4, SLOT_SRC))         # read pointer = src (pos 0)
            emit(ASM.sub_imm(11, 11, 1))
            emit(ASM.cmp_imm(11, 0))
            emit_branch(:bcond, sample, cond: :ne)
            emit_branch(:b, end_voice)

            place_label(retire)                          # one-shot done: mark idle, stop adding
            emit(ASM.load_immediate(0, 0))
            emit(ASM.str_offset(0, 4, SLOT_ACTIVE))

            place_label(end_voice)
            emit(ASM.str_offset(8, 4, SLOT_POS))         # remember how far this voice has played

            place_label(next_voice)
            emit(ASM.add_imm(4, 4, SLOT_BYTES))          # next slot
            emit(ASM.sub_imm(5, 5, 1))
            emit(ASM.cmp_imm(5, 0))
            emit_branch(:bcond, voice, cond: :ne)
          end

          # Leave r0 = the address of a free voice slot, or 0 if all MAX_VOICES are busy.
          # Uses r0/r1/r2 only, so the caller's r4 (the sample address) survives.
          def find_free_slot
            emit(ASM.load_immediate(1, @voice_base))
            emit(ASM.load_immediate(2, @voice_base + (MAX_VOICES * SLOT_BYTES)))
            scan = gensym
            found = gensym
            miss = gensym
            place_label(scan)
            emit(ASM.ldr_offset(0, 1, SLOT_ACTIVE))
            emit(ASM.cmp_imm(0, 0))
            emit_branch(:bcond, found, cond: :eq)        # active == 0 -> free
            emit(ASM.add_imm(1, 1, SLOT_BYTES))
            emit(ASM.cmp_reg(1, 2))
            emit_branch(:bcond, scan, cond: :lt)
            emit(ASM.load_immediate(0, 0))               # none free
            emit_branch(:b, miss)
            place_label(found)
            emit(ASM.mov_reg(0, 1))                      # r0 = the free slot's address
            place_label(miss)
          end

          # Zero +bytes+ bytes of memory starting at +addr+ (voice slots, output buffers).
          def emit_zero_region(addr, bytes)
            emit(ASM.load_immediate(0, addr))
            emit(ASM.load_immediate(1, 0))
            emit(ASM.load_immediate(2, bytes))
            loop_lbl = gensym
            place_label(loop_lbl)
            emit(ASM.strb(1, 0))
            emit(ASM.add_imm(0, 0, 1))
            emit(ASM.sub_imm(2, 2, 1))
            emit(ASM.cmp_imm(2, 0))
            emit_branch(:bcond, loop_lbl, cond: :ne)
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
            rates = program.walk.select { |n| n.kind == :sample }.map { |n| n[:rate] }
            return RubyGBA::Builder::SampledAudio::DEFAULT_SAMPLE_RATE if rates.empty?

            rates.group_by(&:itself).max_by { |_rate, list| list.size }.first
          end
        end
      end
    end
  end
end
