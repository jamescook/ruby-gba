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

          def initialize(emitter:, primitives:, lowering:, mixer:, sounds:, songs:, frames:, expressions:,
                          raster:, drawing:, uses_pressed:, any_buffered:)
            @emitter = emitter
            @primitives = primitives
            @lowering = lowering # works out a song's number when the game names it by one
            @mixer = mixer # where a recorded part's notes are played
            @defined_sounds = sounds
            @songs = songs
            @frames = frames
            @expressions = expressions
            @raster = raster
            @drawing = drawing
            @uses_pressed = uses_pressed
            @any_buffered = any_buffered
            @song_numbers = {} # tune name -> the number the player knows it by (see #prepare_music)
            @lanes = []        # the hardware the player drives (see Lane)
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

          # The two square-wave channels a tune's plain parts play on, in order. The score names
          # parts, not channels — this mapping is the console's business and lives here.
          MUSIC_CHANNELS = [1, 2].freeze

          # THE MUSIC PLAYER'S STATE, in the console's quick memory. The game writes the first
          # and nothing else; the rest belong to the player, which runs in the screen's
          # interrupt. That split is what makes sharing them safe — see #emit_music_tick.
          MUSIC_WANTED = :__music_wanted   # the tune the game named, by number (0 = none)
          MUSIC_PLAYING = :__music_playing # the tune the player is on
          MUSIC_FRAME = :__music_frame     # how far into it, in frames
          # How many times the game has said stop_music, and how many of those the player has
          # acted on. Counted rather than only said, so a stop and a play in one frame still
          # reach the player as a stop — which is how a tune starts over from its first note.
          MUSIC_STOPS = :__music_stops
          MUSIC_STOPS_SEEN = :__music_stops_seen

          # Each lane's next event, as a byte offset into the score.
          def self.music_cursor(lane) = :"__music_cursor_#{lane}"

          # Every tune the game plays, in one piece of cartridge data. See #score_blob.
          MUSIC_SCORE = :__music_score

          # THE LANES A TUNE IS PLAYED ON: the hardware the player drives, fixed for the whole
          # game. The two square-wave channels, then one voice of the mixer for each part that
          # plays a recording — as many as the most any one tune has — and then the wave voice
          # and the noise voice, one each, for the games that use them. A song's parts are handed
          # to lanes when it is built, each kind to its own lanes in order. So the code for a lane
          # only ever does one kind of thing, and the player never has to ask, as it runs, what
          # kind of part it is playing.
          #
          # The two console voices go LAST on purpose: a game that uses neither emits not one
          # instruction for them, and adding them moved no lane a game already had.
          Lane = Data.define(:kind, :index) # :square/:wave/:noise and its channel, or :recorded and its mixer lane

          # One event on a lane the console plays itself — square, wave or noise: [frame (u32),
          # the note's two register values (u16 each)]. All three are two register writes, so
          # all three read the same row and the player copies two halfwords whichever it is.
          SQUARE_ROW = 8

          # The wave voice's channel number, and the noise voice's, in the console's own count.
          # There is one of each, so a lane's index is the channel rather than a number among
          # several.
          WAVE_CHANNEL = 3
          NOISE_CHANNEL = 4

          # The lanes the console plays itself, and how many of each a song may have.
          CONSOLE_LANES = { wave: WAVE_CHANNEL, noise: NOISE_CHANNEL }.freeze

          # One event on a recorded lane: [frame (u32), step (u32 — how fast to read the
          # recording, 0 for a rest), instrument (u16), loudness (u16)]. The instrument is a
          # number into the score's own table of recordings, so a part can change instrument
          # from one note to the next.
          RECORDED_ROW = 12

          # One entry in that table: where the recording is in the cartridge, and how long it is.
          INSTRUMENT_SHIFT = 3
          INSTRUMENT_BYTES = 1 << INSTRUMENT_SHIFT

          # A frame no tune ever reaches. Each part ends in a row that waits for it, so a part
          # that has run out stays quiet until the tune comes round again.
          NEVER = 0xFFFF_FFFF

          # Where things sit in a tune's directory entry: its length, which lanes it uses, where
          # its loop table is (0 when it loops from its start), where its waveform is (0 when it
          # has no part on the wave voice), then each lane's first event.
          ENTRY_LANES_USED = 4
          ENTRY_LOOP = 8
          ENTRY_WAVE = 12
          ENTRY_STARTS = 16

          # A waveform, packed for wave RAM: eight halfwords the voice loops as one cycle.
          WAVE_HALFWORDS = 8
          WAVE_BYTES = WAVE_HALFWORDS * 2

          # Number the tunes the program plays, pick the lanes they need, and keep the mixer
          # voices their recorded parts will use. A tune that is written but never played costs
          # nothing. The score itself waits for #build_score, because a recorded note's step
          # depends on the rate the mixer settles on.
          def prepare_music(program)
            program.walk.each do |node|
              next unless node.kind == :play_song

              @songs.key?(node.name) || raise(LoweringError, "play_song for undefined song #{node.name.inspect}")
            end
            number_the_songs(program)
            @counts_stops = program.walk.any? { |node| node.kind == :stop_music }
            @loops = IR::Tunes.played(program).any? { |song| IR::Tunes.loop_frame(song).positive? }
            recorded = IR::Tunes.most_recorded_parts(program)
            if recorded > Sound::MIXER_VOICES # refused before this by Guardrails::Checks::SongTooManyParts
              raise LoweringError, "a song has #{recorded} recorded parts, and the mixer has #{Sound::MIXER_VOICES} voices"
            end

            # The wave and noise lanes are added only for a game that has a part on them, so a
            # game that uses neither emits nothing for them at all.
            console = CONSOLE_LANES.select { |kind, _| IR::Tunes.played(program).any? { |song| IR::Tunes.parts_on(song, kind).positive? } }
            @lanes = MUSIC_CHANNELS.map { |channel| Lane.new(:square, channel) } +
                     Array.new(recorded) { |lane| Lane.new(:recorded, lane) } +
                     console.map { |kind, channel| Lane.new(kind, channel) }
            @waves = console.key?(:wave)
            # One directory entry: the tune's length in frames, which lanes it uses, where it
            # loops from, and where each lane's events start — rounded up to a power of two, so
            # finding a tune's entry is a shift of its number rather than a multiply.
            @entry_shift = (ENTRY_STARTS + (4 * @lanes.size) - 1).bit_length
            @mixer.music_takes_voices! if recorded.positive?
          end

          # Put every tune the program plays in the cartridge, as one score.
          def build_score
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

          # NAME SONG +which+ OF A LIST as the tune playing now: the list's first number plus
          # +which+, into the same one variable `play_song` writes. A number the game works out is
          # checked first, and one naming no song in the list leaves the music as it is — the
          # same as `show_map` given a number naming no map.
          def emit_play_from_list(node)
            base = @list_bases[node.name] or return # a list with no songs names none
            count = @list_sizes.fetch(node.name)
            fixed = @primitives.const_int(node.which)
            if fixed
              return unless fixed.between?(0, count - 1)

              @emitter.emit(ASM.load_immediate(ACC, base + fixed))
              return @primitives.store_var(ACC, MUSIC_WANTED)
            end

            none = @emitter.gensym
            @lowering.value(node.which)                       # ACC = which
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit_branch(:bcond, none, cond: :lt)
            @emitter.emit(ASM.load_immediate(TMP, count))
            @emitter.emit(ASM.cmp_reg(ACC, TMP))
            @emitter.emit_branch(:bcond, none, cond: :ge)     # past the last song
            @primitives.emit_add_const(ACC, ACC, base, TMP)
            @primitives.store_var(ACC, MUSIC_WANTED)
            @emitter.place_label(none)
          end

          # No tune — the player silences whatever it was playing. With no tune anywhere in the
          # program there is nothing to silence, and nothing to write.
          def emit_stop_music(_node = nil)
            return unless plays_music?

            @emitter.emit(ASM.load_immediate(ACC, 0))
            @primitives.store_var(ACC, MUSIC_WANTED) # first, so the player never sees a count
            @primitives.load_var(ACC, MUSIC_STOPS)   # move on with the old tune still named
            @emitter.emit(ASM.add_imm(ACC, ACC, 1))
            @primitives.store_var(ACC, MUSIC_STOPS)
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
          # Then each lane looks at the ONE event its cursor points at: due on this frame, the note
          # is played and the cursor steps on; otherwise nothing. So a frame costs one check per
          # lane, and a long tune costs what a short one does. A square lane's note is two
          # register values copied out; a recorded lane's is a voice of the mixer filled in —
          # which recording, how fast to read it, how loud. The frame moves on, and at the tune's
          # length it goes back to 0 with every cursor back at its lane's first event — the tune
          # loops — or, for a tune with an introduction, back to its loop frame (#emit_loop_back).
          #
          # SAFE TO SHARE WITH THE GAME because the game only ever writes WANTED, with a single
          # store, and this only ever reads it. Everything else here belongs to the player alone
          # — except the mixer's voices, which the game's sounds share, and which the game only
          # touches with interrupts held off (see Mixer#emit_music_voice_routine).
          #
          # Every register is free here — the console saves r0-r3 and r12 on the way in, and the
          # dispatcher r4-r11. r2 holds the score, r3 an entry or a row in it, r4 the tune asked
          # for and then a cursor, r5 the frame, r6 the tune playing, r7-r9 a mixer voice, its
          # part's mark and its recording; r0/r1 carry each write.
          def emit_music_tick
            base, at, value, frame, playing = 2, 3, 4, 5, 6
            changed = @emitter.gensym
            play = @emitter.gensym
            done = @emitter.gensym

            @primitives.load_var(value, MUSIC_WANTED)
            @primitives.load_var(playing, MUSIC_PLAYING)
            @emitter.emit(ASM.cmp_reg(value, playing))
            @emitter.emit_branch(:bcond, changed, cond: :ne)
            if @counts_stops # ...or the same tune, stopped and named again since last frame
              @primitives.load_var(ACC, MUSIC_STOPS)
              @primitives.load_var(TMP, MUSIC_STOPS_SEEN)
              @emitter.emit(ASM.cmp_reg(ACC, TMP))
              @emitter.emit_branch(:bcond, changed, cond: :ne)
            end

            # The same tune as last frame — or still none.
            @emitter.emit(ASM.cmp_imm(playing, 0))
            @emitter.emit_branch(:bcond, done, cond: :eq)
            @emitter.emit_load_data_address(base, MUSIC_SCORE)
            @primitives.load_var(frame, MUSIC_FRAME)
            @emitter.emit_branch(:b, play)

            # A different tune, or none, or a stop. Silence the one playing, then start the new one.
            @emitter.place_label(changed)
            if @counts_stops
              @primitives.load_var(ACC, MUSIC_STOPS)
              @primitives.store_var(ACC, MUSIC_STOPS_SEEN)
            end
            @emitter.emit_load_data_address(base, MUSIC_SCORE)
            emit_silence_tune(base, at, frame, playing)
            @emitter.emit(ASM.mov_reg(playing, value))
            @primitives.store_var(playing, MUSIC_PLAYING)
            @emitter.emit(ASM.cmp_imm(playing, 0))
            @emitter.emit_branch(:bcond, done, cond: :eq)
            @emitter.emit(ASM.load_immediate(frame, 0))
            emit_rewind_lanes(base, at, playing)
            emit_upload_wavetable(base, at, playing) if @waves

            @emitter.place_label(play)
            @lanes.each_with_index { |lane, number| emit_play_lane(lane, number, base, at, value, frame) }

            onward = @emitter.gensym
            @emitter.emit(ASM.add_imm(frame, frame, 1))
            emit_entry_address(at, base, playing)
            @emitter.emit(ASM.ldr(ACC, at))                 # the tune's length
            @emitter.emit(ASM.cmp_reg(frame, ACC))
            @emitter.emit_branch(:bcond, onward, cond: :lt) # not at the end yet
            emit_loop_back(base, at, frame, onward) if @loops
            @emitter.emit(ASM.load_immediate(frame, 0))     # round again from the top
            emit_rewind_lanes(base, at, playing)
            @emitter.place_label(onward)
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

          # THE NUMBER EACH TUNE IS KNOWN BY — the songs named on their own first, then each list's
          # songs together and in the list's order. Together is what makes picking from a list
          # one addition: song +which+ of a list is the list's first number plus +which+.
          def number_the_songs(program)
            lists = IR::Tunes.lists_played(program).reject { |_, songs| songs.empty? }
            listed = lists.values.flatten
            if listed.uniq.size < listed.size
              raise LoweringError, "a song is in more than one song list, and each song can be in one"
            end
            (listed - @songs.keys).each do |name|
              raise LoweringError, "a song list names #{name.inspect}, which is not a song"
            end
            plain = IR::Tunes.played(program).map(&:name) - listed
            @song_numbers = (plain + listed).each.with_index(1).to_h
            @list_bases = lists.transform_values { |songs| @song_numbers.fetch(songs.first) }
            @list_sizes = lists.transform_values(&:size)
          end

          # +at+ = where tune number +playing+'s directory entry sits.
          def emit_entry_address(at, base, playing)
            @emitter.emit(ASM.lsl_imm(at, playing, @entry_shift))
            @emitter.emit(ASM.add_reg(at, base, at))
          end

          # Point every lane's cursor at its first event.
          def emit_rewind_lanes(base, at, playing)
            emit_entry_address(at, base, playing)
            @lanes.each_index do |number|
              @emitter.emit(ASM.ldr_offset(ACC, at, ENTRY_STARTS + (4 * number)))
              @primitives.store_var(ACC, self.class.music_cursor(number))
            end
          end

          # AT THE END OF A TUNE THAT LOOPS FROM A POINT: back to its loop frame, with each lane
          # at the event it carries on from (see IR::Tunes#passes). Both come out of the tune's
          # loop table, so the player does nothing here that it does not do going back to the top
          # — and a tune that loops from its start has no table, and falls through to that.
          # +at+ holds the tune's directory entry.
          def emit_loop_back(base, at, frame, onward)
            top = @emitter.gensym
            @emitter.emit(ASM.ldr_offset(ACC, at, ENTRY_LOOP))
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit_branch(:bcond, top, cond: :eq)   # no table: it loops from its start
            @emitter.emit(ASM.add_reg(at, base, ACC))
            @emitter.emit(ASM.ldr(frame, at))              # the frame it goes back to
            @lanes.each_index do |number|
              @emitter.emit(ASM.ldr_offset(ACC, at, 4 + (4 * number)))
              @primitives.store_var(ACC, self.class.music_cursor(number))
            end
            @emitter.emit_branch(:b, onward)
            @emitter.place_label(top)
          end

          # PUT THE NEW TUNE'S WAVEFORM IN WAVE RAM, on the frame the tune changes and nowhere
          # else.
          #
          # The wave voice loops a short waveform — that is what makes it rounder than a square
          # wave — and the waveform belongs to the PART, so it changes only when the tune does.
          # Uploaded here, a note on that voice costs the same two register writes a square note
          # does; uploaded per note it would cost this every frame the part played one. A tune
          # with no part on the wave voice has no waveform, and nothing is written.
          #
          # BOTH BANKS GET IT, which is the console's own trap: wave RAM is two banks, the voice
          # loops one and the CPU can reach the other, so a table written to the bank being
          # played is not heard. Writing both means whichever it loops, it loops this one.
          # +at+ holds the tune's directory entry. Uses r7-r10 and ACC/TMP, all free here.
          def emit_upload_wavetable(base, at, playing)
            source, dest, walk, left = 7, 8, 9, 10
            none = @emitter.gensym
            emit_entry_address(at, base, playing)
            @emitter.emit(ASM.ldr_offset(ACC, at, ENTRY_WAVE))
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit_branch(:bcond, none, cond: :eq) # this tune plays no waveform
            @emitter.emit(ASM.add_reg(source, base, ACC))

            WAVE_BANKS.each do |bank|
              copy = @emitter.gensym
              @emitter.write_reg16(REG_SOUND3CNT_L, bank) # the CPU reaches this bank
              @emitter.emit(ASM.mov_reg(walk, source))
              @emitter.emit(ASM.load_immediate(dest, REG_WAVE_RAM))
              @emitter.emit(ASM.load_immediate(left, WAVE_HALFWORDS))
              @emitter.place_label(copy)
              @emitter.emit(ASM.load_halfword(ACC, walk))
              @emitter.emit(ASM.store_halfword(ACC, dest))
              @emitter.emit(ASM.add_imm(walk, walk, 2))
              @emitter.emit(ASM.add_imm(dest, dest, 2))
              @emitter.emit(ASM.subs_imm(left, left, 1))
              @emitter.emit_branch(:bcond, copy, cond: :ne)
            end
            @emitter.write_reg16(REG_SOUND3CNT_L, WAVE_ON)
            @emitter.place_label(none)
          end

          # Which bank of wave RAM the CPU reaches, and the value that switches the voice on
          # over one 32-sample bank.
          WAVE_BANKS = [0x0000, 0x0040].freeze
          WAVE_ON = 0x0080

          # Silence every lane tune number +playing+ uses, and nothing when no tune is playing.
          # Only its OWN lanes: the second square channel is also the one sound effects play on,
          # and a one-part tune ending must not cut a beep off.
          def emit_silence_tune(base, at, lanes_used, playing)
            quiet = @emitter.gensym
            @emitter.emit(ASM.cmp_imm(playing, 0))
            @emitter.emit_branch(:bcond, quiet, cond: :eq)
            emit_entry_address(at, base, playing)
            @emitter.emit(ASM.ldr_offset(lanes_used, at, ENTRY_LANES_USED)) # one bit for each lane it uses
            @lanes.each_with_index do |lane, number|
              unused = @emitter.gensym
              @emitter.emit(ASM.tst_imm(lanes_used, 1 << number))
              @emitter.emit_branch(:bcond, unused, cond: :eq)
              emit_silence_lane(lane)
              @emitter.place_label(unused)
            end
            @emitter.place_label(quiet)
          end

          # A lane the console plays goes quiet with a rest on its own channel — which is the
          # rest row that lane would have played, so nothing new is decided here. A recorded
          # lane goes quiet by switching off the mixer voice carrying its mark, if it still has
          # one.
          def emit_silence_lane(lane)
            if lane.kind == :recorded
              @emitter.emit(ASM.load_immediate(8, Mixer.music_owner(lane.index)))
              @mixer.emit_music_voice_off
            else
              emit_writes(console_note(lane, { duty: :half, metallic: false }, 0, 0))
            end
          end

          # Play one lane's next event, if it is due on this frame.
          def emit_play_lane(lane, number, base, at, cursor, frame)
            skip = @emitter.gensym
            @primitives.load_var(cursor, self.class.music_cursor(number))
            @emitter.emit(ASM.add_reg(at, base, cursor))      # the row it points at
            @emitter.emit(ASM.ldr(ACC, at))                   # the frame it is due
            @emitter.emit(ASM.cmp_reg(ACC, frame))
            @emitter.emit_branch(:bcond, skip, cond: :ne)     # not yet — leave the lane alone

            if lane.kind == :recorded
              emit_recorded_note(lane.index, base, at)
              @emitter.emit(ASM.add_imm(cursor, cursor, RECORDED_ROW))
            else
              emit_console_note(lane, at)
              @emitter.emit(ASM.add_imm(cursor, cursor, SQUARE_ROW))
            end
            @primitives.store_var(cursor, self.class.music_cursor(number))
            @emitter.place_label(skip)
          end

          # Copy the row's two register values onto whichever voice the console plays itself.
          # The row was worked out at build time, so this is the same handful of instructions
          # for a square note, a wave note and a drum hit alike.
          def emit_console_note(lane, at)
            regs = music_voice_regs(lane)
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
          end

          # Start the row's note on a mixer voice — from the top of the recording the row names, at
          # the row's step and loudness — or switch the part's voice off for a rest. Which voice is
          # the mixer's to say (Mixer#emit_music_voice_routine): the part's own, a free one, or
          # one of the game's. The voice's SOUNDING word goes last, and it is the part's mark.
          def emit_recorded_note(lane, base, at)
            voice, mark, recording = 7, 8, 9
            rest = @emitter.gensym
            sounded = @emitter.gensym
            @emitter.emit(ASM.load_immediate(mark, Mixer.music_owner(lane)))
            @emitter.emit(ASM.ldr_offset(ACC, at, 4))                         # how fast to read it
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit_branch(:bcond, rest, cond: :eq)                     # 0 is a rest
            @mixer.emit_take_music_voice                                      # r7 = the voice it gets
            @emitter.emit(ASM.ldr_offset(ACC, at, 4))
            @emitter.emit(ASM.str_offset(ACC, voice, Mixer::SLOT_STEP))
            @emitter.emit(ASM.load_halfword_offset(ACC, at, 10))              # how loud
            @emitter.emit(ASM.str_offset(ACC, voice, Mixer::SLOT_VOL))
            @emitter.emit(ASM.load_halfword_offset(ACC, at, 8))               # which recording...
            @emitter.emit(ASM.lsl_imm(ACC, ACC, INSTRUMENT_SHIFT))
            @emitter.emit(ASM.add_reg(recording, base, ACC))
            @primitives.emit_add_const(recording, recording, @instruments_at, ACC) # ...its table entry
            @emitter.emit(ASM.ldr(ACC, recording))                            # where it is
            @emitter.emit(ASM.str_offset(ACC, voice, Mixer::SLOT_SRC))
            @emitter.emit(ASM.ldr_offset(ACC, recording, 4))                  # how long it is
            @emitter.emit(ASM.str_offset(ACC, voice, Mixer::SLOT_LEN))
            @emitter.emit(ASM.load_immediate(ACC, 0))
            [Mixer::SLOT_POS, Mixer::SLOT_FRAC, Mixer::SLOT_LOOP].each do |field|
              @emitter.emit(ASM.str_offset(ACC, voice, field))                # from the top, once
            end
            @emitter.emit(ASM.str_offset(mark, voice, Mixer::SLOT_ACTIVE))      # the part's now
            @emitter.emit_branch(:b, sounded)
            @emitter.place_label(rest)
            @mixer.emit_music_voice_off
            @emitter.place_label(sounded)
          end

          # EVERY TUNE THE PROGRAM PLAYS, as one piece of data:
          #
          #   * a directory, one entry per tune (entry 0 is the "no tune" number and is never read):
          #     its length in frames, one bit for each lane it uses, where its loop table is, and
          #     where each lane's events start;
          #   * the table of recordings its notes can name: where each one is and how long;
          #   * then the events themselves, lane by lane — and, for a tune that loops from a point,
          #     its loop table: the frame it goes back to, and where each lane carries on from.
          #     That is nearly always part way into the lane's own events. A lane holding a note
          #     across the loop point carries on from a copy of its later events instead, headed
          #     by the held note (see IR::Tunes#passes), so only such a lane costs more room.
          #
          # Where things start is a byte offset into this same data, so nothing in it needs to know
          # where the cartridge puts it — except the recordings, which are data of their own, and
          # whose addresses are filled in once everything has a place (Emit#link_data). A lane a
          # tune does not use points at a row that waits for NEVER.
          def score_blob
            entry_bytes = 1 << @entry_shift
            instruments = @song_numbers.keys.flat_map { |name| IR::Tunes.instruments(@songs.fetch(name)) }.uniq
            @instrument_numbers = instruments.each_with_index.to_h
            @instruments_at = (@song_numbers.size + 1) * entry_bytes
            waves_at = @instruments_at + (instruments.size * INSTRUMENT_BYTES)
            # One copy of each waveform the played tunes use, whichever of them use it.
            shapes = @song_numbers.keys.flat_map { |name| wave_shapes(@songs.fetch(name)) }.uniq
            wave_at = shapes.each_with_index.to_h { |shape, i| [shape, waves_at + (i * WAVE_BYTES)] }
            events_at = waves_at + (shapes.size * WAVE_BYTES)

            directory = ("\0" * entry_bytes).b
            table = instruments.each_with_index.map do |name, number|
              @emitter.link_data(MUSIC_SCORE, @instruments_at + (number * INSTRUMENT_BYTES), name)
              [0, @mixer.sample_info(name).length].pack("VV") # where it is: filled in by the link
            end.join
            table += shapes.map { |shape| Sound::Registers.wavetable_halfwords(shape).pack("v*") }.join
            events = [NEVER, 0, 0, 0].pack("VVvv") # a row any lane can wait on
            @song_numbers.each_key do |name|
              song = @songs.fetch(name)
              passes = IR::Tunes.passes(song)
              starts = Array.new(@lanes.size, events_at)
              again = starts.dup
              used = 0
              lanes_for(name, song).each_with_index do |(part, number), index|
                lane = @lanes[number]
                pass = passes[index]
                starts[number] = events_at + events.bytesize
                used |= 1 << number
                events << lane_rows(lane, part, pass.first)
                again[number] = if pass.first.last(pass.again.size) == pass.again
                                  starts[number] + ((pass.first.size - pass.again.size) * row_bytes(lane))
                                else
                                  (events_at + events.bytesize).tap { events << lane_rows(lane, part, pass.again) }
                                end
              end
              loop_at = 0
              if IR::Tunes.loop_frame(song).positive?
                loop_at = events_at + events.bytesize
                events << [IR::Tunes.loop_frame(song), *again].pack("V*")
              end
              shape = wave_shapes(song).first
              directory << [song.total_frames, used, loop_at, shape ? wave_at.fetch(shape) : 0,
                            *starts].pack("V*").ljust(entry_bytes, "\0")
            end
            directory + table + events
          end

          # The waveform a song's parts on the wave voice play. There is one wave voice, so
          # there is at most one — Checks::SongTooManyParts refuses a song with two such parts.
          def wave_shapes(song) = song.voices.filter_map { |part| part[:wave] }.uniq

          def row_bytes(lane) = lane.kind == :recorded ? RECORDED_ROW : SQUARE_ROW

          # Which lane each of a song's parts plays on: each kind takes its own lanes in the
          # order the parts are written. Refused before this by Checks::SongTooManyParts, so a
          # part with no lane left is a lowering error rather than anything an author sees.
          def lanes_for(name, song)
            taken = Hash.new(0)
            song.voices.map do |part|
              kind = IR::Tunes.part_kind(part)
              number = @lanes.each_index.select { |i| @lanes[i].kind == kind }[taken[kind]]
              unless number
                raise LoweringError, "song #{name.inspect} has more parts on the #{kind} voice " \
                                     "than this console can play"
              end

              taken[kind] += 1
              [part, number]
            end
          end

          # A part's events on its lane, each worked out here so the player only copies it, and
          # a row after the last that waits for NEVER. An event may name its own instrument and
          # loudness; one that does not plays the part's.
          def lane_rows(lane, part, events)
            if lane.kind == :recorded
              rows = events.map do |frame, frequency, instrument, volume|
                name = instrument || part[:instrument]
                step = frequency.zero? ? 0 : @mixer.step_at(@mixer.sample_info(name), frequency)
                [frame, step, @instrument_numbers.fetch(name), loudness(volume || part[:volume])].pack("VVvv")
              end
              rows.join + [NEVER, 0, 0, 0].pack("VVvv")
            else
              regs = music_voice_regs(lane)
              rows = events.map do |frame, frequency, _instrument, volume|
                writes = console_note(lane, part, frequency, volume || part[:volume])
                [frame, note_reg_value(writes, regs[:reg_a]), note_reg_value(writes, regs[:reg_b])].pack("Vvv")
              end
              rows.join + [NEVER, 0, 0].pack("Vvv")
            end
          end

          # ONE NOTE ON A VOICE THE CONSOLE PLAYS ITSELF, as its two register values. Each kind
          # answers the pair its own way — a square voice by pitch and tone, the wave voice by a
          # sample rate, the noise voice by which rung of its clock ladder sits nearest the note
          # — and the player copies whichever pair it finds, knowing none of that.
          def console_note(lane, part, frequency, volume)
            case lane.kind
            when :square
              Sound::Registers.channel_note(lane.index, frequency: frequency, duty: part[:duty], volume: volume)
            when :wave
              Sound::Registers.wave_note(frequency: frequency, volume: volume)
            else
              Sound::Registers.noise_note(frequency: frequency, volume: volume,
                                          decay: part[:decay] || :fast, metallic: part[:metallic])
            end
          end

          # A part's volume, 0..15 like the square voices', as the mix's 0..64.
          def loudness(volume) = (volume * Mixer::MIX_LEVELS[:full] / 15.0).round

          # Which two sound registers carry a music note's varying values on a given lane — the
          # control (tone and loudness) and the pitch-and-trigger. Channel 1 also clears its
          # sweep register (const 0), written before the note so the trigger lands last.
          #
          # Every lane the console plays itself comes down to this pair, which is what lets one
          # piece of player code drive all four voices.
          def music_voice_regs(lane)
            case lane.index
            when 1 then { const: [[REG_SOUND1CNT_L, 0]], reg_a: REG_SOUND1CNT_H, reg_b: REG_SOUND1CNT_X }
            when 2 then { const: [],                     reg_a: REG_SOUND2CNT_L, reg_b: REG_SOUND2CNT_H }
            when WAVE_CHANNEL then { const: [], reg_a: REG_SOUND3CNT_H, reg_b: REG_SOUND3CNT_X }
            when NOISE_CHANNEL then { const: [], reg_a: REG_SOUND4CNT_L, reg_b: REG_SOUND4CNT_H }
            else raise LoweringError, "no music voice on channel #{lane.index}"
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
