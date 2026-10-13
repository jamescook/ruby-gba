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

    def self.start(given_args = ARGV, config = {})
      super(given_args, config.merge(debug: true))
    rescue Thor::Error => e
      raise if ENV["THOR_DEBUG"] == "1"

      warn e.message
      exit(given_args.first == "compare" ? NOT_COMPARED : 1)
    end

    # The options `play` and `compare` both take: what says which buttons to press, and the
    # settings a game file is built with.
    def self.options_for_playing(tape:)
      option :script, banner: "PATH", desc: "A Ruby file that declares playthroughs with RubyGBA.playthrough"
      option :playthrough, banner: "NAME", desc: "Which playthrough in the script file to play, when it declares several"
      option :tape, banner: "PATH", desc: tape
      option :set, type: :array, banner: "NAME=VALUE", default: [],
                   desc: "Tell every game file a setting it reads with `setting` (for example --set floors=1)"
    end

    desc "build GAME_FILE", "Build a game file into a .gba cartridge"
    long_desc <<~TEXT
      Build the game declared in GAME_FILE into a Game Boy Advance cartridge. The file
      declares its game with:

        RubyGBA.game "NAME" do
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
    option :set, type: :array, banner: "NAME=VALUE", default: [],
                 desc: "Tell the game a setting it reads with `setting` (for example --set floors=1)"
    def build(game_file)
      case options[:format]
      when "game" then build_cartridge(game_file)
      when "ir" then build_ir(game_file)
      else
        raise Thor::Error, "#{options[:format].inspect} is not a build format. The formats are: game, ir."
      end
    rescue ArgumentError => e
      # A setting the game does not ask for, or one it cannot read: say why, not a backtrace.
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
    TEXT
    option :format, banner: "NAME", default: "human",
                    desc: "What to print: human (the report) or json (the same numbers as data)"
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
      game.build_rom(settings: given_settings).profile(format: format, frames: options[:frames],
                             settle: options[:settle], scene: options[:scene],
                             from: options[:from], keys: held_buttons || [])
    rescue ArgumentError => e
      raise Thor::Error, e.message
    end

    desc "play CARTRIDGE", "Play a game from a script or a tape, with nobody at the controls"
    long_desc <<~TEXT
      Play CARTRIDGE with nobody at the controls, and say how many frames went by and the
      frame each named moment fell on. CARTRIDGE is a game file (a .rb that declares a
      game, which is built first) or a cartridge file (a .gba, yours or somebody else's).

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
      saying_errors_plainly do
        refuse_missing_cartridges!(cartridge_file)
        playing = tape_or_playthrough(lead_in_flag: :lead_in)
        lead_in = lead_in_named(options[:lead_in])
        %i[write_tape write_save].each { |flag| refuse_unwritable_file!(flag) }
        cartridge = cartridge_at(cartridge_file)
        played = playing.play(cartridge, **{ save: options[:save], lead_in: lead_in, pictures_in: options[:pictures_in] }.compact)
        say_frames_and_moments(played, playing, cartridge)
        write_tape_and_save(played)
      end
    end

    desc "compare FIRST SECOND", "Play two cartridges on the same presses, and say where they drift"
    long_desc <<~TEXT
      Play the cartridges FIRST and SECOND side by side and say the first frame on which
      they differ. Each is a game file (a .rb, built first) or a cartridge file (a .gba).

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
      result = saying_errors_plainly do
        refuse_missing_cartridges!(first_file, second_file)
        presses = tape_or_playthrough(lead_in_flag: :lead_ins)
        settings = comparison_settings
        cartridges = [first_file, second_file].map { |file| cartridge_at(file) }
        presses.compare(*cartridges, **settings).tap { |found| say_drifts_or_agreement(found) }
      end
      exit DRIFTED if result.drift?
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

    # What a playing or a comparison stops with that is the caller's to fix: a setting that
    # makes no sense, a wait that never ended, a reading that could not be read, a report
    # that could not be written. Each already says what happened and what to do, so it is
    # printed as it is, and not as a backtrace.
    PLAYING_ERRORS = [ArgumentError, RubyGBA::ROMError, RubyGBA::Diagnostics::Playthrough::GaveUp,
                      RubyGBA::Diagnostics::Comparison::ReadingFailed,
                      RubyGBA::Diagnostics::Comparison::ReportNotWritten].freeze

    # The settings the library names in its own messages, written the way Ruby writes them.
    # On the command line each is the flag of the same name.
    SETTINGS_WITH_FLAGS = (RubyGBA::Diagnostics::Comparison.settings + %i[lead_in pictures_in]).freeze

    def saying_errors_plainly
      yield
    rescue *PLAYING_ERRORS => e
      raise Thor::Error, message_with_flags(e.message)
    end

    # A message from the library names a setting the way Ruby writes it (`ignoring_frames:`).
    # The message is kept as it is, and a line under it says which flag that setting is.
    def message_with_flags(message)
      named = message.scan(/`(\w+):/).flatten.uniq.map(&:to_sym) & SETTINGS_WITH_FLAGS
      return message if named.empty?

      "#{message}\nOn the command line, #{named.map { |setting| "`#{setting}:` is #{flag_of(setting)}" }.join(', and ')}."
    end

    def flag_of(setting) = "--#{setting.to_s.tr('_', '-')}"

    # Every file has to be there before anything is built: building the first game file
    # takes a while, and the second file's name can be the one spelled wrong.
    def refuse_missing_cartridges!(*files)
      missing = files.find { |file| !File.file?(file) } or return

      raise Thor::Error, "I cannot find #{missing}. Give a game file (a .rb that declares a game) or a cartridge file (a .gba)."
    end

    # The cartridge a file is: a game file is built, the way `build` builds it, and
    # anything else is taken for a cartridge file and read.
    def cartridge_at(file)
      return RubyGBA::Diagnostics::Playthrough.cartridge_from(file) unless file.end_with?(".rb")

      load_game(file).build_rom(settings: given_settings)
    end

    # What says which buttons to press: the tape, where one was given, or else the
    # playthrough picked from the script file. +lead_in_flag+ is the option this command
    # takes a lead-in by, which a tape recorded after one needs.
    def tape_or_playthrough(lead_in_flag:)
      return playthrough_to_play unless options[:tape]

      refuse_tape_with_same_script!
      RubyGBA::Diagnostics::Playthrough::Tape.read(options[:tape]).tap { |tape| refuse_tape_missing_start!(tape, lead_in_flag) }
    end

    def refuse_tape_with_same_script!
      return unless same_script?

      raise Thor::Error, "--same script plays a script on each cartridge by itself, and a tape holds no script. " \
                         "Give the script with --script in place of --tape, or leave --same out."
    end

    # A tape says what it was recorded from, and the same presses from anywhere else are a
    # different game. What it needs is asked for by its flag, before anything is built.
    def refuse_tape_missing_start!(tape, lead_in_flag)
      if tape.recorded_from_save? && !options[:save]
        raise Thor::Error, "The tape #{options[:tape]} was recorded from a save. Give that save with --save."
      end
      return unless tape.recorded_after_lead_in? && !options[lead_in_flag]

      raise Thor::Error, "The tape #{options[:tape]} was recorded after a lead-in. Name the lead-in with " \
                         "#{flag_of(lead_in_flag)}, and give the script file that declares it with --script."
    end

    # Every playthrough the script file declares. The file only declares them, so the
    # list is cleared, the file loaded, and what it added taken — once, however many
    # times it is asked.
    def declared_playthroughs
      @declared_playthroughs ||= begin
        file = options[:script] or
          raise Thor::Error, "I need to know what to press. Give a script file with --script, or a tape with --tape."
        raise Thor::Error, "I cannot find the script file #{file}." unless File.file?(file)

        RubyGBA.forget_registered_playthroughs!
        load File.expand_path(file)
        RubyGBA.registered_playthroughs.tap do |declared|
          next unless declared.empty?

          raise Thor::Error, <<~MSG.chomp
            #{file} does not declare a playthrough. Add:
              RubyGBA.playthrough "NAME" do
                # ...the steps...
              end
          MSG
        end
      end
    end

    def playthrough_to_play
      return playthrough_named(options[:playthrough]) if options[:playthrough]
      return declared_playthroughs.first if declared_playthroughs.one?

      raise Thor::Error, "#{options[:script]} declares #{declared_playthroughs.size} playthroughs, and I do not know which " \
                         "to play. Say which with --playthrough. They are: #{playthrough_names}."
    end

    # A playthrough by its name, which a command line can only give as text: one declared
    # with a symbol for a name is found by the same letters.
    def playthrough_named(name)
      declared_playthroughs.find { |declared| declared.name.to_s == name } or
        raise Thor::Error, "#{options[:script]} declares no playthrough named #{name.inspect}. " \
                           "Its playthroughs are: #{playthrough_names}."
    end

    def playthrough_names = declared_playthroughs.map { |declared| declared.name.to_s.inspect }.join(", ")

    # A lead-in is a playthrough from the script file, by its name, and `-` or nothing
    # said is none. A tape says what to press and declares no playthrough, so a lead-in
    # needs the script file whatever the presses come from.
    def lead_in_named(name)
      return nil if name.nil? || name == "-"
      return playthrough_named(name) if options[:script]

      raise Thor::Error, "A lead-in is a playthrough in a script file, and no script file was given. " \
                         "Give the file that declares #{name.inspect} with --script."
    end

    # The lead-in of each cartridge, the first one's and then the second's.
    def lead_ins_named(names)
      return names.map { |name| lead_in_named(name) } if names.size == 2

      raise Thor::Error, "--lead-ins needs two names, the first cartridge's lead-in and then the second's. " \
                         "It was given #{names.size}. Write - for a cartridge with no lead-in, for example --lead-ins intro -."
    end

    # A tape and a save are written after the whole playing, so a place that cannot be
    # written to is refused before a frame is played.
    def refuse_unwritable_file!(flag)
      path = options[flag] or return
      raise Thor::Error, "#{flag_of(flag)} #{path} is a folder. Give the name of a file to write." if File.directory?(path)

      folder = File.dirname(File.expand_path(path))
      return if File.directory?(folder) && File.writable?(folder)

      raise Thor::Error, "#{flag_of(flag)} #{path} cannot be written. The folder #{File.dirname(path)} is not there, " \
                         "or cannot be written to. Make the folder, then run this again."
    end

    def say_frames_and_moments(played, playing, cartridge)
      title = RubyGBA::Diagnostics::Playthrough::Tape.title_and_checksum_of(cartridge).first
      what = options[:tape] ? "the tape #{options[:tape]}" : playing.name.to_s.inspect
      say "Played #{played.frames} frames of #{what} on #{title}."
      say_moments(played.moments) { |frame| "frame #{frame}" }
      say "Wrote #{played.picture_files.size} pictures in #{options[:pictures_in]}." if options[:pictures_in]
    end

    # One line a moment, the names in a column, and after each whatever the block makes of
    # the frame or frames it was reached on.
    def say_moments(moments)
      width = moments.keys.map { |name| name.to_s.size }.max
      moments.each { |name, reached| say "  #{name.to_s.ljust(width)}  #{yield reached}" }
    end

    def write_tape_and_save(played)
      say "Wrote the tape to #{played.tape.write(options[:write_tape])}." if options[:write_tape]
      return unless options[:write_save]
      return say("This cartridge has no save memory, so no save was written.") unless played.save

      say "Wrote the save to #{played.save.write_sav(options[:write_save])}."
    end

    # Every setting that was said, as `compare` takes them from Ruby: each is the option of
    # the same name, and the ones a command line can only give as text are read here. One
    # that was not said is left out, so that what it is with nothing said stays the
    # library's to say.
    def comparison_settings
      said = RubyGBA::Diagnostics::Comparison.settings.to_h { |setting| [setting, options[setting]] }.compact
      said.to_h do |setting, written|
        [setting, case setting
                  when :ignoring_rectangles then written.map { |one| parse_rectangle(one) }
                  when :ignoring_frames then written.map { |one| parse_frame_stretch(one) }
                  when :readings then written.to_h { |one| parse_reading(one) }
                  when :comparing then written.map(&:to_sym)
                  when :same then written.to_sym
                  when :lead_ins then lead_ins_named(written)
                  else written
                  end]
      end
    end

    def parse_rectangle(written)
      numbers = written.split(",")
      return numbers.map(&:to_i) if numbers.size == 4 && numbers.all? { |number| number.match?(/\A\d+\z/) }

      raise Thor::Error, "--ignoring-rectangles #{written} is not a rectangle. Write it as X,Y,WIDTH,HEIGHT, " \
                         "for example --ignoring-rectangles 0,128,240,32."
    end

    # A stretch as it is written on a command line: two ends with two dots between them,
    # or three to leave the last one out. An end is a frame number or a moment's name, and
    # either can be left off.
    def parse_frame_stretch(written)
      match = written.match(/\A(\w*)(\.{2,3})(\w*)\z/) or raise ArgumentError
      first, last = [match[1], match[3]].map { |text| parse_stretch_end(text) }
      Range.new(first, last, match[2].size == 3)
    rescue ArgumentError
      raise Thor::Error, "--ignoring-frames #{written} is not a range. Write a range of frame numbers or of moments, " \
                         "for example --ignoring-frames 1..120 title..in_the_world."
    end

    def parse_stretch_end(text)
      return nil if text.empty?

      text.match?(/\A\d+\z/) ? text.to_i : text.to_sym
    end

    # A reading as it is written on a command line, which can only be variables: a name
    # alone is the variable of that name on both, and after `=` it is one variable for
    # both, or two with a comma between them, the first cartridge's and the second's.
    def parse_reading(written)
      name, variables = written.split("=", 2)
      variables = (variables || name).split(",").map(&:to_sym)
      if name.to_s.empty? || variables.empty? || variables.size > 2
        raise Thor::Error, "--readings #{written} is not a reading. Write NAME, or NAME=VARIABLE, or NAME=FIRST,SECOND, " \
                           "for example --readings steps hero_x=px,hx."
      end
      [name.to_sym, variables.one? ? variables.first : variables]
    end

    def same_script? = options[:same] == "script"

    def say_drifts_or_agreement(result)
      if result.drift?
        result.drifts.each { |drift| say_drift(drift, result) }
      elsif same_script?
        say "The two cartridges agree at every named moment."
      else
        say "The two cartridges agree. #{result.frames} frames were played, and no frame drifted."
      end
      return unless same_script?

      say "The frame each cartridge reached each moment on:"
      say_moments(result.moments) { |ours, theirs| "first #{ours}, second #{theirs}" }
    end

    def say_drift(drift, result)
      if same_script?
        ours, theirs = result.moments.fetch(drift.moment)
        say "The two cartridges drifted at the moment #{drift.moment}: frame #{ours} on the first, frame #{theirs} on the second."
      else
        before = drift.moment ? " The moment named before it was #{drift.moment}." : ""
        say "The two cartridges drifted on frame #{drift.frame}.#{before}"
      end
      say "  what differed: #{drift.differed.join(', ')}"
      say "  it lasted to frame #{drift.last_frame} (#{HOW_A_DRIFT_ENDED.fetch(drift.ended)})" if drift.last_frame
      say "  report: #{drift.report}" if drift.report
    end

    HOW_A_DRIFT_ENDED = { back_in_step: "then the two were back in step", not_looked_at: "the next frame was not looked at",
                          tape_ran_out: "the last frame that was played" }.freeze

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
      const =~ /\A[A-Z]/ ? const : "Game"
    end
  end
end
