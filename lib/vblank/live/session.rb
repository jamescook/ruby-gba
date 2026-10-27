# frozen_string_literal: true

module VBlank
  module Live
    # A GAME PLAYED LIVE, A PASS AT A TIME, THROUGH A DEVICE. The game is built as Ruby and run in
    # this process (IR::Backends::Ruby#live_game). At the end of each of its frames it hands the
    # session the picture; the session waits for that frame to end, shows the device the picture,
    # asks it whether to stop, and gives the game the buttons for the next pass. The play ends when
    # the device says so, or when the game itself ends.
    #
    # A device answers:
    #
    #   show(pixels, width, height)  the picture, as the screen shows it (15-bit colours, a row at a time),
    #                                which the game draws over next frame: a device that keeps it copies it
    #   held_buttons(pass)           the buttons held as picture number +pass+ is shown (1, 2, 3, …),
    #                                for the pass that starts then
    #   stop?                        asked once a pass, after the picture
    #   now                          the time, in seconds, from any start that does not move back
    #   wait_until(seconds)          returns at that time, or at once if it has gone; the next pass starts then
    #
    # THE FRAMES KEEP THE CONSOLE'S BEAT. On the console the screen ends a frame every sixtieth of
    # a second or so whether the game is ready or not: a pass that finishes early waits for the end
    # of its frame, and one that finishes late has missed the end of one or more and waits for the
    # next. The session keeps the time the current frame began on that even beat, and as each pass
    # ends counts how many frames have begun since — at least the one the pass ran in — moves the
    # beat on by that many and waits for it. A machine faster than the console waits, and plays
    # exactly as fast; a slower one shows fewer pictures, and the game, which counts one frame a
    # pass, runs that much slower.
    class Session
      def initialize(program, device:)
        @program = program
        @device = device
        @frame_seconds = program.described_console.frame_seconds
      end

      # Plays until the device says stop or the game ends, and gives back how fast it went (Rate).
      # A game that does something its rules refuse (a push onto a full list) stops the play with
      # IR::ProgramError, in the words the interpreter would use.
      def play
        @game = IR::Backends::Ruby.new.live_game(@program)
        @passes = @frames = 0
        @started = @frame_began = @device.now
        @device.wait_until(@frame_began)
        @game.play(self)
        Rate.new(passes: @passes, frames: @frames, seconds: @frame_began - @started)
      end

      # Asked by the game as each of its frames ends, with the picture as the screen shows it: waits
      # for the frame to end, shows the device the picture, and gives back the buttons held for
      # the pass that starts, a bit each — or nil when the device says stop.
      def buttons_after(pixels)
        wait_for_frame_end
        @passes += 1
        @device.show(pixels, @game.width, @game.height)
        return nil if @device.stop?

        IR::Buttons.mask(@device.held_buttons(@passes))
      end

      private

      # Moves the beat past the frames the pass just ended took, and waits for it.
      def wait_for_frame_end
        frames = [((@device.now - @frame_began) / @frame_seconds).ceil, 1].max
        @frame_began += frames * @frame_seconds
        @frames += frames
        @device.wait_until(@frame_began)
      end
    end
  end
end
