# frozen_string_literal: true

module Wolf3D
  # A holding screen until there is a game. This is what a cartridge built with no copy of the
  # game shows, so it writes in the framework's own font rather than Wolfenstein's — the
  # alphabets are in VGAGRAPH, and there is no VGAGRAPH to read.
  class Title
    BLINK_ON = 60
    BLINK_OFF = 120

    def initialize(build, data = nil)
      @build = build
      @data = data
      @blink = build.var :_title_blink, 0
    end

    def update
      @build.clear_screen :black
      @build.draw_text "WOLFENSTEIN 3D", 66, 56, :white
      @build.draw_text "RUBY-GBA", 90, 72, :gray

      @blink.add 1
      (@blink >= BLINK_OFF).then { @blink.set 0 }
      (@blink < BLINK_ON).then { @build.draw_text banner, 78, 104, @data ? :green : :red }
    end

    private

    # Which release the cartridge was built from, so a ROM says where its data came from.
    def banner = @data ? @data.set : "NO GAME DATA"
  end
end
