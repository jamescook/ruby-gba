# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      # HOW FAR A FADE OR A TINT HAS GONE, in the steps the console counts in. Both backends
      # read it, so the interpreter's picture and the console's are worked out from the same
      # numbers and cannot drift apart a step at a time.
      #
      # The console has two ways to move a picture toward a color, and they count
      # differently. Its display blends as it draws, and counts in sixteenths: seventeen
      # levels from the picture to the color. Walking the color table (see IR::Fading for
      # when) can go as fine as a color channel does, and a channel has five bits, so a walk
      # counts in thirty-seconds — 33 levels, one a frame over a fade twice as long as the
      # display's can show without repeating itself.
      #
      # A whole percentage is counted in sixteenths whichever way it goes, and a walk takes
      # two of its steps for each: 2/32 and 1/16 are the same share of the way, so the
      # picture is the same to the last bit and only the counting is finer. An amount with a
      # fraction is what asks for the thirty-seconds.
      module FadeSteps
        DISPLAY = Console::Hardware::BLD_MAX
        WALK = Console::Hardware::CHANNEL_LEVELS

        module_function

        # How far +amount+ is, as a number of steps: the walk's when +walked+, the display's
        # otherwise. +fraction_bits+ is how many bits of fraction the amount carries, or nil
        # for a whole percentage. Past either end it settles at that end.
        def steps(amount, fraction_bits:, walked:)
          levels = walked ? WALK : DISPLAY
          return in_walk_steps(sixteenths(amount), walked) unless fraction_bits

          ((amount * levels) / (100 << fraction_bits)).clamp(0, levels)
        end

        # The same, as a value to work out while the game runs, for a backend that compiles
        # rather than interprets. The ends are left to the caller to clamp.
        def steps_value(amount, fraction_bits:, walked:)
          levels = walked ? WALK : DISPLAY
          return Build.binop(:/, Build.binop(:*, amount, Build.int(levels)), Build.int(100 << fraction_bits)) if fraction_bits

          sixteenths = Build.binop(:/, Build.binop(:*, amount, Build.int(DISPLAY)), Build.int(100))
          walked ? Build.binop(:*, sixteenths, Build.int(WALK / DISPLAY)) : sixteenths
        end

        # A number of the display's steps, said in the walk's when +walked+.
        def in_walk_steps(display_steps, walked = true)
          walked ? display_steps * (WALK / DISPLAY) : display_steps
        end

        def sixteenths(percent) = ((percent * DISPLAY) / 100).clamp(0, DISPLAY)
      end
    end
  end
end
