# frozen_string_literal: true

module VBlank
  module Cartridge
    # HOW A GAME IS BUILT, as one value: what a game says about its cartridge beside its name.
    #
    # A game says these where it is named (`VBlank.game "NAME", consoles: %i[gba], save_memory: 128`) or where it
    # is built (`VBlank.build`), and they are needed a long way from there — the frame pacing and
    # the save memory by the Builder running the game's block, the two speed settings by the
    # lowering. Passed as loose keywords they had to be written into every signature on the way
    # down, and a new one meant six edits; as one value a new setting is a field here, and every
    # step between the game and the place that reads it carries it without knowing it is there.
    #
    # Checked as it is made, so a setting that cannot be right is refused at the line that said
    # it, before anything is read off disk.
    #
    # +frame_sync+ is :auto (the framework paces each game_loop) or :manual (the game places
    # `wait_vblank` itself). +save_memory+ is how much save memory the cartridge has, in kilobytes
    # (8, 32, 64 or 128), or nil to let the game's save_data records decide. 8 is the EEPROM, which
    # only a game that asks for it gets (see IR::SaveLayout::EEPROM).
    # +console+ names the console the game is built for (see Console::Kit), held as its Symbol
    # however it was written. It is nil until something names one: a game says its consoles where it
    # is named and is built for one of them, and VBlank.build refuses a build that names none.
    #
    # +fast_cartridge+, +fast_code+ and +stack_room+ are SETTINGS ONLY THE ADVANCE HAS, and only its
    # build reads them: what each means, what it is when nothing is said, and which values it can
    # take are Cartridge::AdvanceBuild's, and so is refusing a value it cannot use. Each is nil when
    # the game says nothing, so that a build for another console can tell a setting it does not
    # have from one nobody asked for (see Console.refuse_unusable_console_settings!).
    #
    # +variant+ names the hardware this copy of the console has beyond the plain one (a chip on a
    # Super Nintendo cartridge, Console::Variant), or is nil for the plain console. It is checked
    # against the console's kit, so a variant the console does not have is refused here.
    Options = Data.define(:frame_sync, :fast_cartridge, :fast_code, :save_memory, :stack_room, :console,
                          :variant) do
      def initialize(frame_sync: :auto, fast_cartridge: nil, fast_code: nil, save_memory: nil, stack_room: nil,
                     console: nil, variant: nil)
        console = Console.named(console) unless console.nil?
        unless variant.nil?
          raise ArgumentError, "A variant needs a console. To fix this, name the console too." if console.nil?

          variant = Console.for(console).variant(variant)&.name
        end
        unless %i[auto manual].include?(frame_sync)
          raise ArgumentError, "frame_sync must be :auto or :manual, got #{frame_sync.inspect}"
        end
        unless save_memory.nil? || IR::SaveLayout::NAMEABLE.include?(save_memory)
          raise ArgumentError, "save_memory: #{save_memory.inspect} is not a size of save memory. A cartridge " \
                               "has 8, 32, 64 or 128 kilobytes. To fix this, use one of those numbers, or leave " \
                               "save_memory: out and the build picks the smallest that holds the saves."
        end

        super
      end
    end
  end
end
