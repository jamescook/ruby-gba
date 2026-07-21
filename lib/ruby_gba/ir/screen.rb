# frozen_string_literal: true

module RubyGBA
  module IR
    # The screen a program draws to: its size in pixels. Like Int32 and the button
    # vocabulary, this is a cross-backend contract — the logical display every
    # backend renders — so it lives in the IR core rather than being re-stated by
    # each one. The console's interpreter sizes its framebuffer from here, the
    # console's hardware constants derive from here, and another backend (a browser
    # canvas, say) would size itself from here too. One source of truth.
    #
    # The dimensions are the Game Boy Advance's bitmap-mode screen; a program that
    # writes a pixel at (5, 5) means this screen, whichever backend runs it.
    module Screen
      WIDTH  = 240
      HEIGHT = 160
    end
  end
end
