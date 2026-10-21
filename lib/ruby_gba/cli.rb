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

    # How `compare` ends. It ends with 1 when the two cartridges drift, the way `diff` does
    # when two files differ. Thor ends every command it stops with 1 as well, which would
    # leave another program unable to tell a drift from a file name spelled wrong. So a
    # `compare` that could not be made ends with 2, and every other command keeps Thor's 1.
    DRIFTED = 1
    NOT_COMPARED = 2

    # What --console takes: every console a game can name.
    CONSOLES = RubyGBA::Console::DESCRIPTIONS.keys.map(&:to_s).freeze

    def self.start(given_args = ARGV, config = {})
      super(given_args, config.merge(debug: true))
    rescue Thor::Error => e
      raise if ENV["THOR_DEBUG"] == "1"

      warn e.message
      exit(given_args.first == "compare" ? NOT_COMPARED : 1)
    end

    # The options `play` and `compare` both take: what says which buttons to press, and the
    # settings and the console a game file is built with.
    def self.options_for_playing(tape:)
      option :console, banner: "NAME", enum: CONSOLES,
                       desc: "Which console's cartridge a game file is built as: gba or gbc (needed for a game for both)"
      option :script, banner: "PATH", desc: "A Ruby file that declares playthroughs with RubyGBA.playthrough"
      option :playthrough, banner: "NAME", desc: "Which playthrough in the script file to play, when it declares several"
      option :tape, banner: "PATH", desc: tape
      option :set, type: :array, banner: "NAME=VALUE", default: [],
                   desc: "Tell every game file a setting it reads with `setting` (for example --set floors=1)"
    end

    desc "build GAME_FILE", "Build a game file into a cartridge for each console it is for"
    long_desc <<~TEXT
      Build the game declared in GAME_FILE into a cartridge for each console it says it is
      for. The file declares its game with:

        RubyGBA.game "NAME", consoles: %i[gba gbc] do
          # ...the game...
        end

      consoles: names the consoles: gba for the Game Boy Advance, gbc for the Game Boy Color.
      Each cartridge is written next to the game file, named from the title: a .gba for the
      Advance and a .gbc for the Color. --console builds one of them only, and --output says
      where to write it. When one console's cartridge cannot be built, the others are still
      written, and the build says why and ends as a failure.

      A Game Boy Color cartridge needs a game that lays itself out from `screen_width` and
      `screen_height`. The build says, as it goes, what the Color shows differently and what
      it cannot do.

      --format=ir emits the game's intermediate representation instead of a cartridge:
      a standalone Ruby class that reconstructs the IR and lowers it to machine code,
      nothing more. It's paged to your terminal, or written to --output like the .gba
      would be.

      --format=native builds the game as a program for this computer instead: one file
      with a window, the keyboard as the console's buttons (mGBA's keys), and nothing
      else to install. It is written next to the game file, named from the title with no
      extension. It needs zig (`mise install`), and the first one takes a while because
      it compiles SDL. --target builds it for another computer instead: windows, linux
      or linux-arm. Those programs are built here and have not been run on those systems.

      --format=web builds the game as one web page instead: open it in a browser and the
      game plays there, drawn in the page, with the same keys. It is written next to the
      game file, named from the title with .html on the end, and needs nothing else.
      A step only the console can run (raw instructions given with `entry`) cannot be
      built for the web; the build names each such line.

      A game that saves keeps its save in a file, in the folder your computer has for
      each program's own files. To keep it in a different file, start the program with
      --save-file PATH. The file holds the bytes of a cartridge's save memory, so a .sav
      file from an emulator starts the same game there.
    TEXT
    option :output, aliases: "-o", banner: "PATH",
                    desc: "Where to write the cartridge (one console's: say which with --console for a game for " \
                          "two), the IR under --format=ir, the program under --format=native, or the page under " \
                          "--format=web (default: beside the game file, named from its title; the pager for IR)"
    option :format, banner: "NAME", default: "game",
                    desc: "What to emit: game (a cartridge for each console), ir (a standalone Ruby class holding " \
                          "the IR), native (a program for this computer), or web (a page that plays it in a browser)"
    option :console, banner: "NAME", enum: CONSOLES,
                     desc: "Build this console's cartridge alone: gba or gbc (default: one for each console the game names)"
    option :profile, type: :boolean, default: false,
                     desc: "Also run the game and report what the build made and what it cost (see `profile`)"
    option :stats, type: :boolean, default: false,
                   desc: "Print how far asset packing shrank the cartridge, and what is kept in quick memory"
    option :scene, banner: "NAME",
                   desc: "With --profile, measure this scene, holding the game there"
    option :keys, type: :array, banner: "BUTTON", default: [],
                  desc: "With --profile, hold these buttons while measuring"
    option :set, type: :array, banner: "NAME=VALUE", default: [],
                 desc: "Tell the game a setting it reads with `setting` (for example --set floors=1)"
    option :target, banner: "COMPUTER",
                    desc: "With --format=native, build for another computer: windows, linux or linux-arm"
    option :template, banner: "FILE",
                      desc: "With --format=web, write the page from this .html.erb template; it must have <%= game %>"
    option :js, default: "page", enum: %w[page module script],
                desc: "With --format=web, what to write: page (one HTML page that plays the game), module " \
                      "(an ES module exporting createGame, for a page of your own) or script (a classic script " \
                      "that puts createGame on window.RubyGBA)"
    option :global, banner: "NAME",
                    desc: "With --js=script, the name on window.RubyGBA the game is put under (the file's own name)"
    option :data, default: "inline", enum: %w[inline separate],
                  desc: "With --format=web, where the game's big tables go: inline (in the one file, which opens " \
                        "from a disk) or separate (a .data file beside it, fetched when the game starts; serve it)"
    def build(game_file)
      refuse_web_options_out_of_place!
      # (--format=gbc is let through here so that it gets its own message, below.)
      if options[:console] && !%w[game gbc].include?(options[:format])
        raise Thor::Error, "--console works only with cartridges (--format=game). Remove --console, or remove --format."
      end

      case options[:format]
      when "game" then build_cartridges(game_file)
      when "ir" then build_ir(game_file)
      when "native" then build_native(game_file)
      when "web" then build_web(game_file)
      when "gbc"
        raise Thor::Error, "There is no --format=gbc now. To build a Game Boy Color cartridge, use --console gbc."
      else
        raise Thor::Error, "#{options[:format].inspect} is not a build format. The formats are: game, ir, native, web."
      end
    rescue ArgumentError, RubyGBA::ROMError => e
      # A setting the game does not ask for, or one it cannot read, or a build the guardrails
      # stopped (their reasons are printed already): say why, not a backtrace.
      raise Thor::Error, e.message
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

      A game for one console is profiled on that console. A game for both needs --console:
      --console=gba, or --console=gbc for its Game Boy Color cartridge, which reports where its
      frames went, by routine, the frame rate it played at, and how much of the time it slept.
    TEXT
    option :format, banner: "NAME", default: "human",
                    desc: "What to print: human (the report) or json (the same numbers as data)"
    option :console, banner: "NAME", enum: CONSOLES,
                     desc: "Which console's cartridge to profile: gba or gbc (needed for a game for both)"
    option :frames, type: :numeric, banner: "N", default: RubyGBA::Diagnostics::Profiler::FRAMES,
                    desc: "How many frames to measure over"
    option :settle, type: :numeric, banner: "N", default: RubyGBA::Diagnostics::Profiler::SETTLE,
                    desc: "Frames to run first, so the game is past its boot"
    option :keys, type: :array, banner: "BUTTON", default: [],
                  desc: "Hold these buttons for the whole run"
    option :scene, banner: "NAME",
                   desc: "Measure this scene, holding the game there (default: measure it as it boots)"
    option :from, banner: "PATH",
                  desc: "Measure a saved moment: an emulator save state, made by playing to it once"
    option :set, type: :array, banner: "NAME=VALUE", default: [],
                 desc: "Tell the game a setting it reads with `setting` (for example --set floors=1)"
    def profile(game_file)
      format = { "human" => :human, "json" => :json }[options[:format]] or
        raise Thor::Error, "#{options[:format].inspect} is not a profile format. The formats are: human, json."
      game = load_game(game_file)
      # Built the same way `build` builds it — measured placement included — so this reports on
      # the cartridge somebody would actually ship, not a differently-placed one.
      game.build_rom(settings: given_settings, console: console_to_run(game, "profile"))
          .profile(format: format, frames: options[:frames], settle: options[:settle], scene: options[:scene],
                   from: options[:from], keys: held_buttons || [])
    rescue ArgumentError => e
      raise Thor::Error, e.message
    end

    desc "play CARTRIDGE", "Play a game from a script or a tape, with nobody at the controls"
    long_desc <<~TEXT
      Play CARTRIDGE with nobody at the controls, and say how many frames went by and the
      frame each named moment fell on. CARTRIDGE is a game file (a .rb that declares a
      game, which is built first) or a cartridge file (a .gba, yours or somebody else's, or
      a Game Boy Color .gbc). A game file for one console is built for that console. A game
      file for both needs --console: --console=gba, or --console=gbc for its Game Boy Color
      cartridge.

      What to press comes from a script or from a tape.

      A SCRIPT FILE is a plain Ruby file that declares one or more playthroughs:

        RubyGBA.playthrough "walk to the door" do
          wait frames: 10
          hold :right, frames: 40
          moment :at_the_door
        end

      Give it with --script. When the file declares several, --playthrough says which.

      A TAPE is the presses of an earlier playing, written down by --write-tape. Give it
      with --tape. It plays the same presses on the same frames whatever it is played on.

      --save starts the cartridge from a save file. --lead-in names another playthrough
      to play first and not count: a way past logos or a title screen, so that frame 1 is
      where the playing begins. A lead-in is declared in the script file, so --script is
      needed for one even when a tape says what to press.

      --pictures-in writes the screen at each named moment into a folder, as a PNG named
      for the moment. --write-tape writes the presses that were made. --write-save writes
      the cartridge's save memory as the last frame left it.
    TEXT
    options_for_playing tape: "Play this tape, in place of a script"
    option :save, banner: "PATH", desc: "Start from this save file"
    option :lead_in, banner: "NAME", desc: "A playthrough in the script file to play first and not count"
    option :pictures_in, banner: "DIR", desc: "Write the screen at each named moment into this folder"
    option :write_tape, banner: "PATH", desc: "Write the presses that were made to this file, as a tape"
    option :write_save, banner: "PATH", desc: "Write the save memory as the last frame left it to this file"
    def play(cartridge_file)
      with_playthroughs_command_line("play") { |command| command.play(cartridge_file) }
    end

    desc "compare FIRST SECOND", "Play two cartridges on the same presses, and say where they drift"
    long_desc <<~TEXT
      Play the cartridges FIRST and SECOND side by side and say the first frame on which
      they differ. Each is a game file (a .rb, built first) or a cartridge file (a .gba). A
      game file for both consoles needs --console gba: a comparison compares Game Boy Advance
      cartridges only.

      HOW IT ENDS, for another program to act on: with 0 when the two agree, with 1 when
      they drift, and with 2 when they could not be compared (a file that is not there, a
      setting that makes no sense, a script that gave up).

      What to press comes from --script (and --playthrough) or --tape, as for `play`.
      --set goes to every game file, so two builds of one game file that differ in a
      setting are two files, or one cartridge file built ahead of time.

      Every setting a comparison takes from Ruby is the flag of the same name.

      HOW ALIKE IS ALIKE. With nothing said, one pixel out on one frame is drift.
      --share-may-differ is the share of the pixels that can differ, from 0 to 1.
      --frames-in-a-row is how many frames running have to differ. --ignoring-rectangles
      leaves parts of the screen out, each written X,Y,WIDTH,HEIGHT. --ignoring-frames
      leaves stretches of the playing out, each a range of frame numbers (1..120) or of
      moments, by their names with no colon (title..in_the_world); an end can be left
      open (900..).

      WHAT IS COMPARED. --readings names variables to compare as well as the picture:
      NAME reads the variable NAME from both, NAME=VARIABLE reads that variable from both,
      and NAME=FIRST,SECOND reads one from each. Variables have names in a game file and
      none in a cartridge file. A reading that needs Ruby to read is given from Ruby.
      --comparing says which of picture and readings is compared.

      HOW THE TWO ARE PLAYED. --same tape, the default, gives both the same presses on the
      same frames. --same script plays the script on each by itself and compares the two
      at each named moment, which forgives timing; --frames-apart then says how many
      frames apart they can reach a moment. --carrying-on plays on past the first drift
      and lists every one.

      WHERE THE TWO START. --save starts both from one save file. --lead-ins names a
      playthrough for each cartridge to play first and not count, the first cartridge's
      and then the second's, with - for none. A lead-in is declared in the script file,
      so --script is needed for one even when a tape says what to press.

      --reports-in writes a folder for each drift: the two screens, a picture of where
      they differ, a text file, and a tape that plays a cartridge back to that frame.
    TEXT
    options_for_playing tape: "Compare on this tape, in place of a script"
    option :share_may_differ, type: :numeric, banner: "SHARE", desc: "The share of the pixels that can differ, from 0 to 1"
    option :frames_in_a_row, type: :numeric, banner: "N", desc: "How many frames running have to differ before it is drift"
    option :ignoring_rectangles, type: :array, banner: "X,Y,WIDTH,HEIGHT", desc: "Parts of the screen that are not looked at"
    option :ignoring_frames, type: :array, banner: "RANGE", desc: "Stretches that are not looked at: 1..120, or title..in_the_world"
    option :readings, type: :array, banner: "NAME[=VARIABLE[,VARIABLE]]", desc: "Variables to compare as well as the picture"
    option :comparing, type: :array, banner: "WHAT", enum: %w[picture readings], desc: "What is compared"
    option :carrying_on, type: :boolean, desc: "Play on past the first drift, and list every one"
    option :same, banner: "WHICH", enum: %w[tape script],
                  desc: "tape (the same presses for both) or script (the script plays each by itself)"
    option :frames_apart, type: :numeric, banner: "N", desc: "With --same script, how many frames apart the two can reach a moment"
    option :save, banner: "PATH", desc: "Start both cartridges from this save file"
    option :lead_ins, type: :array, banner: "NAME", desc: "A playthrough for each cartridge to play first, or - for none"
    option :reports_in, banner: "DIR", desc: "Write a folder for each drift into this folder"
    def compare(first_file, second_file)
      # A comparison lines screens up at the Advance's size, so the Advance's is the one to offer.
      result = with_playthroughs_command_line("compare", offered: [:gba]) do |command|
        command.compare(first_file, second_file)
      end
      exit DRIFTED if result.drift?
    end

    desc "preview GAME_FILE", "Play a game in a browser tab, built again from the file on every reload"
    long_desc <<~TEXT
      Serve the game declared in GAME_FILE as a web page on this computer, and say where it is.
      Open it in a browser and the game plays there. Change the game file and reload the page:
      the page is built again from the file as it is now, with no cartridge and no emulator. A
      build that stops shows its reason in the page.

      The browser plays the game as the framework understands it. A mistake in the game's own
      logic shows there. A mistake that only the console makes does not, so check the cartridge
      as well before you ship it.
    TEXT
    option :port, type: :numeric, default: 8000, desc: "The port to serve the page on"
    option :template, banner: "FILE", desc: "Write the page from this .html.erb template; it must have <%= game %>"
    option :set, type: :array, banner: "NAME=VALUE", default: [],
                 desc: "Tell the game a setting it reads with `setting` (for example --set floors=1)"
    def preview(game_file)
      raise Thor::Error, "I cannot find the game file #{game_file}." unless File.file?(game_file)

      server = RubyGBA::IR::Backends::JS::Preview.new(game_file, settings: options[:set], template: options[:template],
                                                                 port: options[:port])
      trap("INT") { server.stop }
      server.serve
    rescue Errno::EADDRINUSE
      raise Thor::Error, "Port #{options[:port]} is in use already. Give another with --port."
    end

    desc "inspect ROM_FILE", "Show a built .gba's header and a disassembly"
    def inspect(rom_file)
      raise Thor::Error, "I cannot find the ROM file #{rom_file}." unless File.file?(rom_file)

      RubyGBA::Diagnostics::Inspector.new(rom_file).report
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

    # --- play and compare ---

    # `play` and `compare` are done by the library (see Playthroughs::CommandLine), which is
    # handed the options, somewhere to print, and how a game file is built here. What it
    # refuses, it refuses in a sentence, and that sentence is what the command ends with.
    #
    # +doing+ is what the command does with a game file ("play", "compare"), for the question a
    # game for two consoles is asked when --console does not say which.
    def with_playthroughs_command_line(doing, offered: nil)
      build = lambda do |file|
        game = load_game(file)
        game.build_rom(settings: given_settings, console: console_to_run(game, doing, offered: offered || game.consoles))
      end
      yield RubyGBA::Playthroughs::CommandLine.new(options, out: $stdout, build: build)
    rescue RubyGBA::Playthroughs::CommandLine::Refused => e
      raise Thor::Error, e.message
    end

    # --- build and profile ---

    # The "game" format (--format=game, the default): a cartridge for each console the game names,
    # or for the one --console says.
    #
    # EACH IS BUILT WHATEVER HAPPENS TO THE OTHER. A game for both consoles that the Color cannot
    # play still gets its Advance cartridge, and the command then ends saying why the Color's was
    # not made and how to stop asking for it — which may be all the game needs, since not every
    # game is for the Color. It still ends as a failure: a console the game names was not built.
    # A profile asked for comes after every cartridge is written, so refusing one costs no cartridge.
    def build_cartridges(game_file)
      game = load_game(game_file)
      consoles = options[:console] ? [options[:console].to_sym] : game.consoles
      refuse_one_output_for_two_consoles!(game) if options[:output] && consoles.size > 1
      built = {}
      failed = {}
      consoles.each do |console|
        built[console] = write_cartridge_for(game, game_file, console)
      rescue RubyGBA::ROMError, RubyGBA::IR::Backends::GBC::LoweringError => e
        # A build the guardrails stopped (their reasons are printed already), or something the
        # checks let through that a lowering cannot make.
        failed[console] = e.message
      end
      built.each_value { |rom| profile_rom(rom) } if options[:profile] || options[:scene] || options[:keys].any?
      raise Thor::Error, not_built_message(game, failed, built.keys) unless failed.empty?
    end

    # One console's cartridge, written beside the game file or to --output, and handed back.
    def write_cartridge_for(game, game_file, console)
      # Somebody is sitting there waiting for this, so it says what it is doing.
      rom = game.build_rom(progress: RubyGBA::Messages::Progress.to($stderr), settings: given_settings, console: console)
      path = options[:output] || File.join(File.dirname(File.expand_path(game_file)), game.default_filename(console: console))
      rom.write(path)
      say "Built #{File.basename(path)} (#{rom.size} bytes)"
      # What asset packing and the quick memory did is the Advance's to say: the Color's build
      # packs nothing and has no quick memory to choose for.
      if options[:stats] && console == :gba
        say rom.compression.summary_line if rom.compression&.any?
        say placement_line(rom) if rom.placement&.funcs&.any?
      end
      rom
    end

    # Why the consoles in +failed+ (console => reason) were not built, and the ways to stop
    # asking for each. A reason every console gave alike is the game's own fault, so it is said
    # once and with no advice about leaving a console out. +built+ are the consoles that were.
    def not_built_message(game, failed, built)
      reasons = failed.values.uniq
      return reasons.first if reasons.size == 1 && (failed.size > 1 || game.consoles.size == 1)

      failed.map do |console, reason|
        title = RubyGBA::Console.described(console).title
        advice = "#{game.title} was not built for the #{title}. If the game is not for the #{title}, " \
                 "take :#{console} out of consoles: where the game is named."
        if built.size == 1
          advice += " To build the #{RubyGBA::Console.described(built.first).title} cartridge alone, " \
                    "use --console #{built.first}."
        end
        "#{reason}\n\n#{advice}"
      end.join("\n\n")
    end

    def refuse_one_output_for_two_consoles!(game)
      raise Thor::Error, "--output names one file, and #{consoles_choice_message(game, 'write', game.consoles)}"
    end

    # The console a command that runs one cartridge runs +game+ on: the one --console names, or the
    # game's only one. A game for two with neither said is asked which, since nothing is taken to
    # be for the Advance. +doing+ is what the command does with it ("profile", "play"), and
    # +offered+ the consoles it can do that on, which `compare` holds to the Advance.
    def console_to_run(game, doing, offered: game.consoles)
      return options[:console].to_sym if options[:console]
      return game.consoles.first if game.consoles.size == 1

      raise Thor::Error, consoles_choice_message(game, doing, offered)
    end

    # "PONG is for the Game Boy Advance and the Game Boy Color. Say which cartridge to play: add
    # --console gba or --console gbc."
    def consoles_choice_message(game, doing, offered)
      named = game.consoles.map { |name| RubyGBA::Console.described(name).title }.join(" and the ")
      "#{game.title} is for the #{named}. Say which cartridge to #{doing}: add --console #{offered.join(' or --console ')}."
    end

    # A web page, a desktop program and the IR dump are all made from the game as the Advance plays
    # it, since the two runtimes draw the Advance's 240×160 screen. So they need a game for the
    # Advance; one for the Color alone is refused, saying what to write.
    def refuse_game_not_for_advance!(game, made)
      return if game.consoles.include?(:gba)

      raise Thor::Error, "#{made} is made from the Game Boy Advance's game, and #{game.title} is for the Game Boy " \
                         "Color alone. To make one, lay the game out from `screen_width` and `screen_height`, and " \
                         "say `consoles: %i[#{(game.consoles + [:gba]).join(' ')}]` where the game is named."
    end

    # The "ir" format (--format=ir): the game's IR as a standalone Ruby class, instead
    # of a cartridge. Built through the same full pipeline as --format=game (so a
    # guardrail error stops this exactly the way it stops a real build), then the
    # finished ROM's own source tree (rom.source_program) is what gets dumped — the
    # ROM bytes themselves are simply not written anywhere.
    def build_ir(game_file)
      game = load_game(game_file)
      refuse_game_not_for_advance!(game, "The IR")
      rom = game.build_rom(settings: given_settings, console: :gba)
      source = RubyGBA::IR::Dump.class_source(rom.source_program, class_name: "#{constantize(game.title)}IR",
                                            **game.options.lowering)
      if options[:output]
        File.write(options[:output], source)
        say "Wrote #{options[:output]}"
      else
        Pager.new.page(source)
      end
    end

    # The "native" format: the game as a program for this computer, with a window. Written
    # beside the game file, named like the cartridge with no extension — or with "-desktop" on
    # the end where that name is already a folder, as a game split across files often has.
    def build_native(game_file)
      game = load_game(game_file)
      refuse_game_not_for_advance!(game, "A program for this computer")
      target =options[:target]&.tr("-", "_")&.to_sym
      if target && !RubyGBA::IR::Backends::Native::TARGETS.key?(target)
        names = RubyGBA::IR::Backends::Native::TARGETS.keys.map { |name| name.to_s.tr("_", "-") }
        raise Thor::Error, "There is no build for #{options[:target]}. A game can be built for " \
                           "#{names.join(', ')}. To build for this computer, leave out --target."
      end
      path = options[:output] || begin
        plain = File.join(File.dirname(File.expand_path(game_file)), game.default_filename(console: :gba).delete_suffix(".gba"))
        plain = "#{plain}-#{options[:target]}" if target
        plain = "#{plain}-desktop" if File.directory?(plain)
        target == :windows ? "#{plain}.exe" : plain
      end
      say "Building #{File.basename(path)} for #{target ? options[:target] : 'this computer'} " \
          "(the first build compiles SDL, which takes a while)"
      RubyGBA::IR::Backends::Native.new.build_desktop(game, path, settings: given_settings, target: target)
      say "Built #{path}"
    rescue RubyGBA::IR::Backends::Native::LoweringError, RubyGBA::IR::Backends::Native::Zig::Error => e
      raise Thor::Error, e.message
    end

    # An option for the web build given where it does nothing — on another format, or beside an
    # output it is not for — is refused, so nobody thinks it did something.
    def refuse_web_options_out_of_place!
      given = { js: options[:js] != "page", data: options[:data] != "inline", template: options[:template],
                global: options[:global] }.select { |_, said| said }.keys
      if options[:format] != "web" && !given.empty?
        raise Thor::Error, "--#{given.first} works only with --format=web. Add --format=web, or remove --#{given.first}."
      end
      if options[:global] && options[:js] != "script"
        raise Thor::Error, "--global works only with --js=script. Add --js=script, or remove --global."
      end
      return unless options[:template] && options[:js] != "page"

      raise Thor::Error, "--template works only with the page (--js=page). Remove --js, or remove --template."
    end

    # What --js names, and the ending of the file each is written to.
    WEB_OUTPUTS = { "page" => ".html", "module" => ".mjs", "script" => ".js" }.freeze

    # The "web" format: the game as one web page that plays it in a browser, or with --js the game
    # alone as JavaScript for a page of the author's own. Written beside the game file, named like
    # the cartridge with the output's ending in place of .gba.
    def build_web(game_file)
      game = load_game(game_file)
      refuse_game_not_for_advance!(game, "A web page")
      js = options[:js]
      path = options[:output] ||
             File.join(File.dirname(File.expand_path(game_file)),
                       game.default_filename(console: :gba).delete_suffix(".gba") + WEB_OUTPUTS.fetch(js))
      web = RubyGBA::IR::Backends::JS.new
      data = options[:data].to_sym
      case js
      when "module" then web.build_module(game, path, settings: given_settings, data: data)
      when "script" then web.build_script(game, path, name: options[:global] || File.basename(path, ".*"),
                                                      settings: given_settings, data: data)
      else
        template = options[:template] ? File.expand_path(options[:template]) : RubyGBA::IR::Backends::JS::Page::DEFAULT
        web.build_page(game, path, settings: given_settings, template: template, data: data)
      end
      say "Built #{path}"
    rescue RubyGBA::IR::Backends::JS::LoweringError, RubyGBA::IR::Guardrails::ValidationError => e
      raise Thor::Error, e.message
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

    # The settings --set named, as text: the game's own `setting` line reads each as the kind
    # of thing its default is.
    def given_settings
      options[:set].to_h do |pair|
        name, value = pair.split("=", 2)
        if value.nil? || name.empty?
          raise Thor::Error, "--set #{pair} does not say a value. Write it as NAME=VALUE, for example --set floors=1."
        end

        [name.to_sym, value]
      end
    end

    # The file only declares its game (RubyGBA.game records without building), so clear
    # the registry, load the file, and take what it added.
    def load_game(game_file)
      path = File.expand_path(game_file)
      raise Thor::Error, "I cannot find the game file #{game_file}." unless File.file?(path)

      RubyGBA.forget_registered_games!
      load path
      RubyGBA.registered_games.last || raise(Thor::Error, <<~MSG.chomp)
        #{game_file} does not declare a game. Add:
          RubyGBA.game "NAME", consoles: %i[gba gbc] do
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
      const = constantize(name)

      <<~RUBY
        # frozen_string_literal: true
        #
        # #{title} — a starter game. Run it with `ruby #{name}.rb`, or build it with
        # `ruby-gba build #{name}.rb`, which makes a cartridge for each console it names:
        # #{name}.gba for the Game Boy Advance and #{name}.gbc for the Game Boy Color.

        require "ruby_gba"

        #{const} = RubyGBA.game "#{title}", consoles: %i[gba gbc] do
          screen :bitmap

          game_loop do
            clear_screen :black
            # The middle of whichever screen it is built for: the two are not the same size.
            draw_text "#{title}", :center, (screen_height - text_height) / 2, :white
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
