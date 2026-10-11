# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class Native
        # WHAT A GAME'S SOUND LOG SAYS, as the C prints it and as a test reads it.
        #
        # The interpreter keeps a log of what it played (Reference#audio): sound switched on, a
        # beep and everything about it, a note, a voice set, the music turned down, the music
        # stopped. The C prints the same thing a line at a time (runtime/rg_sound.c), and what it
        # prints is numbers: which beep, which song, which pitch. The rest of an entry — what a
        # beep sounds like, a song's name — was settled when the game was built, so the C need
        # not carry it. Both sides number the game's beeps and songs here, the lowering to write
        # the numbers in and the run to read them back, which is what keeps the two in step.
        class SoundLog
          def initialize(program)
            defined = program.walk.select { |node| node.kind == :define_sound }.to_h { |node| [node.name, node.effect] }
            @effects = program.walk.select { |node| node.kind == :beep }.map { |node| effect_of(node, defined) }.uniq
            @defined = defined
            @songs = program.walk.select { |node| node.kind == :song }.uniq(&:name)
          end

          # Every song the game has, in the order the C numbers them.
          attr_reader :songs

          # The number the C prints for this beep: which of the game's sounds it makes.
          def beep_number(node) = @effects.index(effect_of(node, @defined))

          def song_number(name) = @songs.index { |song| song.name == name }

          # One printed line ("sound" and what follows) as the interpreter's log entry.
          def entry(line)
            kind, *numbers = line.delete_prefix("sound ").split(" ")
            numbers = numbers.map { |number| Integer(number) }
            case kind
            when "enabled" then [:enabled]
            when "beep" then [:beep, @effects.fetch(numbers[0])]
            when "note" then [:note, @songs.fetch(numbers[0]).name, numbers[1]]
            when "voice" then [:voice, numbers[0], @songs.fetch(numbers[1]).name, numbers[2], numbers[3]]
            when "loudness" then [:loudness, numbers[0], numbers[1]]
            when "stop_music" then [:stop_music]
            else raise ArgumentError, "the program printed a sound line nobody reads: #{line}"
            end
          end

          private

          # What a beep sounds like, worked out the interpreter's way (Reference#resolve_effect).
          def effect_of(node, defined)
            Audio::Sound.resolve_effect(node.tone, duty: node.duty, decay: node.decay, volume: node.volume, defined: defined)
          end
        end
      end
    end
  end
end
