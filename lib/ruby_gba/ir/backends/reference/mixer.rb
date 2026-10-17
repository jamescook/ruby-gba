# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class Reference
        # THE VOICES SEVERAL RECORDED SOUNDS SHARE, and the sound they make together — the same
        # software mixer the console runs, written in Ruby.
        #
        # On the console the CPU adds every sounding recording together itself, a slice of sound
        # per frame, because the sampled-audio hardware plays one stream (see GBA::Mixer). This
        # does the same arithmetic, sample by sample, and keeps each frame's slice (#slices) —
        # the very bytes the cartridge writes, held to them by a test. So it is also where that
        # arithmetic is written down in Ruby, for anything else that has to make the same sound.
        #
        # ONE FRAME'S SLICE, as the cartridge makes it (#mix). Each sounding voice reads its
        # recording from where it got to, one sample for each sample of the slice, and adds the
        # sample times its loudness, over 512, into a running total for that place in the slice.
        # How fast it reads is its STEP: how many samples of the recording go by for each sample
        # of the slice, in 65536ths, so a note pitched up reads faster and one recorded at
        # another rate is read at the rate the mix runs at. The part of a sample that does not
        # make a whole one is carried, frame to frame. A voice that reaches the end of its
        # recording reads back by however far its recording holds from, or, with nothing to go
        # back to, stops there and gives its voice back. When every voice is in, each total is
        # held to what a byte holds, -128 to 127, which is the clamp: on the finished sum, so a
        # loud voice and a loud one of the other sign cancel. A frame with no voice sounding is
        # silence.
        #
        # A NOTE WITH A SHAPE slides its loudness rather than stepping it (see #step_envelopes):
        # once a frame the shape says where the note should be by the frame's end, and the
        # loudness moves there a little with every sample. That loudness, its GAIN, keeps sixteen
        # bits of fraction, since a slow fade moves it by much less than one a sample.
        #
        # THE VOICES ARE SHARED between the game's own sounds, a song's recorded parts and a sound
        # effect's, each taking one only while it sounds. A slot's +owner+ says whose it is:
        # +:game+, a song's part by its lane number, or an effect's part as [effect, lane]. Who
        # gives way when they run out is a stated rule both backends keep — see #start_music_note.
        #
        # It calls nothing back. The interpreter hands it a log to write what happened into, and
        # values the IR carries are worked out before they arrive — the same bargain
        # {Framebuffer} makes. What both mixers have to work out alike, such as how fast a note
        # reads its recording, is asked of IR::Mixing, so neither is the only one that knows.
        class Mixer
          # The most samples that sound at once — read from {Sound}, where the two backends keep
          # the promises they make to each other, rather than written down again here. A new
          # play past this is dropped rather than stealing one already sounding (safe and quiet
          # — a game rarely needs more).
          MAX_VOICES = Audio::Sound::MIXER_VOICES

          # THE MIX'S OWN NUMBERS, the ones the cartridge's mixer uses too, which is what this one
          # has to agree with byte for byte (see Sound::MIX_LEVELS for what each is).
          LOUDNESS = Audio::Sound::MIX_LEVELS
          VOL_SHIFT = Audio::Sound::VOL_SHIFT
          STEP_SHIFT = Audio::Sound::STEP_SHIFT
          GAIN_FRACTION = Audio::Sound::GAIN_FRACTION
          RAMP_SPLIT = Audio::Sound::RAMP_SPLIT
          LOUDNESS_TO_GAIN = Audio::Sound::LOUDNESS_TO_GAIN

          # ONE SOUNDING VOICE: the sample it is playing, whose it is, the level a game's play
          # asked for, and its ticket — and where it has got to in its recording.
          #
          # A Struct and not a Data, which is the one place this codebase reaches for one: every
          # sounding voice moves on through its recording thousands of times a frame, so an
          # immutable record would mean building a new one per sample for nothing. Named fields
          # either way, so a misspelt one raises where a Hash key would have read as nil.
          #
          # +data+ is the recording, as signed samples; +position+ is the sample it reads next,
          # +fraction+ the part of a sample carried toward the next one (out of 65536), and
          # +step+ how far it moves for each sample of the slice (65536 is one). +back+ is how far
          # it reads back at the end of the recording, and 0 for one that stops there.
          # +loudness+ is out of 512, and +gain+ is the loudness the mix really multiplies by, in
          # 256ths with GAIN_FRACTION bits under it, which +ramp+ moves a little each sample while a
          # shaped note slides. A voice with no shape keeps its gain until the music volume moves
          # (see #rescale_music).
          #
          # +ticket+ says which play started it, so the one playing longest is known when a
          # note of a song or an effect needs a voice. It is [loops?, count] so that a sound which loops sorts
          # after every one-shot — a loop never ends by itself, so it gives way last.
          # +rank+ is the rank of the song or effect whose note it is (IR::Tunes.song_rank), and
          # nil for the game's own sound, which ranks below every one of them.
          # +envelope+ and the two beside it are the shape of the note, when it has one: +level+ is
          # how far it has climbed or fallen (0 to Envelope::FULL) and +phase+ which part of the
          # note it is in. A voice with no envelope carries none of it and sounds flat out, which
          # is what every voice did before shapes existed.
          Voice = Struct.new(:name, :owner, :rank, :volume, :ticket, :envelope, :level, :phase,
                             :data, :position, :fraction, :step, :back, :loudness, :gain, :ramp,
                             keyword_init: true)

          # Which part of a note a voice is in. Named where the rule that moves it is
          # ({RubyGBA::Audio::Envelope}), so this backend and the console's own pass cannot drift apart
          # about when a note is over.
          FALLING = RubyGBA::Audio::Envelope::FALLING

          # ...and the frame after a note has fallen to nothing, which the console spends mixing
          # the last of the fade (GBA::Mixer::PHASE_DONE) and this backend spends holding the voice
          # so it is given back on the same frame. Which frame a voice comes free on decides which
          # voice the next note gets, so the two have to agree about it.
          DONE = :done

          # Whose a voice is, when it is not a song's.
          GAME = :game

          # The most that ever sounded at once — how much polyphony the run really used.
          attr_reader :peak

          # EVERY FRAME'S SLICE OF SOUND, oldest first: as many signed samples as the mix makes a
          # frame, the bytes the cartridge's mixer writes. Empty for a program that mixes no
          # recording, which has no mix.
          attr_reader :slices

          # +log+ is the interpreter's own list of observable audio events, written into rather
          # than owned, so everything a run made a noise about stays in one place and in order.
          def initialize(log:)
            @log = log
            @slots = Array.new(MAX_VOICES)
            @samples = {}   # name -> Assets::Sample
            @data = {}      # name -> the recording, as signed samples
            @tickets = 0    # how many sounds the game has started, for the next ticket
            @peak = 0
            @drops = 0      # plays and notes that found every voice busy and were dropped
            @drops_music = 0 # ...and the most voices songs and effects held at one of those moments
            @slices = []
            @clock = nil
            @shapes = false
          end

          # WHAT THE MIX RUNS AT, settled once for the whole program the way the cartridge settles
          # it: the sample clock (its rate, and how many samples it plays a frame), and whether
          # any note in the program has a shape. That second one changes what the mix reads for a
          # note WITHOUT one: in a program that shapes nothing, its loudness; in one that shapes
          # something, its gain, which is set as the note starts and again whenever the music
          # volume moves (see #rescale_music). Until this is said there is no mix.
          def start_clock(clock:, shapes:)
            @clock = clock
            @shapes = shapes
          end

          # A `sample` declaration was reached. Gathered up front, like a func body, so playing
          # one declared later still works. +bytes+ is the recording itself, a byte a sample.
          def declare(name, info, bytes)
            @samples[name] = info
            @data[name] = bytes.unpack("c*")
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

          # WHOSE each of those voices is, in the same order: +:game+, [:song, part] or
          # [effect, part], where a part is counted among the parts that play recordings.
          def owners = @slots.compact.map { |voice| song?(voice) ? [:song, voice.owner] : voice.owner }

          # The level a currently-sounding sample is playing at (its first voice), or nil if it
          # is not playing — so a test can see `play(volume:)` took effect.
          def volume_of(name)
            @slots.compact.find { |v| v.owner == GAME && v.name == name }&.volume
          end

          # WHAT THIS RUN COULD NOT PLAY: how many plays and notes found every voice busy and were
          # dropped, and how the music and the game were splitting the voices at the worst of
          # them. The same shape the console's own count is read back in
          # (Verifier#sound_drops), so the two backends' answers meet in one equality.
          def drops
            Diagnostics::SoundDrops::Reading.new(dropped: @drops, music_held: @drops_music, voices: MAX_VOICES)
          end

          # --- the game's own sounds ---

          # Start a sample sounding: add a voice to the mix (samples play together, they do not
          # cut each other off), from the top of its recording. One asked to loop reads back to
          # where its recording holds from, or to its start, when it reaches the end; a one-shot
          # falls silent there. It takes the first free voice, as the console does; with none
          # free, the quietest note of a song or an effect that is falling away (see
          # #start_music_note); with none of those either, the new one is dropped.
          def start(node)
            info = sample_info(node.name)
            @log << [:sample, node.name]
            free = @slots.index(nil) || quietest_releasing_slot or return record_drop

            frequency = Audio::Music::NOTE_FREQUENCIES.fetch(node.pitch || info.note || :C4)
            back = node.loop ? (info.loop_length.positive? ? info.loop_length : info.length) : 0
            @slots[free] = Voice.new(name: node.name, owner: GAME, volume: node.volume,
                                     ticket: [node.loop ? 1 : 0, @tickets += 1],
                                     **recording_fields(node.name, frequency, back,
                                                        LOUDNESS.fetch(node.volume, LOUDNESS[:full]), info.envelope))
            record_peak_voices
          end

          # A VOICE AT THE TOP OF RECORDING +name+, read at +frequency+, going +back+ at its end,
          # at +loudness+ out of 512 and shaped by +envelope+. One with a shape starts at nothing and
          # climbs, its gain at nothing until the shape's first frame sets it; one without carries
          # no shape at all and sounds flat out from its first sample.
          def recording_fields(name, frequency, back, loudness, envelope)
            shape = envelope && !envelope.plain? ? envelope : nil
            { envelope: shape, level: shape ? 0 : RubyGBA::Audio::Envelope::FULL,
              phase: RubyGBA::Audio::Envelope::CLIMBING,
              data: @data.fetch(name), position: 0, fraction: 0, back: back,
              step: IR::Mixing.step(@samples.fetch(name), frequency, @clock.rate),
              loudness: loudness, gain: shape ? 0 : loudness << LOUDNESS_TO_GAIN, ramp: 0 }
          end

          # Stop a sample: drop its voices from the mix (or every voice of the game's, if no
          # name is given). A note the music is playing is the music's to stop.
          def stop(name)
            @slots.map! { |v| v if v.nil? || v.owner != GAME || (name && v.name != name) }
            @log << [:stop_sample]
          end

          # ONE FRAME'S SLICE OF SOUND (see the class's own note for what each step is): every
          # sounding voice read for a frame's worth of samples, summed, and each sum held to a
          # byte. A voice that reaches the end of its recording with nowhere to read back to
          # gives its voice back there; a game's sound that reads back logs it, so a loop shows
          # up in the audio log each time round.
          def mix
            return unless @clock

            totals = Array.new(@clock.samples_a_frame, 0)
            @slots.each_with_index do |voice, slot|
              @slots[slot] = nil if voice && !mix_voice(voice, totals)
            end
            @slices << totals.map { |total| total.clamp(-128, 127) }
          end

          # One voice's frame into +totals+. False when its recording ran out partway and it
          # stopped, which is the rest of the frame left out of the totals.
          def mix_voice(voice, totals)
            data = voice.data
            whole = voice.step >> STEP_SHIFT
            part = voice.step & ((1 << STEP_SHIFT) - 1)
            gain = @shapes ? voice.gain : voice.loudness << LOUDNESS_TO_GAIN
            totals.each_index do |at|
              totals[at] += (gain * data[voice.position]) >> (VOL_SHIFT + GAIN_FRACTION)
              gain += voice.ramp
              voice.fraction += part
              voice.position += whole + (voice.fraction >> STEP_SHIFT)
              voice.fraction &= (1 << STEP_SHIFT) - 1
              next if voice.position < data.length
              return false if voice.back.zero?

              # As many times as it takes to be inside the recording again, as the cartridge
              # does. Once is all a step ever needs unless it is longer than the stretch a
              # recording holds over — a short hold, read high.
              voice.position -= voice.back while voice.position >= data.length
              @log << [:sample, voice.name] if voice.owner == GAME
            end
            voice.gain = gain
            true
          end

          # --- the voices the recorded parts of songs and sound effects borrow ---

          # WHICH VOICE A NOTE OF A SONG OR A SOUND EFFECT GETS, by the rule the console's player
          # keeps (GBA::Mixer#emit_take_music_voice_routine). In order:
          #
          #   1. the part's own voice, if it is still sounding a note with no shape;
          #   2. the first free one;
          #   3. the quietest note falling away, whoever's it is;
          #   4. the voice of the lowest-ranked sound ranked below this note — the game's own sounds
          #      first, since they rank below every song and effect, and of those the one playing
          #      longest, a one-shot before a loop. That sound is cut short.
          #
          # With none of those the note is not played, and this answers nil. That is the part of
          # the rule a song on its own never reaches, having fewer recorded parts than there are
          # voices; it is a sound effect ranked above the song, or the song above an effect, that
          # can fill them. Another part of the same song or effect has the same rank, so is never
          # taken.
          #
          # A part's sounding note WITH a shape is not taken over: its note ends here, and it falls
          # away on its own voice while the new note takes another. Taking it over would stop the
          # old wave dead, which is the click the shape is there to remove.
          #
          # +owner+ is the part (a song's lane number, or [effect, lane]) and +rank+ the rank of its
          # song or effect. +name+ is the recording and +frequency+ the note, which is how fast it
          # is read: a higher note reads it faster, so it runs out sooner — unless the recording
          # HOLDS, and then a note reads round its hold point for as long as it lasts. +loudness+
          # is out of 512. +envelope+ is the shape this note was asked for — the note's own, or its
          # part's. A note that asks for none takes whatever the recording itself was declared
          # with.
          def start_music_note(owner:, rank:, name:, frequency:, loudness:, envelope:)
            info = @samples[name] ||
                   raise(ProgramError, "a part plays #{name.inspect}, which is not declared")
            own = sounding_slot(owner)
            own = nil if own && start_release!(@slots[own])
            slot = own || @slots.index(nil) || quietest_releasing_slot || lowest_ranked_slot_below(rank) or return record_drop
            @slots[slot] = Voice.new(name: name, owner: owner, rank: rank,
                                     **recording_fields(name, frequency, info.loop_length, loudness,
                                                        envelope || info.envelope))
          end

          # THE MUSIC VOLUME HAS MOVED: the voice sounding +owner+'s note, if it still has one,
          # plays it at +loudness+ from now on. A note falling away is an earlier one, and is
          # left alone. True when the part had a note sounding to rescale.
          #
          # What the mix reads is the loudness itself in a program that shapes no note, so there
          # the note is heard at the new loudness from the next frame. In one that shapes a note,
          # the mix reads a gain the shape works out once a frame — and a note with no shape has
          # no shape to work it out, so its gain is set here, as it was when the note started.
          def rescale_music(owner, loudness)
            slot = sounding_slot(owner) or return false
            voice = @slots[slot]
            voice.loudness = loudness
            voice.gain = loudness << LOUDNESS_TO_GAIN unless voice.envelope
            true
          end

          # A part rests: its voice, if it still has one, goes quiet and is free for anybody. True
          # when it had one.
          #
          # A SHAPED NOTE IS NOT SILENCED HERE, only told to start falling — it goes on sounding,
          # more quietly each frame, until there is none of it left (see #step_envelopes). That
          # is the whole difference between a note that ends and a note that clicks.
          def release_music(owner)
            slot = sounding_slot(owner)
            return false unless slot

            @slots[slot] = nil unless start_release!(@slots[slot])
            true
          end

          # Every voice the song holds is let go — what changing tune, or stopping, does. The ones
          # with a shape fall away rather than stopping, same as a part's own rest, and the ones
          # already falling carry on as they were. A sound effect's voices are the effect's.
          def release_all_music
            @slots.map! { |voice| voice if voice.nil? || !song?(voice) || releasing?(voice) || start_release!(voice) }
          end

          # The voice sounding a part's note now — not one of its earlier notes falling away.
          def sounding_slot(owner) = @slots.index { |v| v && v.owner == owner && !releasing?(v) }

          # A note of the song's, rather than the game's or a sound effect's.
          def song?(voice) = voice.owner.is_a?(Integer)

          # A note of a song or an effect that has ended and is falling away, or has just finished
          # falling.
          def releasing?(voice) = voice.owner != GAME && [FALLING, DONE].include?(voice.phase)

          # THE QUIETEST OF A SONG'S NOTES FALLING AWAY — the first thing to give way when a voice
          # is wanted and none is free, since it is on its way out already, and cutting the
          # quietest short is the smallest jump. The first of them, when two are as quiet, which is
          # the one the console's walk over its voices keeps.
          def quietest_releasing_slot
            @slots.each_index.select { |i| @slots[i] && releasing?(@slots[i]) }.min_by { |i| @slots[i].level }
          end

          # THE LOWEST-RANKED SOUND RANKED BELOW +rank+ — the game's own first, the one playing
          # longest of those, and then the lowest-ranked note of a song or an effect. The first of
          # them in the order of the voices, when two rank the same, which is the one the console's
          # walk over its voices keeps.
          def lowest_ranked_slot_below(rank)
            ranked = @slots.each_index.select { |i| rank_of(@slots[i]) < rank }
            ranked.min_by { |i| [rank_of(@slots[i]), @slots[i].ticket || [0, 0]] }
          end

          # The game's own sounds rank below every song and effect, whose ranks start at 0.
          def rank_of(voice) = voice.rank || -1

          # Tell a voice its note has ended. True when it has a shape to fall through, so the
          # caller keeps it; false when it has none and simply stops.
          def start_release!(voice)
            return false unless voice.envelope

            voice.phase = FALLING
            true
          end

          # ONE FRAME OF EVERY SOUNDING NOTE'S SHAPE — the counterpart of the pass the console
          # runs between the tune's frame and the mix (GBA::Mixer#emit_envelope_step). The rule
          # itself is neither backend's: it is {RubyGBA::Audio::Envelope}#step, so the two cannot differ
          # about how fast a note fades. A note that has fallen to nothing is over, and its voice
          # goes back on the frame after — the frame the console spends mixing the last of it.
          #
          # Then where the note's gain should be by the end of the frame, and the slide there
          # (see #slide_gain).
          def step_envelopes
            @slots.each_with_index do |voice, slot|
              next unless voice&.envelope
              next @slots[slot] = nil if voice.phase == DONE

              first = voice.phase == RubyGBA::Audio::Envelope::CLIMBING && voice.level.zero?
              voice.level, voice.phase = voice.envelope.step(voice.level, voice.phase)
              voice.phase = DONE if voice.level.zero? && voice.phase == FALLING
              slide_gain(voice, first)
            end
          end

          # THE GAIN A SHAPED NOTE ENDS THE FRAME AT, and the slide to it, one step a sample.
          #
          # The end is the loudness asked for, scaled by the level: a level is a byte and the
          # scale out of 256, so the level's own top bit is added back in, making a full 255 count
          # as 256. The product is a WHOLE number of 256ths, the rest dropped — the loudness's
          # own half a 256th included — which is how a cartridge's own sound engine works a
          # channel's loudness out once a frame, (level x (right + left)) >> 9: so a quiet note
          # falls silent on the frame its whole loudness reaches nothing, while its level is still
          # above it, where a fraction kept would go on adding a step below nothing on every
          # sample below the middle until the level ran out. Below half a level the two are the
          # same sum. Above it they part by the top bit added back: a note held at full is the
          # loudness asked for, where the engine's comes out a step under it, so every game's full
          # notes stay as loud as they were asked. A note's FIRST frame does not slide, it
          # starts there: a recording starts from its own beginning, so there is nothing before
          # it to be smooth with.
          #
          # The slide is the distance shared out over the frame's samples, as a multiply by the
          # share one sample gets (worked out once, as the cartridge is built), with the distance
          # shifted down before it and the product after so that it fits in 32 bits. Shared out in
          # whole steps, it lands off where it was going, so each frame's slide starts from the
          # gain rounded to the nearest whole loudness — and a note at nothing is at nothing, not
          # a little below it.
          def slide_gain(voice, first)
            level = voice.level
            target = ((voice.loudness * (level + (level >> 7))) >> RubyGBA::Audio::Envelope::WHOLE_GAIN_SHIFT) << GAIN_FRACTION
            voice.gain = first ? target : IR::Mixing.nearest_whole_gain(voice.gain)
            share = IR::Mixing.slide_share(@clock.samples_a_frame)
            voice.ramp = (((target - voice.gain) >> RAMP_SPLIT) * share) >> RAMP_SPLIT
          end

          # How loud a sounding voice is right now, out of {RubyGBA::Audio::Envelope}::FULL — its first
          # voice, or nil when it is not sounding at all. What a test reads to see a note fall
          # away instead of stopping.
          def level_of(name)
            @slots.compact.find { |v| v.name == name }&.level
          end

          # Note how much polyphony is in use. Called wherever a voice is taken, by the game or
          # by a song, so the peak is the true one.
          def record_peak_voices = @peak = [@peak, @slots.count(&:itself)].max

          # Written beside what calls them, for reading in order, and nobody else's to call.
          private :recording_fields, :mix_voice, :slide_gain

          private

          # A SOUND WAS JUST LOST — every voice was busy, so this play, or this note of a song or
          # an effect, is dropped rather than cutting off one it may not. Counted here so a test
          # can hold the interpreter's answer against the console's, which is measured the same
          # way (see {SoundDrops}, and GBA::Mixer#emit_count_dropped_sound for the console's half). A drop
          # means every voice was sounding, so the only thing worth writing down is how the music
          # and the game were splitting them.
          def record_drop
            @drops += 1
            @drops_music = [@drops_music, @slots.compact.count { |v| v.owner != GAME }].max
            nil
          end
        end
      end
    end
  end
end
