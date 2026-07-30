# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # Direct Sound — playing recorded PCM samples, the way most real GBA sound worked
        # (as opposed to the synthesized PSG tones beep/wave/noise make). The hardware has
        # a small sample FIFO; a DMA channel keeps it topped up from the sample data in
        # ROM, and a hardware timer paces how fast samples are pulled out and played — so
        # the timer's overflow rate IS the playback rate.
        #
        # We drive Direct Sound channel A, and reserve two of the four hardware timers for
        # it: timer 0 clocks the sample rate, and timer 1 (cascaded off timer 0) counts the
        # samples played and fires an interrupt once the whole clip has gone by, whose
        # handler stops playback — that's how a one-shot ends cleanly. All the FIFO/DMA/
        # timer wiring is hidden behind `sample`/`play`/`stop`.
        module DirectSound
          include Constants

          DS_CLOCK_TIMER  = 0 # timer 0 clocks channel A's sample rate
          DS_LENGTH_TIMER = 1 # timer 1 counts samples played and interrupts at the end

          # A hidden variable remembering whether the clip now playing should loop (1) or
          # stop (0) when it reaches its end. Set at play time, read by the end-of-clip
          # interrupt — so one handler serves both one-shots and looping music.
          DS_LOOP_STATE = :__ds_loop

          # A long clip is played in equal chunks (see CHUNK_SAMPLES). The length counter
          # can only span one chunk at a time, so these hidden variables count the chunks
          # down: DS_CHUNKS_LEFT ticks toward zero as each chunk plays, and once it hits
          # zero the whole clip has played (loop back, or stop). DS_CHUNKS_TOTAL reloads it
          # for the next loop.
          DS_CHUNKS_LEFT  = :__ds_chunks
          DS_CHUNKS_TOTAL = :__ds_chunks_n

          # The most samples one chunk can span — the length counter is a single 16-bit
          # timer, so it counts up to 65536 sample overflows before it would wrap. A clip
          # longer than this is split into equal chunks that each fit, and played straight
          # from ROM back to back (no copying — the DMA just keeps reading the cartridge).
          CHUNK_SAMPLES = 65_536

          # Does the program play any sample? If so we reserve the Direct Sound timers and
          # install its end-of-clip interrupt.
          def direct_sound?
            @plays_samples
          end

          # Register the samples (embed their PCM data as ROM blobs) and note that the
          # program uses Direct Sound, so the timer allocator leaves timers 0-1 for it.
          def prepare_direct_sound(program)
            program.walk.each do |node|
              case node.kind
              when :sample
                @data_blobs[node[:name]] = pad_sample_blob(node[:bytes]) # embed as a ROM blob
                @samples[node[:name]] = sample_playback_plan(node[:rate], node[:bytes].bytesize)
              when :play_sample
                @plays_samples = true
              end
            end
            return unless @plays_samples

            # Reserve timers 0 and 1 for Direct Sound, so user timers allocate from 2 up.
            @next_hw_timer = DS_LENGTH_TIMER + 1
          end

          # How a clip is played: how many equal chunks it splits into (one for anything up
          # to a chunk), and how many samples each chunk spans (each fits the 16-bit length
          # counter). A short clip is one chunk of its own length — the same single-count
          # playback as before; a long one is several equal chunks played back to back.
          def sample_playback_plan(rate, length)
            chunks = [(length + CHUNK_SAMPLES - 1) / CHUNK_SAMPLES, 1].max # ceil, at least 1
            chunk_len = (length + chunks - 1) / chunks # ceil(length / chunks) — always <= CHUNK_SAMPLES
            { rate: rate, length: length, chunks: chunks, chunk_len: chunk_len }
          end

          # Round a clip's data up so its length is a whole number of chunks (see
          # #sample_playback_plan), by repeating a few samples from its own start. The DMA
          # plays a whole number of equal chunks and then loops, and the handful of extra
          # samples at the seam are the start of the clip — so a loop reads on smoothly.
          # A clip that already fits one chunk is returned untouched.
          def pad_sample_blob(bytes)
            plan = sample_playback_plan(nil, bytes.bytesize)
            padded = plan[:chunks] * plan[:chunk_len]
            return bytes if padded == bytes.bytesize

            bytes + bytes.byteslice(0, padded - bytes.bytesize)
          end

          # Start a sample playing on channel A: power on Direct Sound, reset its FIFO, point
          # the DMA at the sample data feeding the FIFO, and start the two timers (the clock,
          # and the length counter that interrupts at the end of each chunk). Re-runnable —
          # playing again just restarts the channel with the new sample. The whole clip
          # streams straight from ROM however long it is; the length counter spans one chunk
          # and a chunk count (in hidden variables) tracks the rest.
          def emit_play_sample(node)
            sample = sample_info(node[:name])
            prescaler, reload = timer_config(sample[:rate]) # timer 0 overflows at the sample rate

            emit(ASM.load_immediate(ACC, node[:loop] ? 1 : 0)) # remember loop-vs-one-shot for the
            store_var(ACC, DS_LOOP_STATE)                      # end-of-clip interrupt to act on
            emit(ASM.load_immediate(ACC, sample[:chunks]))     # how many chunks make up the clip
            store_var(ACC, DS_CHUNKS_LEFT)                     # ...counted down as it plays
            store_var(ACC, DS_CHUNKS_TOTAL)                    # ...and kept to reload on a loop
            write_reg16(REG_SOUNDCNT_X, SOUND_MASTER_ENABLE) # master sound on
            write_reg16(REG_SOUNDCNT_H, direct_sound_a_config) # enable A, full volume, reset its FIFO

            emit_load_data_address(ACC, node[:name])         # r0 = address of the sample data
            store_reg_ioreg(ACC, REG_DMA1SAD)                # DMA source = the sample
            store_word_immediate(REG_FIFO_A, REG_DMA1DAD)    # DMA destination = the sound FIFO
            store_word_immediate(dma_fifo_control, REG_DMA1CNT) # go: feed the FIFO on each request

            write_reg16(timer_reg_l(DS_CLOCK_TIMER), reload)          # the sample clock...
            write_reg16(timer_reg_h(DS_CLOCK_TIMER), TIMER_ENABLE | prescaler)
            write_reg16(timer_reg_l(DS_LENGTH_TIMER), CHUNK_SAMPLES - sample[:chunk_len]) # ...one chunk's worth
            write_reg16(timer_reg_h(DS_LENGTH_TIMER), TIMER_ENABLE | TIMER_CASCADE | TIMER_IRQ)
          end

          # The end-of-chunk interrupt (timer 1 has counted one chunk of the clip through).
          # Most chunks just tick the counter down and let playback flow on into the next
          # chunk (the DMA is already reading it straight from ROM). Only when the last
          # chunk has played — the whole clip is done — does a one-shot stop and a loop
          # restart from the top. A short clip is a single chunk, so this acts the first
          # time, exactly as a one-count clip did. Runs inside the interrupt dispatcher,
          # touching only r0/r1/r12 (all saved by the BIOS on interrupt entry).
          def emit_ds_end_of_clip
            load_var(ACC, DS_CHUNKS_LEFT)                # r0 = chunks still to play
            emit(ASM.sub_imm(ACC, ACC, 1))
            store_var(ACC, DS_CHUNKS_LEFT)
            done = gensym
            emit(ASM.cmp_imm(ACC, 0))
            emit_branch(:bcond, done, cond: :ne)         # more chunks to go -> keep streaming

            load_var(ACC, DS_LOOP_STATE)                 # whole clip played: is it looping?
            emit(ASM.cmp_imm(ACC, 0))
            stop = gensym
            emit_branch(:bcond, stop, cond: :eq)         # not looping -> stop the channel
            emit_ds_restart                              # looping -> feed it from the top again
            load_var(ACC, DS_CHUNKS_TOTAL)               # ...and reload the chunk count for next time
            store_var(ACC, DS_CHUNKS_LEFT)
            emit_branch(:b, done)
            place_label(stop)
            emit_stop_sample
            place_label(done)
          end

          # Restart channel A's DMA from the start of the current clip, to loop it. The
          # DMA source register still points at the clip — the hardware advanced only its
          # own private copy while playing — so switching the channel off then on reloads
          # that source and the clip feeds the FIFO again from the top. The sample clock
          # and the length counter are left running, so each loop is timed like the first.
          def emit_ds_restart
            store_word_immediate(0, REG_DMA1CNT)                # off (re-enabling reloads the source)
            store_word_immediate(dma_fifo_control, REG_DMA1CNT) # on -> feeds the FIFO from clip start
          end

          # Stop the sampled-audio channel: disable the DMA and both timers, and clear
          # channel A's output. Used by stop_sample and by the end-of-clip interrupt. Uses
          # only r0/r1, so it's safe to run inside the interrupt dispatcher.
          def emit_stop_sample
            store_word_immediate(0, REG_DMA1CNT)                 # stop feeding the FIFO
            write_reg16(timer_reg_h(DS_CLOCK_TIMER), 0)          # stop the sample clock
            write_reg16(timer_reg_h(DS_LENGTH_TIMER), 0)         # stop the length counter
            write_reg16(REG_SOUNDCNT_H, PSG_VOLUME_FULL)         # silence A (leave the PSG volume)
          end

          private

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
            emit(ASM.load_immediate(TMP, address))
            emit(ASM.str(reg, TMP))
          end

          def sample_info(name)
            @samples[name] ||
              raise(LoweringError, "play_sample of undefined sample #{name.inspect} — declare it with `sample`")
          end
        end
      end
    end
  end
end
