# frozen_string_literal: true

require "tmpdir" # here and not where it is used: see the note at the top of the verifier

module RubyGBA
  module Playthroughs
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
    # It plays in the emulator, on a cartridge the build made or on a cartridge file — which
    # is how a cartridge the framework did not build is played. Without the emulator it stops
    # where the cartridge is opened, with what to install.
    class Playthrough
      # What playing one gave back. +frames+ is how many were played, +moments+ the frame each
      # named moment fell on, and +game+ the cartridge as the last frame left it — the same
      # reader a test of a running cartridge uses, so anything can be asked of it. +tape+ is
      # the presses that were made, written down (see Tape). +pictures+ is the screen at each
      # named moment: every pixel's colour, a row at a time from the top, which is how
      # Graphics::PNG takes one. +picture_files+ is where each of those was written as a PNG,
      # by moment — nothing at all unless the playing was asked to write them. +save+ is the
      # cartridge's save memory as the last frame left it (an IR::SaveImage), to write to a
      # file or to start another playing from; nil for a cartridge that has none.
      Played = Data.define(:frames, :moments, :game, :tape, :pictures, :picture_files, :save)

      attr_reader :name

      # +script+ is the block of steps. It is read here, once, so a mistake in it is reported
      # where the playthrough is declared and not part way through playing it.
      def initialize(name, &script)
        raise ArgumentError, %(RubyGBA.playthrough needs a block of steps: RubyGBA.playthrough("NAME") { ... }) unless script

        @name = name
        @steps = Script.new(name).tap { |steps| steps.instance_eval(&script) }.steps.freeze
      end

      # Play the script on +cartridge+, from power-on unless it is given a save to hold or a
      # lead-in to play first. At each named moment the block is
      # handed the moment's name and the running cartridge, so the game can be asked about
      # exactly there. +save+ is what the cartridge's save memory holds when the console is
      # switched on; left out, it is a cartridge nobody has played. +pictures_in+ is a folder
      # to write the screen at each moment into, as a PNG named for the moment; left out, no
      # file is written.
      #
      # +lead_in+ is another playthrough, played on the cartridge first and not counted:
      # see `power_on_and_lead_in`.
      def play(cartridge, save: nil, lead_in: nil, pictures_in: nil, &at_each_moment)
        Playing.play(@name, @steps, cartridge, save: save, lead_in: lead_in, pictures_in: pictures_in, &at_each_moment)
      end

      # Play this script on +game+, a console that is already running, as the lead-in to
      # something else: the presses are made and the frames go by, and nothing is kept of
      # them. A moment it names is nobody's to ask for, and a wait in it that never ends
      # gives up as any wait does, saying it was this script's.
      #
      # It is played by a playing that has no cartridge to say a tape was recorded on, and
      # is never asked for what it came to: it is here for its hands on the console.
      def play_as_lead_in(game)
        playing = Playing.new(@name, nil, game, nil, save: nil, folder: nil)
        @steps.each { |step| step.play(playing) }
        game
      end

      # Play the script on +first+ to learn its presses, then play +first+ and +second+ side
      # by side on those presses, comparing the two pictures after every frame. +settings+ say
      # how alike they have to be, and which stretches of the playthrough are not looked at
      # (see Comparison). They are read before the script is played, so one that makes no
      # sense does not cost a playing to find — a stretch that names a moment included,
      # since a script says its moments where it is declared.
      #
      # Or, asked for `same: :script`, play the script on each of the two by itself and
      # compare them at each named moment.
      def compare(first, second, **settings) = Comparison.new(first, second, moment_names, **settings).run_playthrough(self)

      # WRITE ONE PICTURE OF ONE FRAME ON TWO CARTRIDGES at +path+: their two screens on
      # that frame side by side, with the difference between them. The script is played on
      # +first+ to learn its presses, as it is for a comparison, and both are then played on
      # those as far as the frame (see Comparison::PictureRequest). +at+ is the frame, by
      # its number or by the name of a moment, and +difference+ whether the picture marks
      # where the two differ. +settings+ are the ones of a comparison that a picture has a
      # use for (see Comparison::PICTURE_SETTINGS). The path is handed back.
      def write_side_by_side_picture(first, second, path, at: nil, difference: true, **settings)
        request = Comparison::PictureRequest.new(path, at: at, difference: difference)
        Comparison.for_picture(first, second, moment_names, **settings).write_picture_of_playthrough(self, request)
      end

      # The names of the moments the script declares, in the order it declares them.
      def moment_names = @steps.flat_map(&:names)

      # A console switched on with +cartridge+ in it and no frame played yet: the reader over
      # one running cartridge that everything here plays on and asks. +save+ is what the
      # cartridge's save memory holds. It is a copy that goes into the console, so the one
      # handed over is as it was afterwards and can start another.
      def self.power_on(cartridge, save: nil)
        cartridge = cartridge_from(cartridge)
        Diagnostics::Verifier.for(cartridge, frames: 0, vars: cartridge.var_addresses, save: save&.dup)
      end

      # A CONSOLE SWITCHED ON AND BROUGHT TO WHERE PLAYING SHOULD BEGIN: holding +save+, and
      # with +lead_in+ played on it, a playthrough of its own.
      #
      # WHAT A LEAD-IN IS FOR. A cartridge somebody else made shows its logos and an
      # introduction before its first screen, and another does not, so two cartridges that
      # are the same game are out of step from power-on before a button is pressed. A
      # lead-in for each gets each to the same place by its own road — usually a wait that
      # watches for the first screen — and what is played or compared starts there. Its
      # frames are not counted and its presses are on no tape: frame 1 is the first frame
      # after it.
      def self.power_on_and_lead_in(cartridge, save: nil, lead_in: nil)
        game = power_on(cartridge, save: save)
        lead_in&.play_as_lead_in(game)
        game
      end

      def self.refuse_lead_in_not_playthrough!(lead_in)
        return if lead_in.nil? || lead_in.is_a?(Playthrough)

        raise ArgumentError, "A lead-in was #{lead_in.inspect}. It must be a playthrough, which is played before the " \
                             "frames that count: `RubyGBA.playthrough(\"past the logos\") { wait_until(...) { ... } }`."
      end

      # THE CARTRIDGE THAT WAS HANDED OVER, which is one the build made or the path of a
      # cartridge file — a cartridge somebody else made, or one of this framework's written
      # to disk. A path is read into a CartridgeFile, which can be run and looked at like
      # any other and has no names for anything in it. A cartridge passes straight through,
      # so asking twice reads a file once.
      def self.cartridge_from(given)
        return given if given.respond_to?(:buffer) && given.respond_to?(:built)

        unless path?(given)
          raise ArgumentError, "A playthrough was given #{described(given)} to play. It must be a cartridge the build " \
                               "made (`RubyGBA.build`, `game.build_rom`), or the path of a cartridge file."
        end
        if bytes_given_as_path?(given)
          raise ArgumentError, "A playthrough was given #{given.bytesize} bytes of data to play, and not the path of a " \
                               "cartridge file. Write the bytes to a file, and give the path of that file."
        end
        Diagnostics::CartridgeFile.new(given)
      end

      # THE SAVE THAT WAS HANDED OVER, as save memory: the save another playing handed back,
      # or the path of a save file, which is that memory byte for byte. Nothing handed over
      # is no save, and a cartridge nobody has played.
      #
      # A save the framework has a model of is copied, so what was handed over is left as it
      # was. One it only has the bytes of cannot be changed, and is handed on as it is.
      def self.save_from(given)
        return given if given.nil? || given.is_a?(Diagnostics::SaveBytes)
        return given.dup if given.is_a?(IR::SaveImage)

        unless path?(given)
          raise ArgumentError, "`save:` was #{given.inspect}. It must be the save a playthrough handed back " \
                               "(`played.save`), or the path of a save file."
        end
        if bytes_given_as_path?(given)
          raise ArgumentError, "`save:` was #{given.bytesize} bytes of data, and not the path of a save file. To start from " \
                               "the bytes of a save, give `RubyGBA::IR::SaveImage.from_sav(bytes)`."
        end
        raise ArgumentError, "There is no save file at #{given}. Give the path of a save file." unless File.file?(given)

        Diagnostics::SaveBytes.save_holding(File.binread(given), from: "The save file at #{given}")
      end

      # +save+ MADE TO FIT +cartridge+, or refused. A cartridge this framework built says how
      # much save memory it has, and a chip cannot change size: a save of another size came
      # from another game, or is not a save at all. A cartridge it did not build says
      # nothing, so its save is taken as it comes.
      def self.save_fitted_to(cartridge, save)
        program = cartridge.source_program or return save
        memory = IR::SaveLayout.memory_of(program)
        if save.is_a?(Diagnostics::SaveBytes)
          raise ArgumentError, "#{save.from} is #{save.bytesize} bytes, and this cartridge has #{memory.kilobytes}K of " \
                               "save memory. A save file is as big as its cartridge's save memory. " \
                               "Give a save that came from this game."
        end
        save.tap { |fitted| fitted.use_memory!(memory) }
      rescue IR::SaveImage::WrongSize => e
        raise ArgumentError, "The save is #{e.save_kilobytes}K, and this cartridge has #{e.program_kilobytes}K of save " \
                             "memory. A save fits only a cartridge with the same size of save memory. " \
                             "Give a save that came from this game."
      end

      # A path is short and a cartridge or a save is thousands of bytes, so text that long,
      # or text with a nought byte in it, is the bytes themselves handed over where a path
      # was meant. They are named for what they are and not printed.
      LONGEST_PATH = 4096
      private_constant :LONGEST_PATH

      def self.path?(given) = (given.is_a?(String) && !given.empty?) || given.respond_to?(:to_path)
      def self.bytes_given_as_path?(given) = given.is_a?(String) && (given.bytesize > LONGEST_PATH || given.include?("\0"))

      # Something handed over where it does not go, as a refusal says it: a plain value as Ruby
      # writes it, and anything else by its kind, since written out it can be a cartridge's
      # worth of bytes.
      def self.described(given)
        case given
        when nil, Integer, Symbol, String then given.inspect
        else "a #{given.class}"
        end
      end
      private_class_method :path?, :bytes_given_as_path?, :described

      # ONE PLAYING, as it goes: the cartridge running, and a tape of every press made on it so
      # far. Each step plays itself on this. +title+ is the name of what is being played, for
      # an error to say whose playing it was.
      class Playing
        # Play +steps+ on +cartridge+, switched on and led in, and hand back what that came to.
        #
        # Everything handed over is made ready first, so what will not do is refused before
        # the console is switched on: the save, then the folder for pictures, then the
        # cartridge. A save has to fit its cartridge, so with one the cartridge is looked at
        # early, and a save of the wrong size is refused before a folder is made for nothing.
        #
        # The lead-in is played once the console is on and before the playing begins, so
        # none of it is on the tape.
        def self.play(title, steps, cartridge, save: nil, lead_in: nil, pictures_in: nil, &at_each_moment)
          Playthrough.refuse_lead_in_not_playthrough!(lead_in)
          save = Playthrough.save_from(save)
          save = Playthrough.save_fitted_to(cartridge = Playthrough.cartridge_from(cartridge), save) if save
          folder = PictureFolder.at(pictures_in, steps.flat_map(&:names))
          cartridge = Playthrough.cartridge_from(cartridge)
          game = Playthrough.power_on_and_lead_in(cartridge, save: save, lead_in: lead_in)
          playing = new(title, cartridge, game, at_each_moment, save: save, folder: folder, led_in: !lead_in.nil?)
          steps.each { |step| step.play(playing) }
          playing.played
        end

        # +game+ is the console, running, with +cartridge+ in it. +save+ is what the
        # cartridge's save memory held as the console was switched on, or nil for a
        # cartridge nobody has played, and +led_in+ whether a lead-in was played first:
        # both are what the tape says of where it started. +folder+ is where the picture
        # at each moment is written (see PictureFolder), or nil for none to be written.
        def initialize(title, cartridge, game, at_each_moment, save:, folder:, led_in: false)
          @title = title
          @cartridge = cartridge
          @game = game
          @save = save
          @led_in = led_in
          @at_each_moment = at_each_moment
          @folder = folder
          @taping = Tape::Taping.new
          @pictures = {}
          @picture_files = {}
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
          write_screen(PictureFolder.new(Dir.mktmpdir("playthrough"), []), "frame-#{@taping.frames}", @game.frame_gba)
        end

        # +pixels+ written into +folder+ as +name+, at the size of the console's screen.
        def write_screen(folder, name, pixels)
          folder.write(name, pixels, width: @game.screen_width, height: @game.screen_height)
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

        # Give the frame just played a name, keep the picture of it, and hand the game over
        # to whoever is watching. The picture is taken now because it cannot be taken later:
        # the console goes on to its next frame and this one is gone.
        #
        # A picture asked for as a file is written now too, and not when the playing ends:
        # a playthrough that gives up further on leaves the pictures of how far it got.
        def mark(name)
          @taping.moment(name)
          @pictures[name] = @game.frame_gba
          @picture_files[name] = write_screen(@folder, name, @pictures[name]) if @folder
          @at_each_moment&.call(name, @game)
        end

        # What this playing came to. The frames and the moments are the tape's own, so the
        # two can never disagree.
        def played
          tape = Tape.recorded_on(@cartridge, @taping.steps, save: @save, led_in: @led_in)
          Played.new(frames: tape.frames, moments: tape.moments, game: @game, tape: tape,
                     pictures: @pictures, picture_files: @picture_files, save: save_left)
        end

        # The cartridge's save memory as the last frame left it, or nil for a cartridge with
        # none. Whatever size it is: a cartridge somebody else made can keep a save of a
        # size the framework has no model of, and that one comes back as its bytes.
        def save_left
          bytes = @game.save_bytes
          bytes && Diagnostics::SaveBytes.save_holding(bytes, from: "The save this playthrough left")
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
  end

  class << self
    # Declare a playthrough: a game driven with nobody at the controls, from the steps in the
    # block. Nothing is played yet; see {Playthroughs::Playthrough#play}.
    #
    # It is also remembered, so a file that only declares playthroughs can be loaded and
    # asked what it declared — which is how the command line plays a script file.
    def playthrough(name, &script)
      Playthroughs::Playthrough.new(name, &script).tap do |declared|
        Ractor.current[:ruby_gba_registered_playthroughs] = registered_playthroughs + [declared]
      end
    end

    # Every playthrough declared so far, in the order they were. Kept for each core
    # separately, as the declared games are: a test that declares one on one core is not
    # seen from another.
    def registered_playthroughs = Ractor.current[:ruby_gba_registered_playthroughs] || [].freeze

    # Forget them, so that what a file declares can be told from what came before it.
    def forget_registered_playthroughs!
      Ractor.current[:ruby_gba_registered_playthroughs] = nil
    end
  end
end
