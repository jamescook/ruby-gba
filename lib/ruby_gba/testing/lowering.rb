# frozen_string_literal: true

module RubyGBA
  module Testing
    # WHICH LOWERING A RUN OF A SUITE TESTS, said in one setting, and which test files that run
    # loads. Both the rake tasks (RakeTasks) and the tests themselves (Testing.lowering) read it
    # from here, so the two cannot answer differently.
    #
    # A game is played two ways. The GBA lowering's run plays it on the interpreter
    # (Backends::Reference), which is what the cartridge is checked against; the native
    # lowering's run builds it as C and plays that, checked against the interpreter on every
    # frame. A test written once plays on whichever the run is for.
    module Lowering
      # The setting a run's lowering is read from. The native lowering's run sets it to
      # "native"; left alone it is the GBA lowering's run.
      SETTING = "RUBY_GBA_LOWERING"
      NAMES = %i[gba native].freeze

      module_function

      # The lowering +env+ says, refusing one there is not.
      def from(env)
        lowering = env.fetch(SETTING, "gba").to_sym
        return lowering if NAMES.include?(lowering)

        raise ArgumentError, "#{SETTING} is #{lowering}. A run can test #{NAMES.join(' or ')}."
      end

      # THE FILES +lowering+'s RUN LOADS: every one of +files+ but those in a folder another
      # lowering owns. A test there is about that lowering's own output — the ARM a cartridge is
      # made of, the C the game is built as — and the other lowering's run never loads it.
      # +folders+ names them by lowering, `{ gba: [...], native: [...] }`. Every test outside
      # them is about the game, and every lowering's run loads it.
      def files_for(lowering, files:, folders: {})
        others = folders.reject { |owner, _| owner == lowering }.values.flatten
        files.reject { |path| others.any? { |dir| path.start_with?("#{dir}/") } }
      end
    end
  end
end
