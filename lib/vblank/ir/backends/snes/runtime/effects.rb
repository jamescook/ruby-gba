# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # THE SOUND EFFECTS PLAYER, beside the tune's (Music), the same steps as
          # Reference::Player's, in its order.
          #
          # The game asks for an effect (rt_sfx_play); at the next frame it starts from its first
          # note, plays each note once as its frame comes, and at its end lets go of the voices it
          # still holds, quieting them. The tune and the effects share the console's four voices, and
          # WHO SOUNDS ON ONE is settled by rank (SNES::Music, "who sounds on a voice"): a note takes a
          # voice whose holder's rank is no higher than its own, and holds it while it makes a sound
          # (rt_sfx_claim). Each frame plays the effects that outrank the tune before the tune's parts
          # and the rest after, so whoever writes a voice first on a frame is whoever keeps it.
          #
          # AN EFFECT IN A GROUP plays one at a time with the rest of its group: asked for while
          # another of its group is sounding or already asked for, it is not played if its priority
          # is lower, and otherwise stops that one on the next frame and starts in its place
          # (Reference::Player#request_effect).
          module Effects
            # Which voice each holder holds, by channel (1..4, two bytes each from channel 1): the
            # holder's rank's place; and the channels in the order each was first held, as the
            # interpreter's Hash keeps them, which is the order an effect's end lets them go in.
            HOLDERS = "rt sfx holders"
            HOLDER_ORDER = "rt sfx holder order"
            HOLDER_END = "rt sfx holder end"
            HOLDER_SEEN = "rt sfx holder seen"
            # A claim on a voice: its channel, the rank asking, and whether the note sounds.
            CLAIM_CHANNEL = "rt sfx claim channel"
            CLAIM_RANK = "rt sfx claim rank"
            CLAIM_SOUNDS = "rt sfx claim sounds"
            # The tune's rank's place, plus one, as a frame starts; nought for no tune.
            TUNE_RANK = "rt sfx tune rank"
            # The effect being played: its number, where its record is, where its state is, the part
            # being played and how many, that part's entry and its note.
            EFFECT = "rt sfx effect"
            RECORD = "rt sfx record"
            STATE = "rt sfx state"
            PART = "rt sfx part"
            PARTS = "rt sfx parts"
            ENTRY = "rt sfx entry"
            NOTE = "rt sfx note"
            # Where in the effects' rank order a frame is; and where in HOLDER_ORDER an effect's end is,
            # apart, since an effect is ended in the middle of a walk through the rank order.
            WALK = "rt sfx walk"
            RELEASE_WALK = "rt sfx release walk"
            # An effect's end: its rank's place, and the voice it is letting go.
            RELEASE_RANK = "rt sfx release rank"
            RELEASE_CHANNEL = "rt sfx release channel"
            # An effect asked for: its number, group and priority; and another of its group.
            ASKED_EFFECT = "rt sfx asked effect"
            ASKED_GROUP = "rt sfx asked group"
            ASKED_PRIORITY = "rt sfx asked priority"
            OTHER = "rt sfx other"
            # Where a table being read is in the song table (an effect list, the rank order, the
            # ranks' kinds).
            TABLE_AT = "rt sfx table at"
            # Each effect's state, STATE_BYTES apart: asked for since the last frame; asked for, as a
            # frame plays it; to be cut off; sounding; how far into it; each part's next note.
            STATES = "rt sfx states"
            ASKED = 0
            ASKED_NOW = 2
            STOPPING = 4
            RUNNING = 6
            FRAME = 8
            CURSORS = 10
            STATE_BYTES = 32

            CHANNELS = (1..4).freeze

            module_function

            def reserve(memory, effects)
              [HOLDER_END, CLAIM_CHANNEL, CLAIM_RANK, CLAIM_SOUNDS, TUNE_RANK, EFFECT, RECORD, STATE, PART, PARTS,
               ENTRY, NOTE, WALK, RELEASE_WALK, RELEASE_RANK, RELEASE_CHANNEL, ASKED_EFFECT, ASKED_GROUP, ASKED_PRIORITY,
               OTHER, TABLE_AT].each { |name| memory.reserve(name, 2) }
              [HOLDERS, HOLDER_ORDER, HOLDER_SEEN].each { |name| memory.reserve(name, CHANNELS.size * 2) }
              memory.reserve(STATES, effects * STATE_BYTES)
            end

            # +count+ is how many effects the game has; +level_at+ where its music volume is, if it
            # sets one, since an effect taking a voice takes the tune's note there out of those a new
            # level reaches.
            def emit(asm, memory, count, level_at)
              at = ->(name, plus = 0) { asm.abs(memory[name], plus) }
              emit_game_side(asm, at, memory, count)
              emit_passes(asm, at, memory, count)
              emit_frame(asm, at, memory, level_at)
              emit_finish(asm, at, memory)
              emit_claim_routine(asm, at, memory)
              emit_select(asm, at, memory)
            end

            # A call of rt_sfx_claim, inline, by the rank's place in A, for the part whose entry is at
            # +entry+ and its note at +note+ (places in work RAM holding where each is in the table).
            # A = 1 when the note takes the voice, nought when a holder of a higher rank keeps it.
            def emit_claim_call(asm, memory, entry: Music::ENTRY, note: Music::NOTE)
              m = SNES::Music
              asm.sta(asm.abs(memory[CLAIM_RANK]))
              asm.ldx(asm.abs(memory[entry]))
              asm.lda(asm.long_x("music_data", m::CHANNEL))
              asm.sta(asm.abs(memory[CLAIM_CHANNEL]))
              asm.ldx(asm.abs(memory[note]))
              asm.lda(asm.long_x("music_data", m::NOTE_SOUNDS))
              asm.sta(asm.abs(memory[CLAIM_SOUNDS]))
              asm.jsr(asm.abs("rt_sfx_claim"))
            end

            # As the tune stops, inline: R0, the voices its parts play on, less those a sound effect
            # holds; and every voice the tune holds, or nobody does, free
            # (Reference::Player#silence_song).
            def emit_release_tune_voices(asm, memory)
              asm.lda(asm.long("music_data", SNES::Music::RANK_KINDS_AT))
              asm.sta(asm.abs(memory[TABLE_AT])) # where the ranks' kinds are
              CHANNELS.each do |channel|
                kept = "rt_music_quiet_kept_#{channel}"
                done = "rt_music_quiet_done_#{channel}"
                holder = asm.abs(memory[HOLDERS], (channel - 1) * 2)
                asm.lda(holder)
                asm.asl
                asm.clc
                asm.adc(asm.abs(memory[TABLE_AT]))
                asm.tax
                asm.lda(asm.long_x("music_data"))
                asm.bne(kept)
                asm.stz(holder)
                asm.bra(done)
                asm.label(kept) # an effect's: not let go
                asm.lda(asm.direct(Sound::R0))
                asm.and_a(~(1 << DSPWrites::CHANNEL_VOICES.fetch(channel)) & 0xFFFF)
                asm.sta(asm.direct(Sound::R0))
                asm.label(done)
              end
            end

            # rt_sfx_play(which, list): the effect at place +which+ of effect list +list+ starts at the
            # next frame (Reference::Player#request_effect); rt_sfx_play_now, here
            # (Reference::Player#start_effect_here).
            def emit_game_side(asm, at, memory, count)
              m = SNES::Music
              asm.label("rt_sfx_play")
              asm.jsr(asm.abs("rt_sfx_request"))
              asm.rtl

              asm.label("rt_sfx_play_now")
              asm.jsr(asm.abs("rt_sfx_request"))
              asm.bne("rt_sfx_play_now_asked")
              asm.rtl
              asm.label("rt_sfx_play_now_asked")
              asm.lda(at.call(ASKED_EFFECT))
              asm.jsr(asm.abs("rt_sfx_select"))
              asm.lda(0)
              asm.sta(asm.abs_y(memory[STATES], ASKED))
              # Every effect, in rank order: this one plays its first frame; one of a group waiting to
              # be cut off is cut off here.
              asm.stz(at.call(WALK))
              asm.label("rt_sfx_play_now_next")
              asm.jsr(asm.abs("rt_sfx_select_ranked"))
              asm.cmp(at.call(ASKED_EFFECT))
              asm.bne("rt_sfx_play_now_other")
              asm.lda(1)
              asm.sta(asm.abs_y(memory[STATES], ASKED_NOW))
              asm.jsr(asm.abs("rt_sfx_frame"))
              asm.ldy(at.call(STATE))
              asm.lda(0)
              asm.sta(asm.abs_y(memory[STATES], ASKED_NOW))
              asm.bra("rt_sfx_play_now_walk")
              asm.label("rt_sfx_play_now_other")
              asm.lda(asm.abs_y(memory[STATES], STOPPING))
              asm.beq("rt_sfx_play_now_walk")
              asm.lda(0)
              asm.sta(asm.abs_y(memory[STATES], STOPPING))
              asm.jsr(asm.abs("rt_sfx_finish"))
              asm.label("rt_sfx_play_now_walk")
              asm.inc(at.call(WALK))
              asm.lda(at.call(WALK))
              asm.cmp(count)
              asm.bcc("rt_sfx_play_now_next")
              asm.rtl

              # rt_sfx_request: the effect at place R0 (32 bits) of list R1 asked for, A = 1 and
              # ASKED_EFFECT its number; or A = nought, for a place outside the list or an effect its
              # group's sounding one outranks.
              asm.label("rt_sfx_request")
              asm.lda(asm.direct(Sound::R0 + 2))
              asm.branch_long(:bne, "rt_sfx_request_none")
              asm.lda(asm.direct(Sound::R1))
              asm.asl
              asm.clc
              asm.adc(asm.long("music_data", m::EFFECT_LISTS_AT))
              asm.tax
              asm.lda(asm.long_x("music_data"))
              asm.sta(at.call(TABLE_AT))
              asm.tax
              asm.lda(asm.direct(Sound::R0))
              asm.cmp(asm.long_x("music_data")) # how many effects the list holds
              asm.branch_long(:bcs, "rt_sfx_request_none")
              asm.asl
              asm.clc
              asm.adc(at.call(TABLE_AT))
              asm.tax
              asm.lda(asm.long_x("music_data", 2))
              asm.sta(at.call(ASKED_EFFECT))
              asm.jsr(asm.abs("rt_sfx_select"))
              asm.lda(asm.long_x("music_data", m::EFFECT_GROUP))
              asm.beq("rt_sfx_request_ask")
              asm.sta(at.call(ASKED_GROUP))
              asm.lda(asm.long_x("music_data", m::EFFECT_PRIORITY))
              asm.sta(at.call(ASKED_PRIORITY))
              # The first of its group, in the order declared, asked for or sounding and not stopping.
              asm.stz(at.call(OTHER))
              asm.label("rt_sfx_request_find")
              asm.lda(at.call(OTHER))
              asm.cmp(count)
              asm.bcs("rt_sfx_request_ask")
              asm.jsr(asm.abs("rt_sfx_select"))
              asm.lda(asm.long_x("music_data", m::EFFECT_GROUP))
              asm.cmp(at.call(ASKED_GROUP))
              asm.bne("rt_sfx_request_other")
              asm.lda(asm.abs_y(memory[STATES], ASKED))
              asm.bne("rt_sfx_request_current")
              asm.lda(asm.abs_y(memory[STATES], RUNNING))
              asm.beq("rt_sfx_request_other")
              asm.lda(asm.abs_y(memory[STATES], STOPPING))
              asm.beq("rt_sfx_request_current")
              asm.label("rt_sfx_request_other")
              asm.inc(at.call(OTHER))
              asm.bra("rt_sfx_request_find")
              asm.label("rt_sfx_request_current")
              asm.lda(asm.long_x("music_data", m::EFFECT_PRIORITY))
              asm.cmp(at.call(ASKED_PRIORITY))
              asm.beq("rt_sfx_request_cut")
              asm.bcs("rt_sfx_request_none") # the one sounding outranks it
              asm.label("rt_sfx_request_cut")
              asm.lda(0)
              asm.sta(asm.abs_y(memory[STATES], ASKED))
              asm.lda(1)
              asm.sta(asm.abs_y(memory[STATES], STOPPING))
              asm.label("rt_sfx_request_ask")
              asm.lda(at.call(ASKED_EFFECT))
              asm.jsr(asm.abs("rt_sfx_select"))
              asm.lda(1)
              asm.sta(asm.abs_y(memory[STATES], ASKED))
              asm.rts
              asm.label("rt_sfx_request_none")
              asm.lda(0)
              asm.rts
            end

            # rt_sfx_above and rt_sfx_below: a frame's effects that outrank the tune, played before its
            # parts, and the rest, after (Reference::Player#advance). rt_sfx_above takes up first what
            # was asked for since the last frame. rt_sfx_select_ranked: the effect at place WALK of the rank
            # order, selected, its number in A.
            def emit_passes(asm, at, memory, count)
              m = SNES::Music
              asm.label("rt_sfx_above")
              count.times do |e|
                asm.lda(asm.abs(memory[STATES], (e * STATE_BYTES) + ASKED))
                asm.sta(asm.abs(memory[STATES], (e * STATE_BYTES) + ASKED_NOW))
                asm.stz(asm.abs(memory[STATES], (e * STATE_BYTES) + ASKED))
              end
              asm.stz(at.call(TUNE_RANK))
              asm.lda(at.call(Music::PLAYING))
              asm.beq("rt_sfx_above_tune")
              asm.ldx(at.call(Music::SONG))
              asm.lda(asm.long_x("music_data", m::RANK))
              asm.inc
              asm.sta(at.call(TUNE_RANK))
              asm.label("rt_sfx_above_tune")
              emit_pass(asm, at, count, "rt_sfx_above", above: true)

              asm.label("rt_sfx_below")
              emit_pass(asm, at, count, "rt_sfx_below", above: false)

              asm.label("rt_sfx_select_ranked")
              asm.lda(asm.long("music_data", m::BY_RANK_AT))
              asm.inc
              asm.inc # past how many there are
              asm.sta(at.call(TABLE_AT))
              asm.lda(at.call(WALK))
              asm.asl
              asm.clc
              asm.adc(at.call(TABLE_AT))
              asm.tax
              asm.lda(asm.long_x("music_data"))
              asm.pha
              asm.jsr(asm.abs("rt_sfx_select"))
              asm.pla
              asm.rts
            end

            # One pass over the effects in rank order, playing those that outrank the tune (+above+),
            # or those that do not: an effect outranks it when its rank's place is at least TUNE_RANK.
            def emit_pass(asm, at, count, name, above:)
              asm.stz(at.call(WALK))
              asm.label("#{name}_next")
              asm.jsr(asm.abs("rt_sfx_select_ranked"))
              asm.lda(asm.long_x("music_data", SNES::Music::EFFECT_RANK))
              asm.cmp(at.call(TUNE_RANK))
              asm.branch_long(above ? :bcc : :bcs, "#{name}_walk") # past an effect on the other side of the tune
              asm.jsr(asm.abs("rt_sfx_frame"))
              asm.label("#{name}_walk")
              asm.inc(at.call(WALK))
              asm.lda(at.call(WALK))
              asm.cmp(count)
              asm.bcc("#{name}_next")
              asm.rts
            end

            # rt_sfx_frame: one frame of the effect selected (Reference::Player#play_effect_frame).
            # Cut off, it stops first; asked for, it starts from its first note; at its end, it lets
            # go of its voices; sounding, each part plays its note whose frame has come, on the voice
            # its rank lets it take.
            def emit_frame(asm, at, memory, level_at)
              m = SNES::Music
              state = ->(field) { asm.abs_y(memory[STATES], field) }
              asm.label("rt_sfx_frame")
              asm.lda(state.call(STOPPING))
              asm.beq("rt_sfx_frame_not_cut")
              asm.lda(0)
              asm.sta(state.call(STOPPING))
              asm.jsr(asm.abs("rt_sfx_finish"))
              asm.ldy(at.call(STATE))
              asm.label("rt_sfx_frame_not_cut")
              asm.lda(state.call(ASKED_NOW))
              asm.beq("rt_sfx_frame_not_asked")
              asm.lda(1)
              asm.sta(state.call(RUNNING))
              asm.lda(0)
              asm.sta(state.call(FRAME))
              SNES::Music::PARTS.times { |p| asm.sta(state.call(CURSORS + (p * 2))) }
              asm.ldx(at.call(RECORD))
              asm.lda(asm.long_x("music_data", m::EFFECT_START_LOG))
              asm.tax
              asm.jsr(asm.abs("rt_sound_group"))
              asm.bra("rt_sfx_frame_sounding")
              asm.label("rt_sfx_frame_not_asked")
              asm.lda(state.call(RUNNING))
              asm.beq("rt_sfx_frame_sounding")
              asm.ldx(at.call(RECORD))
              asm.lda(state.call(FRAME))
              asm.cmp(asm.long_x("music_data", m::EFFECT_LENGTH))
              asm.bcc("rt_sfx_frame_sounding")
              asm.jsr(asm.abs("rt_sfx_finish"))
              asm.label("rt_sfx_frame_sounding")
              asm.ldy(at.call(STATE))
              asm.lda(state.call(RUNNING))
              asm.bne("rt_sfx_frame_parts")
              asm.rts
              asm.label("rt_sfx_frame_parts")
              asm.ldx(at.call(RECORD))
              asm.lda(asm.long_x("music_data", m::EFFECT_PART_COUNT))
              asm.sta(at.call(PARTS))
              asm.stz(at.call(PART))
              asm.label("rt_sfx_frame_part")
              asm.lda(at.call(PART))
              asm.cmp(at.call(PARTS))
              asm.branch_long(:bcs, "rt_sfx_frame_done")
              asm.jsr(asm.abs("rt_sfx_entry"))
              asm.lda(at.call(PART)) # its next note
              asm.asl
              asm.clc
              asm.adc(at.call(STATE))
              asm.tay
              asm.lda(asm.abs_y(memory[STATES], CURSORS))
              asm.cmp(asm.long_x("music_data", m::NOTE_COUNT))
              asm.branch_long(:bcs, "rt_sfx_frame_next")
              Music.emit_times(asm, m::NOTE_BYTES)
              asm.clc
              asm.adc(asm.long_x("music_data", m::NOTES_AT))
              asm.sta(at.call(NOTE))
              asm.tax
              asm.lda(asm.long_x("music_data", m::NOTE_FRAME))
              asm.ldy(at.call(STATE))
              asm.cmp(state.call(FRAME))
              asm.branch_long(:bne, "rt_sfx_frame_next")
              asm.lda(at.call(PART))
              asm.asl
              asm.clc
              asm.adc(at.call(STATE))
              asm.tax
              asm.inc(asm.abs_x(memory[STATES], CURSORS))
              asm.ldx(at.call(RECORD))
              asm.lda(asm.long_x("music_data", m::EFFECT_RANK))
              emit_claim_call(asm, memory, entry: ENTRY, note: NOTE)
              asm.branch_long(:beq, "rt_sfx_frame_next")
              if level_at # the tune's note there is no longer held for a new level to reach
                asm.lda(at.call(CLAIM_CHANNEL))
                asm.jsr(asm.abs("rt_music_unhold"))
              end
              asm.ldx(at.call(NOTE))
              asm.lda(asm.long_x("music_data", m::NOTE_HEAD))
              asm.tax
              asm.jsr(asm.abs("rt_sound_group"))
              asm.ldx(at.call(NOTE))
              asm.lda(asm.long_x("music_data", m::NOTE_TAIL))
              asm.tax
              asm.jsr(asm.abs("rt_sound_group"))
              asm.label("rt_sfx_frame_next")
              asm.inc(at.call(PART))
              asm.brl("rt_sfx_frame_part")
              asm.label("rt_sfx_frame_done")
              asm.ldy(at.call(STATE))
              asm.lda(state.call(FRAME))
              asm.inc
              asm.sta(state.call(FRAME))
              asm.rts

              # rt_sfx_entry: ENTRY and X = where part PART of the effect selected is.
              asm.label("rt_sfx_entry")
              asm.lda(at.call(PART))
              Music.emit_times(asm, m::PART_BYTES)
              asm.clc
              asm.adc(at.call(RECORD))
              asm.clc
              asm.adc(m::EFFECT_RECORD_BYTES)
              asm.sta(at.call(ENTRY))
              asm.tax
              asm.rts
            end

            # rt_sfx_finish: the effect selected over (Reference::Player#finish_effect): not sounding,
            # and every voice it still holds free and quiet, in the order the voices were first held,
            # each through its part's group for letting the voice go.
            def emit_finish(asm, at, memory)
              m = SNES::Music
              asm.label("rt_sfx_finish")
              asm.ldy(at.call(STATE))
              asm.lda(0)
              asm.sta(asm.abs_y(memory[STATES], RUNNING))
              asm.ldx(at.call(RECORD))
              asm.lda(asm.long_x("music_data", m::EFFECT_RANK))
              asm.sta(at.call(RELEASE_RANK))
              asm.stz(at.call(RELEASE_WALK))
              asm.label("rt_sfx_finish_next")
              asm.lda(at.call(RELEASE_WALK))
              asm.cmp(at.call(HOLDER_END))
              asm.bcs("rt_sfx_finish_done")
              asm.tax
              asm.lda(asm.abs_x(memory[HOLDER_ORDER]))
              asm.sta(at.call(RELEASE_CHANNEL))
              asm.dec
              asm.asl
              asm.tay
              asm.lda(asm.abs_y(memory[HOLDERS]))
              asm.cmp(at.call(RELEASE_RANK))
              asm.bne("rt_sfx_finish_walk")
              asm.lda(0)
              asm.sta(asm.abs_y(memory[HOLDERS]))
              # Its part on that voice, whose group lets the voice go.
              asm.ldx(at.call(RECORD))
              asm.lda(asm.long_x("music_data", m::EFFECT_PART_COUNT))
              asm.sta(at.call(PARTS))
              asm.stz(at.call(PART))
              asm.label("rt_sfx_finish_find")
              asm.lda(at.call(PART))
              asm.cmp(at.call(PARTS))
              asm.bcs("rt_sfx_finish_walk")
              asm.jsr(asm.abs("rt_sfx_entry"))
              asm.lda(asm.long_x("music_data", m::CHANNEL))
              asm.cmp(at.call(RELEASE_CHANNEL))
              asm.beq("rt_sfx_finish_found")
              asm.inc(at.call(PART))
              asm.bra("rt_sfx_finish_find")
              asm.label("rt_sfx_finish_found")
              asm.lda(asm.long_x("music_data", m::EFFECT_RELEASE))
              asm.tax
              asm.jsr(asm.abs("rt_sound_group"))
              asm.label("rt_sfx_finish_walk")
              asm.inc(at.call(RELEASE_WALK))
              asm.inc(at.call(RELEASE_WALK))
              asm.bra("rt_sfx_finish_next")
              asm.label("rt_sfx_finish_done")
              asm.rts
            end

            # rt_sfx_claim: may a note of rank CLAIM_RANK sound on CLAIM_CHANNEL? Yes (A = 1) when
            # nobody holding it outranks it, and then it holds the voice while it sounds
            # (CLAIM_SOUNDS), where a rest lets it go; nought otherwise
            # (Reference::Player#claim_channel).
            def emit_claim_routine(asm, at, memory)
              asm.label("rt_sfx_claim")
              asm.lda(at.call(CLAIM_CHANNEL))
              asm.dec
              asm.asl
              asm.tay
              asm.lda(asm.abs_y(memory[HOLDERS]))
              asm.cmp(at.call(CLAIM_RANK))
              asm.beq("rt_sfx_claim_taken")
              asm.bcs("rt_sfx_claim_refused")
              asm.label("rt_sfx_claim_taken")
              asm.lda(at.call(CLAIM_SOUNDS))
              asm.beq("rt_sfx_claim_hold")
              asm.lda(at.call(CLAIM_RANK))
              asm.label("rt_sfx_claim_hold")
              asm.sta(asm.abs_y(memory[HOLDERS]))
              asm.lda(asm.abs_y(memory[HOLDER_SEEN]))
              asm.bne("rt_sfx_claim_known")
              asm.lda(1)
              asm.sta(asm.abs_y(memory[HOLDER_SEEN]))
              asm.ldx(at.call(HOLDER_END))
              asm.lda(at.call(CLAIM_CHANNEL))
              asm.sta(asm.abs_x(memory[HOLDER_ORDER]))
              asm.inx
              asm.inx
              asm.stx(at.call(HOLDER_END))
              asm.label("rt_sfx_claim_known")
              asm.lda(1)
              asm.rts
              asm.label("rt_sfx_claim_refused")
              asm.lda(0)
              asm.rts
            end

            # rt_sfx_select: the effect numbered A selected — EFFECT, RECORD and X where its record is,
            # STATE and Y where its state is.
            def emit_select(asm, at, memory)
              asm.label("rt_sfx_select")
              asm.sta(at.call(EFFECT))
              Music.emit_times(asm, STATE_BYTES)
              asm.sta(at.call(STATE))
              asm.lda(at.call(EFFECT))
              asm.asl
              asm.clc
              asm.adc(asm.long("music_data", SNES::Music::EFFECTS_AT))
              asm.tax
              asm.lda(asm.long_x("music_data"))
              asm.sta(at.call(RECORD))
              asm.tax
              asm.ldy(at.call(STATE))
              asm.rts
            end
          end
        end
      end
    end
  end
end
