# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class Reference
        # THE VOICES SEVERAL RECORDED SOUNDS SHARE — the reference backend's stand-in for the
        # software mixer the console runs.
        #
        # On the console the CPU adds every sounding recording together itself, a slice of sound
        # per frame, because the sampled-audio hardware plays one stream (see GBA::Mixer). None
        # of that arithmetic matters here: what a test asks is WHICH sounds are playing and
        # which were lost, so this keeps the voices and nothing else. A voice ages by a frame
        # rather than by a sample, and that is the whole model.
        #
        # THE VOICES ARE SHARED between the game's own sounds and a song's recorded parts, each
        # taking one only while it sounds. A slot's +owner+ says whose it is: +:game+, or a
        # song's part by its lane number. Who gives way when they run out is a stated rule both
        # backends keep — see #take_for_music.
        #
        # It calls nothing back. The interpreter hands it a log to write what happened into, and
        # values the IR carries are worked out before they arrive — the same bargain
        # {Framebuffer} makes, and what keeps the interpreter from being the only thing that
        # knows how sound works.
        class Mixer
          # The most samples that sound at once — read from {Sound}, where the two backends keep
          # the promises they make to each other, rather than written down again here. A new
          # play past this is dropped rather than stealing one already sounding (safe and quiet
          # — a game rarely needs more).
          MAX_VOICES = Sound::MIXER_VOICES

          # ONE SOUNDING VOICE: the sample it is playing, whose it is, whether it loops, how
          # loud, at what pitch, how many frames it has left of the recording and how many it
          # started with, and its ticket.
          #
          # A Struct and not a Data, which is the one place this codebase reaches for one: every
          # sounding voice has +frames_left+ taken off it on every frame, so an immutable record
          # would mean building a new one per voice per frame for nothing. Named fields either
          # way, so a misspelt one raises where a Hash key would have read as nil.
          #
          # +ticket+ says which play started it, so the one playing longest is known when a
          # song's note needs a voice. It is [loops?, count] so that a sound which loops sorts
          # after every one-shot — a loop never ends by itself, so it gives way last.
          Voice = Struct.new(:name, :owner, :loop, :volume, :pitch, :frames_left, :frames_total,
                             :ticket, keyword_init: true)

          # Whose a voice is, when it is not a song's.
          GAME = :game

          # The most that ever sounded at once — how much polyphony the run really used.
          attr_reader :peak

          # +log+ is the interpreter's own list of observable audio events, written into rather
          # than owned, so everything a run made a noise about stays in one place and in order.
          def initialize(log:)
            @log = log
            @slots = Array.new(MAX_VOICES)
            @samples = {}   # name -> Assets::Sample
            @tickets = 0    # how many sounds the game has started, for the next ticket
            @peak = 0
            @drops = 0      # plays that found every voice busy and were dropped
            @drops_music = 0 # ...and the most voices a song held at one of those moments
          end

          # A `sample` declaration was reached. Gathered up front, like a func body, so playing
          # one declared later still works.
          def declare(name, info)
            @samples[name] = info
          end

          def sample_info(name)
            @samples[name] ||
              raise(ProgramError, "play_sample of undefined sample #{name.inspect}")
          end

          # --- what a test reads back ---

          # The names of the samples sounding right now — one entry per voice, so the same
          # sample played twice shows up twice. Lets a test see that several sounds really
          # overlap in the mix instead of cutting each other off. In the order of the voices,
          # which is the order the console keeps them in: the game's sounds and the music's
          # notes share them, so they come in whatever order they took them.
          def sounding = @slots.compact.map(&:name)

          # The level a currently-sounding sample is playing at (its first voice), or nil if it
          # is not playing — so a test can see `play(volume:)` took effect.
          def volume_of(name)
            @slots.compact.find { |v| v.owner == GAME && v.name == name }&.volume
          end

          # WHAT THIS RUN COULD NOT PLAY: how many plays found every voice busy and were
          # dropped, and how the song and the game were splitting the voices at the worst of
          # them. The same shape the console's own count is read back in
          # (Verifier#sound_drops), so the two backends' answers meet in one equality.
          def drops
            SoundDrops::Reading.new(dropped: @drops, music_held: @drops_music, voices: MAX_VOICES)
          end

          # --- the game's own sounds ---

          # Start a sample sounding: add a voice to the mix (samples play together, they do not
          # cut each other off), remembering how many frames it runs for (from its length and
          # rate) so a looping voice can re-trigger itself at the end. A one-shot voice simply
          # falls silent there. It takes the first free voice, as the console does; with none
          # free, the new one is dropped.
          def start(node)
            info = sample_info(node.name)
            @log << [:sample, node.name]
            free = @slots.index(nil) or return note_drop

            # A pitched voice reads its sample faster (higher notes) or slower (lower), so it
            # plays out in proportionally fewer or more frames.
            frames = frames_for(info, pitch_ratio(node.pitch, info.note))
            @slots[free] = Voice.new(name: node.name, owner: GAME, loop: node.loop,
                                     volume: node.volume, pitch: node.pitch,
                                     frames_left: frames, frames_total: frames,
                                     ticket: [node.loop ? 1 : 0, @tickets += 1])
            count_the_voices
          end

          # Stop a sample: drop its voices from the mix (or every voice of the game's, if no
          # name is given). A note the music is playing is the music's to stop.
          def stop(name)
            @slots.map! { |v| v if v.nil? || v.owner != GAME || (name && v.name != name) }
            @log << [:stop_sample]
          end

          # Age every sound of the game's by one frame. When one plays out, a looping one starts
          # over — logged again, so the loop shows up in the audio log — and a one-shot leaves
          # the mix.
          def advance
            @slots.each_with_index do |voice, slot|
              next unless voice && voice.owner == GAME

              voice.frames_left -= 1
              next if voice.frames_left.positive?

              if voice.loop
                voice.frames_left = voice.frames_total
                @log << [:sample, voice.name]
              else
                @slots[slot] = nil
              end
            end
          end

          # --- the voices a song's recorded parts borrow ---

          # WHICH VOICE A SONG'S NOTE GETS, by the rule the console's player keeps
          # (GBA::Mixer#emit_music_voice_routine): the part's own voice if it is still sounding,
          # or the first free one, or — with none free — the voice of the game's sound that has
          # been playing longest, a one-shot before a loop. That sound is cut short.
          #
          # +lane+ is the part, by number. +name+ is the recording and +frequency+ the note, out
          # of which comes how many frames the recording lasts read at that pitch: a higher note
          # reads it faster, so it runs out sooner.
          def take_for_music(lane, name, frequency)
            info = @samples[name] ||
                   raise(ProgramError, "a song part plays #{name.inspect}, which is not declared")
            slot = @slots.index { |v| v && v.owner == lane } || @slots.index(nil) ||
                   @slots.each_index.select { |i| @slots[i].owner == GAME }.min_by { |i| @slots[i].ticket }
            frames = frames_for(info, frequency / Music::NOTE_FREQUENCIES.fetch(info.note || :C4).to_f)
            @slots[slot] = Voice.new(name: name, owner: lane, frames_left: frames)
          end

          # A part rests: its voice, if it still has one, goes quiet and is free for anybody.
          def release_music(lane)
            slot = @slots.index { |v| v && v.owner == lane }
            @slots[slot] = nil if slot
          end

          # Every voice a song holds is freed — what changing tune, or stopping, does.
          def release_all_music
            @slots.map! { |voice| voice if voice.nil? || voice.owner == GAME }
          end

          # A frame of the recorded parts' voices: a recording that has played out stops.
          def age_music
            @slots.map! do |voice|
              next voice unless voice && voice.owner != GAME

              voice.frames_left -= 1
              voice if voice.frames_left.positive?
            end
          end

          # Note how much polyphony is in use. Called wherever a voice is taken, by the game or
          # by a song, so the peak is the true one.
          def count_the_voices = @peak = [@peak, @slots.count(&:itself)].max

          private

          # How many whole frames a recording lasts, read at +ratio+ times its own speed. At
          # least one, so a very short clip still sounds.
          def frames_for(info, ratio)
            [(info.length.to_f / (info.rate * ratio) * FRAME_RATE).ceil, 1].max
          end

          # How much faster (>1) or slower (<1) a voice reads its sample when played at +pitch+
          # instead of the sample's recorded note +base+ — the frequency ratio. nil pitch plays
          # it at its recorded pitch (ratio 1).
          def pitch_ratio(pitch, base)
            return 1.0 unless pitch

            notes = Music::NOTE_FREQUENCIES
            notes.fetch(pitch).to_f / notes.fetch(base || :C4)
          end

          # A SOUND WAS JUST LOST — every voice was busy, so this play is dropped rather than
          # cutting one off. Counted here so a test can hold the interpreter's answer against
          # the console's, which is measured the same way (see {SoundDrops}, and
          # GBA::Mixer#emit_note_drop for the console's half). A drop means every voice was
          # sounding, so the only thing worth writing down is how the song and the game were
          # splitting them.
          def note_drop
            @drops += 1
            @drops_music = [@drops_music, @slots.compact.count { |v| v.owner != GAME }].max
            nil
          end
        end
      end
    end
  end
end
