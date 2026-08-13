# frozen_string_literal: true

require "yaml"

module Wolf3D
  # Where your copy of Wolfenstein 3D is, and which release it is.
  #
  # Nothing here is redistributable, so the build reads files you already own. Point at them with
  # WOLF3D_DATA, or with a wolf3d.yml beside this game.
  class GameData
    class NotFound < StandardError; end

    ENV_VAR = "WOLF3D_DATA"
    CONFIG_FILE = "wolf3d.yml"
    EXAMPLE_FILE = "wolf3d.example.yml"

    # A release is told apart by the extension its files carry.
    SETS = {
      "WL6" => "the registered six episodes",
      "WL1" => "the shareware episode",
      "SOD" => "Spear of Destiny",
      "SDM" => "the Spear of Destiny demo"
    }.freeze

    STEMS = %w[VSWAP GAMEMAPS MAPHEAD VGAGRAPH VGADICT VGAHEAD AUDIOT AUDIOHED].freeze

    attr_reader :dir, :set, :source

    # The data, or nil when there is none. For tests that skip rather than fail.
    def self.find(home: Wolf3D.home)
      locate(home: home)
    rescue NotFound
      nil
    end

    def self.locate(home: Wolf3D.home)
      dir, source = configured_dir(home)
      raise NotFound, unset_message(home) if dir.nil?
      raise NotFound, missing_dir_message(dir, source) unless File.directory?(dir)

      sets = complete_sets(dir)
      raise NotFound, no_files_message(dir, source) if sets.empty?
      raise NotFound, ambiguous_message(dir, sets) if sets.length > 1

      new(dir: dir, set: sets.first, source: source)
    end

    def initialize(dir:, set:, source:)
      @dir = dir
      @set = set
      @source = source
    end

    # The file for a stem, e.g. path("VSWAP"). Case is whatever the disk uses.
    def path(stem)
      found = self.class.file_in(@dir, stem, @set)
      raise NotFound, "#{stem}.#{@set} is not in #{@dir}." if found.nil?

      found
    end

    def read(stem) = File.binread(path(stem))

    def label = "#{SETS.fetch(@set, @set)} (#{@set})"

    def describe = "Found #{label} in #{@dir}, set by #{@source}."

    # Every file of +set+ that is in +dir+, matched without regard to case — the files are
    # upper-case on the original disks and often lower-case after a copy through another system.
    def self.file_in(dir, stem, set)
      Dir.children(dir).find { |name| name.casecmp?("#{stem}.#{set}") }
                       &.then { |name| File.join(dir, name) }
    rescue SystemCallError
      nil
    end

    def self.complete_sets(dir)
      SETS.keys.select { |set| STEMS.all? { |stem| file_in(dir, stem, set) } }
    end

    def self.configured_dir(home)
      from_env = ENV.fetch(ENV_VAR, nil)
      return [File.expand_path(from_env), ENV_VAR] unless from_env.to_s.empty?

      config = File.join(home, CONFIG_FILE)
      return [nil, nil] unless File.file?(config)

      named = YAML.safe_load_file(config).then { |y| y.is_a?(Hash) ? y["data"] : nil }
      return [nil, nil] if named.to_s.empty?

      [File.expand_path(named, home), CONFIG_FILE]
    end

    def self.unset_message(home)
      <<~TEXT
        Wolfenstein 3D game data is not set.

        This game reads the data files from a copy of Wolfenstein 3D that you own. The files are
        not free to give away, so they are not in this repository.

        Do one of these two things:

        1. Set the directory in the environment:
             export #{ENV_VAR}="/path/to/wolfenstein"
        2. Or copy #{EXAMPLE_FILE} to #{CONFIG_FILE} and put the directory in it:
             #{File.join(home, CONFIG_FILE)}

        The directory must hold these files: #{STEMS.join(', ')}.
        The extension says which release it is: #{SETS.keys.join(', ')}.

        To get the shareware episode, search for "Wolfenstein 3D shareware". It is free to
        download and it holds the first episode.
      TEXT
    end

    def self.missing_dir_message(dir, source)
      "#{source} points at #{dir}. There is no directory there. Correct the path."
    end

    def self.no_files_message(dir, source)
      present = begin
        Dir.children(dir).sort.first(12)
      rescue SystemCallError
        []
      end
      <<~TEXT
        #{source} points at #{dir}. That directory holds no Wolfenstein 3D data.

        A complete release has all of these files: #{STEMS.join(', ')}.
        Each one ends in #{SETS.keys.join(', ')} — for example VSWAP.WL6.

        #{present.empty? ? 'The directory is empty.' : "The directory holds: #{present.join(', ')}"}

        Spear of Destiny is often in a sub-directory of its own. If you see one, point at it.
      TEXT
    end

    def self.ambiguous_message(dir, sets)
      named = sets.map { |s| "#{s} (#{SETS.fetch(s, s)})" }.join(" and ")
      <<~TEXT
        #{dir} holds more than one release: #{named}.

        Point at one release. Put each in a directory of its own, or set #{ENV_VAR} to the
        directory that holds only the release you want.
      TEXT
    end
  end
end
