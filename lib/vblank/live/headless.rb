# frozen_string_literal: true

module VBlank
  module Live
    # A DEVICE WITH NO SCREEN: it keeps every picture it is shown and every frame's sound it is
    # handed, holds the buttons a script gives it by frame (+buttons+, frame number to the buttons
    # held on it), and stops the play after +frames+ pictures.
    #
    # ITS CLOCK MOVES ONLY WHEN SOMETHING SAYS IT DOES, so a test never waits for real time.
    # Waiting moves it straight to the moment waited for, and every pass then takes
    # +pass_seconds+ — none unless the test says otherwise, a machine infinitely fast. Kept as
    # an exact fraction, so a pass said to take two frames takes two and not a hair more.
    class Headless
      Picture = Data.define(:pixels, :width, :height)

      # +sounds+ is each frame's samples, in the order they were handed over, and +sound_rate+ the
      # samples a second they were made at.
      attr_reader :pictures, :sounds, :sound_rate, :now

      def initialize(frames:, buttons: {}, pass_seconds: 0)
        @frames = frames
        @buttons = buttons
        @pass_seconds = pass_seconds.to_r
        @pictures = []
        @sounds = []
        @sound_rate = nil # until the first frame's sound says it
        @now = 0r
      end

      # The picture is the game's own and is drawn over next frame, so a copy is kept.
      def show(pixels, width, height)
        @pictures << Picture.new(pixels: pixels.dup, width: width, height: height)
      end

      def play_sound(samples, rate)
        @sounds << samples
        @sound_rate = rate
      end

      def held_buttons(frame) = @buttons.fetch(frame, [])

      def stop? = @pictures.size >= @frames

      # The next pass starts the moment this returns, so it is where the pass's time is spent.
      def wait_until(seconds)
        @now = [@now, seconds.to_r].max + @pass_seconds
      end
    end
  end
end
