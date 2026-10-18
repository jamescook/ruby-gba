# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBC
        # WHERE EVERYTHING THE GAME KEEPS LIVES WHILE IT RUNS.
        #
        # A Game Boy Color has 32K of work memory, but only 8K of it is in view at once: 4K always
        # (0xC000), and one of seven more banks of 4K beside it (0xD000). The game's variables, its
        # lists and the runtime's own state go in those 8K, the always-there half first. The stack
        # — where the processor keeps where to come back to from each call — takes the top of the
        # always-there half, so no bank switch can ever take it out of view. The other six banks are
        # for big things the runtime switches in when it works on them (a painted screen's tiles).
        #
        # The processor's own quick memory, 127 bytes at 0xFF80, is quicker to reach than any other
        # (LDH, one byte shorter): the copy routine that fills the sprite table lives there, since
        # nothing else can run while that copy runs, and so does the scratch the arithmetic uses.
        #
        # Nothing here is placed by the cartridge's linker: work memory is the same addresses on
        # every console, so every place is known as soon as it is asked for.
        class Memory
          # The sprite table's copy in work memory, which the console's sprite-table DMA copies in
          # whole every frame. That copy reads from a whole page (an address ending 00), so it is
          # first in work memory.
          SHADOW_OAM = 0xC000
          FIRST = 0xC0A0

          # The stack: the top of the always-there half, growing down.
          STACK_TOP = 0xD000
          STACK_BYTES = 0x200
          LOW_END = STACK_TOP - STACK_BYTES

          # The banked half, as bank 1 leaves it in view.
          HIGH_START = 0xD000
          HIGH_END = 0xE000

          # The quick memory: the sprite table's copy routine, the bank in view, and the scratch.
          OAM_DMA = 0xFF80
          OAM_DMA_BYTES = 10
          CURRENT_BANK = 0xFF8A
          QUICK_FIRST = 0xFF8B
          QUICK_END = 0xFFFE

          # Where the arithmetic keeps what it is working on (see Runtime::Int32).
          Scratch = Data.define(:cmp_top, :mul_by, :product, :div_n, :div_d, :div_r, :div_r_top,
                                :sign_n, :sign_d, :fraction_bits, :wide, :wide_by)

          # Raised when the game keeps more than there is room for.
          class Full < StandardError; end

          attr_reader :scratch

          # Where a runtime routine copies the numbers it was handed (see Runtime::Calls).
          attr_reader :args

          # The most numbers a runtime routine is handed.
          MOST_ARGS = 8

          def initialize
            @next = FIRST
            @next_quick = QUICK_FIRST
            @places = {}
            @scratch = Scratch.new(cmp_top: quick(1), mul_by: quick(4), product: quick(4), div_n: quick(4),
                                   div_d: quick(4), div_r: quick(4), div_r_top: quick(1), sign_n: quick(1),
                                   sign_d: quick(1), fraction_bits: quick(1), wide: quick(8), wide_by: quick(8))
            @args = quick(4 * MOST_ARGS)
          end

          # +bytes+ of work memory for +name+, and its address. The same name asked again is the same
          # place.
          def reserve(name, bytes)
            @places.fetch(name) do
              @next = HIGH_START if @next < HIGH_START && @next + bytes > LOW_END
              raise Full, full_message(name, bytes) if @next + bytes > HIGH_END

              @places[name] = @next.tap { @next += bytes }
            end
          end

          # +bytes+ of quick memory, and its address.
          def quick(bytes)
            raise Full, "the processor's quick memory is full" if @next_quick + bytes > QUICK_END

            @next_quick.tap { @next_quick += bytes }
          end

          # The address +name+ was given.
          def [](name) = @places.fetch(name)

          def reserved?(name) = @places.key?(name)

          # Every name and where it went, for reading a running game back.
          def places = @places.dup

          # How many bytes of work memory are in use.
          def used = (@next >= HIGH_START ? (LOW_END - FIRST) + (@next - HIGH_START) : @next - FIRST)

          private

          def full_message(name, bytes)
            "this game keeps more than a Game Boy Color's work memory holds: #{name} wants #{bytes} bytes and " \
              "#{HIGH_END - @next} are left. Its lists are the usual cause; give them smaller capacities."
          end
        end
      end
    end
  end
end
