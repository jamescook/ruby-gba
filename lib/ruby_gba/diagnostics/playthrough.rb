# frozen_string_literal: true

module RubyGBA
  module Diagnostics
    # A GAME DRIVEN WITH NOBODY AT THE CONTROLS, from a script that says what to press.
    #
    #   walk = RubyGBA.playthrough "walk to the signpost" do
    #     wait frames: 10
    #     press :start
    #     hold :right, frames: 40
    #     moment :at_the_signpost
    #   end
    #
    #   played = walk.play(cartridge) { |moment, game| ... }
    #   played.frames    # how many frames went by
    #   played.moments   # { at_the_signpost: 52 }
    #
    # WHAT IT IS FOR. A game can otherwise only be played by a person, or poked for a few
    # frames by a test that writes out which buttons are down on which frame. This is the
    # whole idea those pieces were missing: say what to do the way a person would say it, and
    # get the same five minutes of play every time.
    #
    # A SCRIPT COUNTS FRAMES. A frame is one picture the console shows, a sixtieth of a second,
    # and the console looks at its buttons on every one — so "down for forty frames" is an
    # exact thing to say, and the same on every machine.
    #
    # What a frame is NOT is a trip round the game's own loop. A game that fits its work into a
    # frame goes round once for each, and then a button down for forty frames is seen forty
    # times. One that does not fit takes two frames a trip, or three, and sees it fewer.
    #
    # FRAMES ARE COUNTED FROM 1. Frame 1 is the first one the playthrough plays, and a moment
    # is the frame that had just been played when the script named it.
    #
    # It plays in the emulator, on the cartridge the build made. Without the emulator it stops
    # where the cartridge is opened, with what to install.
    class Playthrough
      # What playing one gave back. +frames+ is how many were played, +moments+ the frame each
      # named moment fell on, and +game+ the cartridge as the last frame left it — the same
      # reader a test of a running cartridge uses, so anything can be asked of it.
      Played = Data.define(:frames, :moments, :game)

      attr_reader :name

      # +script+ is the block of steps. It is read here, once, so a mistake in it is reported
      # where the playthrough is declared and not part way through playing it.
      def initialize(name, &script)
        raise ArgumentError, %(RubyGBA.playthrough needs a block of steps: RubyGBA.playthrough("NAME") { ... }) unless script

        @name = name
        @steps = Script.new(name).tap { |steps| steps.instance_eval(&script) }.steps.freeze
      end

      # Play the script on +cartridge+, from power-on. At each named moment the block is
      # handed the moment's name and the running cartridge, so the game can be asked about
      # exactly there.
      def play(cartridge, &at_each_moment)
        playing = Playing.new(Verifier.new(cartridge, frames: 0, vars: cartridge.var_addresses), at_each_moment)
        @steps.each { |step| step.play(playing) }
        playing.played
      end

      # ONE PLAYING OF A SCRIPT, as it goes: the cartridge, how many frames it has played, and
      # the moments named so far. Each step of the script plays itself on this.
      class Playing
        def initialize(game, at_each_moment)
          @game = game
          @at_each_moment = at_each_moment
          @frames = 0
          @moments = {}
        end

        # Play +frames+ frames with the buttons of +key_mask+ down.
        def hold(key_mask, frames)
          @game.step(frames, keys: key_mask)
          @frames += frames
        end

        # Give the frame just played a name, and hand the game over to whoever is watching.
        def mark(name)
          @moments[name] = @frames
          @at_each_moment&.call(name, @game)
        end

        def played = Played.new(frames: @frames, moments: @moments, game: @game)
      end

      # Buttons kept down for a number of frames — none at all, for a wait.
      Hold = Data.define(:buttons, :frames) do
        def play(playing) = playing.hold(key_mask, frames)

        # The buttons as the console reads them: one bit apiece, each named for its button.
        def key_mask
          buttons.reduce(0) { |mask, button| mask | Console::Hardware.const_get(:"KEY_#{button.upcase}") }
        end
      end

      # A name for the frame that has just been played.
      Moment = Data.define(:name) do
        def play(playing) = playing.mark(name)
      end

      # THE STEPS OF A SCRIPT, as the block writes them. Each word here is one a script can
      # say; what they add up to is a plain list, in order, of buttons held for some frames and
      # moments named along the way.
      #
      # The block is run with this as itself, so `press` and `hold` need nothing written in
      # front of them. A local variable from around the block is still in reach inside it; a
      # method or an instance variable of the place the block was written is not.
      class Script
        attr_reader :steps

        # +title+ is the playthrough's name, for the errors to say whose script it is.
        def initialize(title)
          @title = title
          @steps = []
          @named = []
        end

        # Tap: the buttons go down for one frame and come up for one. The frame up is part of
        # the tap, so two taps in a row are two presses and not one long hold.
        def press(*buttons)
          refuse_missing_buttons!(:press, buttons)
          refuse_unknown_buttons!(:press, buttons)
          @steps << Hold.new(buttons: buttons, frames: 1) << Hold.new(buttons: [], frames: 1)
          self
        end

        # Keep the buttons down for +frames+ frames, then let go.
        def hold(*buttons, frames:)
          refuse_missing_buttons!(:hold, buttons)
          refuse_unknown_buttons!(:hold, buttons)
          refuse_invalid_frame_count!(:hold, frames)
          @steps << Hold.new(buttons: buttons, frames: frames)
          self
        end

        # Let +frames+ frames go by with nothing pressed.
        def wait(frames:)
          refuse_invalid_frame_count!(:wait, frames)
          @steps << Hold.new(buttons: [], frames: frames)
          self
        end

        # Name the frame that has just been played, so it can be asked for afterwards.
        def moment(name)
          refuse_moment_before_first_frame!(name)
          refuse_repeated_moment!(name)
          @named << name
          @steps << Moment.new(name: name)
          self
        end

        private

        def refuse_missing_buttons!(word, buttons)
          return unless buttons.empty?

          raise ArgumentError,
                "`#{word}` in playthrough #{@title.inspect} names no button. " \
                "Name one or more of #{button_list}. To let frames go by with nothing pressed, use `wait`."
        end

        def refuse_unknown_buttons!(word, buttons)
          unknown = buttons.find { |button| !IR::Buttons.known?(button) } or return

          raise ArgumentError,
                "`#{word} #{unknown.inspect}` in playthrough #{@title.inspect} names a button " \
                "the console does not have. The buttons are #{button_list}."
        end

        def button_list = IR::Buttons::NAMES.map(&:inspect).join(", ")

        def refuse_invalid_frame_count!(word, frames)
          return if frames.is_a?(Integer) && frames >= 1

          raise ArgumentError,
                "`#{word}` in playthrough #{@title.inspect} was given frames: #{frames.inspect}. " \
                "frames: must be a whole number, 1 or more."
        end

        # A moment is the frame just played, and before the first step there is none. Every
        # step but a moment plays a frame or more.
        def refuse_moment_before_first_frame!(name)
          return if @steps.length > @named.length

          raise ArgumentError,
                "moment #{name.inspect} in playthrough #{@title.inspect} comes before any frame. " \
                "A moment names the frame the console just played. Put a step before it, like `wait frames: 1`."
        end

        def refuse_repeated_moment!(name)
          return unless @named.include?(name)

          raise ArgumentError,
                "Playthrough #{@title.inspect} names the moment #{name.inspect} twice. " \
                "A name must mean one frame. Give the second moment a different name."
        end
      end
    end
  end

  class << self
    # Declare a playthrough: a game driven with nobody at the controls, from the steps in the
    # block. Nothing is played yet; see {Diagnostics::Playthrough#play}.
    def playthrough(name, &script) = Diagnostics::Playthrough.new(name, &script)
  end
end
