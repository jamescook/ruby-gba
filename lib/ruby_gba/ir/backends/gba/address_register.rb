# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # WHAT THE ADDRESS REGISTER IS KNOWN TO STILL BE HOLDING, as instructions go past.
        #
        # Reaching a variable takes two instructions: put the base of the console's quick
        # memory into a register, then load from that register plus the variable's distance
        # along (see {Primitives}#load_var). The base never changes for the life of the
        # program, so the first of those two is the same instruction every single time —
        # and in a program that does much arithmetic it is a quarter of the code. Measured
        # on one step of a first-person game's ray walk: eighty-three instructions, of which
        # twenty-one were that one constant being made again.
        #
        # So: remember what was put there, and let the next access skip its half of the
        # pair when the value is still sitting in the register. Which is why this is a
        # class rather than a flag — being WRONG about what a register holds does not fail,
        # it sends a load or a store to the wrong address, so the rule for forgetting has
        # to be somewhere it can be read and tested on its own.
        #
        # The rule has three parts:
        #
        #   * Any instruction that could write the register (ASM.disturbs?, which answers
        #     yes whenever it cannot tell).
        #   * A LABEL, because a label is somewhere other code jumps to, and what a
        #     register held on the way here says nothing about what it holds on the way in.
        #     Every jump in this backend goes to a label, so this one rule covers the lot.
        #   * A CALL, because the routine it reaches uses the register for its own work.
        #     A call is emitted as a placeholder and only becomes a call in the second
        #     pass, so it is {Emit} that says so rather than anything read out of the bytes.
        #
        # An interrupt can arrive between any two instructions and its handler does touch
        # this register — but the console's own dispatcher saves and restores it around
        # the handler, so the interrupted code never sees the difference.
        #
        # The one shape this rule does not see through is a jump computed at run time,
        # which lands somewhere with no label on it. There is one in the whole backend, in
        # the middle of the divide routine, and the divide routine touches no variable at
        # all — but a second one would have to place a label where it lands.
        class AddressRegister
          def initialize(reg:)
            @reg = reg
            @value = nil
          end

          # Is this what the register holds right now?
          def holds?(value) = @value == value

          # It does from here on — said by whoever just put it there.
          def now_holds(value)
            @value = value
          end

          # Whatever was there, we no longer know what it is.
          def forget
            @value = nil
          end

          # These instructions were just emitted. Anything that could change the register
          # ends what we knew about it.
          def saw(bytes)
            return if @value.nil?

            bytes.unpack("V*").each do |word|
              return forget if ASM.disturbs?(word, @reg)
            end
          end
        end
      end
    end
  end
end
