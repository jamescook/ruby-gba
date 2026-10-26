# frozen_string_literal: true

require "fileutils" # here and not where it is used: see the note at the top of the verifier

module VBlank
  module Playthroughs
    class Comparison
      # A DRIFT, WRITTEN DOWN FOR SOMEBODY TO LOOK AT: one folder, holding what it takes to
      # see what went wrong and to get back to it.
      #
      #   first.png, second.png   the two screens where the two drifted
      #   difference.png          the first screen greyed, with every pixel that differs marked
      #   side-by-side.png        the screens and the difference in one picture, left to right
      #                           and bigger: the one to open first, and to send somebody
      #   report.txt              where the drift was, every named reading, the last second of
      #                           presses, what was compared and how alike it had to be
      #   a tape, or two          every press up to there
      #
      # WHY A TAPE AND NOT ONLY A PICTURE. A picture says what the two screens were. A tape
      # plays a cartridge to that exact place again, with a debugger on it or a script that
      # asks it things — which is where finding out WHY starts.
      #
      # THERE ARE TWO KINDS, for the two ways a comparison is made, and this is what they
      # share. A DriftReport is of a drift on a frame both cartridges were on, played on
      # one tape. A MomentReport is of a drift at a named moment each cartridge reached in
      # its own time. Each says what its folder is called, which tapes go in it, and the
      # parts of the text that are about where the drift was.
      class Report
        FIRST_PICTURE = "first.png"
        SECOND_PICTURE = "second.png"
        DIFFERENCE = "difference.png"
        SIDE_BY_SIDE = "side-by-side.png"
        TEXT = "report.txt"

        # A SECOND OF PLAY, in frames: how far back the report says what was down.
        ONE_SECOND = 60

        WIDTH = Console::Hardware::SCREEN_WIDTH
        HEIGHT = Console::Hardware::SCREEN_HEIGHT

        # The two cartridges as a report names them, in order.
        SIDES = %w[first second].freeze

        # What can differ that is not a reading, as a report says it.
        WHAT_IS_NOT_A_READING = { PICTURE => "the picture", FRAMES_APART => "how many frames each cartridge took" }.freeze
        private_constant :ONE_SECOND, :WIDTH, :HEIGHT, :SIDES, :WHAT_IS_NOT_A_READING

        # THE PLACE REPORTS GO, as its path, or nil for nowhere. It is looked at before a
        # frame is played, and nothing is made there: a comparison that finds no drift
        # leaves no folder behind. So what can be known without making it is checked — that
        # it is a path, and that the nearest folder above it that is already there is a
        # folder that can be written to, which is the one it would be made in.
        def self.place_for(given)
          return if given.nil?

          refuse_non_path!(given)
          given.to_s.tap { |place| refuse_unusable_place!(place) }
        end

        def self.refuse_non_path!(given)
          return if (given.is_a?(String) && !given.empty?) || given.respond_to?(:to_path)

          raise ArgumentError, "`reports_in:` was #{given.inspect}. It must be the path of a folder, " \
                               'like `reports_in: "drift"`.'
        end

        def self.refuse_unusable_place!(place)
          there = File.expand_path(place)
          there = File.dirname(there) until File.exist?(there)
          return if File.directory?(there) && File.writable?(there)

          why = if File.directory?(there)
                  "The folder #{there} cannot be written to."
                elsif there == File.expand_path(place)
                  "That is a file, and the reports need a folder."
                else
                  "#{there} is a file, so no folder can be made inside it."
                end
          raise ArgumentError, "`reports_in:` was #{place.inspect}. #{why} Give the path of a folder that can be " \
                               "written to. If the folder is not there, the comparison makes it."
        end
        private_class_method :refuse_non_path!, :refuse_unusable_place!

        # +drift+ is where the two stopped being alike and +screens+ their two screens
        # there with where those differ, a ScreenPair. +cartridges+ is the two that were
        # played, and +settings+ the sentences that say what was compared and how alike
        # the two had to be.
        def initialize(drift, screens, cartridges:, settings:)
          @drift = drift
          @screens = screens
          @cartridges = cartridges
          @settings = settings
        end

        # Write the folder inside +place+, and hand back its path. A report already there
        # under the same name is written over.
        def write_in(place)
          folder = File.join(place, folder_name)
          FileUtils.mkdir_p(folder)
          write_picture(File.join(folder, FIRST_PICTURE), @screens.first)
          write_picture(File.join(folder, SECOND_PICTURE), @screens.second)
          write_picture(File.join(folder, DIFFERENCE), @screens.difference_screen)
          @screens.write_side_by_side(File.join(folder, SIDE_BY_SIDE))
          write_tapes(folder)
          File.write(File.join(folder, TEXT), text)
          folder
        rescue SystemCallError => e
          raise ReportNotWritten.new(@drift, where_lines.first, folder, e.message)
        end

        private

        def write_picture(path, pixels) = Graphics::PNG.write(path, width: WIDTH, height: HEIGHT, pixels: pixels)

        # What the two pictures of the difference are, which every kind of report says alike.
        def difference_lines
          ["#{DIFFERENCE}: the first screen in grey, with each pixel that differed in magenta.",
           "#{SIDE_BY_SIDE}: the two screens and the difference in one picture, left to right, at twice the console's size."]
        end

        # The text, of which each kind of report says the four parts about where the drift
        # was: `where_lines`, `played_lines`, `presses_lines` and `contents_lines`.
        def text
          [
            *where_lines,
            screens_sentence,
            "",
            *readings_lines,
            "What was played",
            *@cartridges.zip(SIDES).map { |cartridge, side| "  the #{side} cartridge: #{Tape.label_of(cartridge)}" },
            *played_lines.map { |line| "  #{line}" },
            "",
            "What was compared, and how alike the two had to be",
            *@settings.map { |sentence| "  #{sentence}" },
            "",
            *presses_lines,
            "",
            "What is in this folder",
            *contents_lines.map { |line| "  #{line}" },
          ].join("\n") << "\n"
        end

        # How many pixels the two screens differed in. A drift found in a reading alone can
        # be on two screens that are the same picture, and then that is what it says — or
        # on two that differ only in a part left out, which the two pictures in the folder
        # still show, so then it says that.
        def screens_sentence
          out = @screens.differing.size
          return "The two screens differed in #{out} #{out == 1 ? 'pixel' : 'pixels'} there." if out.positive?
          return "The two screens were the same picture there." if @screens.first == @screens.second

          "The two screens differed only in the parts that were not looked at."
        end

        # +where+ is `on that frame` or `at that moment`.
        def differed_sentence(where)
          things = @drift.differed.map { |what| WHAT_IS_NOT_A_READING.fetch(what) { "the reading #{what}" } }
          "What differed #{where}: #{things.join(', ')}."
        end

        # Every named reading on both cartridges, the ones that agree as well: a number a
        # pixel out is easier to chase than a picture that looks wrong, and the ones that
        # agree say what the difference is NOT.
        def readings_lines
          return [] if @drift.readings.empty?

          apart = Readings.differing(@drift.readings)
          lines = @drift.readings.map do |name, (ours, theirs)|
            next "  #{name}: #{ours.inspect} on both." unless apart.include?(name)

            "  #{name}: #{ours.inspect} on the first cartridge, #{theirs.inspect} on the second. They differ."
          end
          ["The readings there", *lines, ""]
        end

        # What was down on +frame+ of +tape+ and on the frames of the second before it, a
        # line for each run of frames with the same buttons down.
        def last_second_of_presses(tape, frame)
          from = [frame - ONE_SECOND + 1, 1].max
          tape.presses_within(from..frame).map do |stretch|
            first = stretch.frames.begin
            last = stretch.frames.end
            down = stretch.buttons.empty? ? "nothing down" : stretch.buttons.join(" and ")
            "#{first == last ? "frame #{first}" : "frames #{first} to #{last}"}: #{down}"
          end
        end
      end
    end
  end
end
