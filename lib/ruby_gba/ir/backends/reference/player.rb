# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class Reference
        # THE MUSIC PLAYER — the reference backend's counterpart to the one the console runs
        # from the screen's own interrupt (GBA::Audio#emit_music_tick).
        #
        # A song is a set of parts played together, each walking its own list of events, all
        # reading one frame counter so they stay in step. This does the same steps in the same
        # order as the console's player, because that is what makes the two agree on every note
        # — including the awkward moments, which are the end of a song and a part with no voice
        # free to sound on.
        #
        # IT HOLDS THE MIXER, the way GBA::Audio holds GBA::Mixer, and for the same reason: a
        # part that plays a recording sounds each note on one of the mixer's voices. A part on
        # one of the console's OWN voices — the square wave, the wave voice, the noise voice —
        # takes none, which is what makes those parts cheap.
        #
        # It calls nothing back into the interpreter. What it is given is a log to write into,
        # a mixer to sound recordings on, and songs; a number the IR carries is worked out
        # before it arrives (see #wants_number).
        class Player
          # The wave and noise voices' numbers in the console's own count of its voices, which is
          # what the log names a voice by.
          WAVE_CHANNEL = 3
          NOISE_CHANNEL = 4

          # A sound effect sounding: how far into it, and each of its parts' next event. Both move
          # on every frame it plays.
          EffectRun = Struct.new(:frame, :cursors, keyword_init: true)

          def initialize(mixer:, log:)
            @mixer = mixer
            @log = log
            @songs = {}         # name -> :song node
            @lists = {}         # name -> the songs a song list holds, in order
            @passes = {}        # name -> each part's events, first time round and after
            @stops = 0          # how many times the program has said stop_music...
            @stops_seen = 0     # ...and how many of those this has acted on
            @wanted = nil       # the tune the program last named (nil = none)
            @playing = nil      # ...and the one this is on, which catches up each frame
            @frame = 0          # how far into that tune, in frames
            @events = []        # the events each of its parts is walking now
            @cursors = []       # each of its parts' next event
            @sounding = {}      # a voice the song holds a note on -> its written volume (see #hold)
            @level = IR::Tunes::FULL_LEVEL # the music volume the notes sounding were set at
            @effect_lists = {}  # name -> the effects a sound effect list holds, in order
            @effects = []       # every sound effect, in the order declared (see IR::Tunes.effect_rank)
            @asked = []         # the effects the program asked for since the last frame
            @stopping = []      # ...and the effects of a group those cut off, stopped on that frame
            @running = {}       # an effect sounding -> how far into it, and each part's next event
            @holders = Hash.new(0) # a console voice -> the rank of whoever holds it (IR::Tunes.song_rank)
          end

          # A `song`, `song_list` or `sound_effect_list` declaration was reached. Gathered up
          # front, like a func body, so naming one declared later still works.
          def declare(node) = @songs[node.name] = node
          def declare_list(name, songs) = @lists[name] = songs

          def declare_effects(name, effects)
            @effect_lists[name] = effects
            @effects.concat(effects)
          end

          # START effect number +which+ of a list at the next frame — from its first note, whether
          # or not it is sounding already. A number naming no effect plays nothing.
          #
          # AN EFFECT IN A GROUP is decided here, as it is asked for, the way the console decides it
          # (IR::Tunes.priority_of): if another of its group is sounding or already asked for, an effect
          # of lower priority is not played, and one of at least that priority stops that one on
          # the next frame and starts in its place.
          def wants_effect(list, which)
            effects = @effect_lists[list] ||
                      raise(ProgramError, "play_sound_effect of undefined list #{list.inspect}")
            return unless which >= 0 && which < effects.length

            name = effects[which]
            group = group_of(name)
            current = group && @effects.find { |other| group_of(other) == group && current?(other) }
            if current
              return if priority_of(name) < priority_of(current)
              @asked.delete(current)
              @stopping << current
            end
            @asked << name
          end

          # NAME THE TUNE PLAYING NOW. The player takes it up at the next frame, so this can be
          # written once or every frame, from a branch or a scene, and it is the same tune.
          def wants(name)
            @songs[name] || raise(ProgramError, "play_song for undefined song #{name.inspect}")
            @wanted = name
          end

          # ...or name it by its place in a list. +which+ has already been worked out by
          # whoever called, because a number the game computes is the interpreter's business
          # and not this one's. A number naming no song in the list leaves the music as it is.
          def wants_number(list, which)
            songs = @lists[list] ||
                    raise(ProgramError, "play_from_list of undefined list #{list.inspect}")
            @wanted = songs[which] if which >= 0 && which < songs.length
          end

          # No tune. Counted as well as said, so a stop and a play in the same frame still reach
          # the player as a stop — which is how a tune starts over.
          def stop
            @wanted = nil
            @stops += 1
          end

          # ONE FRAME OF THE PLAYER — the same steps, in the same order, as the console's.
          #
          # First it catches up with what the program asked for. A different tune than the one
          # playing silences the old one and starts the new one from its first frame; no tune at
          # all just silences. Asking for the tune already playing changes nothing, which is
          # what lets `play_song` be written every frame.
          #
          # Then each part plays its next note if that note is due on this frame (frequency 0 is
          # a rest), and the frame moves on, wrapping at the song's length so the tune loops —
          # back to its loop frame, where every part carries on from its list for the passes
          # after the first (IR::Tunes#passes).
          #
          # A part that plays a recording sounds each note on a voice of the mixer, which a note
          # starts from the top and a rest stops. The voice ages in the frame it starts, because
          # the console mixes that frame's slice right after the note is started, in the same
          # interrupt.
          #
          # +level+ is the music volume the game last said (see IR::Tunes::LEVEL), or nil for a
          # program that never says one. A change reaches the notes already sounding before any
          # new note is played, which is the order the console does it in.
          #
          # SOUND EFFECTS PLAY AROUND THE SONG, highest rank first (IR::Tunes.effects_by_rank): the
          # effects that outrank the tune before its parts, the rest after. So a note that loses
          # its voice to one due on the same frame is never written at all, rather than written
          # and then covered — whoever writes a voice first on a frame is whoever keeps it.
          def advance(level: nil)
            catch_up
            asked = @asked.uniq
            @asked.clear
            tune = @playing ? IR::Tunes.song_rank(@songs[@playing]) : -1
            above, below = ranked_effects.partition { |_, rank| rank > tune }
            above.each { |name, rank| effect_frame(name, rank, asked) }
            play_the_song(level) if @playing
            below.each { |name, rank| effect_frame(name, rank, asked) }
            @mixer.count_the_voices
          end

          private

          def play_the_song(level)
            follow_the_level(level) if level
            song = @songs[@playing]
            rank = IR::Tunes.song_rank(song)
            recorded = 0
            squares = 0
            song.voices.each_with_index do |part, number|
              kind = IR::Tunes.part_kind(part)
              lane = kind == :recorded ? (recorded += 1) - 1 : nil
              channel = console_channel(kind) { squares += 1 }
              offset, frequency, instrument, volume, envelope = @events[number][@cursors[number]]
              next unless offset == @frame

              # A voice a sound effect holds with a higher rank, or a mixer with no voice this note
              # can have: the part carries on in time, silent here, and is heard again from its
              # next note once there is one.
              shared = channel && kind != :wave
              sounds = sounds?(frequency, volume || part.volume)
              heard = if shared
                        take_voice(channel, rank, sounds: sounds)
                      elsif lane
                        # A rest is heard whether or not the part still had a voice to give back.
                        sound_recording(owner: lane, rank: rank, name: instrument || part.instrument,
                                        frequency: sounds ? frequency : 0, envelope: envelope || part.envelope) ||
                          !sounds
                      else
                        true
                      end
              unless heard
                @cursors[number] += 1
                next
              end

              @log << [:note, @playing, frequency]
              @log << [:voice, channel, @playing, frequency, volume || part.volume] if shared
              if channel && level
                written = frequency.zero? ? 0 : volume || part.volume
                kind == :noise ? log_loudness(channel, written) : hold(channel, written)
              elsif lane && level
                hold([:mixer, lane], frequency.zero? ? 0 : IR::Tunes.mix_loudness(volume || part.volume))
              end
              # A part on the WAVE or NOISE voice: the console makes the sound itself, so no
              # mixer voice is taken — the whole point of putting a part there.
              console_voice(kind, part, frequency) if %i[wave noise].include?(kind)
              @cursors[number] += 1
            end
            come_round(song)
          end

          # Every sound effect with its rank, highest first.
          def ranked_effects
            @ranked_effects ||= IR::Tunes.effects_by_rank(@effects.map { |name| @songs.fetch(name) })
          end

          # WHAT A VOICE A SOUND EFFECT CAN SHARE WAS SET TO — the square voices and the noise voice
          # — is logged as [:voice, channel, who, frequency, volume] whenever the song or an effect
          # writes it, and as a frequency and volume of 0 when an effect's end silences it. A tune
          # that stops logs [:stop_music] instead.
          #
          # ONE SOUND EFFECT'S FRAME. Asked for, it starts from its first note; at its end it lets
          # go of the voices it still holds, silencing them; and sounding, it plays whatever notes
          # are due, on the voices its rank lets it take.
          def effect_frame(name, rank, asked)
            song = @songs.fetch(name)
            # Cut off by another of its group, or of a group and asked for again: it stops first.
            finish_effect(name, rank) if @stopping.delete(name)
            if asked.include?(name)
              @running[name] = EffectRun.new(frame: 0, cursors: Array.new(song.voices.size, 0))
              @log << [:sound_effect, name]
            elsif @running.key?(name) && @running[name].frame >= song.total_frames
              finish_effect(name, rank)
            end
            run = @running[name] or return

            squares = 0
            recorded = 0
            song.voices.each_with_index do |part, number|
              kind = IR::Tunes.part_kind(part)
              channel = console_channel(kind) { squares += 1 }
              lane = kind == :recorded ? (recorded += 1) - 1 : nil
              offset, frequency, instrument, volume, envelope = part.events[run.cursors[number]]
              next unless offset == run.frame

              run.cursors[number] += 1
              if lane
                heard = sound_recording(owner: [name, lane], rank: rank, name: instrument || part.instrument,
                                        frequency: sounds?(frequency, volume || part.volume) ? frequency : 0,
                                        envelope: envelope || part.envelope)
                @log << [:note, name, frequency] if heard
                next
              end
              next unless take_voice(channel, rank, sounds: sounds?(frequency, volume || part.volume))

              @sounding.delete(channel) # the song's note there, if it had one, is gone
              @log << [:note, name, frequency]
              @log << [:voice, channel, name, frequency, volume || part.volume]
              console_voice(kind, part, frequency) if kind == :noise
            end
            run.frame += 1
          end

          # Is this effect its group's one now: asked for — even when it is stopping first, to start
          # again — or sounding and not stopping? It is still sounding on the frame after its last,
          # until the player lets it go.
          def current?(name) = @asked.include?(name) || (@running.key?(name) && !@stopping.include?(name))

          def group_of(name) = @songs.fetch(name).group

          def priority_of(name) = IR::Tunes.priority_of(IR::Tunes.song_rank(@songs.fetch(name)))

          # An effect over: every voice it still holds goes quiet, and is free — a recorded note
          # with a shape falling away rather than stopping, as it would at a rest.
          def finish_effect(name, rank)
            @running.delete(name)
            @holders.select { |_, holder| holder == rank }.each_key do |channel|
              @holders[channel] = 0
              @log << [:note, name, 0]
              @log << [:voice, channel, name, 0, 0]
              @log << [:noise, nil] if channel == NOISE_CHANNEL
            end
            IR::Tunes.recorded_parts(@songs.fetch(name)).times { |lane| @log << [:note, name, 0] if @mixer.release_music([name, lane]) }
          end

          # MAY A NOTE OF THIS RANK SOUND ON +channel+? Yes when nobody holding it outranks it
          # (IR::Tunes.song_rank) — and then it holds the voice while it +sounds+, where a rest or
          # a note at volume 0 lets it go.
          def take_voice(channel, rank, sounds:)
            return false if @holders[channel] > rank

            @holders[channel] = sounds ? rank : 0
            true
          end

          def sounds?(frequency, volume) = frequency.positive? && volume.positive?

          # The tune the program asked for has changed, or it said stop: silence what was
          # playing and start the new one from its first frame. A voice a sound effect holds is
          # the effect's, and is left alone.
          def catch_up
            return if @wanted == @playing && @stops == @stops_seen

            @stops_seen = @stops
            @log << [:stop_music] if @playing
            @holders.each_key { |channel| @holders[channel] = 0 if (@holders[channel] & IR::Tunes::ORDER_MASK).zero? }
            @sounding.clear
            @mixer.release_all_music
            @playing = @wanted
            @frame = 0
            @events = @playing ? passes(@playing).map(&:first) : []
            @cursors = Array.new(@events.size, 0)
          end

          # At the song's end, back to its loop frame, with every part carrying on from the
          # list it uses for the passes after the first.
          def come_round(song)
            @frame += 1
            return if @frame < song.total_frames

            @frame = IR::Tunes.loop_frame(song)
            @events = passes(@playing).map(&:again)
            @cursors.fill(0)
          end

          # THE MUSIC VOLUME HAS MOVED: every voice holding a note takes the new level — a square
          # voice by sounding the note again, since it takes a volume only as a note starts, and
          # the wave voice and a mixer voice simply, since they take one while they play. Either
          # way the voice is now at the new volume, which is what the log says.
          #
          # A recorded part's note is held only while its voice is still sounding it: the
          # recording may have run out, or the note be falling away after a rest, and neither of
          # those is the part's note any more.
          def follow_the_level(level)
            return if level == @level

            @level = level
            @sounding.each do |voice, volume|
              next unless volume.positive?
              next if voice.is_a?(Array) && !@mixer.sounding_note(voice.last)

              log_loudness(voice, volume)
            end
          end

          # The console voice a part sounds on, if the console plays it itself — the square voices
          # counted from 1 in the order the parts are written (the block counts one), and the wave
          # and noise voices, of which there is one each. Nil for a part that plays a recording.
          def console_channel(kind)
            case kind
            when :square then yield
            when :wave then WAVE_CHANNEL
            when :noise then NOISE_CHANNEL
            end
          end

          # A note held on a voice, at the music volume in force: a console voice by its channel,
          # or a recorded part's mixer voice as [:mixer, lane], whose volume is a loudness out of
          # IR::Tunes::MIX_FULL. A rest is a volume of 0. A drum hit is not held: it rings and
          # fades by itself, so a new level waits for the next hit rather than striking this one
          # again.
          def hold(channel, volume)
            @sounding[channel] = volume
            log_loudness(channel, volume)
          end

          def log_loudness(channel, volume)
            @log << [:loudness, channel, IR::Tunes.scaled_volume(volume, @level)]
          end

          # A note on one of the mixer's voices: it starts from the top of recording +name+,
          # shaped by +envelope+ (or the recording itself), and a rest gives the voice back. True
          # when the note got a voice, or the rest had one to give back.
          def sound_recording(owner:, rank:, name:, frequency:, envelope:)
            return @mixer.release_music(owner) if frequency.zero?

            !@mixer.take_for_music(owner: owner, rank: rank, name: name, frequency: frequency,
                                   envelope: envelope).nil?
          end

          # A SONG'S NOTE ON THE WAVE OR NOISE VOICE. The console makes both sounds itself, so
          # there is nothing to mix and nothing to keep — the note is simply what the voice is
          # doing now, which is why a part here costs no mixer voice.
          #
          # Logged in the same shape the `wave` and `noise` VERBS log a sound effect, because
          # they really are the same voice: a game that plays a hit while its drum part is
          # playing one gets whichever came last, and a test that reads the log sees exactly
          # that.
          def console_voice(kind, part, frequency)
            if kind == :wave
              return @log << [:stop_wave] if frequency.zero?

              @log << [:wave, { shape: part.wave, frequency: frequency, volume: part.volume }]
            else
              return @log << [:noise, nil] if frequency.zero?

              @log << [:noise, { pitch: frequency, decay: part.decay,
                                 volume: part.volume, metallic: part.metallic }]
            end
          end

          def passes(name) = @passes[name] ||= IR::Tunes.passes(@songs[name])
        end
      end
    end
  end
end
