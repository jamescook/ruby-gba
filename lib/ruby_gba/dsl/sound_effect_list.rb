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
    include ScoreList

    # Play effect +which+: a name the list was given, a number counting from 0, or a number the
    # game works out as it runs. Returns self.
    def play(which)
      @builder.play_sound_effect(@name, number(which))
      self
    end

    private

    def entry = "sound effect"
  end
end
