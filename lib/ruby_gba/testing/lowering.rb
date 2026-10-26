# frozen_string_literal: true

module RubyGBA
  module Testing
    # WHICH LOWERING A RUN OF A SUITE TESTS, said in one setting, and which test files that run
    # loads. Both the rake tasks (RakeTasks) and the tests themselves (Testing.lowering) read it
    # from here, so the two cannot answer differently.
    #
    # A game is played three ways, or four when it is for the Game Boy Color too (see
    # Run#console). The GBA lowering's run plays it on the interpreter
    # (Backends::Reference), which is what the cartridge is checked against; the native
    # lowering's run builds it as C and plays that, the JavaScript lowering's run builds it as
    # JavaScript and plays that under node, and the Game Boy Color lowering's builds it as a
    # Game Boy Color cartridge and plays that in the emulator, each checked against the
    # interpreter on every frame. A test written once plays on whichever the run is for.
    #
    # EACH LOWERING'S RUN IS ONE RECORD (RUNS), and everything in the testing kit that differs from
    # one run to the next reads it from there: the rake tasks, the player a test is handed, the
    # skips, what a run is started with. A lowering joins the kit as a record here.
    module Lowering
      # What the testing kit knows of one lowering's run:
      #
      #   name     what RUBY_GBA_LOWERING and `rake test:lowering:<name>` call it
      #   title    what a sentence calls it: "the GBA lowering", "this JavaScript run"
      #   console  the console the run plays a game as (see Console::DESCRIPTIONS). The native and
      #            JavaScript builds play an Advance game, laid out for the Advance's screen, so a
      #            game for the Advance alone is played by the first three runs and a game for the
      #            Color too by all four
      #   checked  whether the run plays the game itself, built for another machine and checked
      #            against the interpreter, rather than the interpreter alone. Such a run starts
      #            programs, so it is played in processes rather than Ractors, and it has no
      #            Advance cartridge to check
      #   does     what `rake -T` says the run does
      #   needs    the program it needs besides Ruby, or nil
      #   player   the class `game_player` makes one of on the run, by its name inside RubyGBA:
      #            the classes are loaded with the whole library, and a Rakefile reads these
      #            records without it
      Run = Data.define(:name, :title, :console, :checked, :does, :needs, :player) do
        alias_method :checked?, :checked

        # The class `game_player` makes one of on this run.
        def player_class = RubyGBA.const_get(player)
      end

      # In the order `rake test` plays them.
      RUNS = Ractor.make_shareable([
                                     Run.new(name: :gba, title: "GBA", console: :gba, checked: false,
                                             does: "the game on the interpreter", needs: nil,
                                             player: "IR::Backends::Reference"),
                                     Run.new(name: :native, title: "native", console: :gba, checked: true,
                                             does: "the game built as C, checked against the interpreter",
                                             needs: "zig", player: "Testing::CheckedPlayer"),
                                     Run.new(name: :js, title: "JavaScript", console: :gba, checked: true,
                                             does: "the game built as JavaScript, checked against the interpreter",
                                             needs: "node", player: "Testing::JSCheckedPlayer"),
                                     Run.new(name: :gbc, title: "Game Boy Color", console: :gbc, checked: true,
                                             does: "the game built as a Game Boy Color cartridge, played in the " \
                                                   "emulator and checked against the interpreter",
                                             needs: nil, player: "Testing::GBCCheckedPlayer")
                                   ])

      # The setting a run's lowering is read from: each run but the GBA lowering's sets it to its
      # name ("native", "js", "gbc"); left alone it is the GBA lowering's run.
      SETTING = "RUBY_GBA_LOWERING"
      NAMES = Ractor.make_shareable(RUNS.map(&:name))

      module_function

      # The record of the lowering named +name+, refusing a name no lowering has.
      def run_named(name) = RUNS.find { |run| run.name == name } || refuse_unknown_lowering!(name)

      # The lowerings whose runs play a game for +consoles+ (Symbols), in the order `rake test`
      # plays them.
      def lowerings_for(consoles)
        RUNS.select { |run| consoles.include?(run.console) }.map(&:name)
      end

      # The lowering +env+ says, refusing one there is not.
      def from(env)
        lowering = env.fetch(SETTING, "gba").to_sym
        return lowering if NAMES.include?(lowering)

        raise ArgumentError, "#{SETTING} is #{lowering}. A run can test #{in_words(NAMES)}."
      end

      def refuse_unknown_lowering!(name)
        raise ArgumentError, "There is no lowering named #{name.inspect}. Name " \
                             "#{in_words(NAMES.map(&:inspect))}."
      end

      # A list said the way a sentence says one: "gba, native or js".
      def in_words(names)
        *most, last = names.map(&:to_s)
        most.empty? ? last : "#{most.join(', ')} or #{last}"
      end

      # THE FILES +lowering+'s RUN LOADS: every one of +files+ but those in a folder another
      # lowering owns. A test there is about that lowering's own output — the ARM a cartridge is
      # made of, the C the game is built as — and the other lowering's run never loads it.
      # +folders+ names them by lowering, `{ gba: [...], native: [...], js: [...] }`. Every test
      # outside them is about the game, and every lowering's run loads it.
      #
      # A folder several lowerings name is loaded by each of them and left out of the rest's runs:
      # what only one CONSOLE can do is played by every lowering that plays a game for it (the
      # Advance's folder is the GBA, native and JavaScript lowerings'), and never by the others.
      def files_for(lowering, files:, folders: {})
        own = folders.fetch(lowering, [])
        others = folders.reject { |owner, _| owner == lowering }.values.flatten - own
        files.reject { |path| others.any? { |dir| path.start_with?("#{dir}/") } }
      end
    end
  end
end
