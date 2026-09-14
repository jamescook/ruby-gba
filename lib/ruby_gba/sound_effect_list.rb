# frozen_string_literal: true

module RubyGBA
  # The game's sound effects, handed over as Scores and played by name or number — what
  # `sound_effects` gives back.
  #
  #   sfx = sound_effects :sfx, { hit: HIT, spark: SPARK }
  #   sfx.play :hit
  #   sfx.play which        # whichever one a number the game holds says
  #
  # Each plays once, over the song that is playing, from the frame after it is asked for. Asked
  # for again while it is still sounding, it starts again from its first note. A number the game
  # works out that names no effect plays nothing.
  class SoundEffectList
    def initialize(builder, name, keys)
      @builder = builder
      @name = name
      @keys = keys
    end

    attr_reader :name

    # How many effects the list holds.
    def count = @keys.length

    # Play effect +which+: a name the list was given, a number counting from 0, or a number the
    # game works out as it runs. Returns self.
    def play(which)
      @builder.play_sound_effect(@name, number(which))
      self
    end

    private

    def number(which)
      case which
      when Symbol
        @keys.index(which) ||
          raise(ArgumentError, "The sound effects :#{@name} have no effect #{which.inspect}. " \
                               "They are #{@keys.map(&:inspect).join(', ')}.")
      when Integer
        return which if which.between?(0, count - 1)

        raise ArgumentError, "The sound effects :#{@name} are #{count}, so there is no effect #{which}. " \
                             "The effects are numbered from 0 to #{count - 1}."
      else which
      end
    end
  end
end
