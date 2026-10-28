# frozen_string_literal: true

module VBlank
  module IR
    module Guardrails
      module Checks
        # A GAME TOLD AT EACH LINE THAT ASKS FOR SOMETHING ITS CONSOLE CANNOT DO, in the words that
        # console's answers have for the verb (Console::Answers): an error, before anything is made.
        # Nothing is shown differently on any console, so nothing is only warned of but a crowded
        # row (below).
        #
        # It asks the console the program was made for, through its kit, so a game for two
        # consoles hears on each build only what that console cannot do. The Advance does every
        # verb and has every part of one, so a game for it alone is never told anything here.
        #
        # One thing is not a verb's: a console that draws only so many sprites on one row of the
        # screen leaves the rest out of that row. Where sprites that never move — a line of tiled
        # text, say — put more than that on a row, that row is named.
        class ConsoleAnswers
          NAME = :console_answers
          PLAIN_NAME = "something the console cannot do"

          # What one line asks of the console: the +verb+ whose answer has the words, what the
          # line asks for in +words+, and +can+ — for a verb that works but has a part some
          # consoles lack, whether this console has that part — or nil, where the verb's own
          # answer decides.
          Question = Data.define(:verb, :words, :can)

          def detect(program)
            return [] unless program.kind == :program

            console = program.described_console
            answers = Console.for(console.name).answers
            nodes = program.walk.to_a
            refused(nodes, console, answers) + wave_beside_recordings(nodes, console, answers) +
              crowded_rows(program, nodes, console)
          end

          private

          # What the console cannot do, at every line that asks for it, in +answers+' words.
          def refused(nodes, console, answers)
            nodes.filter_map do |node|
              question = console_question_for(node, console) or next
              answer = answers.answer(question.verb)
              next if question.can.nil? ? answer.works? : question.can

              Finding.new(check: NAME, severity: :error, node: node,
                          message: "#{question.words}, and a #{console.title} cannot: #{answer.words}")
            end
          end

          # WHAT A LINE ASKS OF THE CONSOLE (a Question), the same question for every console, with
          # whether +console+ has the part asked for read from its description. Nil for a line that
          # asks for nothing a console could lack.
          def console_question_for(node, console)
            case node.kind
            when :raw then Question.new(:entry, "This line hands the Advance's processor raw instructions (`entry`)", nil)
            when :shade_outside then Question.new(:spotlight, "This game has a light (`spotlight`)", nil)
            when :sample, :play_sample then recording_question(node, console)
            when :pixelate then Question.new(:pixelate, "This line shows the screen in blocks (`pixelate`)", nil)
            # The layers' declaration, which every see-through layer is in: one whose amounts are
            # written in the program is told to the console once and has no step of its own.
            when :layers
              unless node.see_through.empty?
                Question.new(:layers, "This game shows one layer through another (`transparency:`)", console.blends)
              end
            when :held, :pressed
              Question.new(:held, "This line reads the #{node.button.inspect} button", console_has_button?(node.button, console))
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

          # THE WAVE VOICE IN A GAME THAT PLAYS A RECORDING, on a console that plays recordings on
          # it: each line that sounds or stops the wave voice itself (`wave`, `stop_wave`) would take
          # the voice from under the recording. A song's wave part stands aside while one plays.
          def wave_beside_recordings(nodes, console, answers)
            return [] if console.mixes_recordings || nodes.none? { |node| node.kind == :play_sample }

            nodes.filter_map do |node|
              next unless %i[wave stop_wave].include?(node.kind)

              Finding.new(check: NAME, severity: :error, node: node,
                          message: "This line uses the wave voice in a game that plays a recording, and a " \
                                   "#{console.title} cannot: #{answers.answer(:sample).words}")
            end
          end

          # Whether +console+ has the button +button+ names; any button at all, every console has.
          def console_has_button?(button, console) = button == Buttons::ANY || console.buttons.include?(button)

          # A sprite turns or resizes when its angle or its size is anything but the one it is drawn
          # at: upright, as drawn (Build#object's defaults).
          def turns?(obj)
            !(obj.angle.kind == :int && obj.angle.value.zero? && obj.scale.kind == :int && obj.scale.value == Build::SCALE_ONE)
          end

          # Rows of the screen where sprites that never move — their place and picture written in
          # the program — come to more than +console+ draws on one row in one scene, each row named
          # once. A console whose rows the build does not count (Console::Description#sprites_a_row)
          # is told nothing.
          def crowded_rows(program, nodes, console)
            most = console.sprites_a_row or return []
            pictures = nodes.select { |node| node.kind == :bitmap }.to_h { |node| [node.name, node] }
            nodes.select { |node| node.kind == :object && fixed?(node) }.group_by(&:scene).flat_map do |_, objects|
              counts = Hash.new(0)
              objects.each do |obj|
                picture = pictures[obj.poses.first]
                next unless picture

                top = obj.y.value
                columns = (picture.width + 7) / 8
                (top...(top + picture.height)).each { |row| counts[row] += columns }
              end
              row, count = counts.select { |r, c| c > most && r.between?(0, console.screen_height - 1) }.min_by(&:first)
              next [] unless row

              blamed = objects.find { |obj| obj.y.value <= row } || :program
              [Finding.new(check: NAME, severity: :warning, node: blamed.respond_to?(:source) ? blamed : program,
                           message: "#{count} pieces of sprites stand on row #{row} of the screen at once. A " \
                                    "#{console.title} draws #{most} on any one row and leaves the rest out of it. " \
                                    "To fix this, move some of them to another row, or use fewer letters there.")]
            end
          end

          def fixed?(obj) = %i[x y pose].all? { |field| obj.public_send(field).kind == :int }
        end
      end
    end
  end
end
