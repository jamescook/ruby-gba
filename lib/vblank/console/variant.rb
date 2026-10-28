# frozen_string_literal: true

module VBlank
  module Console
    # A VARIANT OF A CONSOLE: hardware some copies of a console have and others do not. A game names
    # it where it names its consoles (`variants: { snes: :superfx }`, see Cartridge::Game), since a
    # chip is part of what the cartridge is, and `vblank build --variant` can override it for one
    # build. A Super Nintendo cartridge can carry a chip
    # of its own — the Super FX that draws Star Fox's polygons, the SA-1 that is a second, faster
    # processor — and a game built for one is still a Super Nintendo game, with the same buttons and
    # screen and verbs, only with more room or more speed. So a variant is not a console of its own,
    # and not a lowering of its own: it is the console's description with some of its limits changed
    # (Console::Description, the numbers the builder and the checks read), and a note for the
    # console's build saying what to put on the cartridge.
    #
    # Each console's kit says which variants it has (Kit#variants); most have none. Asking for one
    # a console does not have is refused, naming the ones it does. A build that names none gets the
    # console as it is.
    #
    # +name+ is how a build asks for it, +title+ how a person reads it, +changes+ the description's
    # fields it sets (Description#with), +build+ what the console's build reads of it (for the Super
    # Nintendo, the board the cartridge is laid out for), and +note+ a sentence on what the hardware is.
    Variant = Data.define(:name, :title, :changes, :build, :note) do
      # +description+ with this variant's limits.
      def apply(description) = description.with(**changes, title: "#{description.title} with #{title}")
    end

    # The name a build gives for the console as it is.
    NO_VARIANT = :none
  end
end
