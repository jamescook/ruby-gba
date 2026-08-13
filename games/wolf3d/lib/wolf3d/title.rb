# frozen_string_literal: true

module Wolf3D
  # A holding screen until there is a game. Draws its own lettering because Wolfenstein's own
  # alphabets are still packed inside VGAGRAPH.
  class Title
    BLINK_ON = 60
    BLINK_OFF = 120

    def initialize(build)
      @build = build
      @blink = build.var :_title_blink, 0
    end

    def update
      @build.clear_screen :black
      @build.draw_text "WOLFENSTEIN 3D", 66, 56, :white
      @build.draw_text "RUBY-GBA", 90, 72, :gray

      @blink.add 1
      (@blink >= BLINK_OFF).then { @blink.set 0 }
      (@blink < BLINK_ON).then { @build.draw_text "NO GAME DATA", 78, 104, :red }
    end
  end
end
