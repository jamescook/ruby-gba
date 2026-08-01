# frozen_string_literal: true

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # The console has a small, fixed set of sound voices. A one-part song plays
        # on the music voice and leaves the sound-effect voice free for beeps. But a
        # *two-part* song (a melody with a bass or harmony) needs a second voice —
        # and the only one left is the same one `beep` plays on. So while a two-part
        # song plays, a beep and the song's second part will keep cutting each other
        # off. That's silent and baffling if you don't know the console only has so
        # many voices, so we say it plainly. Advisory — the build still produces a
        # ROM, and the two really can share the voice if you don't mind them
        # interrupting each other.
        class ChannelConflict
          NAME = :channel_conflict

          def detect(program)
            return [] unless program.walk.any? { |node| node.kind == :beep }

            songs = program.walk.select { |node| node.kind == :song }
                            .each_with_object({}) { |node, by_name| by_name[node[:name]] = node }

            played = program.walk.select { |node| node.kind == :play_song }.map { |node| node[:name] }.uniq
            layered = played.select { |name| (song = songs[name]) && song[:voices].length >= 2 }

            layered.map do |name|
              Finding.new(check: NAME, severity: :warning, message: message(name),
                          fix: nil, source: songs[name].source)
            end
          end

          private

          def message(name)
            "The song :#{name} plays in two parts. Its second part uses the same sound voice as your beeps. " \
              "The console has only a few voices. While :#{name} plays, a beep and the song's lower part " \
              "interrupt each other. To use beeps and this music together, make :#{name} a one-part song, " \
              "just the melody. Or play the beeps only while :#{name} does not play."
          end
        end
      end
    end
  end
end
