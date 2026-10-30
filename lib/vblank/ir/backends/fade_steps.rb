# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      # HOW FAR A FADE OR A TINT HAS GONE, in the steps the console counts in. Both backends
      # read it, so the interpreter's picture and the console's are worked out from the same
      # numbers and cannot drift apart a step at a time.
      #
      # The console has two ways to move a picture toward a color, and they count
      # differently. Its display blends as it draws, and counts in sixteenths: seventeen
      # levels from the picture to the color. Walking the color table (see IR::Fading for
      # when) is arithmetic the game does on each color, and counts in 256ths, which is
      # what the console's own games count a fade in: each channel keeps (256 - a) 256ths of
      # itself, takes a 256ths of the color, and the fraction is dropped. A game that fades
      # itself one 256th a frame can be followed frame for frame.
      #
      # A whole percentage is counted in sixteenths whichever way it goes, and a walk takes
      # sixteen of its steps for each: 16/256 and 1/16 are the same share of the way, so the
      # picture is the same to the last bit and only the counting is finer. An amount with a
      # fraction is what asks for the 256ths.
      #
      # These are what a fade MEANS, on every backend and every console, so they are written here
      # rather than read off one console's registers. A console whose display blends counts in
      # the same sixteenths (the Advance's BLD_MAX), and a console that cannot blend walks its
      # colours (Console::Description#blends).
      module FadeSteps
        DISPLAY = 16
        WALK = 256

        module_function

        # How far +amount+ is, as a number of steps: the walk's when +walked+, the display's
        # otherwise. +fraction_bits+ is how many bits of fraction the amount carries, or nil
        # for a whole percentage. Past either end it settles at that end.
        def steps(amount, fraction_bits:, walked:)
          levels = walked ? WALK : DISPLAY
          return in_walk_steps(sixteenths(amount), walked) unless fraction_bits

          times, over = share_of_amount(levels, fraction_bits)
          ((amount * times) / over).clamp(0, levels)
        end

        # The same, as a value to work out while the game runs, for a backend that compiles
        # rather than interprets. The ends are left to the caller to clamp.
        def steps_value(amount, fraction_bits:, walked:)
          levels = walked ? WALK : DISPLAY
          if fraction_bits
            times, over = share_of_amount(levels, fraction_bits)
            scaled = times == 1 ? amount : Build.binop(:*, amount, Build.int(times))
            return Build.binop(:/, scaled, Build.int(over))
          end

          sixteenths = Build.binop(:/, Build.binop(:*, amount, Build.int(DISPLAY)), Build.int(100))
          walked ? Build.binop(:*, sixteenths, Build.int(WALK / DISPLAY)) : sixteenths
        end

        # An amount with +fraction_bits+ of fraction, as a share of +levels+: amount x levels /
        # (100 << fraction_bits), as [times, over]. The levels are a power of two, and taken
        # out of the divisor where it has the bits, so an amount of 100 with sixteen bits of
        # fraction is not multiplied past what a 32-bit number holds. The answer is the same.
        def share_of_amount(levels, fraction_bits)
          shift = levels.bit_length - 1
          return [1, 100 << (fraction_bits - shift)] if fraction_bits >= shift

          [levels, 100 << fraction_bits]
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
