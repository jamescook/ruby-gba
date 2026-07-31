# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # Direct Sound — the console's recorded-audio hardware (as opposed to the
        # synthesized PSG tones beep/wave/noise make). It plays ONE stream of 8-bit samples
        # out of a small FIFO that a DMA channel keeps topped up, paced by a hardware timer
        # whose overflow rate IS the playback rate.
        #
        # This module is the hardware layer: it registers the program's samples (embedding
        # their PCM data in the cartridge) and holds the channel-A / DMA / timer settings.
        # Turning several samples into that one stream — adding them together — is the job of
        # the software {Mixer}, which drives this channel. All of it is hidden behind
        # `sample`/`play`/`stop`.
        module DirectSound
          include Constants

          # Does the program play any sample (so the mixer needs bringing up)?
          def direct_sound?
            @plays_samples
          end

          # Register the samples: embed each one's PCM data as a ROM blob and note the
          # program plays sound. The mixer (prepare_mixer) reserves the timer and memory.
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
