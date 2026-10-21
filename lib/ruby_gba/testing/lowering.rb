# frozen_string_literal: true

module RubyGBA
  module Testing
    # WHICH LOWERING A RUN OF A SUITE TESTS, said in one setting, and which test files that run
    # loads. Both the rake tasks (RakeTasks) and the tests themselves (Testing.lowering) read it
    # from here, so the two cannot answer differently.
    #
    # A game is played three ways, or four when it is for the Game Boy Color too (see CONSOLES).
    # The GBA lowering's run plays it on the interpreter
    # (Backends::Reference), which is what the cartridge is checked against; the native
    # lowering's run builds it as C and plays that, the JavaScript lowering's run builds it as
    # JavaScript and plays that under node, and the Game Boy Color lowering's builds it as a
    # Game Boy Color cartridge and plays that in the emulator, each checked against the
    # interpreter on every frame. A test written once plays on whichever the run is for.
    module Lowering
      # The setting a run's lowering is read from. The native lowering's run sets it to
      # "native" and the JavaScript lowering's to "js"; left alone it is the GBA lowering's run.
      SETTING = "RUBY_GBA_LOWERING"
      NAMES = %i[gba native js gbc].freeze

      # What a sentence calls each lowering, in the order `rake test` plays them: "the GBA
      # lowering", "this JavaScript run". Everything that says a lowering's name to a person reads
      # it from here.
      TITLES = { gba: "GBA", native: "native", js: "JavaScript", gbc: "Game Boy Color" }.freeze

      # The lowerings whose run plays the game itself, built for another machine and checked
      # against the interpreter, rather than the interpreter alone: a run of one of these starts
      # programs, so it is played in processes rather than Ractors.
      CHECKED = %i[native js gbc].freeze

      # What `rake -T` says each lowering's run does, and what it needs besides Ruby.
      RUNS = {
        gba: "the game on the interpreter",
        native: "the game built as C, checked against the interpreter",
        js: "the game built as JavaScript, checked against the interpreter",
        gbc: "the game built as a Game Boy Color cartridge, played in the emulator and checked against the interpreter"
      }.freeze
      NEEDS = { native: "zig", js: "node" }.freeze

      # The console each lowering's run plays the game as (see Console::DESCRIPTIONS). The native
      # and JavaScript builds play an Advance game, laid out for the Advance's screen, so a game for
      # the Advance alone is played by the first three and a game for the Color too by all four.
      CONSOLES = { gba: :gba, native: :gba, js: :gba, gbc: :gbc }.freeze

      module_function

      # The lowerings whose runs play a game for +consoles+ (Symbols), in the order `rake test`
      # plays them.
      def lowerings_for(consoles)
        NAMES.select { |lowering| consoles.include?(CONSOLES.fetch(lowering)) }
      end

      # The lowering +env+ says, refusing one there is not.
      def from(env)
        lowering = env.fetch(SETTING, "gba").to_sym
        return lowering if NAMES.include?(lowering)

        raise ArgumentError, "#{SETTING} is #{lowering}. A run can test #{in_words(NAMES)}."
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
