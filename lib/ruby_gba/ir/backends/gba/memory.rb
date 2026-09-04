# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # The IWRAM bump allocator. Every variable, list, mixer buffer, row-bend
        # table, and the hot-code block itself claims its space here, in the order
        # each is first needed — there is no freeing, because nothing in a running
        # program ever gives its memory back.
        #
        # Nothing fancy: a pointer that only ever moves up. What earns this its own
        # class is that six call sites (divide, lists, mixer, placement, primitives,
        # raster) all need exactly this — "bump the pointer and remember where it
        # was" — and doing it by hand at each one is six chances to get the
        # bump-then-return order backwards, with no single place that says "this is
        # how IWRAM gets handed out."
        class Memory
          def initialize(start:)
            @next = start
          end

          # Claim +bytes+ and return the address the new allocation starts at.
          def alloc(bytes)
            addr = @next
            @next += bytes
            addr
          end

          # Bump up to the next multiple of +to+, claiming nothing — for an
          # allocation (the moved hot-code block) that has to start aligned.
          def align!(to)
            @next += (-@next) % to
          end

          # Where the pointer sits right now, without moving it.
          def high_water = @next
        end
      end
    end
  end
end
