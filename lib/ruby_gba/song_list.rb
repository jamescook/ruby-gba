# frozen_string_literal: true

module RubyGBA
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
    def initialize(builder, name, keys)
      @builder = builder
      @name = name
      @keys = keys
    end

    attr_reader :name

    # How many songs the list holds.
    def count = @keys.length

    # The number of a song the list was given by name (a Hash of Scores).
    def number_of(key)
      at = @keys.index(key)
      return at if at

      raise ArgumentError, "The song list :#{@name} has no song #{key.inspect}. " \
                           "It has #{@keys.map(&:inspect).join(', ')}."
    end

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

    def number(which)
      case which
      when Symbol then number_of(which)
      when Integer
        return which if which.between?(0, count - 1)

        raise ArgumentError, "The song list :#{@name} has #{count} songs, so it has no song #{which}. " \
                             "The songs are numbered from 0 to #{count - 1}."
      else which
      end
    end
  end
end
