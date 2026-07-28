# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # Sound: each op lowered to a short list of sound-register writes.
        module Audio
          include Constants

          #
          # Each op resolves to a short list of sound-register writes via the shared
          # Sound module, so the ROM and the interpreter play the same thing. A write
          # is just "put this 16-bit value at this register address."

          def emit_writes(writes)
            writes.each { |address, value| write_reg16(address, value) }
          end

          # Power on the audio hardware.
          def emit_enable_sound
            emit_writes(Sound::Registers.enable)
          end

          # A one-off sound effect on channel 2. Resolve the beep to concrete musical
          # values (a defined-sound name, a preset, or a raw frequency), then write
          # the channel-2 registers.
          def emit_beep(node)
            effect = Sound.resolve_effect(node[:tone], duty: node[:duty], decay: node[:decay],
                                                       volume: node[:volume], defined: @defined_sounds)
            emit_writes(Sound::Registers.channel2(**effect))
          end

          # Silence the music channel.
          def emit_stop_music
            emit_writes(Sound::Registers.stop_music)
          end

          # Advance a song by one frame. A per-song counter lives in IWRAM and starts
          # at 0 (memory there is zero-initialized). First every note whose frame
          # matches the counter's *current* value triggers — so the note at frame 0,
          # the downbeat every tune opens on, plays. Then the counter ticks up, and
          # once it reaches the song's length it wraps to 0 so the tune loops. This
          # unrolls the whole score into frame comparisons — the same sequencer the
          # legacy emitter builds, so migrated songs sound identical.
          def emit_play_song(node)
            song = @songs.fetch(node[:name]) do
              raise LoweringError, "play_song for undefined song #{node[:name].inspect}"
            end
            counter = :"_music_frame_#{node[:name]}"

            song[:events].each do |frame, frequency|
              skip = gensym
              load_var(ACC, counter)
              compare_acc_to(frame)
              emit_branch(:bcond, skip, cond: :ne) # counter != this note's frame? skip it
              emit_writes(Sound::Registers.channel1_note(frequency: frequency,
                                                         duty: song[:duty], volume: song[:volume]))
              place_label(skip)
            end

            load_var(ACC, counter)               # counter += 1
            emit(ASM.add_imm(ACC, ACC, 1))
            store_var(ACC, counter)

            wrap = gensym                        # loop: if counter >= length, reset to 0
            load_var(ACC, counter)
            compare_acc_to(song[:total_frames])
            emit_branch(:bcond, wrap, cond: :lt)
            emit(ASM.load_immediate(ACC, 0))
            store_var(ACC, counter)
            place_label(wrap)
          end

          # Compare the accumulator to a constant. The constant loads into a temp
          # first, so any 32-bit value works (the immediate compare form only encodes
          # small constants, and frame counts can exceed that).
          def compare_acc_to(value)
            emit(ASM.load_immediate(TMP, value))
            emit(ASM.cmp_reg(ACC, TMP))
          end

          # Wait for the vertical blank — the brief pause between drawn frames, the safe
          # moment to change what's on screen. Rather than spin reading the scanline
          # counter, we ask the BIOS to sleep the CPU until the next VBlank interrupt
          # (VBlankIntrWait). The interrupt itself was armed once at boot (emit_irq_setup),
          # so this is a single instruction; the CPU draws no power while it waits.
          def emit_wait_vblank
            emit(ASM.swi(SWI_VBLANK_INTR_WAIT << 16))

            # A new frame begins now, so refresh the input snapshot: last frame's
            # keys become "previous", and we latch this frame's keys as "current".
            snapshot_keys if @uses_pressed

            # This is the safe moment to swap pages when a buffered scene is live:
            # show the frame just drawn and hand the program the other page. Which mode
            # is live can change frame to frame, so the flip is decided at run time.
            emit_flip_if_buffered if @any_buffered
          end
        end
      end
    end
  end
end
