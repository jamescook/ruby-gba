# frozen_string_literal: true

module RubyGBA
  module Cartridge
    # HOW A GAME IS BUILT, as one value: what a game says about its cartridge beside its name.
    #
    # A game says these where it is named (`RubyGBA.game "NAME", consoles: %i[gba], save_memory: 128`) or where it
    # is built (`RubyGBA.build`), and they are needed a long way from there — the frame pacing and
    # the save memory by the Builder running the game's block, the two speed settings by the
    # lowering. Passed as loose keywords they had to be written into every signature on the way
    # down, and a new one meant six edits; as one value a new setting is a field here, and every
    # step between the game and the place that reads it carries it without knowing it is there.
    #
    # Checked as it is made, so a setting that cannot be right is refused at the line that said
    # it, before anything is read off disk.
    #
    # +frame_sync+ is :auto (the framework paces each game_loop) or :manual (the game places
    # `wait_vblank` itself). +fast_cartridge+ asks the console for quick cartridge timing at boot.
    # +fast_code+ lets the build choose which routines go in the console's quick memory.
    # +save_memory+ is how much save memory the cartridge has, in kilobytes (8, 32, 64 or 128),
    # or nil to let the game's save_data records decide. 8 is the EEPROM, which only a game that
    # asks for it gets (see IR::SaveLayout::EEPROM).
    # +stack_room+ is how many bytes of the quick memory the game's stack is given, or nil for the
    # build to decide (see IR::Backends::GBA::TopOfQuickMemory).
    # +console+ names the console the game is built for (see Console::Description), :gba unless said.
    Options = Data.define(:frame_sync, :fast_cartridge, :fast_code, :save_memory, :stack_room, :console) do
      def initialize(frame_sync: :auto, fast_cartridge: true, fast_code: true, save_memory: nil, stack_room: nil,
                     console: Console::DEFAULT)
        Console.described(console)
        unless %i[auto manual].include?(frame_sync)
          raise ArgumentError, "frame_sync must be :auto or :manual, got #{frame_sync.inspect}"
        end
        unless save_memory.nil? || IR::SaveLayout::NAMEABLE.include?(save_memory)
          raise ArgumentError, "save_memory: #{save_memory.inspect} is not a size of save memory. A cartridge " \
                               "has 8, 32, 64 or 128 kilobytes. To fix this, use one of those numbers, or leave " \
                               "save_memory: out and the build picks the smallest that holds the saves."
        end
        refuse_unusable_stack_room!(stack_room)

        super
      end

      # The least stack room a game can ask for: the console's own routines a game calls need this
      # much of it.
      LEAST_STACK_ROOM = 64

      # The three the lowering takes, which is also what a finished cartridge records it was told
      # (see {BuildRecord#build_options}) and what must be given again to build it the same way.
      def lowering = { fast_cartridge: fast_cartridge, fast_code: fast_code, stack_room: stack_room }

      private

      def refuse_unusable_stack_room!(stack_room)
        most = IR::Backends::GBA::TopOfQuickMemory::MOST_STACK_BYTES
        return if stack_room.nil? ||
                  (stack_room.is_a?(Integer) && stack_room.between?(LEAST_STACK_ROOM, most) && (stack_room % 4).zero?)

        raise ArgumentError, "stack_room: #{stack_room.inspect} is not a size the stack can have. It must be a " \
                             "number of bytes that is a multiple of 4, from #{LEAST_STACK_ROOM} to #{most}. To fix " \
                             "this, use such a number, or remove stack_room: and the build picks the size."
      end
    end
  end
end
