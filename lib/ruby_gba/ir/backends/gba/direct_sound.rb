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

          # The most samples a clip can have — the length counter is a single 16-bit timer,
          # so it can count up to 65536 sample overflows before it would wrap.
          MAX_SAMPLE_LENGTH = 65_536

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
                @data_blobs[node[:name]] = node[:bytes] # embed the PCM data as a ROM blob
                @samples[node[:name]] = { rate: node[:rate], length: node[:bytes].bytesize }
              when :play_sample
                @plays_samples = true
              end
            end
            return unless @plays_samples

            # Reserve timers 0 and 1 for Direct Sound, so user timers allocate from 2 up.
            @next_hw_timer = DS_LENGTH_TIMER + 1
          end

          # Start a sample playing on channel A: power on Direct Sound, reset its FIFO, point
          # the DMA at the sample data feeding the FIFO, and start the two timers (the clock,
          # and the length counter that will interrupt at the end). Re-runnable — playing
          # again just restarts the channel with the new sample.
          def emit_play_sample(node)
            sample = sample_info(node[:name])
            if sample[:length] > MAX_SAMPLE_LENGTH
              raise LoweringError,
                    "sample #{node[:name].inspect} is #{sample[:length]} samples, longer than Direct Sound can " \
                    "play in one go (#{MAX_SAMPLE_LENGTH}). Use a shorter or lower-rate clip."
            end
            prescaler, reload = timer_config(sample[:rate]) # timer 0 overflows at the sample rate

            write_reg16(REG_SOUNDCNT_X, SOUND_MASTER_ENABLE) # master sound on
            write_reg16(REG_SOUNDCNT_H, direct_sound_a_config) # enable A, full volume, reset its FIFO

            emit_load_data_address(ACC, node[:name])         # r0 = address of the sample data
            store_reg_ioreg(ACC, REG_DMA1SAD)                # DMA source = the sample
            store_word_immediate(REG_FIFO_A, REG_DMA1DAD)    # DMA destination = the sound FIFO
            store_word_immediate(dma_fifo_control, REG_DMA1CNT) # go: feed the FIFO on each request

            write_reg16(timer_reg_l(DS_CLOCK_TIMER), reload)          # the sample clock...
            write_reg16(timer_reg_h(DS_CLOCK_TIMER), TIMER_ENABLE | prescaler)
            write_reg16(timer_reg_l(DS_LENGTH_TIMER), MAX_SAMPLE_LENGTH - sample[:length]) # ...and the length counter
            write_reg16(timer_reg_h(DS_LENGTH_TIMER), TIMER_ENABLE | TIMER_CASCADE | TIMER_IRQ)
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
