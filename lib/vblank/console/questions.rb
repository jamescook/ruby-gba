# frozen_string_literal: true

module VBlank
  module Console
    # WHAT A LINE OF A GAME ASKS OF THE CONSOLE IT RUNS ON: which verb's answer (Console::Answers)
    # has the words for it, what the line asks for in words of its own, and — for a verb that works
    # but has a part some consoles lack, the Color's `held` for a shoulder button it does not have —
    # whether this console has that part, read from its description.
    #
    # The question is the same for every console, so it is asked here once and every console's
    # answers read it: the build's checks before anything is made (Checks::ConsoleAnswers), and
    # each lowering, for a program handed to it straight, as a test's is (LoweringPlan). Nothing
    # else keeps a list of what a console refuses.
    #
    # It reads the steps of a program, which are the IR's, and is only asked once everything is
    # loaded, so the console module still needs nothing loaded before it.
    module Questions
      # +verb+ whose answer has the words, what the line asks for in +words+, and +can+: whether the
      # console has the part asked for, or nil where the verb's own answer decides.
      Question = Data.define(:verb, :words, :can)

      module_function

      # The Question +node+ asks of +console+ (a Console::Description), or nil for a line that asks
      # for nothing a console could lack.
      def question_for(node, console)
        case node.kind
        when :raw then Question.new(:entry, "This line hands the Advance's processor raw instructions (`entry`)", nil)
        when :shade_outside then Question.new(:spotlight, "This game has a light (`spotlight`)", nil)
        when :sample, :play_sample then recording_question(node, console)
        when :pixelate then Question.new(:pixelate, "This line shows the screen in blocks (`pixelate`)", nil)
        when :clock then Question.new(:clock, "This line reads the clock (`clock`)", nil)
        when :set_clock then Question.new(:clock, "This line sets the clock (`clock.set_to`)", nil)
        # The layers' declaration, which every see-through layer is in: one whose amounts are
        # written in the program is told to the console once and has no step of its own. A
        # console that mixes only by half is asked no more here: its build says which amounts
        # it can show (Backends::SNES::Lowering::Picture#refuse_unmade_see_through!).
        when :layers
          unless node.see_through.empty?
            Question.new(:layers, "This game shows one layer through another (`transparency:`)",
                         console.blends || console.mixes_by_half)
          end
        # ...and the step that tells the console again how see-through a layer is, before each
        # frame, for an amount the game works out. Only a console that blends by any amount can.
        when :see_through
          Question.new(:layers, "This game changes how much one layer shows through another as the game runs", console.blends)
        when :held, :pressed
          Question.new(:held, "This line reads the #{node.button.inspect} button", button?(node.button, console))
        when :fade
          Question.new(:fade, "This line fades part of the screen", console.blends) if node.under || node.reaches
        when :affine_background
          Question.new(:background, "This line turns or resizes a background", console.turns_backgrounds?)
        when :screen
          if node.mode == :rotozoom
            Question.new(:screen, "This game has a turning screen (`screen :rotozoom`)", console.turns_backgrounds?)
          end
        when :object
          if turns?(node)
            Question.new(:sprite, "This sprite turns or resizes (`scale`, `face_angle`, `turn`, `pulse`)",
                         console.turning_sprites)
          end
        end
      end

      # A recording, and the parts of playing one that only a console that mixes them can do
      # (Console::Description#mixes_recordings): one that plays them as recorded, a sample at a
      # time, has no way to loop one, read it at another note, scale it by three quarters or
      # shape it. Half, a quarter and nothing a sound chip's voice does itself.
      def recording_question(node, console)
        mixes = console.mixes_recordings
        asked = if node.kind == :sample
                  "This recording has a shape (`envelope:`)" if node.envelope && !node.envelope.plain?
                elsif node.loop
                  "This line plays a recording over and over (`loop: true`)"
                elsif node.pitch
                  "This line plays a recording at another note (`pitch:`)"
                elsif node.volume == :three_quarter
                  "This line plays a recording at three quarters of its volume"
                end
        asked ? Question.new(:sample, asked, mixes) : Question.new(:sample, "This game plays a recording", nil)
      end

      # THE WAVE VOICE IN A GAME THAT PLAYS A RECORDING, on a console that plays recordings on it:
      # each line that sounds or stops the wave voice itself (`wave`, `stop_wave`) would take the
      # voice from under the recording. A song's wave part stands aside while one plays. The lines
      # of +nodes+ that do, on +console+.
      def wave_beside_recordings(nodes, console)
        return [] if console.mixes_recordings || nodes.none? { |node| node.kind == :play_sample }

        nodes.select { |node| %i[wave stop_wave].include?(node.kind) }
      end

      # Whether +console+ has the button +button+ names; any button at all, every console has.
      def button?(button, console) = button == IR::Buttons::ANY || console.buttons.include?(button)

      # A sprite turns or resizes when its angle or its size is anything but the one it is drawn
      # at: upright, as drawn (Build#object's defaults).
      def turns?(obj)
        !(obj.angle.kind == :int && obj.angle.value.zero? && obj.scale.kind == :int && obj.scale.value == IR::Build::SCALE_ONE)
      end
    end
  end
end
