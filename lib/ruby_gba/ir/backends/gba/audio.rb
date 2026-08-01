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

          # A one-off percussion / explosion hit on channel 4 (the noise voice).
          # Resolve the hit to concrete musical values (a preset name plus any
          # overrides), then write the channel-4 registers.
          def emit_noise(node)
            hit = Sound.resolve_noise(node[:preset], pitch: node[:pitch], decay: node[:decay],
                                                     volume: node[:volume], metallic: node[:metallic])
            emit_writes(Sound::Registers.channel4(**hit))
          end

          # Play a sustained wavetable tone on channel 3. Resolve the shape to its
          # sample table, then write the wave-RAM upload and channel-3 control.
          def emit_wave(node)
            samples = Sound.wavetable(node[:shape])
            emit_writes(Sound::Registers.wave_play(samples, frequency: node[:frequency], volume: node[:volume]))
          end

          # Silence the wave voice.
          def emit_stop_wave
            emit_writes(Sound::Registers.wave_stop)
          end

          # Silence the music channel.
          def emit_stop_music
            emit_writes(Sound::Registers.stop_music)
          end

          # Which hardware channel each of a song's parts plays on, in order: the
          # two square-wave voices. The score names parts, not channels — this
          # mapping is the console's business and lives here in the lowering.
          MUSIC_CHANNELS = [1, 2].freeze

          # Advance a song by one frame. A shared per-song frame counter lives in IWRAM
          # (starting at 0, since that memory is zero-initialized), and each voice keeps
          # its own cursor — an index into that voice's event table. Every frame we look
          # at only the ONE event each cursor points at: if its frame matches the
          # counter we write that note's registers and step the cursor forward, else we
          # do nothing. So the per-frame cost is one check per voice, not one per note in
          # the whole score — a long tune costs the same as a short one. A layered song
          # has a cursor per part, each on its own channel, all read against the same
          # counter so the parts stay in lock-step. When the counter reaches the song's
          # length it wraps to 0 and every cursor rewinds, so the tune loops. The events
          # themselves — a frame plus the note's two register values — live in a ROM
          # table built once at compile time (build_song_tables).
          #
          # Registers: r5 holds the frame counter for the whole update; r2/r3/r4 are
          # scratch for walking one voice's table (base, cursor address, value).
          def emit_play_song(node)
            song = @songs.fetch(node[:name]) do
              raise LoweringError, "play_song for undefined song #{node[:name].inspect}"
            end
            counter = :"_music_frame_#{node[:name]}"
            cursors = build_song_tables(node[:name], song)
            r_counter, r_base, r_entry, r_val = 5, 2, 3, 4

            load_var(r_counter, counter) # this frame's counter, held across every voice

            cursors.each_with_index do |cursor, index|
              regs = music_voice_regs(MUSIC_CHANNELS.fetch(index) do
                raise LoweringError, "song #{node[:name].inspect} has more parts than this console can play"
              end)
              skip = gensym

              emit_load_data_address(r_base, :"_music_events_#{node[:name]}_#{index}") # &table
              load_var(r_entry, cursor)                        # this voice's cursor (an event index)
              emit(ASM.lsl_imm(r_entry, r_entry, 3))           # * 8 bytes per event
              emit(ASM.add_reg(r_entry, r_base, r_entry))      # &table[cursor]
              emit(ASM.ldr(ACC, r_entry))                      # the event's frame (a 32-bit word)
              emit(ASM.cmp_reg(ACC, r_counter))                # due this frame?
              emit_branch(:bcond, skip, cond: :ne)             # no — leave the voice alone

              regs[:const].each do |addr, value|               # e.g. channel 1's sweep = 0, written first
                emit(ASM.load_immediate(r_val, value))
                emit(ASM.load_immediate(TMP, addr))
                emit(ASM.store_halfword(r_val, TMP))
              end
              [[4, regs[:reg_a]], [6, regs[:reg_b]]].each do |offset, addr| # the two stored values -> registers
                emit(ASM.add_imm(TMP, r_entry, offset))
                emit(ASM.load_halfword(r_val, TMP))
                emit(ASM.load_immediate(TMP, addr))
                emit(ASM.store_halfword(r_val, TMP))
              end
              load_var(ACC, cursor)                            # step this voice to its next event
              emit(ASM.add_imm(ACC, ACC, 1))
              store_var(ACC, cursor)
              place_label(skip)
            end

            emit(ASM.add_imm(r_counter, r_counter, 1))         # counter += 1
            wrap = gensym                                      # loop the tune: at the end, rewind
            emit(ASM.load_immediate(TMP, song[:total_frames]))
            emit(ASM.cmp_reg(r_counter, TMP))
            emit_branch(:bcond, wrap, cond: :lt)               # not at the end yet
            emit(ASM.load_immediate(r_counter, 0))             # counter back to 0...
            cursors.each do |cursor|                           # ...and every cursor back to its first event
              emit(ASM.load_immediate(ACC, 0))
              store_var(ACC, cursor)
            end
            place_label(wrap)
            store_var(r_counter, counter)
          end

          # Which two sound registers carry a music note's varying values on a given
          # channel — the control (duty/volume) and the frequency/trigger. Channel 1
          # also clears its sweep register (const 0), written before the note so the
          # trigger lands last.
          def music_voice_regs(channel)
            case channel
            when 1 then { const: [[REG_SOUND1CNT_L, 0]], reg_a: REG_SOUND1CNT_H, reg_b: REG_SOUND1CNT_X }
            when 2 then { const: [],                     reg_a: REG_SOUND2CNT_L, reg_b: REG_SOUND2CNT_H }
            else raise LoweringError, "no music voice on channel #{channel}"
            end
          end

          # Build each voice's event table as a ROM blob and return the voices' cursor
          # variable names. Each 8-byte entry is [frame (u32), reg_a value (u16), reg_b
          # value (u16)] — the note's register values, pre-computed here so the per-frame
          # code just copies them out. A sentinel entry (frame = the song length, which
          # the counter never reaches mid-tune) sits after the last note so a finished
          # voice doesn't re-trigger before the song loops.
          def build_song_tables(name, song)
            song[:voices].each_index.map do |index|
              voice = song[:voices][index]
              regs = music_voice_regs(MUSIC_CHANNELS.fetch(index) do
                raise LoweringError, "song #{name.inspect} has more parts than this console can play"
              end)
              rows = voice[:events].map do |frame, frequency|
                writes = Sound::Registers.channel_note(MUSIC_CHANNELS.fetch(index),
                                                       frequency: frequency, duty: voice[:duty], volume: voice[:volume])
                [frame, note_reg_value(writes, regs[:reg_a]), note_reg_value(writes, regs[:reg_b])].pack("Vvv")
              end
              rows << [song[:total_frames], 0, 0].pack("Vvv") # sentinel: never matches while the tune plays
              @data_blobs[:"_music_events_#{name}_#{index}"] = rows.join
              :"_music_idx_#{name}_#{index}"
            end
          end

          # The value a note writes to a given sound register (0 if it doesn't touch it).
          def note_reg_value(writes, reg)
            found = writes.find { |addr, _| addr == reg }
            found ? found.last : 0
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

            # A new frame just started — build the next slice of mixed sound and hand it to
            # the DMA. This is the mixer's heartbeat: one refill per displayed frame.
            emit_mixer_tick if @plays_samples

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
