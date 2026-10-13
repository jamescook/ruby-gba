# frozen_string_literal: true

module RubyGBA
  module Diagnostics
    class Comparison
      # THE REPORT OF A DRIFT AT A NAMED MOMENT, for a comparison on the same script, in
      # which each cartridge was played by itself:
      #
      #   - the folder is named for the moment, since the two reached it on different frames;
      #   - there are two tapes, one for each cartridge, because each made its own presses
      #     and its own is the one that plays it back to that moment;
      #   - the text says the frame each reached the moment on, and the last second of
      #     presses on each.
      #
      # +reached+ is how each cartridge got to the drift's moment, the first cartridge and
      # then the second: each a Reached.
      class MomentReport < Report
        FIRST_TAPE = "first-to-the-moment.tape"
        SECOND_TAPE = "second-to-the-moment.tape"

        # One cartridge's way to the moment: the presses it was played with, and the frame
        # it was on when it got there.
        Reached = Data.define(:tape, :frame)

        def initialize(drift, pictures, reached:, **what_any_report_has)
          super(drift, pictures, **what_any_report_has)
          @reached = reached
        end

        private

        def folder_name = "moment-#{@drift.moment}"

        def write_tapes(folder)
          [FIRST_TAPE, SECOND_TAPE].zip(@reached) { |name, side| side.tape.up_to(side.frame).write(File.join(folder, name)) }
        end

        def where_lines
          ours, theirs = @reached.map(&:frame)
          apart = (ours - theirs).abs
          how_far = apart.zero? ? "on the same frame" : "#{apart} #{apart == 1 ? 'frame' : 'frames'} apart"
          ["The two cartridges drifted at the moment #{@drift.moment}.",
           "The first cartridge reached it on frame #{ours} and the second on frame #{theirs}, #{how_far}.",
           differed_sentence("at that moment")]
        end

        def played_lines = ["the same script was played on each cartridge by itself"]

        def presses_lines
          SIDES.zip(@reached).flat_map do |side, reached|
            ["The presses of the last second on the #{side} cartridge",
             *last_second_of_presses(reached.tape, reached.frame).map { |line| "  #{line}" }]
          end
        end

        def contents_lines
          ["#{FIRST_PICTURE} and #{SECOND_PICTURE}: the two screens at the moment #{@drift.moment}.",
           "#{DIFFERENCE}: the first screen in grey, with each pixel that differed in magenta.",
           "#{FIRST_TAPE} and #{SECOND_TAPE}: every press each cartridge was given up to that moment. " \
           "Play each on its own cartridge to be at that moment again."]
        end
      end
    end
  end
end
