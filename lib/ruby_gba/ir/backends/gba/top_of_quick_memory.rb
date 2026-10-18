# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # WHAT THE BUILD HOLDS BACK AT THE TOP OF THE QUICK MEMORY, and where each piece of it goes.
        #
        # THE HARDWARE, briefly. The console's quick memory is 32K, and its top 256 bytes belong to
        # the console's own startup code, which keeps the stacks it answers an interrupt on there.
        # Just below them is the game's own stack: every routine pushes where to return to on the
        # way in and takes it back on the way out, and a value with nowhere else to wait waits there
        # too. It grows down, towards everything else.
        #
        # From the top down, then: the console's 256 bytes, the game's stack, and the two routines
        # that divide — this chip has no instruction that divides — copied there at boot when the
        # game divides by something it works out as it runs. Everything below is the variables, the
        # collections and the code kept in the quick memory, and #ceiling is where that ends.
        #
        # It matters which end the divide routines go at. Variables start at the very beginning of
        # the quick memory, and that address is one the chip can name in a single instruction — a
        # rare piece of luck worth keeping, because a program names a variable thousands of times
        # and names a divide routine a handful. Putting a routine there instead pushed every
        # variable past the single-instruction address and cost one game an extra 5,700 bytes of
        # code, all of it in variable reads.
        #
        # HOW MUCH STACK. A game's stack, measured on the console with every scene held and played,
        # goes a few dozen bytes below where its game loop keeps it — while the build used to hold
        # back the whole 4K for it. So a game gets DEFAULT_STACK_BYTES, many times what any game
        # measured, unless its deepest chain of calls needs more (see .stack_needed), and a game that
        # says how much it wants (`stack_room:`) gets exactly that. Too little is not an error
        # anything can see: the stack walks down into the game's own code and lists and writes over
        # them.
        TopOfQuickMemory = Data.define(:ceiling, :divide_at, :divide_fix_at, :stack_bytes)

        class TopOfQuickMemory
          include Console::Hardware

          END_OF_QUICK = IWRAM_START + IWRAM_SIZE

          # The console's own, at the very top.
          CONSOLE_BYTES = 256

          # The stack room a game gets unless its calls nest deeper or it says otherwise.
          DEFAULT_STACK_BYTES = 1024

          # WHAT ONE CALL DEEPER COSTS THE STACK, held at its dearest: the return address, and the
          # values a counted loop keeps safe around its body. The floor is for the console's own
          # routines a game calls (waiting for the screen, unpacking a picture), which work on the
          # game's stack, and for the values a long expression leaves waiting.
          STACK_BYTES_PER_CALL = 16
          STACK_FLOOR_BYTES = 256

          # The most stack room there can be, asked for or worked out: half of the quick memory.
          MOST_STACK_BYTES = 16_384

          # A game whose calls go round in a circle has no deepest chain to count, so it gets twice
          # the usual room, and can say more.
          UNBOUNDED_STACK_BYTES = 2 * DEFAULT_STACK_BYTES

          # The layout for +program+. +stack_room+ is the bytes a game said its stack wants, or nil
          # for the build to decide; +divides+ and +divides_fractions+ whether it needs each divide
          # routine.
          def self.for(program, stack_room: nil, divides: false, divides_fractions: false)
            stack = stack_room || stack_needed(program).clamp(DEFAULT_STACK_BYTES, MOST_STACK_BYTES)
            fix_at = END_OF_QUICK - CONSOLE_BYTES - stack - (divides_fractions ? Divide::FIX_ROUTINE_BYTES : 0)
            divide_at = fix_at - (divides ? Divide::ROUTINE_BYTES : 0)
            new(ceiling: divide_at, divide_at: (divide_at if divides), divide_fix_at: (fix_at if divides_fractions),
                stack_bytes: stack)
          end

          # THE STACK THE DEEPEST CHAIN OF CALLS NEEDS, from the game loop's body: the longest run of
          # routines each calling the next. What the console runs on an interrupt is not counted
          # here, since it runs on the console's own stack in its 256 bytes, not on this one.
          def self.stack_needed(program)
            bodies = program.walk.select { |node| node.kind == :func }.to_h { |node| [node.name, node] }
            depth = program.walk.select { |node| node.kind == :loop }.map { |root| call_depth(root, bodies, {}, Set.new) }.max || 0
            return UNBOUNDED_STACK_BYTES if depth == Float::INFINITY

            STACK_FLOOR_BYTES + (depth * STACK_BYTES_PER_CALL)
          end

          # How many calls deep +node+ goes, or infinity where a routine is reached again while it is
          # still being counted — calls going round in a circle.
          def self.call_depth(node, bodies, known, open)
            node.walk.flat_map(&:callees).uniq.map do |name|
              next 1 unless (body = bodies[name])
              next Float::INFINITY if open.include?(name)

              known[name] ||= begin
                open << name
                1 + call_depth(body, bodies, known, open)
              ensure
                open.delete(name)
              end
            end.max || 0
          end
          private_class_method :call_depth
        end
      end
    end
  end
end
