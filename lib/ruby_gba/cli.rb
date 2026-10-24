# frozen_string_literal: true

require "thor"
require_relative "../ruby_gba"

module RubyGBA
  # Thor is required here and in bin/ruby-gba only — never by the library — so
  # building a ROM in code or in a test does not depend on it.
  #
  # THE HELP IS WRITTEN OUT BY HAND, one page a command, beside the options it explains. Thor can
  # make a help page from each option's own line, and what it makes is one line an option, as
  # wide as the longest, with every option of every format in one list and the explaining in a
  # paragraph after. Nobody reads that. A page here is what a person wants first, the commands
  # they came to type, and then the options in groups, short, in 80 columns. The class refuses to
  # load if a page leaves out an option its command takes (#refuse_undocumented_options!), so a
  # new option cannot go unexplained.
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

    # The words that ask for help, wherever on the line they are.
    HELP_FLAGS = %w[--help -h].freeze

    # Each command's help page, by the command's name: filled as each command is declared
    # below, and frozen after the last.
    HELP_PAGES = {}

    def self.help_page(command, text)
      HELP_PAGES[command] = text.freeze
    end

    def self.start(given_args = ARGV, config = {})
      args = route_help_flags(given_args)
      args = checked_args(args) unless args.first == "help"
      super(args, config.merge(debug: true))
    rescue Thor::Error => e
      raise if ENV["THOR_DEBUG"] == "1"

      # Thor raises exactly this class, and none of its kinds, when a command is given too few
      # words or too many; its kinds (a value an option does not take) say something worth keeping.
      warn(e.instance_of?(Thor::InvocationError) ? wrong_words_message(args) : e.message)
      exit(given_args.first == "compare" ? NOT_COMPARED : 1)
    end

    # `ruby-gba`, `ruby-gba --help` and `ruby-gba build --help` become `ruby-gba help` and
    # `ruby-gba help build`. Thor would take the --help after a command for an argument, and
    # build would go looking for a game file of that name. A word after `--` is never a flag.
    def self.route_help_flags(args)
      asked = args.take_while { |word| word != "--" }
      return ["help"] if asked.empty? || HELP_FLAGS.include?(asked.first)
      return ["help", asked.first] if asked.intersect?(HELP_FLAGS)

      args
    end

    # The list of commands: `ruby-gba help`, and `ruby-gba help help`.
    def self.help(_shell, _subcommand = false)
      $stdout.print COMMAND_LIST
    end

    # One command's page: `ruby-gba help build`.
    def self.command_help(_shell, name)
      return help(nil) if name == "help"
      raise Thor::Error, no_command_message(name) unless HELP_PAGES.key?(name)

      $stdout.print HELP_PAGES.fetch(name)
    end

    def self.no_command_message(name)
      meant = DidYouMean::SpellChecker.new(dictionary: HELP_PAGES.keys).correct(name).first
      "There is no command \"#{name}\".#{" Did you mean #{meant}?" if meant} The commands are: " \
        "#{HELP_PAGES.keys.join(', ')}. Run ruby-gba --help to see what each one does."
    end

    # What a command and its options say, checked before Thor sees them, and given back with each
    # option's value joined to it (-o out.gba becomes --output=out.gba). Thor hands an option it
    # does not know to the command as a word, so a misspelled --format became a file name, or was
    # dropped without a word and a cartridge built where a web page was asked for; it takes an
    # option given no value for its own name, so -o alone wrote a file called "output"; and it
    # takes a value that starts with a dash for an option.
    def self.checked_args(args)
      name = args.first
      raise Thor::Error, no_command_message(name) unless HELP_PAGES.key?(name)

      options = options_by_switch(all_commands.fetch(name))
      words = args.drop(1)
      checked = [name]
      until words.empty?
        word = words.shift
        if word == "--"
          checked.push(word, *words)
          break
        end
        unless switch?(word)
          checked << word
          next
        end

        switch, value = word.split("=", 2)
        switch = switch.tr("_", "-")
        option = options[switch] or refuse_unknown_option!(args, word, switch, options.keys)
        if value || option.boolean? || option.type == :array
          checked << word
          next
        end

        given = words.first
        if given.nil? || options.key?(given.split("=", 2).first)
          raise Thor::Error, "#{switch} needs a value. Write it as: #{switch} #{option.banner}. " \
                             "Run ruby-gba #{name} --help to see the options."
        end
        checked << "#{option.switch_name}=#{words.shift}"
      end
      checked
    end

    # A word written the way an option is: one or two dashes, then a letter.
    def self.switch?(word) = word.match?(/\A--?[a-zA-Z]/)

    # Every way a command's options can be written, and the option each one is: --format, -o,
    # and --no-stats and --skip-stats for an option that is on or off.
    def self.options_by_switch(command)
      command.options.values.each_with_object({}) do |option, found|
        plain = option.switch_name
        found[plain] = option
        option.aliases.each { |short| found[short] = option }
        next unless option.boolean?

        found["--no-#{plain.delete_prefix('--')}"] = option
        found["--skip-#{plain.delete_prefix('--')}"] = option
      end
    end

    # Other names people reach for, for what a build makes, and the option that says it.
    NATIVE = ["--format=native", "a program for this computer"].freeze
    WEB = ["--format=web", "a web page"].freeze
    CARTRIDGE = [nil, "a .gba cartridge"].freeze
    FORMAT_FLAGS = {
      "--native" => NATIVE, "--desktop" => NATIVE, "--web" => WEB, "--html" => WEB,
      "--gba" => CARTRIDGE, "--cartridge" => CARTRIDGE, "--rom" => CARTRIDGE
    }.freeze

    def self.refuse_unknown_option!(args, word, switch, known)
      name = args.first
      said = "ruby-gba #{name} has no option #{switch}."
      if name == "build" && FORMAT_FLAGS.key?(switch)
        option, what = FORMAT_FLAGS.fetch(switch)
        line = ["ruby-gba", *args].filter_map { |part| part == word ? option : part }.join(" ")
        raise Thor::Error, "#{said} To build #{what}, write:\n  #{line}"
      end

      meant = DidYouMean::SpellChecker.new(dictionary: known).correct(switch).first
      said += " Did you mean #{meant}?" if meant
      said += " To choose what is built, use --format game, native or web." if name == "build"
      raise Thor::Error, "#{said} Run ruby-gba #{name} --help to see the options."
    end

    # A command given too few words, or too many: how it is written, in place of Thor's
    # "was called with arguments". The usual way to get there is an option that takes several
    # words (--set, --keys) written before the game file, which it then takes as one of them, so
    # that is said, with the line put right.
    def self.wrong_words_message(args)
      name = args.first
      command = all_commands.fetch(name)
      wanted = command.usage.split.drop(1)
      plain = wanted.size == 1 ? "one #{wanted.first}" : wanted.join(" and ")
      said = "ruby-gba #{name} takes #{plain}. Write it as: ruby-gba #{command.usage} [options]."
      taken = words_taken_by_lists(args, command, wanted.size)
      if taken
        list, words = taken
        line = ["ruby-gba", name, *words, *(args.drop(1) - words)].join(" ")
        said = "#{list} took #{words.join(' ')}, since it takes every word after it. Put #{plain} first:\n  #{line}"
      end
      "#{said}\nRun ruby-gba #{name} --help to see more."
    end

    # The option that takes several words and the words it took that were meant for the command,
    # when that is what happened; nil otherwise.
    def self.words_taken_by_lists(args, command, wanted)
      lists = command.options.values.select { |option| option.type == :array }.map(&:switch_name)
      at = args.index { |word| lists.include?(word) } or return nil
      before = args[1...at].reject { |word| switch?(word) }
      missing = wanted - before.size
      run = args.drop(at + 1).take_while { |word| !switch?(word) }
      return nil unless missing.positive? && run.size > missing

      [args[at], run.last(missing)]
    end

    # A page that leaves out an option its command takes stops the program loading, so the
    # tests catch it the first time anything runs the command. An option counts as explained
    # where its whole name is on the page: --save is not explained by --save-file.
    def self.refuse_undocumented_options!
      HELP_PAGES.each do |name, page|
        missing = all_commands.fetch(name).options.values.map(&:switch_name).reject do |switch|
          page.match?(/(?<![\w-])#{Regexp.escape(switch)}(?![\w-])/)
        end
        raise "The help page for ruby-gba #{name} does not explain #{missing.join(', ')}." unless missing.empty?
      end
      # help and tree are Thor's own: help prints these pages, and tree is refused as a command
      # that is not there.
      undescribed = all_commands.keys - HELP_PAGES.keys - %w[help tree]
      raise "These commands have no help page: #{undescribed.join(', ')}." unless undescribed.empty?
    end

    COMMAND_LIST = <<~TEXT
      Usage: ruby-gba COMMAND [options]

      Make a game:
        ruby-gba new NAME              Write a starter game to NAME.rb.
        ruby-gba build GAME_FILE       Build a .gba cartridge, a program for this
                                       computer, or a web page.
        ruby-gba preview GAME_FILE     Play the game in a browser. Reload the page
                                       to build it again.

      Check a game:
        ruby-gba profile GAME_FILE     Run the game and report what it costs.
        ruby-gba play CARTRIDGE        Play a script of button presses on a game.
        ruby-gba compare FIRST SECOND  Play two games on the same presses and say
                                       where their screens differ.
        ruby-gba inspect ROM_FILE      Print a .gba's header and first instructions.

      Run ruby-gba COMMAND --help to see a command's options.
    TEXT

    # The words for --set, the same on every command that takes it.
    SET = "--set NAME=VALUE ...     Values for the game's `setting` lines."

    # The words for the buttons --keys holds.
    BUTTONS = RubyGBA::IR::Buttons::NAMES.join(" ")

    # The words for what to press, the same on `play` and `compare`.
    PRESSES = <<~TEXT.chomp
      --script PATH            The script file.
      --playthrough NAME       Which playthrough, when the script has several.
      --tape PATH              Play this tape, in place of a script.
    TEXT

    desc "build GAME_FILE", "Build a .gba cartridge, a program for this computer, or a web page"
    help_page "build", <<~TEXT
      Usage: ruby-gba build GAME_FILE [--format game|native|web] [options]

      Build the game in GAME_FILE, a Ruby file with RubyGBA.game "NAME" do ... end
      in it. What is built goes beside GAME_FILE, named from the game's title.

      Examples:
        ruby-gba build game.rb                    a .gba cartridge
        ruby-gba build game.rb --format=native    a program for this computer
        ruby-gba build game.rb --format=web       a web page that plays the game
        ruby-gba build game.rb -o roms/pong.gba   a cartridge, written to roms/
        ruby-gba build game.rb --set floors=3     with `setting :floors` as 3

      Put GAME_FILE before --set and --keys: they take every word after them.

      Options:
        -o, --output PATH        Where to write what is built.
        --format FORMAT          game, native or web. Default: game.
        #{SET}

      Measuring (see ruby-gba profile --help):
        --stats                  Say how far packing shrank the pictures and
                                 sounds, and what is kept in quick memory.
        --profile                Run the cartridge and report what it costs.
        --scene NAME             Profile this scene. Turns on --profile.
        --keys BUTTON ...        Profile with these buttons held. Turns on
                                 --profile. The buttons are:
                                 #{BUTTONS}

      --format native, a program for this computer:
        --target COMPUTER        windows, linux or linux-arm. Default: this
                                 computer. Not tested on those systems.
        Needs zig 0.17. Run the program with --help to see its keys and options.

      --format web, a web page:
        --js KIND                page, module or script. Default: page.
                                 page: one HTML file that plays the game.
                                 module: an ES module that exports createGame.
                                 script: a script that puts createGame on
                                 window.RubyGBA.
        --global NAME            With --js script: its name on window.RubyGBA.
                                 Default: the file's name.
        --template FILE          An .html.erb file with <%= game %> in it, to
                                 make the page from.
        --data WHERE             inline or separate. Default: inline.
                                 separate: the game's big tables go in a .data
                                 file beside the page, which must be served.

      --format ir prints the game's IR as Ruby, for work on ruby-gba itself.
    TEXT
    option :output, aliases: "-o", banner: "PATH"
    option :format, banner: "NAME", default: "game"
    option :profile, type: :boolean, default: false
    option :stats, type: :boolean, default: false
    option :scene, banner: "NAME"
    option :keys, type: :array, banner: "BUTTON", default: []
    option :set, type: :array, banner: "NAME=VALUE", default: []
    option :target, banner: "COMPUTER"
    option :template, banner: "FILE"
    option :js, default: "page", enum: %w[page module script]
    option :global, banner: "NAME"
    option :data, default: "inline", enum: %w[inline separate]
    def build(game_file)
      refuse_web_options_out_of_place!
      case options[:format]
      when "game" then build_cartridge(game_file)
      when "ir" then build_ir(game_file)
      when "native" then build_native(game_file)
      when "web" then build_web(game_file)
      else
        raise Thor::Error, "#{options[:format].inspect} is not a build format. The formats are: game, ir, native, web."
      end
    rescue ArgumentError => e
      # A setting the game does not ask for, or one it cannot read: say why, not a backtrace.
      raise Thor::Error, e.message
    end

    desc "profile GAME_FILE", "Run the game and report what it costs"
    help_page "profile", <<~TEXT
      Usage: ruby-gba profile GAME_FILE [options]

      Build the game in GAME_FILE, run the cartridge in an emulator, and report
      two things: what the build made (how big each routine is, and which ones
      fit in the console's quick memory), and where the frames went while it ran
      (the frame rate, and how much of each frame was left over).

      Examples:
        ruby-gba profile game.rb
        ruby-gba profile game.rb --keys right a     with right and A held
        ruby-gba profile game.rb --scene level      in the scene named :level
        ruby-gba profile game.rb --from boss.ss1    from an emulator save state

      Options:
        --keys BUTTON ...        Hold these buttons for the whole run. The
                                 buttons are:
                                 #{BUTTONS}
        --scene NAME             Hold the game in this scene, and measure that.
        --from PATH              Start from an emulator save state, made by
                                 playing to that moment once. The state must come
                                 from this same build of the game.
        --frames N               Measure this many frames. Default: #{RubyGBA::Diagnostics::Profiler::FRAMES}.
        --settle N               Run this many frames first, so the game is past
                                 its start. Default: #{RubyGBA::Diagnostics::Profiler::SETTLE}.
        --format FORMAT          human or json. Default: human. json is the
                                 same numbers, to compare two builds.
        #{SET}
    TEXT
    option :format, banner: "NAME", default: "human"
    option :frames, type: :numeric, banner: "N", default: RubyGBA::Diagnostics::Profiler::FRAMES
    option :settle, type: :numeric, banner: "N", default: RubyGBA::Diagnostics::Profiler::SETTLE
    option :keys, type: :array, banner: "BUTTON", default: []
    option :scene, banner: "NAME"
    option :from, banner: "PATH"
    option :set, type: :array, banner: "NAME=VALUE", default: []
    def profile(game_file)
      format = { "human" => :human, "json" => :json }[options[:format]] or
        raise Thor::Error, "#{options[:format].inspect} is not a profile format. The formats are: human, json."
      game = load_game(game_file)
      # Built the same way `build` builds it — measured placement included — so this reports on
      # the cartridge somebody would actually ship, not a differently-placed one.
      game.build_rom(settings: given_settings).profile(format: format, frames: options[:frames],
                             settle: options[:settle], scene: options[:scene],
                             from: options[:from], keys: held_buttons || [])
    rescue ArgumentError => e
      raise Thor::Error, e.message
    end

    # The options `play` and `compare` both take: what says which buttons to press, and the
    # settings a game file is built with.
    def self.options_for_playing
      option :script, banner: "PATH"
      option :playthrough, banner: "NAME"
      option :tape, banner: "PATH"
      option :set, type: :array, banner: "NAME=VALUE", default: []
    end

    desc "play CARTRIDGE", "Play a script of button presses on a game"
    help_page "play", <<~TEXT
      Usage: ruby-gba play CARTRIDGE [options]

      Play CARTRIDGE with nobody at the controls, and print how many frames went
      by and the frame each named moment fell on. CARTRIDGE is a game file (a
      .rb, built first) or a .gba.

      What to press comes from a script or a tape. A script is a Ruby file:

        RubyGBA.playthrough "walk to the door" do
          wait frames: 10
          hold :right, frames: 40
          moment :at_the_door
        end

      A tape is the presses of an earlier play, written by --write-tape. It
      plays the same presses on the same frames on any cartridge.

      Examples:
        ruby-gba play game.rb --script walk.rb
        ruby-gba play game.gba --tape walk.tape --pictures-in shots

      Options:
        #{PRESSES.gsub("\n", "\n  ")}
        --lead-in NAME           Play this playthrough first, and do not count it:
                                 a way past logos and a title screen. Needs
                                 --script, even with --tape.
        --save PATH              Start from this save file.
        --pictures-in DIR        Write the screen at each moment to DIR, as a PNG
                                 named for the moment.
        --write-tape PATH        Write the presses that were made, as a tape.
        --write-save PATH        Write the save memory as the last frame left it.
        #{SET}
    TEXT
    options_for_playing
    option :save, banner: "PATH"
    option :lead_in, banner: "NAME"
    option :pictures_in, banner: "DIR"
    option :write_tape, banner: "PATH"
    option :write_save, banner: "PATH"
    def play(cartridge_file)
      with_playthroughs_command_line { |command| command.play(cartridge_file) }
    end

    desc "compare FIRST SECOND", "Play two games on the same presses and say where they differ"
    help_page "compare", <<~TEXT
      Usage: ruby-gba compare FIRST SECOND [options]

      Play two cartridges on the same presses, and say the first frame on which
      their screens differ. Each is a game file (a .rb, built first) or a .gba.

      Exit status: 0 the same, 1 different, 2 not compared (a file that is not
      there, a script that gave up).

      Examples:
        ruby-gba compare old.gba new.gba --tape walk.tape
        ruby-gba compare game.rb theirs.gba --script walk.rb --carrying-on
        ruby-gba compare a.gba b.gba --tape walk.tape --ignoring-frames 1..120

      What to press, as for ruby-gba play:
        #{PRESSES.gsub("\n", "\n  ")}
        --same WHICH             tape or script. Default: tape.
                                 tape: both get the same presses on the same
                                 frames.
                                 script: the script plays each one by itself,
                                 and the two are compared at each moment.
        --frames-apart N         With --same script: how many frames apart the
                                 two can reach a moment.

      Where the two start:
        --save PATH              Start both from this save file.
        --lead-ins FIRST SECOND  A playthrough for each to play first and not
                                 count, or - for none. Needs --script.

      What counts as different (with none of these, one pixel is a difference):
        --share-may-differ SHARE
                                 The share of the pixels that can differ, 0 to 1.
        --frames-in-a-row N      How many frames in a row must differ.
        --ignoring-rectangles X,Y,WIDTH,HEIGHT ...
                                 Parts of the screen to leave out.
        --ignoring-frames RANGE ...
                                 Frames to leave out: 1..120, 900.., or moments
                                 by name, title..in_the_world.

      What is compared:
        --readings NAME ...      Variables to compare as well as the screen. NAME
                                 reads NAME from both. NAME=VARIABLE reads
                                 VARIABLE from both. NAME=FIRST,SECOND reads a
                                 different one from each. Only a game file has
                                 variable names; a .gba has none.
        --comparing WHAT         picture or readings: compare only that one.
                                 Default: the picture, and any --readings.
        --carrying-on            Go on past the first difference and list them all.
        --reports-in DIR         Write a folder to DIR for each difference: both
                                 screens, where they differ, and a tape that plays
                                 a cartridge to that frame.
        #{SET}
    TEXT
    options_for_playing
    option :share_may_differ, type: :numeric, banner: "SHARE"
    option :frames_in_a_row, type: :numeric, banner: "N"
    option :ignoring_rectangles, type: :array, banner: "X,Y,WIDTH,HEIGHT"
    option :ignoring_frames, type: :array, banner: "RANGE"
    option :readings, type: :array, banner: "NAME[=VARIABLE[,VARIABLE]]"
    option :comparing, type: :array, banner: "WHAT", enum: %w[picture readings]
    option :carrying_on, type: :boolean
    option :same, banner: "WHICH", enum: %w[tape script]
    option :frames_apart, type: :numeric, banner: "N"
    option :save, banner: "PATH"
    option :lead_ins, type: :array, banner: "NAME"
    option :reports_in, banner: "DIR"
    def compare(first_file, second_file)
      result = with_playthroughs_command_line { |command| command.compare(first_file, second_file) }
      exit DRIFTED if result.drift?
    end

    desc "preview GAME_FILE", "Play the game in a browser, built again on every reload"
    help_page "preview", <<~TEXT
      Usage: ruby-gba preview GAME_FILE [options]

      Serve the game in GAME_FILE as a web page on this computer, and print its
      address. Open it in a browser to play. Change the game file and reload the
      page: the page is built again from the file. If the build stops, the page
      says why. Press Ctrl-C to stop the server.

      The browser does not run the cartridge. Test the .gba as well before you
      give it to anybody.

      Options:
        --port N                 The port to serve the page on. Default: 8000.
        --template FILE          Make the page from FILE, an .html.erb file with
                                 <%= game %> in it.
        #{SET}
    TEXT
    option :port, type: :numeric, default: 8000
    option :template, banner: "FILE"
    option :set, type: :array, banner: "NAME=VALUE", default: []
    def preview(game_file)
      raise Thor::Error, "I cannot find the game file #{game_file}." unless File.file?(game_file)

      server = RubyGBA::IR::Backends::JS::Preview.new(game_file, settings: options[:set], template: options[:template],
                                                                 port: options[:port])
      trap("INT") { server.stop }
      server.serve
    rescue Errno::EADDRINUSE
      raise Thor::Error, "Port #{options[:port]} is in use already. Give another with --port."
    end

    desc "inspect ROM_FILE", "Print a .gba's header and first instructions"
    help_page "inspect", <<~TEXT
      Usage: ruby-gba inspect ROM_FILE

      Print the header of a .gba (its title, game code, maker and checksum, and
      whether the checksum is right), then its first instructions, disassembled.
    TEXT
    def inspect(rom_file)
      raise Thor::Error, "I cannot find the ROM file #{rom_file}." unless File.file?(rom_file)

      RubyGBA::Diagnostics::Inspector.new(rom_file).report
    end

    desc "new NAME", "Write a starter game to NAME.rb"
    help_page "new", <<~TEXT
      Usage: ruby-gba new NAME [options]

      Write NAME.rb: a game that builds and runs, to start from.

      Example:
        ruby-gba new pong        writes pong.rb. Then: ruby-gba build pong.rb

      Options:
        --force                  Write over NAME.rb if it is there already.
    TEXT
    option :force, type: :boolean, default: false
    def new(name)
      file = "#{name}.rb"
      if File.exist?(file) && !options[:force]
        raise Thor::Error, "#{file} already exists. Use --force to overwrite it."
      end

      File.write(file, starter_source(name))
      say "Wrote #{file}. Run it with `ruby #{file}` or `ruby-gba build #{file}`."
    end

    refuse_undocumented_options!
    HELP_PAGES.freeze

    private

    # --- play and compare ---

    # `play` and `compare` are done by the library (see Playthroughs::CommandLine), which is
    # handed the options, somewhere to print, and how a game file is built here. What it
    # refuses, it refuses in a sentence, and that sentence is what the command ends with.
    def with_playthroughs_command_line
      build = ->(file) { load_game(file).build_rom(settings: given_settings) }
      yield RubyGBA::Playthroughs::CommandLine.new(options, out: $stdout, build: build)
    rescue RubyGBA::Playthroughs::CommandLine::Refused => e
      raise Thor::Error, e.message
    end

    # --- build and profile ---

    # The "game" format (--format=game, the default): the .gba cartridge itself.
    def build_cartridge(game_file)
      game = load_game(game_file)
      # Somebody is sitting there waiting for this, so it says what it is doing.
      rom = game.build_rom(progress: RubyGBA::Messages::Progress.to($stderr), settings: given_settings)
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
      rom = game.build_rom(settings: given_settings)
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
      target = options[:target]&.tr("-", "_")&.to_sym
      if target && !RubyGBA::IR::Backends::Native::TARGETS.key?(target)
        names = RubyGBA::IR::Backends::Native::TARGETS.keys.map { |name| name.to_s.tr("_", "-") }
        raise Thor::Error, "There is no build for #{options[:target]}. A game can be built for " \
                           "#{names.join(', ')}. To build for this computer, leave out --target."
      end
      path = options[:output] || begin
        plain = File.join(File.dirname(File.expand_path(game_file)), game.default_filename.delete_suffix(".gba"))
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
      js = options[:js]
      path = options[:output] ||
             File.join(File.dirname(File.expand_path(game_file)), game.default_filename.delete_suffix(".gba") + WEB_OUTPUTS.fetch(js))
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
          RubyGBA.game "NAME" do
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
        # `ruby-gba build #{name}.rb`.

        require "ruby_gba"

        #{const} = RubyGBA.game "#{title}" do
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
      const.match?(/\A[A-Z]/) ? const : "Game"
    end
  end
end
