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

          def initialize(emitter:, primitives:, lowering:, mixer:, memory:, sounds:, songs:, frames:, expressions:,
                          raster:, drawing:, uses_pressed:, any_buffered:)
            @emitter = emitter
            @primitives = primitives
            @lowering = lowering # works out a song's number when the game names it by one
            @mixer = mixer # where a recorded part's notes are played
            @memory = memory # where the sound effects keep how far each one has got
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
            @effects = []      # every sound effect, highest rank first (see #prepare_sound_effects)
          end

          def emit_writes(writes)
            writes.each { |address, value| @emitter.write_reg16(address, value) }
          end

          # Power on the audio hardware — keeping whatever sends the recorded sound to the
          # speakers, since switching sound ON must never switch part of it off. The mixer says
          # what that is, and says nothing for a program with no recording in it.
          def emit_enable_sound(_node = nil)
            emit_writes(Sound::Registers.enable(direct_sound: @mixer.direct_sound_routing))
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
            emit_forget_waveform
          end

          # Silence the wave voice.
          def emit_stop_wave(_node = nil)
            emit_writes(Sound::Registers.wave_stop)
            emit_forget_waveform
          end

          # The game's own `wave` puts a waveform of its own in wave RAM, and `stop_wave` switches
          # the voice off: either way, no player's waveform is there to be sounded, so the next note
          # on the voice loads its own (see WAVE_LOADED). The store goes after the writes, so a
          # player running in between loads once more than it needs to rather than once too few.
          def emit_forget_waveform
            return unless @effect_waves

            @emitter.emit(ASM.load_immediate(ACC, 0))
            @primitives.store_var(ACC, WAVE_LOADED)
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

          # The music volume the notes sounding now were started at, so the player can tell when
          # the game has moved it (see IR::Tunes::LEVEL). Belongs to the player alone.
          MUSIC_LEVEL_APPLIED = :__music_level_applied

          # The note a square lane is holding — the two register values of its row, as one word —
          # kept for a game that moves the music volume, because a square voice takes its volume
          # only as a note starts, and the only way to make a held note quieter is to start it
          # again. A rest is kept as its values too, and its volume of 0 is what says there is
          # nothing to start again.
          def self.music_note(lane) = :"__music_note_#{lane}"

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

          # One entry in that table: where the recording is in the cartridge, how long it is, the
          # four numbers that shape a note on it (0 for a note that starts and stops dead), and
          # how far back a held note goes when it reaches the end (0 for one that runs out).
          #
          # THE SHAPE IS HERE AND NOT ON THE NOTE, which is what makes it free: a note already
          # carries the number of the recording it plays, so two notes on the same recording
          # shaped differently are simply two entries and the note's own number picks between
          # them. Putting the four numbers on every note instead would have grown every recorded
          # lane of every tune by a third, whether it shaped anything or not.
          INSTRUMENT_SHIFT = 4
          INSTRUMENT_BYTES = 1 << INSTRUMENT_SHIFT
          INSTRUMENT_LENGTH = 4
          INSTRUMENT_ENVELOPE = 8
          INSTRUMENT_HELD_BY = 12

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

          # SOUND EFFECTS, played once over the tune.
          #
          # Each has a place in a table in memory: whether it is waiting to start (the game's one
          # store), sounding, or neither; how far into it the player is; and each of its lanes'
          # next event. The player walks the table once a frame, so an effect that is not sounding
          # costs a load and a compare. The table is in RANK ORDER, highest first
          # (IR::Tunes.effects_by_rank), and the tune's parts are played at their own rank's place
          # among the effects — so whoever writes a voice first on a frame keeps it, and a note
          # never has to be written and then covered.
          #
          # An effect's lanes are the voices it shares with the tune: the two square voices, the wave
          # voice and the noise voice, whichever of them any effect uses. Who holds each such voice
          # is a rank in a variable of its own (IR::Tunes.song_rank), and a note is written only when
          # nobody holding the voice outranks it.
          #
          # Then one recorded lane for each part that plays a recording, as many as the most any
          # effect has. Those share the mixer's voices rather than one voice each, so who gives way
          # is the mixer's to say, by the rank each voice's mark carries (Mixer.ranked_owner).
          #
          # In a game with groups (IR::Tunes.priority_of) two more states say what the game decided
          # when it asked: an effect stopped by another of its group is STOPPING, and one of a group
          # asked for again while it sounds is RESTARTING — its voices are let go before it starts.
          EFFECT_STATE = 0    # 0, EFFECT_ASKED, EFFECT_SOUNDING, EFFECT_STOPPING or EFFECT_RESTARTING
          EFFECT_FRAME = 4    # how far into the effect, in frames
          EFFECT_CURSORS = 8  # each lane's next event, as a byte offset into the score
          EFFECT_ASKED = 1
          EFFECT_SOUNDING = 2
          EFFECT_STOPPING = 3
          EFFECT_RESTARTING = 4

          # WHO EACH EFFECT STOPS, for a game with groups: one entry a table place, in table order
          # — where its group's list starts in this same data, how many are in it, and its priority,
          # each a halfword, and a fourth left empty so an entry is a shift of its place — and then
          # each group's list of table places, a halfword each.
          SOUND_EFFECT_GROUPS = :__sound_effect_groups
          GROUP_ENTRY_SHIFT = 3
          GROUP_LIST = 0
          GROUP_COUNT = 2
          GROUP_PRIORITY = 4
          GROUP_MEMBER_BYTES = 2

          # An effect's entry in the score: its length in frames, its rank, and where each of its
          # lanes' events start — and in a game whose effects play the wave voice, where its
          # waveform is (see #effect_wave_at).
          EFFECT_LENGTH = 0
          EFFECT_RANK = 4
          EFFECT_STARTS = 8

          # WHICH WAVEFORM IS IN WAVE RAM, for a game whose effects play the wave voice: where it is
          # in the score, or 0 before any. There is room there for one waveform, and the tune and
          # an effect can each want theirs, so a note on the wave voice — not a rest — loads its own
          # first if this says another is there (UPLOAD_WAVE), which is on the frames it changes
          # and no others. The tune's waveform waits in MUSIC_WAVE from the frame the tune starts,
          # rather than being loaded then over an effect that may hold the voice.
          WAVE_LOADED = :__wave_loaded
          MUSIC_WAVE = :__music_wave
          UPLOAD_WAVE = :__upload_wave

          # The registers a waveform is copied with: where it is, where it goes, the walk along it
          # and how many halfwords are left.
          WAVE_COPY_REGS = [7, 8, 9, 10].freeze

          # The routine the tick calls to play a run of the table (#emit_sound_effects_routine).
          SOUND_EFFECTS = :__sound_effects

          # The tune's rank, kept when it starts, for its parts to compare with a voice's holder.
          MUSIC_RANK = :__music_rank

          # Who holds the console voice numbered +channel+: a rank, or 0 for nobody.
          def self.voice_rank(channel) = :"__voice_rank_#{channel}"

          # The effects, highest rank first; which of the console's voices they use; and where
          # each is in the table. Nothing at all for a game with none.
          def prepare_sound_effects(program)
            ranked = IR::Tunes.effects_by_rank(IR::Tunes.effects(program).map { |name| @songs.fetch(name) })
            @effects = ranked.map(&:first)
            @effect_ranks = ranked.to_h
            @effect_lists = {}
            @effect_waves = false
            return unless plays_sound_effects?

            slots = @effects.each_with_index.to_h
            program.walk.each do |node|
              @effect_lists[node.name] = node.effects.map { |name| slots.fetch(name) } if node.kind == :sound_effect_list
            end
            squares = @effects.map { |name| IR::Tunes.parts_on(@songs.fetch(name), :square) }.max
            recorded = @effects.map { |name| IR::Tunes.recorded_parts(@songs.fetch(name)) }.max
            @effect_lanes = MUSIC_CHANNELS.first(squares).map { |channel| Lane.new(:square, channel) }
            CONSOLE_LANES.each do |kind, channel|
              used = @effects.any? { |name| IR::Tunes.parts_on(@songs.fetch(name), kind).positive? }
              @effect_lanes << Lane.new(kind, channel) if used
            end
            @effect_waves = @effect_lanes.any? { |lane| lane.kind == :wave }
            @effect_lanes += Array.new(recorded) { |lane| Lane.new(:recorded, lane) }
            if recorded.positive?
              @mixer.ranks_voices!(@effects.flat_map do |name|
                Array.new(IR::Tunes.recorded_parts(@songs.fetch(name))) do |lane|
                  [Mixer.ranked_owner(@effect_ranks.fetch(name), lane), [name, lane]]
                end
              end.to_h)
            end
            # A power of two, so a place in the table is a shift of its number.
            @effect_slot_bytes = 1 << (EFFECT_CURSORS + (4 * @effect_lanes.size) - 1).bit_length
            @effect_table = @memory.alloc_roomy(@effects.size * @effect_slot_bytes)
          end

          def effect_slots_blob(list) = :"__sound_effect_slots_#{list}"

          # Does an effect share the console voice this tune lane plays on? A recorded lane shares
          # the mixer instead, whose voices say for themselves who holds them.
          def shared_lane?(lane) = plays_sound_effects? && lane.kind != :recorded && @effect_lanes.include?(lane)

          # A PART WITH NOTHING IN IT, for a lane being silenced when a tune changes. Silence is
          # a rest, and a rest names no pitch — so a part's tone, its fade and its rattle are all
          # unread, and a part that says nothing answers every one of them.
          SILENCE = Music::Part.new(events: [])

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
            # A game that never moves the music volume plays every note exactly as it was written,
            # and none of the working-out for one is emitted.
            @scales = program.walk.any? { |node| node.kind == :set && node.var == IR::Tunes::LEVEL }
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
            prepare_sound_effects(program)
            # One directory entry: the tune's length in frames, which lanes it uses, where it
            # loops from, and where each lane's events start — and, in a game with sound effects,
            # the tune's rank — rounded up to a power of two, so finding a tune's entry is a shift
            # of its number rather than a multiply.
            @entry_rank = ENTRY_STARTS + (4 * @lanes.size)
            @entry_shift = (@entry_rank + (plays_sound_effects? ? 4 : 0) - 1).bit_length
            @mixer.music_takes_voices! if recorded.positive?
            @mixer.music_follows_level! if recorded.positive? && @scales
          end

          # Put every tune the program plays in the cartridge, as one score.
          def build_score
            @emitter.data_blobs[MUSIC_SCORE] = score_blob if plays_music?
            @emitter.data_blobs[MUSIC_WAVE_LEVELS] = wave_levels_blob if plays_music? && @scales && @waves
            @effect_lists.each { |name, slots| @emitter.data_blobs[effect_slots_blob(name)] = slots.pack("v*") }
            @emitter.data_blobs[SOUND_EFFECT_GROUPS] = groups_blob if grouped?
          end

          # Does any sound effect belong to a group?
          def grouped? = plays_sound_effects? && @effects.any? { |name| group_of(name) }

          # The group of the sound effect named +name+, or nil.
          def group_of(name) = @songs.fetch(name).group

          # See SOUND_EFFECT_GROUPS.
          def groups_blob
            groups = @effects.each_index.group_by { |slot| group_of(@effects[slot]) }
            groups.delete(nil)
            starts = {}
            at = @effects.size << GROUP_ENTRY_SHIFT
            groups.each do |group, members|
              starts[group] = at
              at += members.size * GROUP_MEMBER_BYTES
            end
            entries = @effects.map do |name|
              group = group_of(name)
              count = group ? groups.fetch(group).size : 0
              priority = IR::Tunes.priority_of(@effect_ranks.fetch(name))
              [starts.fetch(group, 0), count, priority, 0].pack("vvvv")
            end
            entries.join + groups.values.map { |members| members.pack("v*") }.join
          end

          # Does the program play any tune or sound effect (so the player goes in the screen's
          # interrupt)?
          def plays_music? = !@song_numbers.empty? || plays_sound_effects?

          def plays_sound_effects? = !@effects.empty?

          # START SOUND EFFECT +which+ OF A LIST: one number stored in the effect's place in the
          # table, which the player in the screen's interrupt reads on the next frame. A single
          # store is all the game ever writes there, so the interrupt can land before it or after
          # it and never in the middle. Asked for while it sounds, the player starts it again.
          #
          # The table is in rank order, not the list's (see #prepare_sound_effects), so a number
          # the game works out is turned into a place in the table by a small table of its own —
          # and one naming no effect in the list plays nothing.
          #
          # A list with an effect in a group asks through the group instead, for every effect in it
          # (#emit_ask_in_group): the effect a number the game works out names is not known until
          # the game runs.
          def emit_play_sound_effect(node)
            slots = @effect_lists.fetch(node.name)
            fixed = @primitives.const_int(node.which)
            grouped = slots.any? { |slot| group_of(@effects[slot]) }
            if fixed
              return unless fixed.between?(0, slots.size - 1)
              return emit_ask_in_group(place: slots[fixed]) if grouped

              @emitter.emit(ASM.load_immediate(TMP, @effect_table + (slots[fixed] * @effect_slot_bytes)))
              return emit_ask
            end

            none = @emitter.gensym
            @lowering.value(node.which)                       # ACC = which
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit_branch(:bcond, none, cond: :lt)
            @emitter.emit(ASM.load_immediate(TMP, slots.size))
            @emitter.emit(ASM.cmp_reg(ACC, TMP))
            @emitter.emit_branch(:bcond, none, cond: :ge)     # past the last effect
            @emitter.emit_load_data_address(TMP, effect_slots_blob(node.name))
            @emitter.emit(ASM.lsl_imm(ACC, ACC, 1))
            @emitter.emit(ASM.add_reg(TMP, TMP, ACC))
            @emitter.emit(ASM.load_halfword(ACC, TMP))        # its place in the table
            if grouped
              emit_ask_in_group
            else
              @emitter.emit(ASM.lsl_imm(ACC, ACC, @effect_slot_bytes.bit_length - 1))
              @emitter.emit(ASM.load_immediate(TMP, @effect_table))
              @emitter.emit(ASM.add_reg(TMP, TMP, ACC))
              emit_ask
            end
            @emitter.place_label(none)
          end

          # Ask for the effect whose place in the table is at the address in TMP: one store.
          def emit_ask
            @emitter.emit(ASM.load_immediate(ACC, EFFECT_ASKED))
            @emitter.emit(ASM.str_offset(ACC, TMP, EFFECT_STATE))
          end

          # THE REGISTERS THE ASK IN A GROUP WORKS IN. The place asked for is handed over in
          # ASK_PLACE; the rest are kept on the stack and given back, except ACC and TMP, which
          # every statement may use, and r3, where the interrupts' master switch waits.
          ASK_LIST = 0     # the group's list, walked
          ASK_LEFT = 1     # how many of it are left
          ASK_PLACE = 2    # the place in the table asked for
          ASK_BLOB = 4     # the groups' data
          ASK_PRIORITY = 5 # the priority of the effect asked for
          ASK_TABLE = 6    # the table's start
          ASK_MEMBER = 7   # the place of the one of the group being looked at
          ASK_STATE = 8    # its state
          ASK_KEEPS = [ASK_BLOB, ASK_PRIORITY, ASK_TABLE, ASK_MEMBER, ASK_STATE].freeze

          # ASK FOR THE EFFECT AT A TABLE PLACE — +place+, or with none given, the place in ACC —
          # deciding its group as it is asked (IR::Tunes.priority_of).
          #
          # The game reads the table and writes two places in it, where asking in a list with no
          # group is a single store — so the screen's interrupt, which moves the table on, is held
          # off while it does, and sees the decision whole. Each of the group is looked at in turn:
          #
          #   * none of them sounding or asked for: this one is asked for;
          #   * this one itself: asked for again while it sounds, it is RESTARTING; already asked
          #     for, it stays so;
          #   * another: of higher priority than this one, this one is not played; otherwise that one
          #     is STOPPING and this one is asked for — RESTARTING, if it was itself STOPPING, since
          #     then it still holds voices to let go of.
          #
          # A group has one sounding or asked for at most, which is what lets the walk stop at the
          # first it finds. An effect in no group has an empty list, and is simply asked for.
          def emit_ask_in_group(place: nil)
            e = @emitter
            place ? e.emit(ASM.load_immediate(ASK_PLACE, place)) : e.emit(ASM.mov_reg(ASK_PLACE, ACC))
            found = e.gensym
            ask = e.gensym
            done = e.gensym
            @mixer.holding_off_interrupts do
              e.emit(ASM.push(*ASK_KEEPS))
              emit_open_group(ask)
              emit_find_in_group(found)
              e.emit_branch(:b, ask)                                    # none of them: ask
              e.place_label(found)
              emit_decide_in_group(done)
              e.place_label(ask)
              emit_table_place(ADDR, ASK_PLACE)
              e.emit(ASM.ldr_offset(ASK_STATE, ADDR, EFFECT_STATE))
              e.emit(ASM.cmp_imm(ASK_STATE, EFFECT_STOPPING))
              e.emit(ASM.mov_imm_cond(:eq, ASK_STATE, EFFECT_RESTARTING))
              e.emit(ASM.mov_imm_cond(:ne, ASK_STATE, EFFECT_ASKED))
              e.emit(ASM.str_offset(ASK_STATE, ADDR, EFFECT_STATE))
              e.place_label(done)
              e.emit(ASM.pop(*ASK_KEEPS))
            end
          end

          # The asked-for effect's entry: its group's list and how many are in it, and its priority —
          # and on to +ask+ when it has no group.
          def emit_open_group(ask)
            e = @emitter
            e.emit_load_data_address(ASK_BLOB, SOUND_EFFECT_GROUPS)
            e.emit(ASM.lsl_imm(ADDR, ASK_PLACE, GROUP_ENTRY_SHIFT))
            e.emit(ASM.add_reg(ADDR, ASK_BLOB, ADDR))
            e.emit(ASM.load_halfword_offset(ASK_LIST, ADDR, GROUP_LIST))
            e.emit(ASM.add_reg(ASK_LIST, ASK_BLOB, ASK_LIST))
            e.emit(ASM.load_halfword_offset(ASK_LEFT, ADDR, GROUP_COUNT))
            e.emit(ASM.load_halfword_offset(ASK_PRIORITY, ADDR, GROUP_PRIORITY))
            e.emit(ASM.load_immediate(ASK_TABLE, @effect_table))
            e.emit(ASM.cmp_imm(ASK_LEFT, 0))
            e.emit_branch(:bcond, ask, cond: :eq)
          end

          # Walk the group for the one sounding or asked for, and on to +found+ with its place in
          # ASK_MEMBER, its address in ADDR and its state in ASK_STATE. Falls through when none is.
          def emit_find_in_group(found)
            e = @emitter
            scan = e.gensym
            e.place_label(scan)
            e.emit(ASM.load_halfword(ASK_MEMBER, ASK_LIST))
            e.emit(ASM.add_imm(ASK_LIST, ASK_LIST, GROUP_MEMBER_BYTES))
            emit_table_place(ADDR, ASK_MEMBER)
            e.emit(ASM.ldr_offset(ASK_STATE, ADDR, EFFECT_STATE))
            [EFFECT_ASKED, EFFECT_SOUNDING, EFFECT_RESTARTING].each do |current|
              e.emit(ASM.cmp_imm(ASK_STATE, current))
              e.emit_branch(:bcond, found, cond: :eq)
            end
            e.emit(ASM.subs_imm(ASK_LEFT, ASK_LEFT, 1))
            e.emit_branch(:bcond, scan, cond: :ne)
          end

          # The group's one is found. Itself, it restarts if it is sounding and is left as it is
          # otherwise; another, it is STOPPING unless it outranks the one asked for, and then this
          # one is not played. Both of those go on to +done+; stopping the other falls through, to
          # ask for this one.
          def emit_decide_in_group(done)
            e = @emitter
            other = e.gensym
            e.emit(ASM.cmp_reg(ASK_MEMBER, ASK_PLACE))
            e.emit_branch(:bcond, other, cond: :ne)
            e.emit(ASM.cmp_imm(ASK_STATE, EFFECT_SOUNDING))
            e.emit_branch(:bcond, done, cond: :ne)
            e.emit(ASM.load_immediate(ASK_STATE, EFFECT_RESTARTING))
            e.emit(ASM.str_offset(ASK_STATE, ADDR, EFFECT_STATE))
            e.emit_branch(:b, done)

            e.place_label(other)
            e.emit(ASM.lsl_imm(ASK_STATE, ASK_MEMBER, GROUP_ENTRY_SHIFT))
            e.emit(ASM.add_reg(ASK_STATE, ASK_BLOB, ASK_STATE))
            e.emit(ASM.load_halfword_offset(ASK_STATE, ASK_STATE, GROUP_PRIORITY))
            e.emit(ASM.cmp_reg(ASK_PRIORITY, ASK_STATE))
            e.emit_branch(:bcond, done, cond: :lo)                      # it outranks this one
            e.emit(ASM.load_immediate(ASK_STATE, EFFECT_STOPPING))
            e.emit(ASM.str_offset(ASK_STATE, ADDR, EFFECT_STATE))
          end

          # +reg+ = the address of the table place whose number is in +number+ (the table's start
          # in ASK_TABLE).
          def emit_table_place(reg, number)
            @emitter.emit(ASM.lsl_imm(reg, number, @effect_slot_bytes.bit_length - 1))
            @emitter.emit(ASM.add_reg(reg, ASK_TABLE, reg))
          end

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
          #
          # In a game with sound effects, the effects that outrank the tune are played just before
          # its parts and the rest just after, and with no tune playing all of them are.
          def emit_music_tick
            base, at, value, frame, playing = 2, 3, 4, 5, 6
            changed = @emitter.gensym
            play = @emitter.gensym
            done = @emitter.gensym
            finished = @emitter.gensym

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
            if @waves && @effect_waves
              emit_entry_address(at, base, playing)
              @emitter.emit(ASM.ldr_offset(ACC, at, ENTRY_WAVE))
              @primitives.store_var(ACC, MUSIC_WAVE)
            elsif @waves
              emit_upload_wavetable(base, at, playing)
            end
            if plays_sound_effects?
              emit_entry_address(at, base, playing)
              @emitter.emit(ASM.ldr_offset(ACC, at, @entry_rank))
              @primitives.store_var(ACC, MUSIC_RANK)
            end

            @emitter.place_label(play)
            if plays_sound_effects? # ...the effects that outrank the tune
              @primitives.load_var(EFFECT_OUTRANKS, MUSIC_RANK)
              emit_first_effect
              @emitter.emit(ASM.push(frame))
              @emitter.emit_branch(:bl, SOUND_EFFECTS)
              @emitter.emit(ASM.pop(frame))
              @emitter.emit(ASM.push(EFFECT_SLOT, EFFECT_ENTRY)) # where they stopped
            end
            emit_follow_the_level if @scales
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
            if plays_sound_effects? # ...and the rest, carrying on from where the first run stopped
              @emitter.emit(ASM.pop(EFFECT_SLOT, EFFECT_ENTRY))
              @emitter.emit_load_data_address(base, MUSIC_SCORE)
              @emitter.emit(ASM.load_immediate(EFFECT_OUTRANKS, 0))
              @emitter.emit_branch(:bl, SOUND_EFFECTS)
              @emitter.emit_branch(:b, finished)
            end
            @emitter.place_label(done)
            if plays_sound_effects? # no tune: every effect
              @emitter.emit_load_data_address(base, MUSIC_SCORE)
              @emitter.emit(ASM.load_immediate(EFFECT_OUTRANKS, 0))
              emit_first_effect
              @emitter.emit_branch(:bl, SOUND_EFFECTS)
            end
            @emitter.place_label(finished)
          end

          # THE REGISTERS THE EFFECTS ROUTINE TAKES AND GIVES BACK: where in the table it starts and
          # the effect's entry in the score, both handed back where it stopped, and a rank — it
          # plays the effects that outrank that one, and stops at the first that does not.
          EFFECT_SLOT = 7
          EFFECT_ENTRY = 8
          EFFECT_OUTRANKS = 11

          def emit_first_effect
            @emitter.emit(ASM.load_immediate(EFFECT_SLOT, @effect_table))
            @primitives.emit_add_const(EFFECT_ENTRY, 2, @effects_at, ACC)
          end

          # PLAY A RUN OF THE SOUND EFFECTS TABLE, from EFFECT_SLOT until an effect that does not
          # outrank EFFECT_OUTRANKS or the end of the table; r2 holds the score. Emitted once, inside
          # the screen's interrupt, and called from it.
          #
          # For each effect: asked for, it starts from its first frame; sounding and at its end, it
          # lets go of every voice it still holds, silencing each; and sounding, each of its lanes
          # plays its next event if that is due — on the voice only if nobody holding it outranks
          # the effect, and then holding it while the note sounds and letting it go for a rest. A
          # tune's note it takes the voice from is no longer held by the tune, so a music volume
          # moving later does not start it again.
          #
          # Uses r0, r1, r3-r5, r9, r10 and r12. In a game whose effects play recordings or the
          # wave voice, it calls the mixer or UPLOAD_WAVE too, so it keeps its return address on the
          # stack and gives back every register it holds around each call.
          def emit_sound_effects_routine
            e = @emitter
            slot, entry, outranks = EFFECT_SLOT, EFFECT_ENTRY, EFFECT_OUTRANKS
            base, table_end, cursor, frame, rank, row = 2, 3, 4, 5, 9, 10
            walk = e.gensym
            out = e.gensym
            makes_calls = @mixer.ranks_voices? || @effect_waves
            e.place_label(SOUND_EFFECTS)
            e.emit(ASM.push(Mixer::LR)) if makes_calls
            e.emit(ASM.load_immediate(table_end, @effect_table + (@effects.size * @effect_slot_bytes)))
            e.place_label(walk)
            e.emit(ASM.cmp_reg(slot, table_end))
            e.emit_branch(:bcond, out, cond: :hs)
            e.emit(ASM.ldr_offset(rank, entry, EFFECT_RANK))
            e.emit(ASM.cmp_reg(rank, outranks))
            e.emit_branch(:bcond, out, cond: :le)              # not above the tune

            onward = e.gensym
            sounding = e.gensym
            play = e.gensym
            stop = e.gensym
            e.emit(ASM.ldr_offset(ACC, slot, EFFECT_STATE))
            e.emit(ASM.cmp_imm(ACC, EFFECT_SOUNDING))
            e.emit_branch(:bcond, sounding, cond: :eq)
            if grouped?
              start = e.gensym
              e.emit(ASM.cmp_imm(ACC, EFFECT_ASKED))
              e.emit_branch(:bcond, start, cond: :eq)
              e.emit(ASM.cmp_imm(ACC, EFFECT_STOPPING))
              e.emit_branch(:bcond, stop, cond: :eq)           # cut off by another of its group
              e.emit(ASM.cmp_imm(ACC, EFFECT_RESTARTING))
              e.emit_branch(:bcond, onward, cond: :ne)         # none of those: nothing to do
              emit_let_go_of_voices(rank)                      # asked for again: it stops first
              e.place_label(start)
            else
              e.emit(ASM.cmp_imm(ACC, EFFECT_ASKED))
              e.emit_branch(:bcond, onward, cond: :ne)         # neither: nothing to do
            end

            e.emit(ASM.load_immediate(ACC, EFFECT_SOUNDING))  # asked for: from its first frame
            e.emit(ASM.str_offset(ACC, slot, EFFECT_STATE))
            e.emit(ASM.load_immediate(frame, 0))
            @effect_lanes.each_index do |number|
              e.emit(ASM.ldr_offset(ACC, entry, EFFECT_STARTS + (4 * number)))
              e.emit(ASM.str_offset(ACC, slot, EFFECT_CURSORS + (4 * number)))
            end
            e.emit_branch(:b, play)

            e.place_label(sounding)
            e.emit(ASM.ldr_offset(frame, slot, EFFECT_FRAME))
            e.emit(ASM.ldr_offset(ACC, entry, EFFECT_LENGTH))
            e.emit(ASM.cmp_reg(frame, ACC))
            e.emit_branch(:bcond, play, cond: :lt)
            e.place_label(stop)
            e.emit(ASM.load_immediate(ACC, 0))                # at its end
            e.emit(ASM.str_offset(ACC, slot, EFFECT_STATE))
            emit_let_go_of_voices(rank)
            e.emit_branch(:b, onward)

            e.place_label(play)
            @effect_lanes.each_with_index do |lane, number|
              skip = e.gensym
              e.emit(ASM.ldr_offset(cursor, slot, EFFECT_CURSORS + (4 * number)))
              e.emit(ASM.add_reg(row, base, cursor))
              e.emit(ASM.ldr(ACC, row))
              e.emit(ASM.cmp_reg(ACC, frame))
              e.emit_branch(:bcond, skip, cond: :ne)           # not due
              e.emit(ASM.add_imm(cursor, cursor, row_bytes(lane)))
              e.emit(ASM.str_offset(cursor, slot, EFFECT_CURSORS + (4 * number)))
              if lane.kind == :recorded
                emit_effect_recorded_note(lane, rank, row)
              else
                emit_take_voice(lane: lane, rank: rank, row: row, dropped: skip)
                if lane.kind == :wave
                  e.emit(ASM.ldr_offset(ACC, entry, effect_wave_at))
                  emit_load_waveform(row)
                end
                emit_console_note(lane, row)
                song_lane = @lanes.index(lane)
                forget_held_note(song_lane) if song_lane && holds_notes?(lane)
              end
              e.place_label(skip)
            end
            e.emit(ASM.add_imm(frame, frame, 1))
            e.emit(ASM.str_offset(frame, slot, EFFECT_FRAME))

            e.place_label(onward)
            e.emit(ASM.add_imm(slot, slot, @effect_slot_bytes))
            e.emit(ASM.add_imm(entry, entry, effect_entry_bytes))
            e.emit_branch(:b, walk)
            e.place_label(out)
            e.emit(makes_calls ? ASM.pop(PC) : ASM.return)
            emit_upload_wave_routine if @effect_waves
          end

          # Where an effect's waveform sits in its entry, after where its lanes start — and how
          # long an entry is.
          def effect_wave_at = EFFECT_STARTS + (4 * @effect_lanes.size)
          def effect_entry_bytes = effect_wave_at + (@effect_waves ? 4 : 0)

          # THE ROW AT +row+ IS ABOUT TO BE WRITTEN TO THE WAVE VOICE, with its waveform in ACC: a
          # note loads that waveform first if it is not the one there, and a rest loads nothing. A
          # note starts the voice and a rest does not, so the bit that starts it says which.
          def emit_load_waveform(row)
            rest = @emitter.gensym
            @emitter.emit(ASM.load_halfword_offset(TMP, row, 6))
            @emitter.emit(ASM.tst_imm(TMP, 0x8000))
            @emitter.emit_branch(:bcond, rest, cond: :eq)
            @emitter.emit_branch(:bl, UPLOAD_WAVE)
            @emitter.place_label(rest)
          end

          # LOAD THE WAVEFORM AT OFFSET ACC IN THE SCORE (r2) INTO WAVE RAM, unless it is there
          # already (WAVE_LOADED). Keeps every register but r0, r1 and r12.
          def emit_upload_wave_routine
            e = @emitter
            loaded = e.gensym
            e.place_label(UPLOAD_WAVE)
            @primitives.load_var(TMP, WAVE_LOADED)
            e.emit(ASM.cmp_reg(ACC, TMP))
            e.emit_branch(:bcond, loaded, cond: :eq)
            @primitives.store_var(ACC, WAVE_LOADED)
            e.emit(ASM.push(*WAVE_COPY_REGS))
            e.emit(ASM.add_reg(WAVE_COPY_REGS.first, 2, ACC))
            emit_copy_waveform(WAVE_COPY_REGS.first)
            e.emit(ASM.pop(*WAVE_COPY_REGS))
            e.place_label(loaded)
            e.emit(ASM.return)
          end

          # EVERY VOICE THE EFFECT OF RANK +rank+ STILL HOLDS goes quiet and is free: a console voice
          # whose holder is still that rank, and its recorded lanes' mixer voices.
          def emit_let_go_of_voices(rank)
            @effect_lanes.each do |lane|
              next emit_effect_voice_off(lane, rank) if lane.kind == :recorded

              kept = @emitter.gensym
              @primitives.load_var(ACC, self.class.voice_rank(lane.index))
              @emitter.emit(ASM.cmp_reg(ACC, rank))
              @emitter.emit_branch(:bcond, kept, cond: :ne)    # not its voice any more
              emit_free_voice(lane)
              @emitter.place_label(kept)
            end
          end

          # THE REGISTERS THE EFFECTS ROUTINE KEEPS across a call into the mixer, which uses most
          # of them: the score, the table's end, the cursor, the frame, the slot, the entry, the
          # rank, the row and the rank it plays down to — the numbers #emit_sound_effects_routine
          # names at its top.
          EFFECT_KEEPS = [2, 3, 4, 5, EFFECT_SLOT, EFFECT_ENTRY, 9, 10, EFFECT_OUTRANKS].freeze

          # The program counter: the routine's return address, kept on the stack, is popped
          # straight into it to return.
          PC = 15

          # AN EFFECT'S NOTE ON A RECORDED LANE, in the row at +row+: played the way a song's is
          # (#emit_recorded_note), on a voice whose mark carries the effect's rank in +rank+.
          def emit_effect_recorded_note(lane, rank, row)
            mark, base, at = 8, 2, 3
            @emitter.emit(ASM.push(*EFFECT_KEEPS))
            @emitter.emit(ASM.mov_reg(at, row))
            @emitter.emit(ASM.mov_reg(mark, rank))
            @mixer.emit_ranked_mark(mark, lane.index)
            emit_recorded_note(lane: lane.index, base: base, at: at)
            @emitter.emit(ASM.pop(*EFFECT_KEEPS))
          end

          # At an effect's end, its recorded lane lets go of the voice it still has, if it has one —
          # a note with a shape falling away rather than stopping, the same as at a rest.
          def emit_effect_voice_off(lane, rank)
            @emitter.emit(ASM.push(EFFECT_SLOT, EFFECT_ENTRY))
            @emitter.emit(ASM.mov_reg(8, rank))
            @mixer.emit_ranked_mark(8, lane.index)
            @mixer.emit_music_voice_off
            @emitter.emit(ASM.pop(EFFECT_SLOT, EFFECT_ENTRY))
          end

          # +reg+ = the mark a voice of the tune's recorded lane +lane+ carries: its own number, or
          # in a game whose sound effects play recordings, that and the tune's rank.
          def emit_song_mark(reg, lane)
            return @emitter.emit(ASM.load_immediate(reg, Mixer.music_owner(lane))) unless @mixer.ranks_voices?

            @primitives.load_var(reg, MUSIC_RANK)
            @mixer.emit_ranked_mark(reg, lane)
          end

          # MAY THE NOTE IN +row+, OF RANK +rank+, SOUND ON +lane+'s VOICE? When whoever holds the
          # voice outranks it, on to +dropped+. Otherwise it holds the voice while it sounds, and a
          # rest — a row whose volume is 0 — lets it go.
          def emit_take_voice(lane:, rank:, row:, dropped:)
            holder = self.class.voice_rank(lane.index)
            @primitives.load_var(ACC, holder)
            @emitter.emit(ASM.cmp_reg(ACC, rank))
            @emitter.emit_branch(:bcond, dropped, cond: :gt)
            @emitter.emit(ASM.load_halfword_offset(ACC, row, 4))
            @emitter.emit(ASM.tst_imm(ACC, 0xF000))
            @emitter.emit(ASM.mov_reg(TMP, rank)) unless rank == TMP
            @emitter.emit(ASM.mov_imm_cond(:eq, TMP, 0))
            @primitives.store_var(TMP, holder)
          end

          # Silence +lane+'s voice, and nobody holds it.
          def emit_free_voice(lane)
            emit_writes(console_note(lane, SILENCE, 0, 0))
            @emitter.emit(ASM.load_immediate(ACC, 0))
            @primitives.store_var(ACC, self.class.voice_rank(lane.index))
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
          #
          # A game whose sound effects play the wave voice does not do this, since an effect may
          # hold the voice as the tune changes: see WAVE_LOADED.
          def emit_upload_wavetable(base, at, playing)
            none = @emitter.gensym
            emit_entry_address(at, base, playing)
            @emitter.emit(ASM.ldr_offset(ACC, at, ENTRY_WAVE))
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit_branch(:bcond, none, cond: :eq) # this tune plays no waveform
            @emitter.emit(ASM.add_reg(WAVE_COPY_REGS.first, base, ACC))
            emit_copy_waveform(WAVE_COPY_REGS.first)
            @emitter.place_label(none)
          end

          # Copy the waveform at the address in +source+ into both banks of wave RAM, and switch the
          # voice on. Uses the other WAVE_COPY_REGS and ACC/TMP.
          def emit_copy_waveform(source)
            _, dest, walk, left = WAVE_COPY_REGS
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
              emit_silence_lane(lane, number)
              @emitter.place_label(unused)
            end
            @emitter.place_label(quiet)
          end

          # A lane the console plays goes quiet with a rest on its own channel — which is the
          # rest row that lane would have played, so nothing new is decided here. A recorded
          # lane goes quiet by switching off the mixer voice carrying its mark, if it still has
          # one.
          def emit_silence_lane(lane, number)
            if lane.kind == :recorded
              forget_held_note(number) if holds_notes?(lane)
              emit_song_mark(8, lane.index)
              @mixer.emit_music_voice_off
            elsif !shared_lane?(lane)
              emit_writes(console_note(lane, SILENCE, 0, 0))
              forget_held_note(number) if holds_notes?(lane)
            else
              # A voice a sound effect holds is the effect's, and is left alone: its rank's bottom
              # half is not 0 (IR::Tunes.song_rank).
              forget_held_note(number) if holds_notes?(lane)
              kept = @emitter.gensym
              @primitives.load_var(ACC, self.class.voice_rank(lane.index))
              @emitter.emit(ASM.lsl_imm(ACC, ACC, IR::Tunes::RANK_SHIFT))
              @emitter.emit(ASM.cmp_imm(ACC, 0))
              @emitter.emit_branch(:bcond, kept, cond: :ne)
              emit_free_voice(lane)
              @emitter.place_label(kept)
            end
          end

          # THE REGISTERS THE MUSIC VOLUME IS WORKED OUT IN, all free in the player's interrupt:
          # the level, a lane's held note, and two to work its register values out in.
          LEVEL_REG = 11
          NOTE_REG = 7
          WORK_REG = 8
          WRITE_REG = 9

          # Whether a lane keeps the note it is holding, for setting it to a new volume. The noise
          # voice does not: a drum hit rings and fades by itself, and striking it again at a new
          # volume would be a second hit, so a new level waits for the next one.
          #
          # A recorded lane keeps its note's loudness (0..IR::Tunes::MIX_FULL) rather than register
          # values, and 0 for a rest.
          def holds_notes?(lane) = @scales && %i[square wave recorded].include?(lane.kind)

          # THE WAVE VOICE'S VOLUMES, looked up by a volume of 0..15: it has five, and a note sets
          # the one nearest (Sound::Registers.wave_level). A table rather than arithmetic, since
          # nearest-of-five is a divide.
          MUSIC_WAVE_LEVELS = :__music_wave_levels

          def wave_levels_blob
            (0..15).map { |volume| Sound::Registers::WAVE_VOLUMES.fetch(Sound::Registers.wave_level(volume)) }
                   .pack("v*")
          end

          # WHERE A WAVE ROW KEEPS ITS WRITTEN VOLUME, in a game that moves the music volume. The
          # register value says one of five volumes, and sixteen do not come back out of five —
          # so the 0..15 rides along in four bits of the same value that the voice does not read.
          WAVE_VOLUME_SHIFT = 8

          # A held note that is really sounding: its written volume is not 0. Where those four
          # bits sit is the one thing that differs between the two voices.
          def sounding_mask(lane) = lane.kind == :wave ? 0xF << WAVE_VOLUME_SHIFT : 0xF000

          def forget_held_note(number)
            @emitter.emit(ASM.load_immediate(ACC, 0))
            @primitives.store_var(ACC, self.class.music_note(number))
          end

          # THE GAME HAS MOVED THE MUSIC VOLUME since the player last looked: every lane holding a
          # note sets it to the new level — a square lane by starting it again, the wave voice
          # and a recorded part's mixer voice while they play — before any lane plays this
          # frame's notes, which is the order the interpreter does it in. A drum hit is left to
          # ring (see #holds_notes?).
          def emit_follow_the_level
            same = @emitter.gensym
            @primitives.load_var(LEVEL_REG, IR::Tunes::LEVEL)
            @primitives.load_var(ACC, MUSIC_LEVEL_APPLIED)
            @emitter.emit(ASM.cmp_reg(LEVEL_REG, ACC))
            @emitter.emit_branch(:bcond, same, cond: :eq)
            @primitives.store_var(LEVEL_REG, MUSIC_LEVEL_APPLIED)
            @lanes.each_with_index do |lane, number|
              next unless holds_notes?(lane)
              next emit_follow_recorded(lane, number) if lane.kind == :recorded

              resting = @emitter.gensym
              @primitives.load_var(NOTE_REG, self.class.music_note(number))
              @emitter.emit(ASM.tst_imm(NOTE_REG, sounding_mask(lane))) # 0: a rest, or nothing yet
              @emitter.emit_branch(:bcond, resting, cond: :eq)
              emit_scaled_note(lane, starts: lane.kind == :square)
              @emitter.place_label(resting)
            end
            @emitter.place_label(same)
          end

          # Start the note in NOTE_REG on a square lane at the level in LEVEL_REG. The word holds
          # the row's two register values, the control low and the pitch high; the control's top
          # four bits are the volume, which comes out as that volume times the level over
          # IR::Tunes::FULL_LEVEL (a multiply and a shift, IR::Tunes.scaled_volume) and goes back
          # in over the same four bits. The pitch is written last, because its top bit is what
          # starts the note — and starting it is what makes the voice take the new volume.
          #
          # The console's own documentation says a square voice loads its volume when a note
          # starts, and Nintendo's sound engine agrees: it writes the volume and then starts the
          # note again, every time it moves one. The emulator the tests run on takes a new volume
          # at once without that, so nothing there can tell the difference — the start is here
          # for the console.
          #
          # THE WAVE VOICE is the other shape of the same thing. Its written volume is the four
          # bits WAVE_VOLUME_SHIFT keeps it in, the level scales it the same way, and what goes to
          # the register is the nearest of the voice's five volumes, out of a table — with the
          # bits below them kept, so the written volume is still there next time. It takes a new
          # volume while it plays, so a held note is not started again (+starts:+ false); a new
          # note is, the same as always.
          def emit_scaled_note(lane, starts: true)
            regs = music_voice_regs(lane)
            emit_sweep(regs)
            wave = lane.kind == :wave
            @emitter.emit(ASM.lsr_imm(WORK_REG, NOTE_REG, wave ? WAVE_VOLUME_SHIFT : 12))
            @emitter.emit(ASM.and_imm(WORK_REG, WORK_REG, 0xF))      # the written volume
            emit_scaled_loudness(WORK_REG)                           # ...times the level, over sixteen
            wave ? emit_nearest_wave_volume : emit_square_volume
            @emitter.emit(ASM.load_immediate(TMP, regs[:reg_a]))
            @emitter.emit(ASM.store_halfword(WRITE_REG, TMP))
            return unless starts

            @emitter.emit(ASM.lsr_imm(WRITE_REG, NOTE_REG, 16))
            @emitter.emit(ASM.load_immediate(TMP, regs[:reg_b]))
            @emitter.emit(ASM.store_halfword(WRITE_REG, TMP))
          end

          # A RECORDED PART'S NOTE AT THE NEW LEVEL: the mixer voice sounding it, if it still has
          # one, gets the note's loudness times the level. The mixer reads a voice's loudness as
          # it mixes, so nothing is started again.
          def emit_follow_recorded(lane, number)
            resting = @emitter.gensym
            @primitives.load_var(WRITE_REG, self.class.music_note(number))
            @emitter.emit(ASM.cmp_imm(WRITE_REG, 0))
            @emitter.emit_branch(:bcond, resting, cond: :eq)          # a rest, or nothing yet
            emit_song_mark(WORK_REG, lane.index)
            @mixer.emit_find_music_voice                              # r7 = its voice, or 0
            @emitter.emit(ASM.cmp_imm(NOTE_REG, 0))
            @emitter.emit_branch(:bcond, resting, cond: :eq)          # it ran out, or is falling away
            emit_scaled_loudness(WRITE_REG)
            @emitter.emit(ASM.str_offset(WRITE_REG, NOTE_REG, Mixer::SLOT_VOL))
            @emitter.place_label(resting)
          end

          # +reg+ = the loudness in it times the music volume, over sixteen. The level is read
          # again here rather than trusted to still be in its register, because finding a note a
          # voice uses that register too.
          def emit_scaled_loudness(reg)
            @primitives.load_var(LEVEL_REG, IR::Tunes::LEVEL)
            @emitter.emit(ASM.mul(reg, LEVEL_REG, reg))
            @emitter.emit(ASM.lsr_imm(reg, reg, IR::Tunes::LEVEL_SHIFT))
          end

          # WRITE_REG = the square control in NOTE_REG with the volume in WORK_REG over its top
          # four bits.
          def emit_square_volume
            @emitter.emit(ASM.lsl_imm(WRITE_REG, NOTE_REG, 20))
            @emitter.emit(ASM.lsr_imm(WRITE_REG, WRITE_REG, 20))
            @emitter.emit(ASM.orr_reg_lsl(WRITE_REG, WRITE_REG, WORK_REG, 12))
          end

          # WRITE_REG = the wave control in NOTE_REG with its top three bits — the voice's volume —
          # replaced by the nearest of the five to the volume in WORK_REG.
          def emit_nearest_wave_volume
            @emitter.emit_load_data_address(WRITE_REG, MUSIC_WAVE_LEVELS)
            @emitter.emit(ASM.lsl_imm(WORK_REG, WORK_REG, 1))
            @emitter.emit(ASM.add_reg(WRITE_REG, WRITE_REG, WORK_REG))
            @emitter.emit(ASM.load_halfword(WORK_REG, WRITE_REG))
            @emitter.emit(ASM.lsl_imm(WRITE_REG, NOTE_REG, 19))
            @emitter.emit(ASM.lsr_imm(WRITE_REG, WRITE_REG, 19))
            @emitter.emit(ASM.orr_reg(WRITE_REG, WRITE_REG, WORK_REG))
          end

          # Play one lane's next event, if it is due on this frame.
          def emit_play_lane(lane, number, base, at, cursor, frame)
            skip = @emitter.gensym
            @primitives.load_var(cursor, self.class.music_cursor(number))
            @emitter.emit(ASM.add_reg(at, base, cursor))      # the row it points at
            @emitter.emit(ASM.ldr(ACC, at))                   # the frame it is due
            @emitter.emit(ASM.cmp_reg(ACC, frame))
            @emitter.emit_branch(:bcond, skip, cond: :ne)     # not yet — leave the lane alone

            if shared_lane?(lane)
              # A sound effect holding the voice with a higher rank: the part carries on in time,
              # silent here, and is heard again from its next note once the voice is free.
              dropped = @emitter.gensym
              @primitives.load_var(TMP, MUSIC_RANK)
              emit_take_voice(lane: lane, rank: TMP, row: at, dropped: dropped)
              heard = @emitter.gensym
              @emitter.emit_branch(:b, heard)
              @emitter.place_label(dropped)
              @emitter.emit(ASM.add_imm(cursor, cursor, SQUARE_ROW))
              @primitives.store_var(cursor, self.class.music_cursor(number))
              @emitter.emit_branch(:b, skip)
              @emitter.place_label(heard)
            end
            if lane.kind == :wave && @effect_waves
              @primitives.load_var(ACC, MUSIC_WAVE)
              emit_load_waveform(at)
            end

            if lane.kind == :recorded
              emit_recorded_note(lane: lane.index, number: number, base: base, at: at)
              @emitter.emit(ASM.add_imm(cursor, cursor, RECORDED_ROW))
            elsif @scales
              @emitter.emit(ASM.ldr_offset(NOTE_REG, at, 4))           # both register values
              @primitives.store_var(NOTE_REG, self.class.music_note(number)) if holds_notes?(lane)
              emit_scaled_note(lane)
              @emitter.emit(ASM.add_imm(cursor, cursor, SQUARE_ROW))
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
            emit_sweep(regs)
            [[4, regs[:reg_a]], [6, regs[:reg_b]]].each do |offset, addr|
              @emitter.emit(ASM.load_halfword_offset(ACC, at, offset))
              @emitter.emit(ASM.load_immediate(TMP, addr))
              @emitter.emit(ASM.store_halfword(ACC, TMP))
            end
          end

          # Channel 1's sweep, cleared before each note it plays so the trigger lands last.
          def emit_sweep(regs)
            regs[:const].each do |addr, value|
              @emitter.emit(ASM.load_immediate(ACC, value))
              @emitter.emit(ASM.load_immediate(TMP, addr))
              @emitter.emit(ASM.store_halfword(ACC, TMP))
            end
          end

          # Start the row's note on a mixer voice — from the top of the recording the row names, at
          # the row's step and loudness — or switch the part's voice off for a rest. Which voice is
          # the mixer's to say (Mixer#emit_music_voice_routine): the part's own, a free one, or
          # one of the game's. The voice's SOUNDING word goes last, and it is the part's mark. In a
          # game whose sound effects play recordings there may be no voice to have, and then the
          # note is not played.
          #
          # A tune's lane is +number+, and in a game that moves the music volume, the loudness the
          # row says is kept for the lane (see #holds_notes?) and the voice gets it times the
          # level. With no +number+ the note is a sound effect's, whose mark is already in r8 and
          # whose volume is its own.
          def emit_recorded_note(lane:, base:, at:, number: nil)
            voice, mark, recording = 7, 8, 9
            rest = @emitter.gensym
            sounded = @emitter.gensym
            follows_level = @scales && number # an effect keeps its own volume
            emit_song_mark(mark, lane) if number
            @emitter.emit(ASM.ldr_offset(ACC, at, 4))                         # how fast to read it
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit_branch(:bcond, rest, cond: :eq)                     # 0 is a rest
            @mixer.emit_take_music_voice                                      # r7 = the voice it gets
            if @mixer.ranks_voices?
              @emitter.emit(ASM.cmp_imm(voice, 0))
              @emitter.emit_branch(:bcond, sounded, cond: :eq)                # ...none: not played
            end
            @emitter.emit(ASM.ldr_offset(ACC, at, 4))
            @emitter.emit(ASM.str_offset(ACC, voice, Mixer::SLOT_STEP))
            @emitter.emit(ASM.load_halfword_offset(ACC, at, 10))              # how loud
            if follows_level
              @primitives.store_var(ACC, self.class.music_note(number))
              emit_scaled_loudness(ACC)
            end
            @emitter.emit(ASM.str_offset(ACC, voice, Mixer::SLOT_VOL))
            @emitter.emit(ASM.load_halfword_offset(ACC, at, 8))               # which recording...
            @emitter.emit(ASM.lsl_imm(ACC, ACC, INSTRUMENT_SHIFT))
            @emitter.emit(ASM.add_reg(recording, base, ACC))
            @primitives.emit_add_const(recording, recording, @instruments_at, ACC) # ...its table entry
            @emitter.emit(ASM.ldr(ACC, recording))                            # where it is
            @emitter.emit(ASM.str_offset(ACC, voice, Mixer::SLOT_SRC))
            @emitter.emit(ASM.ldr_offset(ACC, recording, INSTRUMENT_LENGTH))  # how long it is
            @emitter.emit(ASM.str_offset(ACC, voice, Mixer::SLOT_LEN))
            # A NOTE CAN OUTLAST ITS RECORDING, and this is what stops it ending there: a
            # recording that holds says how far back to read when it reaches the end, so the body
            # of the note goes round for as long as the note lasts. One that does not hold says 0
            # here, and runs out as it always did.
            @emitter.emit(ASM.ldr_offset(ACC, recording, INSTRUMENT_HELD_BY))
            @emitter.emit(ASM.str_offset(ACC, voice, Mixer::SLOT_LOOP))
            @emitter.emit(ASM.load_immediate(ACC, 0))
            [Mixer::SLOT_POS, Mixer::SLOT_FRAC].each do |field|
              @emitter.emit(ASM.str_offset(ACC, voice, field))                # from the top, once
            end
            emit_note_shape(voice, recording) if @mixer.shapes_notes?
            @emitter.emit(ASM.str_offset(mark, voice, Mixer::SLOT_ACTIVE))      # the part's now
            @emitter.emit_branch(:b, sounded)
            @emitter.place_label(rest)
            forget_held_note(number) if follows_level
            @mixer.emit_music_voice_off
            @emitter.place_label(sounded)
          end

          # WHERE THE NOTE STARTS IN ITS OWN SHAPE, read off the recording's table entry.
          #
          # The four numbers are a fact about the entry, which the note names by a number it
          # already carries — so which shape this note has is not known until the row is read,
          # and the two cases are told apart here rather than at build time. A note with no shape
          # is full from its first frame and its gain never moves again; a shaped one starts at
          # nothing and the pass before the mix climbs it, in this same frame.
          #
          # The compare's flags carry down through the two stores after it: an LDR, an STR and a
          # plain MOV all leave the flags alone, so one compare answers both questions.
          def emit_note_shape(voice, recording)
            @emitter.emit(ASM.load_immediate(TMP, Mixer::PHASE_CLIMBING))
            @emitter.emit(ASM.str_offset(TMP, voice, Mixer::SLOT_PHASE))
            @emitter.emit(ASM.ldr_offset(ACC, recording, INSTRUMENT_ENVELOPE))
            @emitter.emit(ASM.str_offset(ACC, voice, Mixer::SLOT_ENV))
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit(ASM.mov_imm_cond(:eq, ACC, Envelope::FULL))
            @emitter.emit(ASM.mov_imm_cond(:ne, ACC, 0))
            @emitter.emit(ASM.str_offset(ACC, voice, Mixer::SLOT_LEVEL))
            @emitter.emit(ASM.ldr_offset(ACC, voice, Mixer::SLOT_VOL))
            @emitter.emit(ASM.mov_imm_cond(:ne, ACC, 0))     # a shaped note is silent until it climbs
            @emitter.emit(ASM.lsl_imm(ACC, ACC, Mixer::GAIN_FRACTION))
            @emitter.emit(ASM.str_offset(ACC, voice, Mixer::SLOT_GAIN))
            @emitter.emit(ASM.load_immediate(ACC, 0))
            @emitter.emit(ASM.str_offset(ACC, voice, Mixer::SLOT_RAMP)) # and it does not slide
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
            soundings = (@song_numbers.keys + @effects).flat_map { |name| IR::Tunes.soundings(@songs.fetch(name)) }.uniq
            @sounding_numbers = soundings.each_with_index.to_h
            @instruments_at = (@song_numbers.size + 1) * entry_bytes
            waves_at = @instruments_at + (soundings.size * INSTRUMENT_BYTES)
            # One copy of each waveform the played tunes and the sound effects use, whichever of
            # them use it.
            shapes = (@song_numbers.keys + @effects).flat_map { |name| wave_shapes(@songs.fetch(name)) }.uniq
            wave_at = shapes.each_with_index.to_h { |shape, i| [shape, waves_at + (i * WAVE_BYTES)] }
            events_at = waves_at + (shapes.size * WAVE_BYTES)

            directory = ("\0" * entry_bytes).b
            table = soundings.each_with_index.map do |sounding, number|
              @emitter.link_data(MUSIC_SCORE, @instruments_at + (number * INSTRUMENT_BYTES), sounding.name)
              info = @mixer.sample_info(sounding.name)
              # A part or a note that says nothing about the shape takes whatever the recording
              # itself was declared with, which is where music decoded from elsewhere keeps it.
              shape = sounding.envelope || info.envelope
              shape = nil if shape&.plain?
              [0, info.length, shape ? shape.packed : 0, info.held_by].pack("VVVV")
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
              rank = plays_sound_effects? ? [IR::Tunes.song_rank(song)] : []
              directory << [song.total_frames, used, loop_at, waveform_at(song, wave_at),
                            *starts, *rank].pack("V*").ljust(entry_bytes, "\0")
            end
            score = directory + table + events
            score + effects_blob(at: score.bytesize, never: events_at, wave_at: wave_at)
          end

          # EVERY SOUND EFFECT, after the tunes: an entry for each, in rank order — its length, its
          # rank, where each lane's events start and, in a game whose effects play the wave voice,
          # where its waveform is in +wave_at+ (0 for one that plays none) — and then the events
          # themselves. A lane an effect does not use waits on the row at +never+. Sets where the
          # entries start, for the tick to walk them.
          def effects_blob(at:, never:, wave_at:)
            @effects_at = at
            return "".b unless plays_sound_effects?

            rows = "".b
            rows_at = at + (@effects.size * effect_entry_bytes)
            entries = @effects.each_with_index.map do |name, order|
              song = @songs.fetch(name)
              starts = Array.new(@effect_lanes.size, never)
              effect_lanes_for(song).each do |part, number|
                starts[number] = rows_at + rows.bytesize
                rows << lane_rows(@effect_lanes[number], part, part.events)
              end
              wave = @effect_waves ? [waveform_at(song, wave_at)] : []
              [song.total_frames, @effect_ranks.fetch(name), *starts, *wave].pack("V*")
            end
            entries.join + rows
          end

          # Which effect lane each of an effect's parts plays on: its square parts the square
          # voices in order, its wave and noise parts those voices, and its recorded parts the
          # recorded lanes in order.
          def effect_lanes_for(song)
            squares = 0
            recorded = 0
            song.voices.map do |part|
              kind = IR::Tunes.part_kind(part)
              lane = case kind
                     when :wave, :noise then Lane.new(kind, CONSOLE_LANES.fetch(kind))
                     when :recorded then Lane.new(:recorded, recorded).tap { recorded += 1 }
                     else Lane.new(:square, MUSIC_CHANNELS.fetch(squares).tap { squares += 1 })
                     end
              [part, @effect_lanes.index(lane)]
            end
          end

          # The waveform a song's parts on the wave voice play. There is one wave voice, so
          # there is at most one — Checks::SongTooManyParts refuses a song with two such parts.
          def wave_shapes(song) = song.voices.filter_map { |part| part.wave }.uniq

          # Where in the score that waveform is, given where each one is in +wave_at+ — or 0 for a
          # song or effect with no part on the wave voice.
          def waveform_at(song, wave_at)
            shape = wave_shapes(song).first
            shape ? wave_at.fetch(shape) : 0
          end

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
              rows = events.map do |frame, frequency, instrument, volume, envelope|
                sounding = IR::Tunes::Sounding.new(name: instrument || part.instrument,
                                                   envelope: envelope || part.envelope)
                heard = loudness(volume || part.volume)
                # A note at volume 0 sounds nothing, so it is a rest: it takes no voice.
                step = frequency.zero? || heard.zero? ? 0 : @mixer.step_at(@mixer.sample_info(sounding.name), frequency)
                [frame, step, @sounding_numbers.fetch(sounding), heard].pack("VVvv")
              end
              rows.join + [NEVER, 0, 0, 0].pack("VVvv")
            else
              regs = music_voice_regs(lane)
              rows = events.map do |frame, frequency, _instrument, volume|
                writes = console_note(lane, part, frequency, volume || part.volume)
                control = note_reg_value(writes, regs[:reg_a])
                control |= (volume || part.volume) << WAVE_VOLUME_SHIFT if keeps_wave_volume?(lane, frequency)
                [frame, control, note_reg_value(writes, regs[:reg_b])].pack("Vvv")
              end
              rows.join + [NEVER, 0, 0].pack("Vvv")
            end
          end

          # Whether this row carries its written volume alongside the register value (see
          # WAVE_VOLUME_SHIFT) — a note, not a rest, on the wave voice, in a game that moves the
          # music volume. Every other game's rows are exactly what they were.
          def keeps_wave_volume?(lane, frequency) = @scales && lane.kind == :wave && frequency.positive?

          # ONE NOTE ON A VOICE THE CONSOLE PLAYS ITSELF, as its two register values. Each kind
          # answers the pair its own way — a square voice by pitch and tone, the wave voice by a
          # sample rate, the noise voice by which rung of its clock ladder sits nearest the note
          # — and the player copies whichever pair it finds, knowing none of that.
          def console_note(lane, part, frequency, volume)
            case lane.kind
            when :square
              Sound::Registers.channel_note(lane.index, frequency: frequency, duty: part.duty, volume: volume)
            when :wave
              Sound::Registers.wave_note(frequency: frequency, volume: volume)
            else
              Sound::Registers.noise_note(frequency: frequency, volume: volume,
                                          decay: part.decay, metallic: part.metallic)
            end
          end

          # A part's volume, 0..15 like the square voices', as the mix's 0..64.
          def loudness(volume) = IR::Tunes.mix_loudness(volume)

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
