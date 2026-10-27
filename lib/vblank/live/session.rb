# frozen_string_literal: true

module VBlank
  module Live
    # A GAME PLAYED BY THE INTERPRETER, A PASS AT A TIME, THROUGH A DEVICE. Each pass the game
    # runs to its next frame; then the session waits for that frame to end, reads the buttons,
    # shows the device the picture and asks it whether to stop. The play ends when it says so,
    # or when the game itself ends.
    #
    # A device answers:
    #
    #   show(pixels, width, height)  the picture, as the screen shows it (15-bit colours, a row at a time)
    #   held_buttons(frame)          the buttons held on the screen's frame +frame+ (1, 2, 3, …)
    #   stop?                        asked once a pass, after the picture
    #   now                          the time, in seconds, from any start that does not move back
    #   wait_until(seconds)          returns at that time, or at once if it has gone; the next pass starts then
    #
    # THE GAME KEEPS THE CONSOLE'S TIME, whatever the machine. On the console the screen ends a
    # frame every sixtieth of a second or so whether the game is ready or not: a pass that
    # finishes early waits for the end of its frame, and one that finishes late has missed the
    # end of one or more and waits for the next. Either way the frames land on the same even
    # beat, and the music and the buttons move on by every one of them.
    #
    # The interpreter has no clock, so it cannot find that out; it takes every pass as one
    # frame unless it is told otherwise (Reference#frames_each_pass). The session tells it. It
    # keeps the time the current frame began on that even beat, and as each pass ends it counts
    # how many frames have begun since — at least the one the pass ran in — moves the beat on
    # by that many and waits for it. A machine slower than the console shows fewer pictures,
    # and the game still moves at the console's speed; a faster one waits, and plays exactly as
    # fast. The buttons are read after the wait, at the frame's end, which is when the console
    # reads them.
    class Session
      def initialize(program, device:)
        @program = program
        @device = device
        @frame_seconds = program.described_console.frame_seconds
      end

      # Plays until the device says stop or the game ends, and gives back how fast it went (Rate).
      def play
        interpreter = IR::Backends::Reference.new
        interpreter.frames_each_pass { wait_for_frame_end }
        interpreter.input_each_frame { |frame| @device.held_buttons(frame) }
        interpreter.each_vblank { show_picture_or_stop(interpreter.screen) }
        @passes = @frames = 0
        @started = @frame_began = @device.now
        @device.wait_until(@frame_began)
        catch(:stop) { interpreter.run(@program, frames: Float::INFINITY) }
        Rate.new(passes: @passes, frames: @frames, seconds: @frame_began - @started)
      end

      private

      # Moves the beat past the frames the pass just ended took, waits for it, and says how
      # many frames that was.
      def wait_for_frame_end
        frames = [((@device.now - @frame_began) / @frame_seconds).ceil, 1].max
        @frame_began += frames * @frame_seconds
        @frames += frames
        @device.wait_until(@frame_began)
        frames
      end

      def show_picture_or_stop(screen)
        @passes += 1
        @device.show(screen.shown, screen.width, screen.height)
        throw :stop if @device.stop?
      end
    end
  end
end
