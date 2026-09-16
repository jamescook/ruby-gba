# frozen_string_literal: true

module RubyGBA
  module DSL
    # The game's music, handed over as Scores and played by number — what `songs` gives back.
    #
    #   music = songs :music, [title_theme, file_select, forest]
    #   music.play 0          # the title theme
    #   music.play track      # whichever one a number the game holds says
    #   music.stop
    #
    # Playing works the way `play_song` does: it says which song is playing now, so naming the
    # one already playing changes nothing, and naming another starts that one from its first
    # note. A number the game works out that names no song leaves the music as it is — the same
    # as `show_map` with a number naming no map.
    class SongList
      include ScoreList

      # Play song +which+: a name the list was given, a number counting from 0, or a number the
      # game works out as it runs. Returns self.
      def play(which)
        @builder.play_from_list(@name, number(which))
        self
      end

      # No song is playing now — the same as `stop_music`. Returns self.
      def stop
        @builder.stop_music
        self
      end

      private

      def entry = "song"
    end
  end
end
