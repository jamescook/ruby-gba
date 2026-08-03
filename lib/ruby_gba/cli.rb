# frozen_string_literal: true

require "thor"
require_relative "../ruby_gba"

module RubyGBA
  # Thor is required here and in bin/ruby-gba only — never by the library — so
  # building a ROM in code or in a test does not depend on it.
  class CLI < Thor
    # Without this, Thor reports a failed command but still exits 0.
    def self.exit_on_failure?
      true
    end

    desc "build GAME_FILE", "Build a game file into a .gba cartridge"
    long_desc <<~TEXT
      Build the game declared in GAME_FILE into a Game Boy Advance cartridge. The file
      declares its game with:

        RubyGBA.game "NAME", code: "CODE", maker: "01" do
          # ...the game...
        end

      The .gba is written next to the game file, named from the title, unless you pass
      --output.
    TEXT
    option :output, aliases: "-o", banner: "PATH",
                    desc: "Where to write the .gba (default: <name>.gba beside the game file)"
    option :explain, type: :boolean, default: false,
                     desc: "Print the per-frame draw and sound cost breakdown"
    option :stats, type: :boolean, default: false,
                   desc: "Print how far asset packing shrank the cartridge"
    option :analyze, type: :boolean, default: false,
                     desc: "Run the ROM on the emulator and report the measured per-frame cost"
    option :scene, type: :array, banner: "NAME", default: [],
                   desc: "With --analyze, profile only these scenes (default: all scenes)"
    def build(game_file)
      game = load_game(game_file)
      rom = game.build_rom
      path = options[:output] || File.join(File.dirname(File.expand_path(game_file)), game.default_filename)
      rom.write(path)
      say "Built #{File.basename(path)} (#{rom.size} bytes)"
      say rom.compression.summary_line if options[:stats] && rom.compression&.any?
      rom.explain if options[:explain]
      analyze_game(game) if options[:analyze] || options[:scene].any?
    end

    desc "inspect ROM_FILE", "Show a built .gba's header and a disassembly"
    def inspect(rom_file)
      raise Thor::Error, "I cannot find the ROM file #{rom_file}." unless File.file?(rom_file)

      RubyGBA::Inspector.new(rom_file).report
    end

    desc "new NAME", "Write a runnable starter game as NAME.rb"
    option :force, type: :boolean, default: false, desc: "Overwrite the file if it already exists"
    def new(name)
      file = "#{name}.rb"
      if File.exist?(file) && !options[:force]
        raise Thor::Error, "#{file} already exists. Use --force to overwrite it."
      end

      File.write(file, starter_source(name))
      say "Wrote #{file}. Run it with `ruby #{file}` or `ruby-gba build #{file}`."
    end

    private

    # Profile the game on the emulator and print the measured per-frame cost per scene
    # (or once for a game with no scenes). Needs the emulator built; a missing build, or
    # an unknown scene name, is a friendly error, not a backtrace.
    def analyze_game(game)
      only = options[:scene].any? ? options[:scene] : nil
      RubyGBA::Analyzer.profile(game, only: only).each do |scene, result|
        say "#{scene ? "scene :#{scene} — " : ''}#{analyze_line(result)}"
      end
    rescue LoadError => e
      raise Thor::Error, "--analyze needs the emulator. #{e.message}"
    rescue ArgumentError => e
      raise Thor::Error, e.message
    end

    # The measured-cost line. Below the frame ceiling it reports the real scanline count
    # and that it fits; near the ceiling the measurement saturates, so it reads as over
    # budget instead of a precise number.
    def analyze_line(result)
      frame = RubyGBA::Analyzer::FRAME_SCANLINES
      if result.saturated?
        "measured on emulator: the frame saturates the CPU " \
          "(~#{result.scanlines.round} of #{frame} scanlines) — over budget, drops frames"
      else
        "measured on emulator: ~#{result.scanlines.round(1)} of #{frame} scanlines per frame " \
          "(#{result.percent}%) — fits 60fps"
      end
    end

    # The file only declares its game (RubyGBA.game records without building), so clear
    # the registry, load the file, and take what it added.
    def load_game(game_file)
      path = File.expand_path(game_file)
      raise Thor::Error, "I cannot find the game file #{game_file}." unless File.file?(path)

      RubyGBA.registered_games.clear
      load path
      RubyGBA.registered_games.last || raise(Thor::Error, <<~MSG.chomp)
        #{game_file} does not declare a game. Add:
          RubyGBA.game "NAME", code: "CODE", maker: "01" do
            # ...the game...
          end
      MSG
    rescue RubyGBA::ROMError => e
      # A build the guardrails stopped: show the plain-language reason, not a backtrace.
      raise Thor::Error, e.message
    end

    def starter_source(name)
      title = name.upcase.gsub(/[^A-Z0-9 ]/, "").strip[0, 12]
      title = "GAME" if title.empty?
      letters = title.gsub(/[^A-Z0-9]/, "")
      code = "B#{letters}".ljust(4, "X")[0, 4]
      const = name.split(/[^a-zA-Z0-9]+/).map(&:capitalize).join
      const = "Game" unless const =~ /\A[A-Z]/

      <<~RUBY
        # frozen_string_literal: true
        #
        # #{title} — a starter game. Run it with `ruby #{name}.rb`, or build it with
        # `ruby-gba build #{name}.rb`.

        require "ruby_gba"

        #{const} = RubyGBA.game "#{title}", code: "#{code}", maker: "01" do
          screen :bitmap

          game_loop do
            wait_vblank
            clear_screen :black
            draw_text "#{title}", 40, 76, :white
          end
        end

        #{const}.write_if_main
      RUBY
    end
  end
end
