# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBC
        module Runtime
          # THE SOUND EFFECTS, played over the song by the music player (Runtime::Music) in the
          # frame's interrupt, with the same steps in the same order as the interpreter's player
          # (Reference::Player): a short tune that plays once, from its first note, when the game
          # asks for it.
          #
          # The song and the effects share the console's four voices. Whoever has the higher RANK
          # sounds on a voice they both want (IR::Tunes.song_rank): each voice keeps the rank of
          # whoever holds it, as a byte (GBC::Music#rank), and a note takes a voice only from a
          # rank no higher than its own. A frame plays the effects that outrank the song before the
          # song's parts and the rest after, so whoever writes a voice first on a frame keeps it.
          #
          # Everything an effect does is known when the cartridge is built — its notes, its voices,
          # its rank, its group — so each effect has routines of its own here, written out for it,
          # rather than one routine that looks all of that up as it plays.
          #
          # Each effect keeps a few bytes (STATE_BYTES, and two for each part's next note): asked
          # for since the last frame, to be stopped first, sounding, and how far into it.
          module Effects
            HOLDERS = "rt sfx holders" # the rank holding each voice, by voice 1 to 4
            TUNE_RANK = "rt sfx tune rank" # the playing song's rank this frame (0 for none)

            ASKED = 0
            STOPPING = 1
            RUNNING = 2
            FRAME = 3 # 16 bits
            CURSORS = 5 # each part's next note, 16 bits each
            STATE_BYTES = CURSORS

            module_function

            def state(effect) = "rt sfx #{effect.number}"

            def reserve(memory, effects)
              return if effects.empty?

              memory.reserve(HOLDERS, 4)
              memory.reserve(TUNE_RANK, 1)
              effects.each { |effect| memory.reserve(state(effect), STATE_BYTES + (2 * effect.parts.length)) }
            end

            # +effects+ are the game's (GBC::Music#effects), +by_rank+ the same highest rank first.
            def emit(asm, memory, effects, by_rank)
              emit_claim(asm, memory)
              emit_tune_rank(asm, memory)
              emit_sides(asm, memory, by_rank)
              effects.each do |effect|
                emit_frame(asm, memory, effect)
                emit_finish(asm, memory, effect)
                emit_ask(asm, memory, effect, effects, now: false)
                emit_ask(asm, memory, effect, effects, now: true, by_rank: by_rank)
              end
              emit_note(asm, memory)
            end

            # rt_claim: may a note of rank C sound on the part's voice ([PART])? Carry set when a
            # higher rank holds it, and nothing changes. Otherwise the voice is rank C's while the note
            # sounds — a rest, or a note at no volume, gives it to nobody — and carry is clear.
            # HL = the note's tuning, then its volume. Keeps HL and C.
            def emit_claim(asm, memory)
              part = memory[Music::PART]
              holders = memory[HOLDERS]
              asm.label("rt_claim")
              asm.load(:a, [part])
              asm.dec(:a)
              asm.add_a(holders & 0xFF)
              asm.load(:e, :a)
              asm.load(:a, holders >> 8)
              asm.adc_a(0)
              asm.load(:d, :a) # DE = where the voice's holder is kept
              asm.load(:a, [:de])
              asm.load(:b, :a)
              asm.load(:a, :c)
              asm.cp_a(:b)
              asm.ret(:c)
              asm.call("rt_note_sounds")
              asm.load(:a, :c)
              asm.jump_relative(:nz, "rt_claim_held")
              asm.xor_a(:a)
              asm.label("rt_claim_held")
              asm.load([:de], :a)
              asm.and_a(:a) # carry clear
              asm.ret

              # rt_note_sounds: does the note at HL make a sound — not a rest, not at volume 0, and not
              # at a volume the wave voice has no level for? Z when it does not. Keeps HL, DE and C.
              asm.label("rt_note_sounds")
              asm.push(:hl)
              asm.load(:a, [:hli])
              asm.load(:b, :a)
              asm.load(:a, [:hli])
              asm.and_a(:b)
              asm.inc(:a)
              asm.jump_relative(:z, "rt_note_sounds_said")
              asm.load(:a, [:hl])
              asm.and_a(:a)
              asm.jump_relative(:z, "rt_note_sounds_said")
              asm.load(:b, :a)
              asm.load(:a, [part])
              asm.cp_a(GBC::Music::WAVE_VOICE)
              asm.jump_relative(:nz, "rt_note_sounds_said")
              asm.load(:a, :b)
              asm.load(:hl, "rt_music_wave_levels")
              asm.add_a(:l)
              asm.load(:l, :a)
              asm.load(:a, :h)
              asm.adc_a(0)
              asm.load(:h, :a)
              asm.load(:a, [:hl])
              asm.and_a(:a)
              asm.label("rt_note_sounds_said")
              asm.pop(:hl)
              asm.ret
            end

            # rt_music_tune_rank: the playing song's rank, kept for this frame — 0 when none plays,
            # so every effect outranks it, as the interpreter's -1 does.
            def emit_tune_rank(asm, memory)
              asm.label("rt_music_tune_rank")
              asm.load(:a, [memory[Music::PLAYING]])
              asm.and_a(:a)
              asm.jump_relative(:z, "rt_music_tune_rank_said")
              asm.dec(:a)
              asm.load(:e, :a)
              asm.load(:d, 0)
              asm.load(:hl, "music_ranks")
              asm.add_hl(:de)
              asm.load(:a, [:hl])
              asm.label("rt_music_tune_rank_said")
              asm.load([memory[TUNE_RANK]], :a)
              asm.ret
            end

            # rt_sfx_above: a frame of every effect that outranks the song, highest first;
            # rt_sfx_below: every other one, after the song's parts.
            def emit_sides(asm, memory, by_rank)
              { "above" => :nc, "below" => :c }.each do |side, skip|
                asm.label("rt_sfx_#{side}")
                by_rank.each do |effect|
                  past = "rt_sfx_#{side}_past_#{effect.number}"
                  asm.load(:a, [memory[TUNE_RANK]])
                  asm.cp_a(effect.rank)
                  asm.jump(skip, past)
                  asm.call("rt_sfx_frame_#{effect.number}")
                  asm.label(past)
                end
                asm.ret
              end
            end

            # rt_sfx_frame_N: one frame of effect N (Reference::Player#play_effect_frame). Stopped
            # first when its group cut it off; asked for, it starts from its first note, and a run
            # of the cartridge reads it starting at rt_sfx_started_N; past its last frame it lets its
            # voices go; and sounding, each part plays its note whose frame this is, on the voice its
            # rank lets it take.
            def emit_frame(asm, memory, effect)
              n = effect.number
              at = memory[state(effect)]
              frame = at + FRAME
              asm.label("rt_sfx_frame_#{n}")
              asm.load(:a, [at + STOPPING])
              asm.and_a(:a)
              asm.jump(:z, "rt_sfx_#{n}_ask")
              asm.xor_a(:a)
              asm.load([at + STOPPING], :a)
              asm.call("rt_sfx_finish_#{n}")
              asm.label("rt_sfx_#{n}_ask")
              asm.load(:a, [at + ASKED])
              asm.and_a(:a)
              asm.jump(:z, "rt_sfx_#{n}_sounding")
              asm.xor_a(:a)
              asm.load([at + ASKED], :a)
              asm.load(:hl, at + RUNNING)
              asm.load(:a, 1)
              asm.load([:hli], :a)
              asm.xor_a(:a)
              (2 + (2 * effect.parts.length)).times { asm.load([:hli], :a) }
              asm.label("rt_sfx_started_#{n}")
              asm.jump("rt_sfx_#{n}_play")
              asm.label("rt_sfx_#{n}_sounding")
              asm.load(:a, [at + RUNNING])
              asm.and_a(:a)
              asm.ret(:z)
              total = effect.total_frames
              asm.load(:a, [frame + 1])
              asm.cp_a(total >> 8)
              asm.jump(:c, "rt_sfx_#{n}_play")
              asm.jump(:nz, "rt_sfx_finish_#{n}")
              asm.load(:a, [frame])
              asm.cp_a(total & 0xFF)
              asm.jump(:nc, "rt_sfx_finish_#{n}")
              asm.label("rt_sfx_#{n}_play")
              effect.parts.each_with_index { |part, p| emit_effect_part(asm, memory, effect, part, p) }
              asm.load(:hl, frame)
              asm.inc([:hl])
              asm.ret(:nz)
              asm.inc(:hl)
              asm.inc([:hl])
              asm.ret
            end

            # Part +p+ of an effect: its next note, if this is its frame — the part moved on past it,
            # and the note played if the voice is the effect's to take.
            def emit_effect_part(asm, memory, effect, part, p)
              at = memory[state(effect)]
              cursor = at + CURSORS + (2 * p)
              frame = at + FRAME
              past = "rt_sfx_#{effect.number}_part_#{p}_past"
              asm.load(:a, [cursor])
              asm.load(:e, :a)
              asm.load(:a, [cursor + 1])
              asm.load(:d, :a)
              asm.load(:a, :e)
              asm.cp_a(part.count & 0xFF)
              asm.jump_relative(:nz, "rt_sfx_#{effect.number}_part_#{p}_more")
              asm.load(:a, :d)
              asm.cp_a(part.count >> 8)
              asm.jump(:z, past) # no more notes
              asm.label("rt_sfx_#{effect.number}_part_#{p}_more")
              asm.load(:h, :d) # HL = where its notes are + 5 × the number
              asm.load(:l, :e)
              asm.add_hl(:hl)
              asm.add_hl(:hl)
              asm.add_hl(:de)
              asm.load(:de, part.label)
              asm.add_hl(:de)
              asm.load(:a, [frame])
              asm.cp_a([:hl])
              asm.jump(:nz, past)
              asm.inc(:hl)
              asm.load(:a, [frame + 1])
              asm.cp_a([:hl])
              asm.jump(:nz, past)
              asm.inc(:hl)
              asm.push(:hl)
              asm.load(:hl, cursor)
              asm.inc([:hl])
              asm.jump_relative(:nz, "rt_sfx_#{effect.number}_part_#{p}_counted")
              asm.inc(:hl)
              asm.inc([:hl])
              asm.label("rt_sfx_#{effect.number}_part_#{p}_counted")
              asm.pop(:hl)
              part_memory = memory[Music::PART]
              asm.load(:a, part.voice)
              asm.load([part_memory], :a)
              asm.load(:a, part.tone)
              asm.load([part_memory + 1], :a)
              asm.load(:c, effect.rank)
              asm.call("rt_claim")
              asm.jump(:c, past)
              asm.call("rt_sfx_note")
              asm.label(past)
            end

            # rt_sfx_finish_N: effect N is over, and every voice it still holds goes quiet and is
            # nobody's (Reference::Player#finish_effect). A run of the cartridge reads each voice let
            # go at rt_sfx_N_free_V.
            def emit_finish(asm, memory, effect)
              n = effect.number
              asm.label("rt_sfx_finish_#{n}")
              asm.xor_a(:a)
              asm.load([memory[state(effect)] + RUNNING], :a)
              effect.parts.map(&:voice).uniq.each do |voice|
                holder = memory[HOLDERS] + voice - 1
                asm.load(:a, [holder])
                asm.cp_a(effect.rank)
                asm.jump_relative(:nz, "rt_sfx_#{n}_kept_#{voice}")
                asm.xor_a(:a)
                asm.load([holder], :a)
                asm.label("rt_sfx_#{n}_free_#{voice}")
                Music.emit_silence(asm, voice)
                asm.label("rt_sfx_#{n}_kept_#{voice}")
              end
              asm.ret
            end

            # rt_sfx_ask_N: the game asks for effect N, which starts at the next frame
            # (Reference::Player#request_effect). In a group, the one of its group sounding or asked
            # for already decides it: one of higher priority than N keeps on and N is not played, and
            # any other is stopped at the next frame and N starts in its place.
            #
            # rt_sfx_now_N: the same, and N takes its first frame here (`this_frame: true`), with
            # every effect of a group waiting to be cut off cut off here too, in rank order.
            def emit_ask(asm, memory, effect, effects, now:, by_rank: [])
              n = effect.number
              name = now ? "rt_sfx_now_#{n}" : "rt_sfx_ask_#{n}"
              asked = "#{name}_asked"
              asm.label(name)
              asm.di
              if effect.group
                group = effects.select { |other| other.group == effect.group }
                group.each do |other|
                  at = memory[state(other)]
                  asm.load(:a, [at + ASKED])
                  asm.and_a(:a)
                  asm.jump(:nz, "#{name}_current_#{other.number}")
                  asm.load(:a, [at + RUNNING])
                  asm.and_a(:a)
                  asm.jump_relative(:z, "#{name}_not_#{other.number}")
                  asm.load(:a, [at + STOPPING])
                  asm.and_a(:a)
                  asm.jump(:z, "#{name}_current_#{other.number}")
                  asm.label("#{name}_not_#{other.number}")
                end
                asm.jump(asked)
                group.each do |other|
                  asm.label("#{name}_current_#{other.number}")
                  if effect.priority < other.priority
                    asm.reti
                    next
                  end

                  at = memory[state(other)]
                  asm.xor_a(:a)
                  asm.load([at + ASKED], :a)
                  asm.load(:a, 1)
                  asm.load([at + STOPPING], :a)
                  asm.jump(asked)
                end
              end
              asm.label(asked)
              at = memory[state(effect)]
              asm.load(:a, 1)
              asm.load([at + ASKED], :a)
              emit_start_here(asm, memory, effect, by_rank) if now
              asm.reti
            end

            # Reference::Player#start_effect_here: every effect in rank order, the one asked for
            # taking its first frame and every other waiting to be stopped stopped.
            def emit_start_here(asm, memory, effect, by_rank)
              by_rank.each do |other|
                if other == effect
                  asm.call("rt_sfx_frame_#{effect.number}")
                  next
                end

                at = memory[state(other)]
                past = "rt_sfx_now_#{effect.number}_past_#{other.number}"
                asm.load(:a, [at + STOPPING])
                asm.and_a(:a)
                asm.jump_relative(:z, past)
                asm.xor_a(:a)
                asm.load([at + STOPPING], :a)
                asm.call("rt_sfx_finish_#{other.number}")
                asm.label(past)
              end
            end

            # rt_sfx_note: an effect's note at HL — its tuning, then its volume — on the part's voice.
            # It is not the music, so it keeps its own volume, and the voice no longer holds a note of
            # the song's for a new music level to reach. A run of the cartridge reads the note here
            # (GBC::SoundLog).
            def emit_note(asm, memory)
              asm.label("rt_sfx_note")
              asm.load(:a, [:hli])
              asm.load(:e, :a)
              asm.load(:a, [:hli])
              asm.load(:d, :a)
              asm.load(:b, [:hl])
              asm.load(:a, [memory[Music::PART]])
              asm.cp_a(Music::HELD_VOICES + 1)
              asm.jump(:nc, "rt_voice_write")
              asm.dec(:a)
              held = memory[Music::HELD]
              asm.add_a(held & 0xFF)
              asm.load(:l, :a)
              asm.load(:a, held >> 8)
              asm.adc_a(0)
              asm.load(:h, :a)
              asm.xor_a(:a)
              asm.load([:hl], :a)
              asm.jump("rt_voice_write")
            end
          end
        end
      end
    end
  end
end
