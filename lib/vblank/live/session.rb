# frozen_string_literal: true

module VBlank
  module Live
    # A GAME PLAYED LIVE, A PASS AT A TIME, THROUGH A DEVICE. The game is built as Ruby and run in
    # this process (IR::Backends::Ruby#live_game). At the end of each of its frames it hands the
    # session the picture and the frame's sound; the session waits for that frame to end, shows
    # the device the picture, hands it the sound, asks it whether to stop, and gives the game the
    # buttons for the next pass. The play ends when the device says so, or when the game itself ends.
    #
    # A device answers:
    #
    #   show(pixels, width, height)  the picture, as the screen shows it (15-bit colours, a row at a time),
    #                                which the game draws over next frame: a device that keeps it copies it
    #   play_sound(samples, rate)    the sound of the frame just shown, one speaker's worth of 16-bit
    #                                samples, +rate+ a second
    #   sound_waiting                seconds of sound the speaker has still to play, or nil for a
    #                                device with no speaker (yet)
    #   held_buttons(pass)           the buttons held as picture number +pass+ is shown (1, 2, 3, …),
    #                                for the pass that starts then
    #   fast_forward_speed(pass)     how many of the game's frames to play in the time of one through
    #                                pass number +pass+: 1, or more while the player holds fast
    #                                forward; asked before the pass is played (never, played uncapped)
    #   hold_while_paused            asked once a pass, after the picture: returns false at once unless
    #                                the player paused; otherwise returns true once they carry on or
    #                                stop, with what was waiting for the speaker thrown away
    #   stop?                        asked once a pass, after the pause
    #   now                          the time, in seconds, from any start that does not move back
    #   wait_until(seconds)          returns at that time, or at once if it has gone; the next pass starts then
    #
    # A DEVICE WITH A SPEAKER IS PACED BY IT (#wait_for_speaker): the speaker plays a second of
    # sound in a second, so the play waits on it, a frame a pass, keeping a few frames of sound
    # waiting. That is what keeps the sound whole: on the clock's beat below, a pass that missed
    # its frame skips one, and the speaker is a frame's sound short.
    #
    # WITH NO SPEAKER, THE FRAMES KEEP THE CONSOLE'S BEAT. On the console the screen ends a frame
    # every sixtieth of a second or so whether the game is ready or not: a pass that finishes early
    # waits for the end of its frame, and one that finishes late has missed the end of one or more
    # and waits for the next. The session keeps the time the current frame began on that even
    # beat, and as each pass ends counts how many frames have begun since — at least the one the
    # pass ran in — moves the beat on by that many and waits for it. A machine faster than the
    # console waits, and plays exactly as fast; a slower one shows fewer pictures, and the game,
    # which counts one frame a pass, runs that much slower.
    #
    # UNCAPPED, for measuring, there is no beat: each pass starts the moment the last one ends, a
    # frame a pass, so the rate is how fast the machine can play the game.
    class Session
      # Frames of sound kept waiting for the speaker while it paces the play: enough that a pass
      # that runs late — a scene setting itself up as it arrives can take four frames over one —
      # or a wait that wakes late, uses up some of it and never empties it; and few, since what is
      # waiting is how far what a person sees and hears trails the buttons they press.
      SPEAKER_AHEAD_FRAMES = 4

      # The game is built as Ruby here, before any device is opened, so a game the Ruby runtime
      # cannot play yet is refused (IR::Backends::Ruby::RuntimeGap) before a window comes up.
      # +stop_after_passes+ is how many passes to play at most, whatever the device says.
      def initialize(program, uncapped: false, stop_after_passes: nil)
        @game = IR::Backends::Ruby.new.live_game(program)
        @uncapped = uncapped
        @stop_after_passes = stop_after_passes
        @frame_seconds = program.described_console.frame_seconds
      end

      # Plays once, on +device+, until it says stop or the game ends, and gives back how fast it
      # went (Rate). A game that does something its rules refuse (a push onto a full list) stops
      # the play with IR::ProgramError, in the words the interpreter would use.
      def play(device)
        @device = device
        @passes = @frames = 0
        @paced_by_speaker = false
        @seconds_paused = 0
        @fast_frame_began = nil # when the frame being fast forwarded through began, or nil
        @fast_forward_passes = 0 # passes played in it
        @started = @frame_began = @device.now
        @device.wait_until(@frame_began)
        stopped_on = @game.play(self)
        rate = Rate.new(passes: @passes, frames: @frames, seconds: @frame_began - @started - @seconds_paused,
                        stopped_itself: !stopped_on.nil?)
        keep_showing(stopped_on) if stopped_on
        rate
      end

      # Asked by the game as each of its frames ends, with the picture as the screen shows it and
      # the frame's sound: shows the device the picture, hands it the sound, and gives back the
      # buttons held for the pass that starts, a bit each — or nil when the device says stop. The
      # pass waits once: on the speaker, after its sound, where the device has one; on the clock,
      # for its frame to end, before its picture, where it has none.
      #
      # A speaker opens with the first frame's sound, so the first pass is played on the clock, and
      # paces the play from the second on. The first pass is the frame the game sets itself up in,
      # and counts the frames it took on the clock, which can be more than one.
      def buttons_after(pixels, samples)
        speed = @uncapped ? 1 : @device.fast_forward_speed(@passes + 1)
        if speed > 1
          play_fast_forward(pixels, speed)
        else
          end_fast_forward if @fast_frame_began
          play_at_console_speed(pixels, samples)
        end
        leave_pause_out_of_pacing
        return nil if @device.stop? || @passes == @stop_after_passes

        IR::Buttons.mask(@device.held_buttons(@passes))
      end

      private

      # A GAME THAT STOPPED ITSELF — it halted, or came to its end — leaves its last picture on the
      # screen, as the console does: the picture is shown a frame at a time, the window still read
      # and pause and its menu still working, until the device says stop. A play told how many
      # passes to go on for counts each picture shown here as one of them, so it still ends. The
      # game runs no pass, so none of this is in the play's rate.
      def keep_showing(pixels)
        shown = 0
        loop do
          @device.show(pixels, @game.width, @game.height)
          shown += 1
          @device.hold_while_paused
          break if @device.stop? || (@stop_after_passes && @passes + shown >= @stop_after_passes)

          @device.wait_until(@device.now + @frame_seconds)
        end
      end

      def play_at_console_speed(pixels, samples)
        wait_for_frame_end unless @paced_by_speaker
        @passes += 1
        @device.show(pixels, @game.width, @game.height)
        @device.play_sound(samples, @game.sound_rate)
        if @paced_by_speaker
          wait_for_speaker
        else
          @paced_by_speaker = !@uncapped && !@device.sound_waiting.nil?
        end
      end

      # FAST FORWARD plays up to +speed+ of the game's frames for each picture shown, in the time
      # of one: a machine that can goes that many times the console's speed and no faster. A
      # picture is shown, and the next frame's time waited for, once that many passes
      # have been played or the frame's time is up, so a machine that cannot go that fast still
      # shows a picture a frame. The frames counted are the frames of time that went by, as on
      # the beat, and not the game's, which are its passes. The game's sound is not handed to the
      # speaker: it would be several times what the speaker can play, and heard later and later.
      # What the speaker holds as fast forward begins is a few frames, and plays out.
      def play_fast_forward(pixels, speed)
        @fast_frame_began ||= @frame_began
        @passes += 1
        @fast_forward_passes += 1
        if @fast_forward_passes >= speed || @device.now - @fast_frame_began >= @frame_seconds
          @device.show(pixels, @game.width, @game.height)
          frames = [((@device.now - @fast_frame_began) / @frame_seconds).ceil, 1].max
          @frames += frames
          @fast_frame_began += frames * @frame_seconds
          @fast_forward_passes = 0
          @device.wait_until(@fast_frame_began)
        else
          @device.wait_until(@device.now)
        end
        @frame_began = @fast_frame_began
      end

      # Back to the console's speed from fast forward. The speaker has had nothing for as long as
      # fast forward was held, so it has little or nothing waiting, as after a pause.
      def end_fast_forward = restart_pacing

      # The next frame begins now, and the pass that ends it is played on the clock, as the first
      # pass of all is, until the speaker has the game's sound again. Fast forward, if it is
      # still held, starts its frames afresh too.
      def restart_pacing
        @frame_began = @device.now
        @paced_by_speaker = false
        @fast_frame_began = nil
        @fast_forward_passes = 0
      end

      # A PAUSE holds the game between two passes, for as long as the device holds it. The time
      # held is not the game's: the next frame begins when the pause ends, so the beat does not
      # count it as frames missed, and the play's rate leaves it out. The device empties its
      # speaker as the pause begins, so the game carries on with nothing queued from before.
      def leave_pause_out_of_pacing
        held_from = @device.now
        return unless @device.hold_while_paused

        @seconds_paused += @device.now - held_from
        restart_pacing
      end

      # WITH A SPEAKER, THE SPEAKER PACES THE PLAY, as an emulator's sound sync does. Its own clock
      # plays a second of samples in a second, so once a frame's sound is handed to it the next pass
      # waits only while more than SPEAKER_AHEAD_FRAMES of sound are waiting. A pass is a frame:
      # no frame is skipped, and a late pass, or a wait that wakes late, only uses up some of what is
      # waiting.
      def wait_for_speaker
        @frames += 1
        over = (@device.sound_waiting || 0) - (SPEAKER_AHEAD_FRAMES * @frame_seconds)
        @device.wait_until(@device.now + (over.positive? ? over : 0))
        @frame_began = @device.now
      end

      # Moves the beat past the frames the pass just ended took, and waits for it. Uncapped, the
      # pass took one frame and the next starts now.
      def wait_for_frame_end
        if @uncapped
          @frames += 1
          @frame_began = @device.now
        else
          frames = [((@device.now - @frame_began) / @frame_seconds).ceil, 1].max
          @frame_began += frames * @frame_seconds
          @frames += frames
        end
        @device.wait_until(@frame_began)
      end
    end
  end
end
