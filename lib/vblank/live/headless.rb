# frozen_string_literal: true

module VBlank
  module Live
    # A DEVICE WITH NO SCREEN: it keeps every picture it is shown and every frame's sound it is
    # handed, holds the buttons a script gives it by frame (+buttons+, frame number to the buttons
    # held on it), and stops the play after +frames+ pictures.
    #
    # ITS CLOCK MOVES ONLY WHEN SOMETHING SAYS IT DOES, so a test never waits for real time.
    # Waiting moves it straight to the moment waited for, and every pass then takes
    # +pass_seconds+ — none unless the test says otherwise, a machine infinitely fast — or, given
    # something callable, what it answers for the pass's number (1, 2, 3, …). Kept as an exact
    # fraction, so a pass said to take two frames takes two and not a hair more.
    #
    # WITH +speaker: true+ IT HAS A SPEAKER, which plays what it is handed on the same clock, a
    # second of samples in a second: #sound_waiting is how much is left to play, #gaps how many
    # times sound arrived after the speaker had run out (a gap a person would hear), and
    # #most_waiting the most there ever was waiting. Without one, #sound_waiting is nil.
    #
    # +pauses+ maps a picture's number to the seconds the player pauses for after it is shown, and
    # +fast_forward+ holds the numbers of the passes (1, 2, 3, …) fast forward is held through.
    class Headless
      Picture = Data.define(:pixels, :width, :height)

      # +sounds+ is each frame's samples, in the order they were handed over, and +sound_rate+ the
      # samples a second they were made at.
      attr_reader :pictures, :sounds, :sound_rate, :now, :gaps, :most_waiting

      def initialize(frames:, buttons: {}, pass_seconds: 0, speaker: false, pauses: {}, fast_forward: [])
        @frames = frames
        @buttons = buttons
        @pauses = pauses
        @fast_forward = fast_forward
        @held_after = nil # the picture the last pause came after
        @pass_seconds = pass_seconds.respond_to?(:call) ? pass_seconds : ->(_pass) { pass_seconds }
        @speaker = speaker
        @pictures = []
        @sounds = []
        @sound_rate = nil # until the first frame's sound says it
        @now = 0r
        @passes = 0
        @gaps = 0
        @most_waiting = 0r
        @speaker_done_at = nil # when what the speaker holds has all been played; nil before any sound
      end

      # The picture is the game's own and is drawn over next frame, so a copy is kept.
      def show(pixels, width, height)
        @pictures << Picture.new(pixels: pixels.dup, width: width, height: height)
      end

      def play_sound(samples, rate)
        @sounds << samples
        @sound_rate = rate
        return unless @speaker

        @gaps += 1 if @speaker_done_at && @speaker_done_at < @now
        @speaker_done_at = [@speaker_done_at || @now, @now].max + Rational(samples.length, rate)
        @most_waiting = [@most_waiting, sound_waiting].max
      end

      # Seconds of sound the speaker has still to play, or nil with no speaker.
      def sound_waiting
        return nil unless @speaker

        @speaker_done_at ? [@speaker_done_at - @now, 0r].max : 0r
      end

      def held_buttons(frame) = @buttons.fetch(frame, [])

      def stop? = @pictures.size >= @frames

      def fast_forward?(pass) = @fast_forward.include?(pass)

      # Held for the seconds +pauses+ gives the picture just shown, once, with the speaker emptied
      # as the pause begins.
      def hold_while_paused
        seconds = @pauses[@pictures.size] or return false
        return false if @held_after == @pictures.size

        @held_after = @pictures.size
        @speaker_done_at = nil
        @now += seconds.to_r
        true
      end

      # The next pass starts the moment this returns, so it is where the pass's time is spent.
      def wait_until(seconds)
        @passes += 1
        @now = [@now, seconds.to_r].max + @pass_seconds.call(@passes).to_r
      end
    end
  end
end
