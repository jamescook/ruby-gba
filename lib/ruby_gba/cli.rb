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
                     desc: "Print the per-frame cost report (verdict measured on the emulator when available)"
    option :stats, type: :boolean, default: false,
                   desc: "Print how far asset packing shrank the cartridge"
    option :scene, type: :array, banner: "NAME", default: [],
                   desc: "Measure only these scenes in the report (default: all scenes)"
    def build(game_file)
      game = load_game(game_file)
      rom = game.build_rom
      path = options[:output] || File.join(File.dirname(File.expand_path(game_file)), game.default_filename)
      rom.write(path)
      say "Built #{File.basename(path)} (#{rom.size} bytes)"
      say rom.compression.summary_line if options[:stats] && rom.compression&.any?
      rom.explain(measured: measured_verdicts(game)) if options[:explain] || options[:scene].any?
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

    # Measure the game's scenes on the emulator and return the plain verdict hash the
    # explain report folds in: { scene_or_nil => { scanlines:, fps:, saturated: } } — a
    # whole-frame reading for a single-loop game (nil key), or one per scene. Returns nil
    # when the emulator is not built, so the report shows the hedged estimate instead of
    # failing. An unknown scene name is a friendly error, not a backtrace.
    def measured_verdicts(game)
      only = options[:scene].any? ? options[:scene] : nil
      RubyGBA::Analyzer.profile(game, only: only).transform_values do |result|
        { scanlines: result.scanlines, fps: result.fps, saturated: result.saturated? }
      end
    rescue LoadError
      nil
    rescue ArgumentError => e
      raise Thor::Error, e.message
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
