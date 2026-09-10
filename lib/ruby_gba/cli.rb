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

      --format=ir emits the game's intermediate representation instead of a cartridge:
      a standalone Ruby class that reconstructs the IR and lowers it to machine code,
      nothing more. It's paged to your terminal, or written to --output like the .gba
      would be.
    TEXT
    option :output, aliases: "-o", banner: "PATH",
                    desc: "Where to write the .gba, or the IR under --format=ir " \
                          "(default: <name>.gba beside the game file, or the pager for IR)"
    option :format, banner: "NAME", default: "game",
                    desc: "What to emit: game (a .gba cartridge) or ir (a standalone Ruby class holding the IR)"
    option :profile, type: :boolean, default: false,
                     desc: "Also run the game and report what the build made and what it cost (see `profile`)"
    option :stats, type: :boolean, default: false,
                   desc: "Print how far asset packing shrank the cartridge, and what is kept in quick memory"
    option :scene, banner: "NAME",
                   desc: "With --profile, measure this scene, holding the game there"
    option :keys, type: :array, banner: "BUTTON", default: [],
                  desc: "With --profile, hold these buttons while measuring"
    def build(game_file)
      case options[:format]
      when "game" then build_cartridge(game_file)
      when "ir" then build_ir(game_file)
      else
        raise Thor::Error, "#{options[:format].inspect} is not a build format. The formats are: game, ir."
      end
    end

    desc "profile GAME_FILE", "Report what the build made of the game, and what it cost when it ran"
    long_desc <<~TEXT
      Build the game in GAME_FILE and report on it in two halves.

      First what the BUILD made: how big each of your routines came out, which ones fit in
      the console's quick memory and which missed, what a routine that missed wanted and
      what was left when its turn came. None of that can be recovered from a running
      cartridge — by then the decisions are made and the evidence is gone.

      Then what it COST: the game is run, and this reports which of your routines the
      console really spent its frames in, the frame rate it produced, and how much of each
      frame was left over. Nothing here is predicted, so nothing here can be wrong about a
      loop nobody could see through.

      --keys holds buttons for the whole run, and it is worth passing: a game costs what
      the player makes it cost, so a profile with nothing held is a profile of a game
      standing still. --settle runs that many frames first, so the measuring starts in the
      game rather than on its title screen.

      --scene holds the game in one screen and measures that, with nobody having to play to
      it. --from measures a saved moment instead — an emulator save state you made by
      playing to it once. Use --from for a moment a scene cannot give: a scene says which
      routines run, a saved moment also carries the state that makes them expensive, so the
      boss fight with twelve fireballs on screen needs the state. A state saved from a
      different build of the game is refused, since all of its addresses have moved.

      --format=json prints the same numbers as data, for comparing two builds.
    TEXT
    option :format, banner: "NAME", default: "human",
                    desc: "What to print: human (the report) or json (the same numbers as data)"
    option :frames, type: :numeric, banner: "N", default: RubyGBA::Profiler::FRAMES,
                    desc: "How many frames to measure over"
    option :settle, type: :numeric, banner: "N", default: RubyGBA::Profiler::SETTLE,
                    desc: "Frames to run first, so the game is past its boot"
    option :keys, type: :array, banner: "BUTTON", default: [],
                  desc: "Hold these buttons for the whole run"
    option :scene, banner: "NAME",
                   desc: "Measure this scene, holding the game there (default: measure it as it boots)"
    option :from, banner: "PATH",
                  desc: "Measure a saved moment: an emulator save state, made by playing to it once"
    def profile(game_file)
      format = { "human" => :human, "json" => :json }[options[:format]] or
        raise Thor::Error, "#{options[:format].inspect} is not a profile format. The formats are: human, json."
      game = load_game(game_file)
      # Built the same way `build` builds it — measured placement included — so this reports on
      # the cartridge somebody would actually ship, not a differently-placed one.
      game.build_rom.profile(format: format, frames: options[:frames],
                             settle: options[:settle], scene: options[:scene],
                             from: options[:from], keys: held_buttons || [])
    rescue ArgumentError => e
      raise Thor::Error, e.message
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

    # The "game" format (--format=game, the default): the .gba cartridge itself.
    def build_cartridge(game_file)
      game = load_game(game_file)
      # Somebody is sitting there waiting for this, so it says what it is doing.
      rom = game.build_rom(progress: RubyGBA::Progress.to($stderr))
      path = options[:output] || File.join(File.dirname(File.expand_path(game_file)), game.default_filename)
      rom.write(path)
      say "Built #{File.basename(path)} (#{rom.size} bytes)"
      say rom.compression.summary_line if options[:stats] && rom.compression&.any?
      say placement_line(rom) if options[:stats] && rom.placement&.funcs&.any?
      profile_rom(rom) if options[:profile] || options[:scene] || options[:keys].any?
    end

    # The "ir" format (--format=ir): the game's IR as a standalone Ruby class, instead
    # of a cartridge. Built through the same full pipeline as --format=game (so a
    # guardrail error stops this exactly the way it stops a real build), then the
    # finished ROM's own source tree (rom.source_program) is what gets dumped — the
    # ROM bytes themselves are simply not written anywhere.
    def build_ir(game_file)
      game = load_game(game_file)
      rom = game.build_rom
      source = RubyGBA::IR::Dump.emit_class(rom.source_program, class_name: "#{constantize(game.title)}IR",
                                            fonts: custom_fonts, **game.build_options)
      if options[:output]
        File.write(options[:output], source)
        say "Wrote #{options[:output]}"
      else
        Pager.new.page(source)
      end
    end

    # Fonts the game registered itself with `font :name do ... end` — everything
    # BUT the two that ship built in, which the emitted class gets back for free
    # just by requiring the library. {RubyGBA::Fonts} is process-global (a font
    # once registered stays registered), so by the time this runs (after
    # load_game/build_rom evaluated the DSL block) it already holds whichever ones
    # this game defined.
    def custom_fonts
      (RubyGBA::Fonts.names - %i[default tiny]).to_h { |name| [name, RubyGBA::Fonts.get(name)] }
    end

    # One line on what the build kept in the console's quick memory, for --stats. The
    # full list is in the cost report; this is the size of it.
    def placement_line(rom)
      placement = rom.placement
      routines = placement.funcs.length
      format("Quick memory: %d routine%s (%.1fK), %.1fK of 32K free",
             routines, routines == 1 ? "" : "s",
             placement.code_bytes / 1024.0, placement.free_bytes / 1024.0)
    end

    # What the build made, and what it cost when it ran. An unknown scene name is a friendly
    # error, not a backtrace.
    def profile_rom(rom, format: :human)
      rom.profile(format: format, scene: options[:scene], keys: held_buttons || [])
    rescue ArgumentError => e
      raise Thor::Error, e.message
    end

    # The buttons --keys named, checked before the emulator runs. nil when none were
    # named, which leaves the profiler to hold each button the game reads, in turn.
    def held_buttons
      return nil if options[:keys].empty?

      buttons = options[:keys].map { |name| name.to_s.downcase.to_sym }
      unknown = buttons.reject { |button| RubyGBA::IR::Buttons.known?(button) }
      unless unknown.empty?
        raise Thor::Error, "#{unknown.first} is not a button. The buttons are: " \
                           "#{RubyGBA::IR::Buttons::NAMES.join(', ')}."
      end
      buttons
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
      const = constantize(name)

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

    # A CamelCase Ruby constant name from an arbitrary string (a file name, a game
    # title) — "PONG" -> "Pong", "grid-cursor" -> "GridCursor". Falls back to "Game"
    # for a string with nothing constant-safe in it (all punctuation, a leading digit).
    def constantize(str)
      const = str.to_s.split(/[^a-zA-Z0-9]+/).map(&:capitalize).join
      const =~ /\A[A-Z]/ ? const : "Game"
    end
  end
end
