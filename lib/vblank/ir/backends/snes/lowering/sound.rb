# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        class Lowering
          # SOUND, lowered for a Super Nintendo: each sound statement the S-DSP register writes its
          # entry of the interpreter's sound log means (DSPWrites), sent one at a time through the
          # sound unit's program (Runtime::Sound's rt_sound_write), and then the entry's number added
          # to the cartridge's own sound log (rt_sound_log), which a run reads back as the
          # interpreter's words (#sound_entries). Mixed into Lowering.
          module Sound
            STATEMENTS = Ractor.make_shareable({ enable_sound: :emit_enable_sound, beep: :emit_beep, noise: :emit_noise,
                                                 wave: :emit_wave, stop_wave: :emit_stop_wave, play_song: :emit_play_song,
                                                 stop_music: :emit_stop_music, play_from_list: :emit_play_from_list,
                                                 play_sound_effect: :emit_play_sound_effect, play_sample: :emit_play_sample,
                                                 stop_sample: :emit_stop_sample })

            # The kinds that reach the sound unit: a program with none of them is built without it.
            KINDS = STATEMENTS.keys.freeze

            # A recording's step (IR::Mixing.step: samples of it a sample of the DSP's, in 65536ths) as
            # the pitch register (fullsnes: $1000 reads one sample of a recording each of the DSP's).
            RECORDING_STEP_TO_PITCH = (1 << VBlank::Audio::Sound::STEP_SHIFT) / DSPWrites::PITCH_ONE

            # What the plays are to the author, for a cartridge too full for them.
            PLAYS = W65816::Holding.new(what: "the game's recordings", fix: "play fewer different recordings")

            # Whether +program+ makes any sound.
            def self.sounds?(program) = program.walk.any? { |node| KINDS.include?(node.kind) }

            # Whether +program+ plays songs, and so carries their player (Runtime::Music).
            def self.songs?(program) = program.walk.any? { |node| %i[song play_song stop_music play_from_list play_sound_effect].include?(node.kind) }

            # Whether +program+ plays recordings of its own, and so carries their count (Runtime::Recordings).
            def self.samples?(program) = program.walk.any? { |node| node.kind == :play_sample }

            # Every entry of the sound log the cartridge can write, by the number it writes.
            def sound_entries = @sound_entries.dup

            # The game's recordings as the sound unit keeps them (Samples.recording), each once for
            # every way it is played — through to its end, or round from where it holds — in the
            # order their source numbers follow the waves'.
            def sound_recordings
              @recordings.map { |name, back| Samples.recording(@samples.fetch(name).bytes, back) }
            end

            # The recordings' names, by the number a place playing one keeps (Runtime::Recordings).
            def recording_names = @samples.keys

            # The table of the game's plays, one row each (Runtime::Recordings), labelled "recording_plays".
            def recordings_section
              asm = W65816.new("recording plays", holds: PLAYS)
              asm.label("recording_plays")
              @plays.each { |row| asm.data_words(row) }
              asm.data_words(0) if @plays.empty? # a label has to be somewhere
              asm.section
            end

            # The wave voice's waveforms this game plays, each at the loudness it plays it, in the
            # order they are recorded beside the sound program (Samples::FIRST_WAVE on).
            def sound_waves = @sound_waves.dup

            # What the DSP writes for this game's sound-log entries are worked out with.
            def sound_voicing = DSPWrites::Voicing.new(waves: @sound_waves, parts: @music.parts, effects: @music.effect_names)

            # The section of the game's songs (SNES::Music), each note's sound-log entries numbered
            # among the rest.
            def music_section = @music.section(@music.words(sound_voicing) { |entry| sound_entry_number(entry) })

            private

            def prepare_sound
              @sound_entries = []
              @defined_sounds = @program.walk.select { |node| node.kind == :define_sound }.to_h { |node| [node.name, node.effect] }
              @music = SNES::Music.new(@program)
              verb_waves = @program.walk.select { |node| node.kind == :wave }.map { |node| wave_params(node) }
              @sound_waves = (verb_waves + @music.waves).map { |params| DSPWrites.wave_steps(params) }.uniq
              @samples = @program.walk.select { |node| node.kind == :sample }.to_h { |node| [node.name, node] }
              @recordings = [] # [name, read-back] for each way a recording is played
              @plays = []      # each play's row of "recording_plays"
            end

            # Reference#exec_play_sample (Reference::Mixer#start): a row of the table for the play —
            # the voice's source, pitch and volume, and the count the interpreter's mix keeps for it —
            # and the runtime handed its number.
            def emit_play_sample(node)
              declared = @samples.fetch(node.name) { raise LoweringError, "the sample #{node.name.inspect} is not declared" }
              refuse_shaped_sample!(declared)
              info = Assets::Sample.of(declared)
              clock = Console::SUPER_NINTENDO.sample_clock(declared.rate)
              frequency = VBlank::Audio::Music::NOTE_FREQUENCIES.fetch(node.pitch || info.note || :C4)
              back = node.loop ? (info.loop_length.positive? ? info.loop_length : info.length) : 0
              step = IR::Mixing.step(info, frequency, clock.rate)
              refuse_unreadable_play!(node.name, step, back)
              @recordings << [node.name, back] unless @recordings.include?([node.name, back])
              loudness = VBlank::Audio::Sound::MIX_LEVELS.fetch(node.volume, VBlank::Audio::Sound::MIX_LEVELS[:full])
              row = Runtime::Recordings.row(
                source: Samples::FIRST_WAVE + @sound_waves.size + @recordings.index([node.name, back]),
                pitch: [step / RECORDING_STEP_TO_PITCH, 1].max,
                volume: (loudness * DSPWrites::MAIN_VOLUME / VBlank::Audio::Sound::MIX_LEVELS[:full].to_f).round,
                length: info.length, back: back, advance: step * clock.samples_a_frame,
                logged: sound_entry_number([:sample, node.name]), name: @samples.keys.index(node.name)
              )
              @plays << row unless @plays.include?(row)
              runtime_call("rt_recordings_play", [Build.int(@plays.index(row))])
            end

            # Reference#exec_stop_sample (Reference::Mixer#stop): the recording's places freed, or every place.
            def emit_stop_sample(node)
              name = node.name ? @samples.keys.index(node.name) : Runtime::Recordings::ALL
              runtime_call("rt_recordings_stop", [Build.int(name), Build.int(sound_entry_number([:stop_sample]))])
            end

            # A recording with a shape of its own (an envelope) climbs and falls by the interpreter's
            # mix, which the Super Nintendo build does not keep yet.
            def refuse_shaped_sample!(declared)
              return unless declared.envelope

              raise NotMadeYet.new("The sample #{declared.name.inspect} has an envelope. The Super Nintendo build does " \
                                   "not make that yet. To fix this, build the game for the Game Boy Advance alone for " \
                                   "now (`consoles: %i[gba]`).", part: "the sound")
            end

            # A play the sound unit cannot keep with the interpreter's count: one read more than four
            # times as fast as the DSP plays (fullsnes: the pitch register reads at most $3FFF), and
            # one so fast that a single sample of the mix goes past the whole part a recording holds
            # (the interpreter logs that once, where the cartridge's count would log each time round).
            def refuse_unreadable_play!(name, step, back)
              if step / RECORDING_STEP_TO_PITCH > DSPWrites::PITCH_TOP
                raise LoweringError, "The sample #{name.inspect} plays more than four times faster than its recording. A " \
                                     "Super Nintendo cannot read a recording that fast. To fix this, play it at a " \
                                     "lower note."
              end
              return unless back.positive? && step > (back << VBlank::Audio::Sound::STEP_SHIFT)

              raise LoweringError, "The sample #{name.inspect} plays so fast that one step goes past the whole part it " \
                                   "holds. To fix this, hold it from an earlier point, or play it at a lower note."
            end

            # Reference#exec_play_song: the tune named, from the next frame or from here.
            def emit_play_song(node)
              routine = node.this_frame ? "rt_music_play_now" : "rt_music_play"
              runtime_call(routine, [Build.int(@music.number(node.name))])
            end

            def emit_stop_music(_node) = runtime_call("rt_music_stop", [])

            # Reference#exec_play_from_list: the song at the place the game works out, of the list.
            def emit_play_from_list(node)
              routine = node.this_frame ? "rt_music_play_from_list_now" : "rt_music_play_from_list"
              runtime_call(routine, [node.which, Build.int(@music.list_number(node.name))])
            end

            # Reference#exec_play_sound_effect: the effect at the place the game works out, of the list.
            def emit_play_sound_effect(node)
              routine = node.this_frame ? "rt_sfx_play_now" : "rt_sfx_play"
              runtime_call(routine, [node.which, Build.int(@music.effect_list_number(node.name))])
            end

            # Reference#exec_wave's entry.
            def wave_params(node) = { shape: node.shape, frequency: node.frequency, volume: node.volume }

            def emit_wave(node) = emit_sound_entry([:wave, wave_params(node)])
            def emit_stop_wave(_node) = emit_sound_entry([:stop_wave])

            # Reference#exec_enable_sound.
            def emit_enable_sound(_node) = emit_sound_entry([:enabled])

            # Reference#exec_beep: the beep resolved as the interpreter resolves it.
            def emit_beep(node)
              effect = VBlank::Audio::Sound.resolve_effect(node.tone, duty: node.duty, decay: node.decay,
                                                                      volume: node.volume, defined: @defined_sounds)
              emit_sound_entry([:beep, effect])
            end

            # Reference#exec_noise: the hit resolved as the interpreter resolves it.
            def emit_noise(node)
              hit = VBlank::Audio::Sound.resolve_noise(node.preset, pitch: node.pitch, decay: node.decay,
                                                                    volume: node.volume, metallic: node.metallic)
              emit_sound_entry([:noise, hit])
            end

            # +entry+'s DSP writes, then its number into the cartridge's sound log.
            def emit_sound_entry(entry)
              DSPWrites.for_entry(entry, sound_voicing).each do |write|
                command, *numbers = Runtime::Sound.command_for(write)
                runtime_call(Runtime::Sound::ROUTINES.fetch(command), numbers.map { |number| Build.int(number) })
              end
              runtime_call("rt_sound_log", [Build.int(sound_entry_number(entry))])
            end

            # The number the cartridge's sound log keeps +entry+ as, the next one the first time.
            def sound_entry_number(entry)
              number = @sound_entries.index(entry) || (@sound_entries << entry).size - 1
              if number >= Runtime::Sound::LOG_LENGTH
                raise LoweringError, "This game makes more than #{Runtime::Sound::LOG_LENGTH} different sounds. The Super " \
                                     "Nintendo build can tell #{Runtime::Sound::LOG_LENGTH} apart. To fix this, make " \
                                     "fewer different sounds."
              end
              number
            end
          end
        end
      end
    end
  end
end
