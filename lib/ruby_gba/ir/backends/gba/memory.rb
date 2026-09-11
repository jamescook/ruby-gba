# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # The IWRAM allocator, which hands memory out from BOTH ENDS.
        #
        # Every variable, list, mixer buffer, row-bend table, and the block of moved
        # code itself claims its space here. There is no freeing, because nothing in a
        # running program ever gives its memory back.
        #
        # WHY TWO ENDS RATHER THAN ONE, which is the whole point of this class. A
        # variable is reached by naming the base of this memory and riding the distance
        # to it inside the load instruction — and that distance is twelve bits. So a
        # variable within 4096 bytes of the base is two instructions, and one past that
        # line is up to four, because the whole address has to be built again on every
        # read and every write.
        #
        # With one pointer, who lands inside that window is decided by the order things
        # are first NEEDED, which is not a decision anybody made. A game with a lot of
        # state declares its lists and pools early, those claim the first few thousand
        # bytes, and the variables land past the line — so the games with the most going
        # on are exactly the ones that pay for every variable, which is the wrong way
        # round. Measured on the Wolfenstein port: 248 of its 288 variables sat past the line,
        # and a fifth of the instructions in its per-frame routines were the address
        # arithmetic that costs.
        #
        # So variables grow UP from the base and everything else grows DOWN from the
        # ceiling, and what is free is the gap between them. Nothing has to guess how
        # much room to set aside for variables: they take what they need, at the one end
        # where being near the base is worth anything, and the gap they leave is what
        # the moved code gets.
        #
        # Everything is rounded up to a whole word, so both ends stay aligned however
        # odd a size is asked for — a list of bytes, say.
        # AND THE OTHER MEMORY, which this hands out too because there should be one
        # owner of both. The console has 256K more of it on a separate chip — eight times
        # the room, and about six times the wait on a read — and until this it was touched
        # by nothing but the audio mixer's two output buffers, through six private lines
        # with no bounds check. A quarter of a megabyte, idle, while everything a program
        # declared competed for the 32K that also holds the hot code.
        class Memory
          WORD = 4

          def initialize(start:, ceiling:, roomy: nil, roomy_ceiling: nil)
            @base = start
            @near = start
            @ceiling = ceiling
            @far = ceiling
            @roomy_base = roomy
            @roomy_next = roomy
            @roomy_ceiling = roomy_ceiling
          end

          # Claim +bytes+ next to the base, for something that is cheaper to reach
          # there. Only variables want this.
          def alloc_near_base(bytes)
            addr = @near
            @near += whole_words(bytes)
            addr
          end

          # Claim +bytes+ at the far end, for anything that does not care where it sits.
          def alloc(bytes)
            @far -= whole_words(bytes)
          end

          # Claim +bytes+ in the roomy memory, for something that does not fit in the quick
          # one or was told it does not need to be there. Nil when there is no more, which
          # a caller reports as the friendly error it is — this one really is a program
          # asking for more than the console has.
          def alloc_roomy(bytes)
            return nil if @roomy_next.nil? || @roomy_next + whole_words(bytes) > @roomy_ceiling

            addr = @roomy_next
            @roomy_next += whole_words(bytes)
            addr
          end

          # Is there room in the quick memory for one more thing of this size, with the two
          # ends where they are now?
          def room_for?(bytes) = free >= whole_words(bytes)

          def roomy_used = @roomy_next ? @roomy_next - @roomy_base : 0
          def roomy_free = @roomy_next ? @roomy_ceiling - @roomy_next : 0

          # How much of this memory is spoken for, both ends added together.
          def used = (@near - @base) + (@ceiling - @far)

          # The gap left in the middle, which is what is still to be had. Negative would
          # mean the two ends have passed each other, so a caller asking how much room
          # there is gets nought rather than a number it might act on.
          def free = [@far - @near, 0].max

          # By how much the two ends have run into each other, or nought if they have
          # not. This is the one failure this memory can have, and both of the guards
          # that report it (see Divide and Placement) ask it here.
          def overrun = [@near - @far, 0].max

          private

          def whole_words(bytes) = bytes + ((-bytes) % WORD)
        end
      end
    end
  end
end
