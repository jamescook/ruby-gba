# frozen_string_literal: true

require_relative "native/zig"

module RubyGBA
  module IR
    module Backends
      # The game as a program for a desktop computer: the IR written out as C, built by zig into
      # one executable. The cartridge stays the main thing this library makes; this is a second
      # one beside it.
      #
      # It TRAILS the other two backends rather than standing beside them. `rake test` never
      # runs its tests (`rake test:native` does), and a feature that works on the console and
      # in the interpreter is done without it; anything it cannot do yet is a gap to fill here.
      #
      # How it writes C, and why that way (doc/research/writing-c.md has the reading behind it):
      #
      # - The game's arithmetic lives in runtime/rg_int32.h, a C function for each thing IR::Int32
      #   and the interpreter do with a number. C leaves several of the things a game does with numbers undefined —
      #   running off the end of a number, dividing the lowest number by -1, shifting by 32 —
      #   and an optimising compiler is allowed to assume they never happen. Those functions
      #   work on the unsigned kind of number, which C does promise wraps, and test the rest.
      # - The C this writes never uses an operator on one of the game's numbers; it calls one
      #   of those functions. That is what keeps it correct, and it is also why the precedence
      #   of C's operators, and && skipping its right side, never come up.
      # - It never names SDL. The picture, the buttons and the sound go through the runtime,
      #   which a desktop build links against SDL and a test links against a version that has
      #   no window at all.
      # - It is checked by running, against Backends::Reference, and never by comparing the C
      #   it wrote against C somebody wrote down.
      class Native
      end
    end
  end
end
