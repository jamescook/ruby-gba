# frozen_string_literal: true

require "tmpdir" # here and not where it is used: see the note at the top of the verifier

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
    # ...OR IT WATCHES THE GAME. Counting is exact and brittle: the day a screen takes a frame
    # longer to come up, every step after it is a frame out. So a step can instead wait until
    # something is true of the game, and the script carries on from the frame it first is.
    #
    # FRAMES ARE COUNTED FROM 1. Frame 1 is the first one the playthrough plays, and a moment
    # is the frame that had just been played when the script named it.
    #
    # It plays in the emulator, on the cartridge the build made. Without the emulator it stops
    # where the cartridge is opened, with what to install.
    class Playthrough
      # What playing one gave back. +frames+ is how many were played, +moments+ the frame each
      # named moment fell on, and +game+ the cartridge as the last frame left it — the same
      # reader a test of a running cartridge uses, so anything can be asked of it. +tape+ is
      # the presses that were made, written down (see Tape).
      Played = Data.define(:frames, :moments, :game, :tape)

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
      def play(cartridge, &at_each_moment) = Playing.play(@name, @steps, cartridge, &at_each_moment)

      # Play the script on +first+ to learn its presses, then play +first+ and +second+ side
      # by side on those presses, comparing the two pictures after every frame. +settings+ say
      # how alike they have to be, and which stretches of the playthrough are not looked at
      # (see Comparison). They are read before the script is played, so one that makes no
      # sense does not cost a playing to find — a stretch that names a moment included,
      # since a script says its moments where it is declared.
      def compare(first, second, **settings)
        comparison = Comparison.new(first, second, moment_names, **settings)
        comparison.run(play(first).tape)
      end

      # The names of the moments the script declares, in the order it declares them.
      def moment_names = @steps.flat_map(&:names)

      # A console switched on with +cartridge+ in it and no frame played yet: the reader over
      # one running cartridge that everything here plays on and asks.
      def self.power_on(cartridge) = Verifier.new(cartridge, frames: 0, vars: cartridge.var_addresses)

      # ONE PLAYING, as it goes: the cartridge running, and a tape of every press made on it so
      # far. Each step plays itself on this. +title+ is the name of what is being played, for
      # an error to say whose playing it was.
      class Playing
        # Play +steps+ on +cartridge+ from power-on, and hand back what that came to.
        def self.play(title, steps, cartridge, &at_each_moment)
          playing = new(title, cartridge, at_each_moment)
          steps.each { |step| step.play(playing) }
          playing.played
        end

        def initialize(title, cartridge, at_each_moment)
          @title = title
          @cartridge = cartridge
          @game = Playthrough.power_on(cartridge)
          @at_each_moment = at_each_moment
          @taping = Tape::Taping.new
        end

        # Play +frames+ frames with +buttons+ down, and write that on the tape.
        def hold(buttons, frames)
          @game.step(frames, keys: Playthrough.key_mask(buttons))
          @taping.hold(buttons, frames)
        end

        # Play a frame at a time with +buttons+ down, until the block says yes of the game.
        # The game is asked after each frame, so this stops on the first frame the answer is
        # yes. After +within+ frames of no it gives up (see GaveUp).
        def hold_until(buttons, words, within)
          within.times do
            hold(buttons, 1)
            answer = yield(@game)
            refuse_non_boolean_answer!(words, answer)
            return if answer
          end
          raise GaveUp.new(title: @title, words: words, waited: within, frame: @taping.frames,
                           picture: write_picture_of_frame)
        end

        # The screen as it is now, written where a person can open it.
        #
        # In a folder of its own that nothing takes away, unlike everything else a playing
        # makes: the picture is what the error points at, so it has to be there after the
        # playing is gone.
        def write_picture_of_frame
          path = File.join(Dir.mktmpdir("playthrough"), "frame-#{@taping.frames}.png")
          Graphics::PNG.write(path, width: Console::Hardware::SCREEN_WIDTH, height: Console::Hardware::SCREEN_HEIGHT,
                                    pixels: @game.frame_gba)
        end

        # A watching block has to answer yes or no. Ruby takes every number for yes, nought
        # included, so a block that answers one — `flags & 4`, the way the test is written in
        # C — would end the wait on its first frame whatever the game was doing.
        def refuse_non_boolean_answer!(words, answer)
          return if [true, false].include?(answer)

          raise ArgumentError,
                "The block that waits until #{words}, in playthrough #{@title.inspect}, answered #{answer.inspect}. " \
                "It must answer true or false. To ask about a number, compare it, " \
                "like `(game.var(:flags) & 4) != 0`."
        end

        # Give the frame just played a name, and hand the game over to whoever is watching.
        def mark(name)
          @taping.moment(name)
          @at_each_moment&.call(name, @game)
        end

        # What this playing came to. The frames and the moments are the tape's own, so the
        # two can never disagree.
        def played
          tape = Tape.recorded_on(@cartridge, @taping.steps)
          Played.new(frames: tape.frames, moments: tape.moments, game: @game, tape: tape)
        end
      end

      # A WAIT THAT NEVER ENDED. The script waited for something to be true of the game, and
      # after as many frames as it was willing to wait it still was not. A playthrough that
      # hung there would say nothing at all, so it stops and says which wait it was, the frame
      # it gave up on, and where it left a picture of the screen at that frame — which is
      # usually the whole answer: the game is on a screen the script did not expect.
      class GaveUp < StandardError
        attr_reader :words, :frame, :picture

        # The picture's path gets a line of its own, so it can be copied whole.
        def initialize(title:, words:, waited:, frame:, picture:)
          @words = words
          @frame = frame
          @picture = picture
          super("Playthrough #{title.inspect} waited until #{words}. That did not happen in #{waited} frames. " \
                "It stopped on frame #{frame}. Look at the screen on that frame first:\n#{picture}\n" \
                "If the game is where you expect and needs longer, give the step a bigger `within:`.")
        end
      end

      # The buttons as the console reads them: one bit apiece, each named for its button.
      def self.key_mask(buttons)
        buttons.reduce(0) { |mask, button| mask | Console::Hardware.const_get(:"KEY_#{button.upcase}") }
      end

      # +buttons+ once each, in the order the console numbers them — so two holds of the same
      # buttons are the same hold however they were written.
      def self.in_console_order(buttons) = IR::Buttons::NAMES & buttons

      # Buttons kept down for a number of frames — none at all, for a wait. It is also a line
      # of a tape, and says the three things a tape asks of a line: the moments it names
      # (none), the text it is written as, and itself made longer when the frames after it
      # have the same buttons down.
      Hold = Data.define(:buttons, :frames) do
        def play(playing) = playing.hold(buttons, frames)
        def names = []
        def tape_line = "#{frames} #{buttons.empty? ? Tape::NOTHING_DOWN : buttons.join(' ')}"
        def extended_by(held, more) = held == buttons ? with(frames: frames + more) : nil
      end

      # Buttons kept down — or none — until something is true of the game. +words+ say what,
      # for a person; +condition+ is asked of the running cartridge after each frame; +within+
      # is how many frames to go on asking.
      Watch = Data.define(:buttons, :words, :within, :condition) do
        def play(playing) = playing.hold_until(buttons, words, within, &condition)
        def names = []
      end

      # A name for the frame that has just been played. As a line of a tape it plays no frames,
      # names one moment, and is never made longer.
      Moment = Data.define(:name) do
        def play(playing) = playing.mark(name)
        def frames = 0
        def names = [name]
        def tape_line = "moment #{name}"
        def extended_by(_held, _more) = nil
      end

      class Moment
        # What a moment can be called: a word of letters, digits and underscores. A tape
        # writes the name down as a word and reads it back as one, so a name has to be one.
        NAME = /\A[A-Za-z][A-Za-z0-9_]*\z/

        # WHY A MOMENT CANNOT BE NAMED +name+ HERE, as one word a caller turns into its own
        # sentence — a script and a tape say it differently — or nil when it can. +named+ are
        # the moments there are already, and +any_frames+ whether a frame has been played.
        def self.problem_with(name, named:, any_frames:)
          return :not_a_plain_name unless name.is_a?(Symbol) && NAME.match?(name)
          return :before_any_frame unless any_frames
          return :named_already if named.include?(name)

          nil
        end
      end

      # THE STEPS OF A SCRIPT, as the block writes them. Each word here is one a script can
      # say; what they add up to is a plain list, in order: buttons held for a count of frames,
      # buttons held until something is true of the game, and moments named along the way.
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

        # How many frames a step that watches the game goes on asking, unless it says: ten
        # seconds of play.
        LONGEST_WAIT = 600

        # Let frames go by with nothing pressed until the block says yes of the game. +words+
        # say what is being waited for, in the middle of a sentence: "the file menu is up".
        # The block is handed the running cartridge and asked after every frame, so the script
        # carries on from the first frame the answer is yes. It always plays one frame at least.
        def wait_until(words, within: LONGEST_WAIT, &condition)
          add_watch_step(:wait_until, Watch.new(buttons: [], words: words, within: within, condition: condition))
        end

        # The same, with the buttons down while it waits: walk right until the hero is at the
        # door. They come up when the wait ends. The words come first, as they do in
        # `wait_until`, and the buttons after.
        def hold_until(words, *buttons, within: LONGEST_WAIT, &condition)
          refuse_watch_without_words!(:hold_until, words) # first: a button written first is the words missing
          refuse_missing_buttons!(:hold_until, buttons, otherwise: "wait_until")
          refuse_unknown_buttons!(:hold_until, buttons)
          add_watch_step(:hold_until, Watch.new(buttons: buttons, words: words, within: within, condition: condition))
        end

        # Name the frame that has just been played, so it can be asked for afterwards.
        def moment(name)
          refuse_unusable_moment!(name)
          @named << name
          @steps << Moment.new(name: name)
          self
        end

        private

        # +step_name+ is the step as the script wrote it, for the errors to quote.
        def add_watch_step(step_name, watch)
          refuse_watch_without_words!(step_name, watch.words)
          refuse_watch_without_block!(step_name, watch)
          refuse_invalid_frame_count!(step_name, watch.within, keyword: "within:")
          @steps << watch
          self
        end

        # The words are what a wait that never ends has to say for itself.
        def refuse_watch_without_words!(step_name, words)
          return if words.is_a?(String) && !words.strip.empty?

          raise ArgumentError,
                "`#{step_name}` in playthrough #{@title.inspect} must start with a few words that say what it " \
                "waits for, like `#{step_name}(\"the file menu is up\")`. It was given #{words.inspect}."
        end

        def refuse_watch_without_block!(step_name, watch)
          return if watch.condition

          raise ArgumentError,
                "`#{step_name}(#{watch.words.inspect})` in playthrough #{@title.inspect} has no block. " \
                "Give it a block that reads the game and is true when the wait is over, " \
                "like `{ |game| game.var(:screen) == 1 }`."
        end

        # +otherwise+ is the step that does the same with nothing pressed.
        def refuse_missing_buttons!(step_name, buttons, otherwise: "wait")
          return unless buttons.empty?

          raise ArgumentError,
                "`#{step_name}` in playthrough #{@title.inspect} names no button. " \
                "Name one or more of #{button_list}. To let frames go by with nothing pressed, use `#{otherwise}`."
        end

        def refuse_unknown_buttons!(step_name, buttons)
          unknown = buttons.find { |button| !IR::Buttons.known?(button) } or return

          raise ArgumentError,
                "`#{step_name} #{unknown.inspect}` in playthrough #{@title.inspect} names a button " \
                "the console does not have. The buttons are #{button_list}."
        end

        def button_list = IR::Buttons::NAMES.map(&:inspect).join(", ")

        def refuse_invalid_frame_count!(step_name, frames, keyword: "frames:")
          return if frames.is_a?(Integer) && frames >= 1

          raise ArgumentError,
                "`#{step_name}` in playthrough #{@title.inspect} was given #{keyword} #{frames.inspect}. " \
                "#{keyword} must be a whole number, 1 or more."
        end

        # The rules are Moment's own, shared with a tape read from a file; the words are this
        # script's. Every step but a moment plays a frame or more, so there has been a frame
        # once there are more steps than moments.
        def refuse_unusable_moment!(name)
          problem = Moment.problem_with(name, named: @named, any_frames: @steps.length > @named.length) or return

          raise ArgumentError, "moment #{name.inspect} in playthrough #{@title.inspect} #{MOMENT_PROBLEMS.fetch(problem)}"
        end

        MOMENT_PROBLEMS = {
          not_a_plain_name: "is not a name a moment can have. A moment is named with a symbol of letters, " \
                            "digits and underscores, like :at_the_door.",
          before_any_frame: "comes before any frame. A moment names the frame the console just played. " \
                            "Put a step before it, like `wait frames: 1`.",
          named_already: "is the second moment of that name. A name must mean one frame. " \
                         "Give this moment a different name.",
        }.freeze
      end
    end
  end

  class << self
    # Declare a playthrough: a game driven with nobody at the controls, from the steps in the
    # block. Nothing is played yet; see {Diagnostics::Playthrough#play}.
    def playthrough(name, &script) = Diagnostics::Playthrough.new(name, &script)
  end
end
