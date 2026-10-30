# frozen_string_literal: true

module VBlank
  module Cartridge
    # A game the DSL block defines but has not built yet.
    #
    # `VBlank.game "NAME", consoles: %i[gba] do ...dsl... end` records the title, the consoles, the cartridge codes if
    # the game bothered to write any, and the DSL block, and hands back this handle — WITHOUT building
    # or writing anything. That separation is the point: a game file only declares the
    # game, so the tool that drives the build (the `vblank` command) owns the output
    # path and how much it prints. The same handle also carries the two methods tests
    # build against — #program (the op-tree the reference interpreter runs) and
    # #build_rom (the finished cartridge) — so an example is one `VBlank.game` call
    # instead of a module of wiring.
    class Game
      # +options+ is how the game is built (see {Options}), as the game said it.
      attr_reader :title, :code, :maker, :options

      # The consoles the game is for, by name (see Console::DESCRIPTIONS), in the order the game
      # wrote them. A game built for one it is not for is refused.
      attr_reader :consoles

      # Whether the game's window, played on a computer, has a menu: it does unless the game says not.
      def menu? = @menu

      # +options+ is part of what the cartridge is — how much save memory it has, how quickly
      # it reads — so like +code+ it is said where the game is named. +menu+ false is a game whose
      # window, played on a computer, opens no menu over the picture.
      def initialize(title, consoles:, code: nil, maker: nil, block:, options: Options.new, menu: true, variants: {})
        @title = title
        @code = code
        @maker = maker
        @options = options
        @menu = menu
        @consoles = Console.refuse_unknown_consoles!(consoles, setting: "consoles:")
        @variants = refuse_unusable_variants!(variants)
        refuse_piece_size_not_for_consoles!
        Console.refuse_unusable_console_settings!(console_settings_said, consoles: @consoles, title: title,
                                                                         named_in: "consoles:")
        @block = shareable_if_possible(block)
        freeze
      end

      # A GAME CAN BE BUILT ON ANY CORE, so long as its block reaches for nothing around it.
      #
      # The handle keeps the author's block so the game can be built later, and a block
      # normally carries the scope it was written in — which is the one thing two cores may
      # never share. A block that captures nothing can be cut loose from that scope, and one
      # written inside `module Pong` is exactly that: it names constants and methods, never a
      # variable from outside.
      #
      # A game declared at the top LEVEL of a file cannot be, because a block written there
      # belongs to Ruby's own main object and that is not shareable either. Such a game still
      # builds perfectly well — on the core that declared it, which is where it was going to
      # be built anyway. So this tries, and keeps what it was given when it cannot.
      private def shareable_if_possible(block)
        materialize_block_parameters(block)
        Ractor.make_shareable(block)
      rescue Ractor::IsolationError
        block
      end

      # A BLOCK PARAMETER IS THE ONE LOCAL RUBY DOES NOT CHECK, so it is read here first.
      #
      # A method written `def declare(&subject)` is not handed a Proc for +subject+ until
      # something asks for one: until then the variable is an empty place and the block waits
      # beside it. Cutting a block loose copies the places it reads, so a game's block that
      # reads +subject+ was given the empty place — nothing to refuse, since nothing is as
      # shareable as it gets — and the game read nil where its method's block was, with no
      # error anywhere.
      #
      # Reading every local the block can see asks for that Proc. After that the place holds
      # one, which cannot be shared, so the block is refused like any other that reaches for
      # something around it and the game is built on the core that declared it.
      #
      # A block made from a method or a symbol has no surroundings to read, and none to lose.
      private def materialize_block_parameters(block)
        scope = block.binding
        scope.local_variables.each { |name| scope.local_variable_get(name) }
      rescue ArgumentError
        nil
      end

      # The op-tree the DSL block builds — what the headless interpreter runs in tests.
      # Built with the same frame timing #build_rom uses, so the tree a test runs is
      # the tree that ships.
      #
      # RUN ONCE AND REMEMBERED, because asking a game what it is should not be an event: a
      # game's block is the slowest thing in a build, since it is where the art and the levels
      # are read off disk, and a test or a tool asks more than once. Every consumer in the
      # library treats the tree as read-only and the one that rewrites one (see
      # {Analyzer#boot_into}) already answers a copy, so there is one tree and everybody
      # shares it.
      #
      # The game's own progress reporting is OFF here, deliberately: this path is a test or
      # a tool asking what the game is, and nobody is watching a tree being built. A person
      # waiting on a build gets it through {#build_rom}, which takes a +progress+.
      #
      # +settings+ are what this build is told, read by the game with `setting` — which floors,
      # which screen it boots on. A test builds a variant by passing a value here, and nothing
      # anybody else is building changes. Remembered per set of settings.
      #
      # +console+ is the console it is built for, the first the game names unless said: the game
      # reads that console's screen as its block runs (`screen_width`), so the tree is that
      # console's.
      #
      # +variant+ is the console's variant it is built for (Console::Variant): the one the game
      # names for +console+ in `variants:` unless said, and nil for the plain console.
      def program(settings: {}, console: @consoles.first, variant: variant_for(console))
        evaluated(settings, refuse_console_not_for!(console), variant).program
      end

      # THE PROGRAM A GAME PLAYED AS RUBY RUNS: checked as a build checks it, every guardrail on and
      # their warnings printed to +err+, without making the cartridge (VBlank.build's +cartridge+).
      # +progress+, +settings+ and +console+ are as for #build_rom.
      def checked_program(err: $stderr, progress: Messages::Progress.silent, settings: {}, console: @consoles.first)
        build_rom(out: nil, err: err, progress: progress, profile: false, settings: settings, console: console,
                  cartridge: false)
      end

      # The variant the game names for +console+ in `variants:`, or nil.
      def variant_for(console) = @variants[console.to_sym]

      # The finished ROM. Where the build prints is injectable, so a test (or the CLI) captures
      # it: out:/err: each take an open stream, the name of a file, or nil for a build that
      # prints nothing (see {Messages::BuildOutput}).
      # THIS ONE MEASURES THE GAME, which {VBlank.build} does not do by default.
      #
      # The split is by who is asking. This is the method that makes a cartridge somebody is
      # going to play — it is what `ruby game.rb` and the `vblank` command call — so it is
      # worth building twice to get the placement right: build, run, measure, build again
      # knowing (see {VBlank.build_measured}). VBlank.build is the primitive the suite calls
      # thousands of times to check pixels and guardrails, where none of that matters.
      #
      # Pass `profile: false` to skip it — a quicker build, and one that depends on nothing but
      # the source. Pass a path or a {RoutineProfile} to use a measurement taken by hand, for a
      # moment the automatic one cannot reach.
      #
      # +settings+ are what this build is told, as for #program.
      #
      # +console+ is the console the cartridge is for, the first the game names unless said: a
      # Game Boy Advance cartridge (Cartridge::ROM) or a Game Boy Color one (Cartridge::GBCROM).
      #
      # A console setting the game says that +console+ does not have is for another of the game's
      # consoles, and this cartridge is built without it. A saved +profile+ handed here is this
      # build's own, so on a console that cannot use one it is refused.
      #
      # +variant+ is as for #program; the command line's `--variant` hands one here.
      def build_rom(out: $stdout, err: $stderr, validate: true, progress: Messages::Progress.silent,
                    profile: true, settings: {}, console: @consoles.first, variant: variant_for(console), cartridge: true)
        console = refuse_console_not_for!(console)
        options = { code: @code, maker: @maker, **@options.with(console: console, variant: variant).to_h }
        options = options.except(*(Console.console_settings - Console.for(console).console_settings))
        VBlank.build(@title, validate: validate, out: out, err: err, progress: progress, profile: profile,
                              settings: settings, cartridge: cartridge, **options, &@block)
      end

      # A friendly output filename from the title, ending as the console's cartridges do:
      # "BIRD" -> "bird.gba", and for a Game Boy Color "bird.gbc".
      def default_filename(console: @consoles.first)
        base = @title.to_s.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_+|_+\z/, "")
        "#{base.empty? ? 'game' : base}#{Console.described(console).extension}"
      end

      # Build this game and write a cartridge for each console it names beside the file that
      # calls this, as `vblank build` does — but only when that file is the script Ruby was
      # run with (`ruby game.rb`). Put it as the last line of a game file so a plain run
      # produces its cartridges, while requiring the file (a test) or loading it (the
      # `vblank` command) stays silent and writes nothing. Returns self. Unlike the command, it
      # stops at the first console whose build fails, with Ruby's own report of the error; the
      # cartridges built before it are written.
      #
      # +settings+ are what this build is told. This line is the command line's edge, so it is
      # the one place a game reads the environment if it wants to:
      # `write_if_main(settings: { floors: ENV.fetch("FLOORS", "60") })`.
      def write_if_main(settings: {})
        caller_path = caller_locations(1, 1)&.first&.path
        return self unless caller_path && main_script?(caller_path)

        # SAY WHAT IT IS DOING, because this path is by definition somebody who ran a build by
        # hand and is now waiting for it. A build reached any other way — a test, a tool, a
        # library call — stays silent, which is what the default does.
        @consoles.each do |console|
          rom = build_rom(progress: Messages::Progress.to($stderr), settings: settings, console: console)
          path = File.join(File.dirname(File.expand_path(caller_path)), default_filename(console: console))
          rom.write(path)
          $stdout.puts "Built #{File.basename(path)} (#{rom.size} bytes)"
        end
        self
      end

      private

      # The console settings this game says, by name, to their values.
      def console_settings_said = Console.console_settings_said(code: @code, maker: @maker, **@options.to_h)

      # This game's block, run — the tree and what the run learned besides.
      #
      # REMEMBERED PER CORE rather than on the handle, because the handle is frozen so that
      # it can cross to another core at all. Each core that asks runs the block once and
      # keeps the answer; running a block is cheap next to lowering it, and a core that
      # never asks pays nothing.
      def evaluated(settings, console, variant)
        seen = (Ractor.current[:vblank_evaluated_games] ||= {})
        seen[[self, settings, console, variant]] ||=
          EvaluatedGame.new(@block, options: @options.with(console: console, variant: variant), settings: settings)
      end

      # A GAME NAMES ITS CHIP WHERE IT NAMES ITS CONSOLES: `consoles: %i[gba snes], variants: {
      # snes: :superfx }`. A chip is part of what the cartridge is, as much as which console it goes
      # in, so it is said in the same line and not left to whoever builds it; `vblank build
      # --variant` still overrides it for one build. +variants+ is keyed by console, since one game
      # can be for several consoles and only some of them have variants. Each must be one of the
      # game's consoles and one of that console's variants (Console::Kit#variants).
      def refuse_unusable_variants!(variants)
        unless variants.is_a?(Hash)
          raise ArgumentError, "#{@title} says variants: #{variants.inspect}. variants: names a console and its " \
                               "variant, like `variants: { snes: :superfx }`."
        end

        variants.to_h do |console, name|
          console = Console.named(console)
          unless @consoles.include?(console)
            raise ArgumentError, "#{@title} names a variant for the #{Console.described(console).title}, and the " \
                                 "game is not for it. To fix this, add :#{console} to consoles:, or remove it from " \
                                 "variants:."
          end
          [console, Console.for(console).variant(name)&.name]
        end.compact.freeze
      end

      # A size of sprite piece named for a console the game is not for is refused, as a variant is:
      # the author asked for something no cartridge of the game's would have.
      def refuse_piece_size_not_for_consoles!
        console = @options.sprite_piece_size.each_key.find { |name| !@consoles.include?(name) } or return

        raise ArgumentError, "#{@title} names a sprite_piece_size: for the #{Console.described(console).title}, and " \
                             "the game is not for it. To fix this, add :#{console} to consoles:, or remove it from " \
                             "sprite_piece_size:."
      end

      # +console+, when the game is for it; a plain refusal when it is not.
      def refuse_console_not_for!(console)
        console = console.to_sym
        return console if @consoles.include?(console)

        described = Console.described(console)
        raise ArgumentError, "#{@title} is written for the #{@consoles.map { |name| Console.described(name).title }.join(' and ')}, " \
                             "not the #{described.title}. A #{described.title} has a #{described.screen_width}×" \
                             "#{described.screen_height} screen. To build it for one, lay the game out from " \
                             "`screen_width` and `screen_height` rather than numbers for one screen, and say " \
                             "`consoles: %i[#{(@consoles + [console]).join(' ')}]` where the game is named."
      end

      # Is +path+ the very script Ruby was told to run? Compared as full paths so a
      # relative "examples/bird.rb" and an absolute run path still match.
      # Read when this file loads. It never changes while a process runs, and a worker
      # Ractor may not read a global at all.
      MAIN_SCRIPT = $PROGRAM_NAME

      def main_script?(path)
        program = MAIN_SCRIPT
        !program.nil? && File.expand_path(path) == File.expand_path(program)
      end
    end
  end

  class << self
    # Every game declared here, in declaration order (usually one per file). The `vblank`
    # command loads a game file and reads the game it declared from here.
    #
    # KEPT PER RACTOR rather than for the whole process. A declared game holds the author's
    # own block so it can be built later, and a block carries the surroundings it was
    # written in — the one thing Ruby will not let two cores share. Kept on the module this
    # could be neither written nor read from a worker, and a worker builds games.
    #
    # Nothing is lost by it being per core: whoever declares a game is whoever wants it
    # back. The command-line tool declares and reads on the main one.
    def registered_games = Ractor.current[:vblank_registered_games] || EMPTY

    # Forget every game declared so far. The `vblank` command does this before loading a
    # game file, so that whatever the file adds is the game it asked for.
    def forget_registered_games!
      Ractor.current[:vblank_registered_games] = nil
      self
    end

    EMPTY = [].freeze

    # Declare a game: record its DSL block for later building and return a Game
    # handle. Building and writing are left to the caller — see Game — except for the
    # `ruby game.rb` convenience above.
    #
    # +frame_sync+, +fast_cartridge+, +fast_code+, +save_memory+ and +stack_room+ say how it is
    # built, the same five {VBlank.build} takes; see {Cartridge::Options}.
    #
    # +consoles+ are the consoles the game is for (see Console::DESCRIPTIONS), and every game says
    # them: `consoles: %i[gba]` for the Game Boy Advance alone, `consoles: %i[gba gbc]` for the
    # Game Boy Color too. NOTHING IS TAKEN TO BE FOR THE ADVANCE, because the command line builds
    # a cartridge for each console a game names, and a game that said nothing would be built for
    # whichever console the framework happened to start with.
    #
    # A console setting, one only some consoles have (+code+, +maker+, +fast_cartridge+,
    # +fast_code+, +stack_room+; see Cartridge::AdvanceBuild::SETTINGS), is for the consoles of the
    # game's that have it, and a game none of whose consoles has it is refused here.
    #
    # +menu+ false leaves out the menu a window played on a computer opens over the picture.
    #
    # +variants+ names a chip on a console's cartridge, by console: `variants: { snes: :superfx }`
    # for a Super Nintendo cartridge with a Super FX 2 (see Console::Variant).
    #
    # +sprite_piece_size+ is the size each of its consoles draws a sprite's pieces at, by console:
    # `sprite_piece_size: { gbc: [8, 16] }` for the Color's tall pieces (see Cartridge::Options).
    def game(title, code: nil, maker: nil, frame_sync: :auto, fast_cartridge: nil, fast_code: nil,
             save_memory: nil, stack_room: nil, consoles: nil, menu: true, variants: {}, sprite_piece_size: {},
             &block)
      unless block
        raise ArgumentError, %(VBlank.game needs a block: VBlank.game("NAME", consoles: %i[gba]) { ... })
      end
      refuse_unsaid_consoles!(title) if consoles.nil?
      unless [true, false].include?(menu)
        raise ArgumentError, "#{title} says menu: #{menu.inspect}. menu: must be true or false. Write menu: false " \
                             "to leave out the menu."
      end

      options = Cartridge::Options.new(frame_sync: frame_sync, fast_cartridge: fast_cartridge,
                                       fast_code: fast_code, save_memory: save_memory, stack_room: stack_room,
                                       sprite_piece_size: sprite_piece_size)
      handle = Cartridge::Game.new(title, code: code, maker: maker, block: block, options: options, consoles: consoles,
                                          menu: menu, variants: variants)
      Ractor.current[:vblank_registered_games] = registered_games + [handle]
      handle
    end

    private

    def refuse_unsaid_consoles!(title)
      raise ArgumentError, "#{title} does not say which consoles it is for. Add consoles: where the game is " \
                           "named: `VBlank.game #{title.to_s.inspect}, consoles: %i[gba]` for the Game Boy " \
                           "Advance alone, or `consoles: %i[gba gbc]` for the Game Boy Color too."
    end
  end
end
