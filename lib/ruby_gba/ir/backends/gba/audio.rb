# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # Sound: each op lowered to a short list of sound-register writes — and the music
        # player, which runs in the screen's interrupt rather than where a tune is named.
        #
        # Reads two prepare-pass results handed in at construction — the defined-sound
        # and song tables, filled by collect_definitions before any code is emitted —
        # and a handful of live collaborators for what a vblank does besides waiting:
        # stepping the frame counter, snapshotting input, flipping a buffered page, and
        # feeding a bending background's tables. `uses_pressed`/`any_buffered` are
        # program facts settled elsewhere in the same lowering, read through a callable
        # since they aren't known yet when this object is built.
        class Audio
          include Constants

          #
          # Each op resolves to a short list of sound-register writes via the shared
          # Sound module, so the ROM and the interpreter play the same thing. A write
          # is just "put this 16-bit value at this register address."

          def initialize(emitter:, primitives:, sounds:, songs:, frames:, expressions:, raster:,
                          drawing:, uses_pressed:, any_buffered:)
            @emitter = emitter
            @primitives = primitives
            @defined_sounds = sounds
            @songs = songs
            @frames = frames
            @expressions = expressions
            @raster = raster
            @drawing = drawing
            @uses_pressed = uses_pressed
            @any_buffered = any_buffered
            @song_numbers = {} # tune name -> the number the player knows it by (see #prepare_music)
          end

          def emit_writes(writes)
            writes.each { |address, value| @emitter.write_reg16(address, value) }
          end

          # Power on the audio hardware.
          def emit_enable_sound(_node = nil)
            emit_writes(Sound::Registers.enable)
          end

          # A one-off sound effect on channel 2. Resolve the beep to concrete musical
          # values (a defined-sound name, a preset, or a raw frequency), then write
          # the channel-2 registers.
          def emit_beep(node)
            effect = Sound.resolve_effect(node.tone, duty: node.duty, decay: node.decay,
                                                       volume: node.volume, defined: @defined_sounds)
            emit_writes(Sound::Registers.channel2(**effect.to_h))
          end

          # A one-off percussion / explosion hit on channel 4 (the noise voice).
          # Resolve the hit to concrete musical values (a preset name plus any
          # overrides), then write the channel-4 registers.
          def emit_noise(node)
            hit = Sound.resolve_noise(node.preset, pitch: node.pitch, decay: node.decay,
                                                     volume: node.volume, metallic: node.metallic)
            emit_writes(Sound::Registers.channel4(**hit))
          end

          # Play a sustained wavetable tone on channel 3. Resolve the shape to its
          # sample table, then write the wave-RAM upload and channel-3 control.
          def emit_wave(node)
            samples = Sound.wavetable(node.shape)
            emit_writes(Sound::Registers.wave_play(samples, frequency: node.frequency, volume: node.volume))
          end

          # Silence the wave voice.
          def emit_stop_wave(_node = nil)
            emit_writes(Sound::Registers.wave_stop)
          end

          # Which hardware channel each of a song's parts plays on, in order: the
          # two square-wave voices. The score names parts, not channels — this
          # mapping is the console's business and lives here in the lowering.
          MUSIC_CHANNELS = [1, 2].freeze

          # THE MUSIC PLAYER'S STATE, in the console's quick memory. The game writes the first
          # and nothing else; the rest belong to the player, which runs in the screen's
          # interrupt. That split is what makes sharing them safe — see #emit_music_tick.
          MUSIC_WANTED = :__music_wanted   # the tune the game named, by number (0 = none)
          MUSIC_PLAYING = :__music_playing # the tune the player is on
          MUSIC_FRAME = :__music_frame     # how far into it, in frames

          # Each part's next event, as a byte offset into the score.
          def self.music_cursor(part) = :"__music_cursor_#{part}"

          # Every tune the game plays, in one piece of cartridge data: a directory first, then
          # each part's events. See #score_blob.
          MUSIC_SCORE = :__music_score

          # One directory entry: the tune's length in frames, how many parts it has, and where
          # each part's events start — rounded up to a power of two, so finding a tune's entry
          # is a shift of its number rather than a multiply.
          ENTRY_SHIFT = ((4 * (2 + RubyGBA::Music::MAX_PARTS)) - 1).bit_length
          ENTRY_BYTES = 1 << ENTRY_SHIFT

          # One event: [frame (u32), the note's two register values (u16 each)].
          ROW_BYTES = 8

          # A frame no tune ever reaches. Each part ends in a row that waits for it, so a part
          # that has run out stays quiet until the tune comes round again.
          NEVER = 0xFFFF_FFFF

          # Number the tunes the program plays, and put them in the cartridge as one score. A
          # tune that is written but never played costs nothing.
          def prepare_music(program)
            played = program.walk.filter_map { |node| node.name if node.kind == :play_song }.uniq
            played.each do |name|
              @songs.key?(name) || raise(LoweringError, "play_song for undefined song #{name.inspect}")
            end
            @song_numbers = (@songs.keys & played).each.with_index(1).to_h
            @emitter.data_blobs[MUSIC_SCORE] = score_blob if plays_music?
          end

          # Does the program play any tune (so the player goes in the screen's interrupt)?
          def plays_music? = !@song_numbers.empty?

          # NAME THE TUNE PLAYING NOW. One number into one variable, and the player in the
          # screen's interrupt does the rest. Written every frame or once, from a branch or from
          # two, it is the same number and so the same tune.
          def emit_play_song(node)
            number = @song_numbers.fetch(node.name) do
              raise LoweringError, "play_song for undefined song #{node.name.inspect}"
            end
            @emitter.emit(ASM.load_immediate(ACC, number))
            @primitives.store_var(ACC, MUSIC_WANTED)
          end

          # No tune — the player silences whatever it was playing. With no tune anywhere in the
          # program there is nothing to silence, and nothing to write.
          def emit_stop_music(_node = nil)
            return unless plays_music?

            @emitter.emit(ASM.load_immediate(ACC, 0))
            @primitives.store_var(ACC, MUSIC_WANTED)
          end

          # ONE FRAME OF THE MUSIC PLAYER, emitted inside the screen's own interrupt.
          #
          # THAT IS WHERE IT HAS TO BE, for the reason the mixer's refill is there too. A tempo
          # is a fact about the clock on the wall. Stepped once per pass of the game loop, a tune
          # played at half speed in a game whose pass took two frames, and a branch that skipped
          # the step stopped it dead. The interrupt comes once for every frame the display
          # really shows, whatever the game is doing.
          #
          # First it catches up with the game. A different tune than the one playing silences
          # the parts of the old one and starts the new one from its first frame; no tune at all
          # just silences. The same tune changes nothing.
          #
          # Then each part looks at the ONE event its cursor points at: due on this frame, its
          # two register values are copied out and the cursor steps on; otherwise nothing. So a
          # frame costs one check per part, and a long tune costs what a short one does. The
          # frame moves on, and at the tune's length it goes back to 0 with every cursor back at
          # its part's first event — the tune loops.
          #
          # SAFE TO SHARE WITH THE GAME because the game only ever writes WANTED, with a single
          # store, and this only ever reads it. Everything else here belongs to the player alone.
          #
          # Every register is free here — the console saves r0-r3 and r12 on the way in, and the
          # dispatcher r4-r11. r2 holds the score, r3 an entry or a row in it, r4 the tune asked
          # for and then a cursor, r5 the frame, r6 the tune playing; r0/r1 carry each write.
          def emit_music_tick
            base, at, value, frame, playing = 2, 3, 4, 5, 6
            changed = @emitter.gensym
            play = @emitter.gensym
            done = @emitter.gensym

            @primitives.load_var(value, MUSIC_WANTED)
            @primitives.load_var(playing, MUSIC_PLAYING)
            @emitter.emit(ASM.cmp_reg(value, playing))
            @emitter.emit_branch(:bcond, changed, cond: :ne)

            # The same tune as last frame — or still none.
            @emitter.emit(ASM.cmp_imm(playing, 0))
            @emitter.emit_branch(:bcond, done, cond: :eq)
            @emitter.emit_load_data_address(base, MUSIC_SCORE)
            @primitives.load_var(frame, MUSIC_FRAME)
            @emitter.emit_branch(:b, play)

            # A different tune, or none. Silence the one playing, then start the new one.
            @emitter.place_label(changed)
            @emitter.emit_load_data_address(base, MUSIC_SCORE)
            emit_silence_tune(base, at, frame, playing)
            @emitter.emit(ASM.mov_reg(playing, value))
            @primitives.store_var(playing, MUSIC_PLAYING)
            @emitter.emit(ASM.cmp_imm(playing, 0))
            @emitter.emit_branch(:bcond, done, cond: :eq)
            @emitter.emit(ASM.load_immediate(frame, 0))
            emit_rewind_parts(base, at, playing)

            @emitter.place_label(play)
            RubyGBA::Music::MAX_PARTS.times { |part| emit_play_part(part, base, at, value, frame) }

            wrap = @emitter.gensym
            @emitter.emit(ASM.add_imm(frame, frame, 1))
            emit_entry_address(at, base, playing)
            @emitter.emit(ASM.ldr(ACC, at))                 # the tune's length
            @emitter.emit(ASM.cmp_reg(frame, ACC))
            @emitter.emit_branch(:bcond, wrap, cond: :lt)   # not at the end yet
            @emitter.emit(ASM.load_immediate(frame, 0))     # round again from the top
            emit_rewind_parts(base, at, playing)
            @emitter.place_label(wrap)
            @primitives.store_var(frame, MUSIC_FRAME)
            @emitter.place_label(done)
          end

          # Wait for the vertical blank — the brief pause between drawn frames, the safe
          # moment to change what's on screen. Rather than spin reading the scanline
          # counter, we ask the BIOS to sleep the CPU until the next VBlank interrupt
          # (VBlankIntrWait). The interrupt itself was armed once at boot (emit_irq_setup),
          # so this is a single instruction; the CPU draws no power while it waits.
          def emit_wait_vblank(_node = nil)
            @emitter.emit(ASM.swi(SWI_VBLANK_INTR_WAIT << 16))

            # How many frames the pass that just ended really took. First thing after the wait,
            # because everything below is entitled to ask — and it is the difference between two
            # marks, so it has to be taken before anything else moves either of them.
            @frames.emit_frame_step

            # The next slice of mixed sound, and the tune's next frame, were both done by the
            # screen's own interrupt, which is what just woke us — not here. See the vblank
            # handler in #emit_irq_handler: sound is played by a clock the game does not own, so
            # it cannot be moved on once per PASS of a loop whose length the game decides.

            # A new frame begins now, so refresh the input snapshot: last frame's
            # keys become "previous", and we latch this frame's keys as "current".
            @expressions.snapshot_keys if @uses_pressed.call

            # This is the safe moment to swap pages when a buffered scene is live:
            # show the frame just drawn and hand the program the other page. Which mode
            # is live can change frame to frame, so the flip is decided at run time.
            @drawing.emit_flip_if_buffered if @any_buffered.call

            # This is the safe moment to point the copier back at the top of the table it
            # just walked down, ready for the frame that starts when we leave. It goes
            # before the table is refilled, and not after: stopping and restarting the
            # engine is only harmless while nothing is being drawn, and a heavy fill can run
            # on past the end of this gap.
            @raster.emit_rearm_row_bend_copiers if @raster.copies_row_bends?

            # Nothing is being drawn now, so this is where a frame is settled: work out
            # where every row of a bending background sits, from the game's variables as
            # they stand — the same ones the sprites are about to be placed from, so the
            # bend and everything standing on it show the same frame. (Nothing here when no
            # background bends, or when a program with no frame runs its block per line.)
            @raster.emit_fill_row_bend_tables if @raster.latches_row_bends?
          end

          private

          # +at+ = where tune number +playing+'s directory entry sits.
          def emit_entry_address(at, base, playing)
            @emitter.emit(ASM.lsl_imm(at, playing, ENTRY_SHIFT))
            @emitter.emit(ASM.add_reg(at, base, at))
          end

          # Point every part's cursor at its first event.
          def emit_rewind_parts(base, at, playing)
            emit_entry_address(at, base, playing)
            RubyGBA::Music::MAX_PARTS.times do |part|
              @emitter.emit(ASM.ldr_offset(ACC, at, 8 + (4 * part)))
              @primitives.store_var(ACC, self.class.music_cursor(part))
            end
          end

          # Silence each part tune number +playing+ has — a rest on its channel — and nothing
          # when no tune is playing. Only its OWN parts: the second music voice is also the one
          # sound effects play on, and a one-part tune ending must not cut a beep off.
          def emit_silence_tune(base, at, parts, playing)
            quiet = @emitter.gensym
            @emitter.emit(ASM.cmp_imm(playing, 0))
            @emitter.emit_branch(:bcond, quiet, cond: :eq)
            emit_entry_address(at, base, playing)
            @emitter.emit(ASM.ldr_offset(parts, at, 4))     # how many parts it has
            MUSIC_CHANNELS.each_with_index do |channel, part|
              @emitter.emit(ASM.cmp_imm(parts, part))
              @emitter.emit_branch(:bcond, quiet, cond: :le) # no part this far along
              emit_writes(Sound::Registers.channel_note(channel, frequency: 0, duty: :half, volume: 0))
            end
            @emitter.place_label(quiet)
          end

          # Play one part's next event, if it is due on this frame.
          def emit_play_part(part, base, at, cursor, frame)
            regs = music_voice_regs(MUSIC_CHANNELS.fetch(part))
            skip = @emitter.gensym
            @primitives.load_var(cursor, self.class.music_cursor(part))
            @emitter.emit(ASM.add_reg(at, base, cursor))      # the row it points at
            @emitter.emit(ASM.ldr(ACC, at))                   # the frame it is due
            @emitter.emit(ASM.cmp_reg(ACC, frame))
            @emitter.emit_branch(:bcond, skip, cond: :ne)     # not yet — leave the voice alone

            regs[:const].each do |addr, value|                # channel 1's sweep, written first
              @emitter.emit(ASM.load_immediate(ACC, value))
              @emitter.emit(ASM.load_immediate(TMP, addr))
              @emitter.emit(ASM.store_halfword(ACC, TMP))
            end
            [[4, regs[:reg_a]], [6, regs[:reg_b]]].each do |offset, addr|
              @emitter.emit(ASM.load_halfword_offset(ACC, at, offset))
              @emitter.emit(ASM.load_immediate(TMP, addr))
              @emitter.emit(ASM.store_halfword(ACC, TMP))
            end
            @emitter.emit(ASM.add_imm(cursor, cursor, ROW_BYTES))
            @primitives.store_var(cursor, self.class.music_cursor(part))
            @emitter.place_label(skip)
          end

          # Every tune the program plays, as one piece of data. First a directory with an entry
          # per tune (entry 0 is the "no tune" number and is never read), then each part's
          # events. Where a part starts is a byte offset into this same data, so nothing in it
          # needs to know where the cartridge puts it. A part a tune does not have points at a
          # row that is nothing but a wait for NEVER.
          def score_blob
            directory_size = (@song_numbers.size + 1) * ENTRY_BYTES
            waiting = [NEVER, 0, 0].pack("Vvv")
            directory = ("\0" * ENTRY_BYTES).b
            events = waiting.dup

            @song_numbers.each_key do |name|
              song = @songs.fetch(name)
              starts = Array.new(RubyGBA::Music::MAX_PARTS, directory_size)
              song.voices.each_with_index do |voice, part|
                starts[part] = directory_size + events.bytesize
                events << part_rows(name, part, voice) << waiting
              end
              directory << [song.total_frames, song.voices.size, *starts].pack("V*").ljust(ENTRY_BYTES, "\0")
            end
            directory + events
          end

          # A part's events, each with the note's register values worked out here so the player
          # only copies them.
          def part_rows(name, part, voice)
            channel = MUSIC_CHANNELS.fetch(part) do
              raise LoweringError, "song #{name.inspect} has more parts than this console can play"
            end
            regs = music_voice_regs(channel)
            voice[:events].map do |frame, frequency|
              writes = Sound::Registers.channel_note(channel, frequency: frequency, duty: voice[:duty],
                                                              volume: voice[:volume])
              [frame, note_reg_value(writes, regs[:reg_a]), note_reg_value(writes, regs[:reg_b])].pack("Vvv")
            end.join
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

          # The value a note writes to a given sound register (0 if it doesn't touch it).
          def note_reg_value(writes, reg)
            found = writes.find { |addr, _| addr == reg }
            found ? found.last : 0
          end
        end
      end
    end
  end
end
