# frozen_string_literal: true

module VBlank
  module IR
    # The Advance's screen, in pixels: what a program built for the Advance draws to, and what
    # the backends that only ever draw the Advance's picture (the native and JavaScript ones)
    # size themselves from.
    #
    # A program carries the console it was built for, and whatever reads its screen asks that
    # (Program#described_console), since a program built for a smaller console draws to a
    # smaller screen. These two are for what has no program to ask.
    module Screen
      WIDTH  = Console::ADVANCE.screen_width
      HEIGHT = Console::ADVANCE.screen_height
    end
  end
end
