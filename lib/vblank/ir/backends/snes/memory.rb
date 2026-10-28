# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        # WHERE EVERYTHING THE GAME KEEPS LIVES WHILE IT RUNS.
        #
        # A Super Nintendo has 128K of work RAM. Its first 8K is in view from every bank the
        # cartridge's code runs in, at addresses $0000 to $1FFF, so an instruction reaches it with
        # a 16-bit address; all of it is in view at $7E:0000 to $7F:FFFF, reached with a 24-bit
        # (long) address, a cycle slower. So:
        #
        #   $0000-$00FF  the direct page of the game's code: the runtime's working numbers, R0 to R7
        #                (four bytes each, R0 at $00), and its scratch after them. An instruction
        #                naming a direct page byte is a byte shorter and a cycle quicker than any
        #                other, which is why the arithmetic works here.
        #   $0100-$01FF  the direct page of the vertical blank's interrupt, which has its own so that
        #                arriving in the middle of a sum never disturbs the sum
        #   $0200-...    the runtime's own state, then the game's variables
        #   ...-$1FFF    the stack, 1K of it, growing down from the top
        #   $7E:2000-    the lists and pools, a long address each (reserve_far)
        #
        # Nothing here is placed by the linker: work RAM is the same addresses on every console, so
        # every place is known as soon as it is asked for.
        class Memory
          # The working numbers every runtime routine takes and gives (see Runtime): R0 holds a
          # value as the lowering works it out, and a routine's numbers are handed in R0, R1, R2...
          REGISTERS = 8
          SCRATCH = 0x20 # the runtime's scratch on the direct page, past the registers
          SCRATCH_END = 0x100
          INTERRUPT_PAGE = 0x0100

          FIRST = 0x0200
          STACK_TOP = 0x1FFF
          STACK_BYTES = 0x400
          LOW_END = STACK_TOP + 1 - STACK_BYTES

          FAR_FIRST = 0x7E2000
          FAR_END = 0x800000

          # The direct page address of working number +n+.
          def self.register(n) = n * 4

          # Raised when the game keeps more than there is room for. It is the game's to fix, so it
          # is a refusal like the lowering's others, said to the author in the same way.
          class Full < LoweringError; end

          def initialize
            @next = FIRST
            @next_far = FAR_FIRST
            @next_scratch = SCRATCH
            @places = {}
          end

          # +bytes+ of the first 8K for +name+, and its address. The same name asked again is the
          # same place.
          def reserve(name, bytes)
            @places.fetch(name) do
              raise Full, full_message(name, bytes, LOW_END - @next, "the part of its work RAM every variable is in") if
                @next + bytes > LOW_END

              @places[name] = @next.tap { @next += bytes }
            end
          end

          # +bytes+ of the rest of work RAM for +name+, and its 24-bit address. A place never
          # straddles the edge of a 64K bank, so a 16-bit index from its start stays inside it.
          def reserve_far(name, bytes)
            @places.fetch(name) do
              @next_far = (@next_far & 0xFF0000) + 0x10000 if (@next_far & 0xFFFF) + bytes > 0x10000
              raise Full, full_message(name, bytes, FAR_END - @next_far, "its work RAM") if @next_far + bytes > FAR_END

              @places[name] = @next_far.tap { @next_far += bytes }
            end
          end

          # +bytes+ of the runtime's scratch on the direct page, and its address there.
          def scratch(bytes)
            raise Full, "the runtime's direct page is full" if @next_scratch + bytes > SCRATCH_END

            @next_scratch.tap { @next_scratch += bytes }
          end

          # The address +name+ was given.
          def [](name) = @places.fetch(name)

          def reserved?(name) = @places.key?(name)

          # Every name and where it went, for reading a running game back.
          def places = @places.dup

          # How many bytes of the first 8K are in use.
          def used = @next - FIRST

          private

          def full_message(name, bytes, left, part)
            "This game keeps more than a Super Nintendo's work RAM holds. #{name.sub(/\A./, &:upcase)} needs " \
              "#{bytes} bytes in #{part}, and #{[left, 0].max} are left. A list is the usual cause. To fix this, " \
              "give the game's lists smaller capacities, or use fewer variables."
          end
        end
      end
    end
  end
end
