# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # THE MUSIC PLAYER. The game only names a tune (rt_music_play) or stops it (rt_music_stop),
          # and the player walks each part's notes (SNES::Music) a frame at a time, handing each note's
          # group of commands to the sound unit as its frame comes.
          #
          # WHERE IT RUNS. The Advance and the Color play their music from the screen's interrupt.
          # Here that interrupt would come between any two of the game's own writes to the sound
          # unit, and the mailboxes take one command at a time: a note sent from the interrupt in
          # the middle of a beep's write would spoil both. So the player runs where a pass's wait
          # ends (Sound's rt_sound_frame), once for every frame the pass took — which is also where
          # the interpreter moves its music on (Reference#advance_frame), after the pass and by every
          # frame it took. A game that keeps up hears each note on its own frame; one that falls
          # behind hears the frames it missed at once, as the interpreter logs them.
          #
          # What it does each frame is Reference::Player#advance's steps, in its order: catch up
          # with the tune the game names (a different one, or a stop, quiets the old and starts the
          # new from its first frame; one that played once and ended stays quiet), then each part's
          # next note if its frame has come, then the frame on, round to the tune's loop frame at its
          # end.
          module Music
            NAMED = "rt music named" # the tune the game named last (SNES::Music#number), nought for none
            PLAYING = "rt music playing" # ...and the tune playing
            STOPS = "rt music stops" # how many times the game said stop_music...
            STOPS_SEEN = "rt music stops seen" # ...and how many of those the player has acted on
            ENDED = "rt music ended" # a tune that played once and reached its end
            FRAME = "rt music frame" # how far into the tune, in frames
            AGAIN = "rt music again" # 1 once the tune has come round
            SONG = "rt music song" # where the playing tune's record is in the table
            CURSORS = "rt music cursors" # each part's next note
            PART = "rt music part" # the part being played...
            PARTS_IN = "rt music parts in" # ...of how many
            COUNT = "rt music count" # how many notes the part has this time round...
            LIST = "rt music list" # ...and where they are
            LEFT = "rt music left" # frames still to play where a wait ends
            ENTRY = "rt music entry" # where the part being played's entry is in the table
            NOTE = "rt music note" # ...and its note being played
            # THE MUSIC VOLUME, in a game that sets it (SNES::Music#follows_level?): the level the
            # notes sounding were set at, kept with its FULL_LEVEL bit turned over so the nought
            # memory starts at says full; each part's note's volume as written, while its voice holds
            # it (nought for a rest, or none); a note's loudness at the level, worked out; the level
            # itself while a loudness is worked out; and where the part's loudness groups are while
            # one is found.
            LEVEL_SET = "rt music level set"
            HELD = "rt music held"
            LOUDNESS = "rt music loudness"
            LEVEL_NOW = "rt music level now"
            LOUDNESS_TABLE = "rt music loudness table"

            module_function

            # +follows_level+ for a game that sets the music volume (SNES::Music.follows_level?).
            def reserve(memory, follows_level: false)
              [NAMED, PLAYING, STOPS, STOPS_SEEN, ENDED, FRAME, AGAIN, SONG, PART, PARTS_IN, COUNT, LIST,
               LEFT, ENTRY, NOTE].each { |name| memory.reserve(name, 2) }
              memory.reserve(CURSORS, SNES::Music::PARTS * 2)
              return unless follows_level

              [LEVEL_SET, LOUDNESS, LEVEL_NOW, LOUDNESS_TABLE].each { |name| memory.reserve(name, 2) }
              memory.reserve(HELD, SNES::Music::PARTS * 2)
            end

            # +level_at+ is where a game that sets its music volume keeps it (IR::Tunes::LEVEL), or nil.
            def emit(asm, memory, level_at: nil)
              at = ->(name, plus = 0) { asm.abs(memory[name], plus) }
              emit_game_side(asm, at)
              emit_frames(asm, at)
              emit_switch(asm, at, memory, level_at)
              emit_song_frame(asm, at, memory, level_at)
              emit_level(asm, at, memory, level_at) if level_at
              emit_group(asm)
            end

            # rt_music_play(tune): play it from the next frame, unless it is playing already.
            # rt_music_play_now(tune): the same, and a tune that is starting plays its first frame
            # here (Reference::Player#start_song_here). rt_music_stop(): no tune.
            def emit_game_side(asm, at)
              asm.label("rt_music_play")
              asm.lda(asm.direct(Sound::R0))
              asm.sta(at.call(NAMED))
              asm.rtl

              asm.label("rt_music_play_now")
              asm.lda(asm.direct(Sound::R0))
              asm.sta(at.call(NAMED))
              # The tune named, caught up with here: one that starts plays its first frame.
              asm.label("rt_music_start_here")
              asm.jsr(asm.abs("rt_music_switch"))
              asm.beq("rt_music_start_here_done")
              asm.lda(at.call(PLAYING))
              asm.beq("rt_music_start_here_done")
              asm.jsr(asm.abs("rt_music_song_frame"))
              asm.label("rt_music_start_here_done")
              asm.rtl

              asm.label("rt_music_stop")
              asm.stz(at.call(NAMED))
              asm.inc(at.call(STOPS))
              asm.rtl

              # rt_music_play_from_list(which, list): the song at place +which+ of song list +list+
              # (SNES::Music#list_number), from the next frame; a place outside the list leaves the
              # music as it is (Reference::Player#request_song_at). rt_music_play_from_list_now: the
              # same, and a song it names that is starting plays its first frame here.
              asm.label("rt_music_play_from_list")
              asm.jsr(asm.abs("rt_music_name_from_list"))
              asm.rtl

              asm.label("rt_music_play_from_list_now")
              asm.jsr(asm.abs("rt_music_name_from_list"))
              asm.bne("rt_music_start_here")
              asm.rtl

              # rt_music_name_from_list: NAMED = the song at place R0 (32 bits) of list R1, and A = 1;
              # or A = nought, and nothing named, for a place outside the list.
              asm.label("rt_music_name_from_list")
              asm.lda(asm.direct(Sound::R0 + 2))
              asm.bne("rt_music_name_from_list_outside") # below nought, or far past any list's end
              asm.lda(asm.direct(Sound::R1))
              asm.asl
              asm.clc
              asm.adc(asm.long("music_data", SNES::Music::LISTS_AT))
              asm.tax
              asm.lda(asm.long_x("music_data"))
              asm.sta(at.call(LIST))
              asm.tax
              asm.lda(asm.direct(Sound::R0))
              asm.cmp(asm.long_x("music_data")) # how many songs the list holds
              asm.bcs("rt_music_name_from_list_outside")
              asm.asl
              asm.clc
              asm.adc(at.call(LIST))
              asm.tax
              asm.lda(asm.long_x("music_data", 2))
              asm.sta(at.call(NAMED))
              asm.lda(1)
              asm.rts
              asm.label("rt_music_name_from_list_outside")
              asm.lda(0)
              asm.rts
            end

            # rt_music_frames: the player, once for each frame the pass just ended took.
            def emit_frames(asm, at)
              asm.label("rt_music_frames")
              asm.lda(at.call(Frame::FRAMES_TAKEN))
              asm.sta(at.call(LEFT))
              asm.label("rt_music_frames_next")
              asm.jsr(asm.abs("rt_music_switch"))
              asm.lda(at.call(PLAYING))
              asm.beq("rt_music_frames_played")
              asm.jsr(asm.abs("rt_music_song_frame"))
              asm.label("rt_music_frames_played")
              asm.dec(at.call(LEFT))
              asm.bne("rt_music_frames_next")
              asm.rts
            end

            # rt_music_switch: caught up with the tune the game names (Reference::Player#switch_to_wanted_song).
            # A is 1 when that changed what is playing, nought when not.
            def emit_switch(asm, at, memory, level_at)
              asm.label("rt_music_switch")
              asm.lda(at.call(ENDED))
              asm.beq("rt_music_switch_live")
              asm.cmp(at.call(NAMED))
              asm.bne("rt_music_switch_forget")
              asm.lda(at.call(STOPS))
              asm.cmp(at.call(STOPS_SEEN))
              asm.bne("rt_music_switch_forget")
              # Still named, and no stop since: the tune that ended stays quiet.
              asm.lda(at.call(PLAYING))
              asm.beq("rt_music_switch_ended")
              asm.jsr(asm.abs("rt_music_quiet"))
              asm.label("rt_music_switch_ended")
              asm.stz(at.call(PLAYING))
              asm.lda(0)
              asm.rts
              asm.label("rt_music_switch_forget")
              asm.stz(at.call(ENDED))
              asm.label("rt_music_switch_live")
              asm.lda(at.call(NAMED))
              asm.cmp(at.call(PLAYING))
              asm.bne("rt_music_switch_change")
              asm.lda(at.call(STOPS))
              asm.cmp(at.call(STOPS_SEEN))
              asm.bne("rt_music_switch_change")
              asm.lda(0)
              asm.rts
              asm.label("rt_music_switch_change")
              asm.lda(at.call(STOPS))
              asm.sta(at.call(STOPS_SEEN))
              asm.lda(at.call(PLAYING))
              asm.beq("rt_music_switch_quiet")
              asm.jsr(asm.abs("rt_music_quiet"))
              asm.label("rt_music_switch_quiet")
              asm.lda(at.call(NAMED))
              asm.sta(at.call(PLAYING))
              asm.beq("rt_music_switch_changed")
              asm.dec # the tune's word in the table of songs, whose place is at SONGS_AT
              asm.asl
              asm.clc
              asm.adc(asm.long("music_data", SNES::Music::SONGS_AT))
              asm.tax
              asm.lda(asm.long_x("music_data"))
              asm.sta(at.call(SONG))
              asm.stz(at.call(FRAME))
              asm.stz(at.call(AGAIN))
              asm.jsr(asm.abs("rt_music_from_the_top"))
              asm.label("rt_music_switch_changed")
              asm.lda(1)
              asm.rts

              asm.label("rt_music_from_the_top")
              SNES::Music::PARTS.times { |p| asm.stz(at.call(CURSORS, p * 2)) }
              asm.rts

              # The playing tune's group for stopping (SONG is still the tune's), and no note held.
              asm.label("rt_music_quiet")
              SNES::Music::PARTS.times { |p| asm.stz(asm.abs(memory[HELD], p * 2)) } if level_at
              asm.ldx(at.call(SONG))
              asm.lda(asm.long_x("music_data", SNES::Music::QUIET_GROUP))
              asm.tax
              asm.jmp(asm.abs("rt_sound_group"))
            end

            # rt_music_song_frame: each part's note whose frame has come, then the frame on
            # (Reference::Player#play_song_frame and #advance_song_frame).
            def emit_song_frame(asm, at, memory, level_at)
              m = SNES::Music
              asm.label("rt_music_song_frame")
              asm.ldx(at.call(SONG))
              asm.lda(asm.long_x("music_data", m::PART_COUNT))
              asm.sta(at.call(PARTS_IN))
              asm.jsr(asm.abs("rt_music_relevel")) if level_at
              asm.stz(at.call(PART))
              asm.label("rt_music_part")
              asm.lda(at.call(PART))
              asm.cmp(at.call(PARTS_IN))
              asm.branch_long(:bcs, "rt_music_parts_done")
              asm.jsr(asm.abs("rt_music_entry"))
              asm.lda(at.call(AGAIN))
              asm.beq("rt_music_part_pass")
              m::AGAIN.times { asm.inx }
              asm.label("rt_music_part_pass")
              asm.lda(asm.long_x("music_data", m::NOTE_COUNT))
              asm.sta(at.call(COUNT))
              asm.lda(asm.long_x("music_data", m::NOTES_AT))
              asm.sta(at.call(LIST))
              asm.lda(at.call(PART))
              asm.asl
              asm.tay
              asm.lda(asm.abs_y(memory[CURSORS]))
              asm.cmp(at.call(COUNT))
              asm.bcs("rt_music_part_next")
              emit_times(asm, m::NOTE_BYTES) # the next note: its frame, and where its group is
              asm.clc
              asm.adc(at.call(LIST))
              asm.tax
              asm.lda(asm.long_x("music_data", m::NOTE_FRAME))
              asm.cmp(at.call(FRAME))
              asm.bne("rt_music_part_next")
              asm.stx(at.call(NOTE))
              asm.lda(asm.long_x("music_data", m::NOTE_HEAD))
              asm.tax
              asm.jsr(asm.abs("rt_sound_group"))
              emit_note_loudness(asm, at, memory) if level_at
              asm.ldx(at.call(NOTE))
              asm.lda(asm.long_x("music_data", m::NOTE_TAIL))
              asm.tax
              asm.jsr(asm.abs("rt_sound_group"))
              asm.lda(at.call(PART))
              asm.asl
              asm.tax
              asm.inc(asm.abs_x(memory[CURSORS]))
              asm.label("rt_music_part_next")
              asm.inc(at.call(PART))
              asm.brl("rt_music_part")

              # rt_music_entry: ENTRY and X = where part PART's entry is.
              asm.label("rt_music_entry")
              asm.lda(at.call(PART))
              emit_times(asm, m::PART_BYTES)
              asm.clc
              asm.adc(at.call(SONG))
              asm.clc
              asm.adc(m::RECORD_BYTES)
              asm.sta(at.call(ENTRY))
              asm.tax
              asm.rts

              asm.label("rt_music_parts_done")
              asm.inc(at.call(FRAME))
              asm.ldx(at.call(SONG))
              asm.lda(at.call(FRAME))
              asm.cmp(asm.long_x("music_data", m::LENGTH))
              asm.bcc("rt_music_song_frame_done")
              asm.lda(asm.long_x("music_data", m::PLAYS_ONCE))
              asm.beq("rt_music_round")
              asm.lda(at.call(PLAYING)) # a tune that plays once: ended
              asm.sta(at.call(ENDED))
              asm.rts
              asm.label("rt_music_round")
              asm.lda(asm.long_x("music_data", m::LOOP_FRAME))
              asm.sta(at.call(FRAME))
              asm.lda(1)
              asm.sta(at.call(AGAIN))
              asm.jsr(asm.abs("rt_music_from_the_top"))
              asm.label("rt_music_song_frame_done")
              asm.rts
            end

            # A NOTE'S LOUDNESS, between its head and its tail (SNES::Music#part_layout): its volume as
            # written held for a new level to reach, if its voice holds one, and its loudness at the
            # level written and logged.
            def emit_note_loudness(asm, at, memory)
              m = SNES::Music
              asm.ldx(at.call(NOTE))
              asm.lda(asm.long_x("music_data", m::NOTE_VOLUME))
              asm.pha
              asm.ldx(at.call(ENTRY))
              asm.lda(asm.long_x("music_data", m::HOLDS))
              asm.beq("rt_music_note_not_held")
              asm.lda(at.call(PART))
              asm.asl
              asm.tay
              asm.lda(asm.stack(1))
              asm.sta(asm.abs_y(memory[HELD]))
              asm.label("rt_music_note_not_held")
              asm.pla
              asm.jsr(asm.abs("rt_music_loudness"))
            end

            # THE MUSIC VOLUME MOVED (Reference::Player#apply_music_volume): at the start of a frame
            # of the tune, before any note, every part whose voice holds a note writes and logs its
            # loudness at the new level, in the order of the parts — which is the order they first
            # sounded, as the interpreter keeps them, since every part's first time round starts with
            # an event at frame 0 (IR::Tunes.loop_passes).
            #
            # rt_music_loudness: the part at ENTRY's loudness group for the volume in A at the level.
            # rt_music_scaled: A = the volume in A at the level (IR::Tunes.scaled_volume), the level
            # times the volume by adding, and a shift.
            def emit_level(asm, at, memory, level_at)
              m = SNES::Music
              full = IR::Tunes::FULL_LEVEL
              asm.label("rt_music_relevel")
              asm.lda(asm.abs(level_at))
              asm.eor(full)
              asm.cmp(at.call(LEVEL_SET))
              asm.bne("rt_music_relevel_moved")
              asm.rts
              asm.label("rt_music_relevel_moved")
              asm.sta(at.call(LEVEL_SET))
              asm.stz(at.call(PART))
              asm.label("rt_music_relevel_part")
              asm.lda(at.call(PART))
              asm.cmp(at.call(PARTS_IN))
              asm.bcs("rt_music_relevel_done")
              asm.asl
              asm.tay
              asm.lda(asm.abs_y(memory[HELD]))
              asm.beq("rt_music_relevel_next")
              asm.pha
              asm.jsr(asm.abs("rt_music_entry"))
              asm.pla
              asm.jsr(asm.abs("rt_music_loudness"))
              asm.label("rt_music_relevel_next")
              asm.inc(at.call(PART))
              asm.bra("rt_music_relevel_part")
              asm.label("rt_music_relevel_done")
              asm.rts

              asm.label("rt_music_loudness")
              asm.jsr(asm.abs("rt_music_scaled"))
              asm.sta(at.call(LOUDNESS))
              asm.ldx(at.call(ENTRY))
              asm.lda(asm.long_x("music_data", m::LOUDNESS_GROUPS))
              asm.sta(at.call(LOUDNESS_TABLE))
              asm.lda(at.call(LOUDNESS))
              asm.asl
              asm.clc
              asm.adc(at.call(LOUDNESS_TABLE))
              asm.tax
              asm.lda(asm.long_x("music_data"))
              asm.tax
              asm.jmp(asm.abs("rt_sound_group"))

              asm.label("rt_music_scaled")
              asm.tax
              asm.lda(at.call(LEVEL_SET))
              asm.eor(full)
              asm.sta(at.call(LEVEL_NOW))
              asm.lda(0)
              asm.cpx(0)
              asm.beq("rt_music_scaled_summed")
              asm.label("rt_music_scaled_add")
              asm.clc
              asm.adc(at.call(LEVEL_NOW))
              asm.dex
              asm.bne("rt_music_scaled_add")
              asm.label("rt_music_scaled_summed")
              IR::Tunes::LEVEL_SHIFT.times { asm.lsr }
              asm.rts
            end

            # rt_sound_group (X = where a group is in the table): each of its commands sent to the sound
            # unit, or its entry put in the sound log, until its end.
            def emit_group(asm)
              m = SNES::Music
              asm.label("rt_sound_group")
              asm.lda(asm.long_x("music_data"))
              asm.beq("rt_sound_group_done")
              asm.cmp(m::GROUP_LOG)
              asm.beq("rt_sound_group_log")
              asm.pha
              asm.lda(asm.long_x("music_data", m::COMMAND_FIRST))
              asm.sta(asm.direct(Sound::R0))
              asm.lda(asm.long_x("music_data", m::COMMAND_SECOND))
              asm.sta(asm.direct(Sound::R1))
              asm.pla
              asm.phx
              asm.jsl(asm.long("rt_sound_command"))
              asm.plx
              asm.bra("rt_sound_group_next")
              asm.label("rt_sound_group_log")
              asm.lda(asm.long_x("music_data", m::COMMAND_FIRST))
              asm.sta(asm.direct(Sound::R0))
              asm.phx
              asm.jsl(asm.long("rt_sound_log"))
              asm.plx
              asm.label("rt_sound_group_next")
              asm.txa
              asm.clc
              asm.adc(m::COMMAND_BYTES)
              asm.tax
              asm.bra("rt_sound_group")
              asm.label("rt_sound_group_done")
              asm.rts
            end

            # A times +count+, a power of two, by shifting.
            def emit_times(asm, count)
              raise ArgumentError, "#{count} is not a power of two" unless count.positive? && (count & (count - 1)).zero?

              (count.bit_length - 1).times { asm.asl }
            end
          end
        end
      end
    end
  end
end
