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

            module_function

            def reserve(memory)
              [NAMED, PLAYING, STOPS, STOPS_SEEN, ENDED, FRAME, AGAIN, SONG, PART, PARTS_IN, COUNT, LIST,
               LEFT].each { |name| memory.reserve(name, 2) }
              memory.reserve(CURSORS, SNES::Music::PARTS * 2)
            end

            def emit(asm, memory)
              at = ->(name, plus = 0) { asm.abs(memory[name], plus) }
              emit_game_side(asm, at)
              emit_frames(asm, at)
              emit_switch(asm, at)
              emit_song_frame(asm, at, memory)
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
              asm.jsr(asm.abs("rt_music_switch"))
              asm.beq("rt_music_play_now_done")
              asm.lda(at.call(PLAYING))
              asm.beq("rt_music_play_now_done")
              asm.jsr(asm.abs("rt_music_song_frame"))
              asm.label("rt_music_play_now_done")
              asm.rtl

              asm.label("rt_music_stop")
              asm.stz(at.call(NAMED))
              asm.inc(at.call(STOPS))
              asm.rtl
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
            def emit_switch(asm, at)
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
              asm.dec # the tune's word in the table of songs, whose place is the table's first word
              asm.asl
              asm.clc
              asm.adc(asm.long("music_data"))
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

              asm.label("rt_music_quiet")
              asm.ldx(SNES::Music::QUIET_AT)
              asm.jmp(asm.abs("rt_sound_group"))
            end

            # rt_music_song_frame: each part's note whose frame has come, then the frame on
            # (Reference::Player#play_song_frame and #advance_song_frame).
            def emit_song_frame(asm, at, memory)
              record = SNES::Music::RECORD_WORDS * 2
              asm.label("rt_music_song_frame")
              asm.ldx(at.call(SONG))
              asm.lda(asm.long_x("music_data", 6))
              asm.sta(at.call(PARTS_IN))
              asm.stz(at.call(PART))
              asm.label("rt_music_part")
              asm.lda(at.call(PART))
              asm.cmp(at.call(PARTS_IN))
              asm.bcs("rt_music_parts_done")
              asm.asl # the part's two lists, each where it is and how many notes
              asm.asl
              asm.asl
              asm.clc
              asm.adc(at.call(SONG))
              asm.adc(record)
              asm.tax
              asm.lda(at.call(AGAIN))
              asm.beq("rt_music_part_pass")
              4.times { asm.inx }
              asm.label("rt_music_part_pass")
              asm.lda(asm.long_x("music_data", 2))
              asm.sta(at.call(COUNT))
              asm.lda(asm.long_x("music_data"))
              asm.sta(at.call(LIST))
              asm.lda(at.call(PART))
              asm.asl
              asm.tay
              asm.lda(asm.abs_y(memory[CURSORS]))
              asm.cmp(at.call(COUNT))
              asm.bcs("rt_music_part_next")
              asm.asl # the next note: its frame, and where its group is
              asm.asl
              asm.clc
              asm.adc(at.call(LIST))
              asm.tax
              asm.lda(asm.long_x("music_data"))
              asm.cmp(at.call(FRAME))
              asm.bne("rt_music_part_next")
              asm.lda(asm.long_x("music_data", 2))
              asm.tax
              asm.jsr(asm.abs("rt_sound_group"))
              asm.lda(at.call(PART))
              asm.asl
              asm.tax
              asm.inc(asm.abs_x(memory[CURSORS]))
              asm.label("rt_music_part_next")
              asm.inc(at.call(PART))
              asm.bra("rt_music_part")

              asm.label("rt_music_parts_done")
              asm.inc(at.call(FRAME))
              asm.ldx(at.call(SONG))
              asm.lda(at.call(FRAME))
              asm.cmp(asm.long_x("music_data"))
              asm.bcc("rt_music_song_frame_done")
              asm.lda(asm.long_x("music_data", 4))
              asm.beq("rt_music_round")
              asm.lda(at.call(PLAYING)) # a tune that plays once: ended
              asm.sta(at.call(ENDED))
              asm.rts
              asm.label("rt_music_round")
              asm.lda(asm.long_x("music_data", 2))
              asm.sta(at.call(FRAME))
              asm.lda(1)
              asm.sta(at.call(AGAIN))
              asm.jsr(asm.abs("rt_music_from_the_top"))
              asm.label("rt_music_song_frame_done")
              asm.rts
            end

            # rt_sound_group (X = where a group is in the table): each of its commands sent to the sound
            # unit, or its entry put in the sound log, until its end.
            def emit_group(asm)
              asm.label("rt_sound_group")
              asm.lda(asm.long_x("music_data"))
              asm.beq("rt_sound_group_done")
              asm.cmp(SNES::Music::GROUP_LOG)
              asm.beq("rt_sound_group_log")
              asm.pha
              asm.lda(asm.long_x("music_data", 2))
              asm.sta(asm.direct(Sound::R0))
              asm.lda(asm.long_x("music_data", 4))
              asm.sta(asm.direct(Sound::R1))
              asm.pla
              asm.phx
              asm.jsl(asm.long("rt_sound_command"))
              asm.plx
              asm.bra("rt_sound_group_next")
              asm.label("rt_sound_group_log")
              asm.lda(asm.long_x("music_data", 2))
              asm.sta(asm.direct(Sound::R0))
              asm.phx
              asm.jsl(asm.long("rt_sound_log"))
              asm.plx
              asm.label("rt_sound_group_next")
              asm.txa
              asm.clc
              asm.adc(6)
              asm.tax
              asm.bra("rt_sound_group")
              asm.label("rt_sound_group_done")
              asm.rts
            end
          end
        end
      end
    end
  end
end
