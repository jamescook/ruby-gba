# frozen_string_literal: true

require "fileutils" # here and not where it is used: see the note at the top of the verifier

module RubyGBA
  module Playthroughs
    class Comparison
      # A DRIFT, WRITTEN DOWN FOR SOMEBODY TO LOOK AT: one folder, holding what it takes to
      # see what went wrong and to get back to it.
      #
      #   first.png, second.png   the two screens where the two drifted
      #   difference.png          the first screen greyed, with every pixel that differs marked
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
        TEXT = "report.txt"

        # What a differing pixel is marked in: a colour a greyed screen cannot hold.
        MARK = Graphics::Color.resolve(:magenta)

        # A SECOND OF PLAY, in frames: how far back the report says what was down.
        ONE_SECOND = 60

        WIDTH = Console::Hardware::SCREEN_WIDTH
        HEIGHT = Console::Hardware::SCREEN_HEIGHT

        # The two cartridges as a report names them, in order.
        SIDES = %w[first second].freeze

        # What can differ that is not a reading, as a report says it.
        WHAT_IS_NOT_A_READING = { PICTURE => "the picture", FRAMES_APART => "how many frames each cartridge took" }.freeze
        private_constant :MARK, :ONE_SECOND, :WIDTH, :HEIGHT, :SIDES, :WHAT_IS_NOT_A_READING

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

        # +drift+ is where the two stopped being alike and +pictures+ their two screens
        # there. +cartridges+ is the two that were played, +pixels_differing+ where in a
        # picture the two differ (see Likeness#differing_places), and +settings+ the
        # sentences that say what was compared and how alike the two had to be.
        def initialize(drift, pictures, cartridges:, pixels_differing:, settings:)
          @drift = drift
          @first, @second = pictures
          @cartridges = cartridges
          @pixels_differing = pixels_differing
          @settings = settings
        end

        # Write the folder inside +place+, and hand back its path. A report already there
        # under the same name is written over.
        def write_in(place)
          folder = File.join(place, folder_name)
          FileUtils.mkdir_p(folder)
          write_picture(File.join(folder, FIRST_PICTURE), @first)
          write_picture(File.join(folder, SECOND_PICTURE), @second)
          write_picture(File.join(folder, DIFFERENCE), difference_picture)
          write_tapes(folder)
          File.write(File.join(folder, TEXT), text)
          folder
        rescue SystemCallError => e
          raise ReportNotWritten.new(@drift, where_lines.first, folder, e.message)
        end

        private

        def write_picture(path, pixels) = Graphics::PNG.write(path, width: WIDTH, height: HEIGHT, pixels: pixels)

        # The first screen with its colour taken out and dimmed, so it is only there to say
        # where on the screen things are, and every pixel that differs in the mark's colour.
        def difference_picture
          marked = @first.map { |colour| greyed(colour) }
          @pixels_differing.each { |at| marked[at] = MARK }
          marked
        end

        # A colour as the grey of half its brightness. The console keeps five bits each of
        # red, green and blue, lowest first.
        def greyed(colour)
          grey = ((colour & 31) + ((colour >> 5) & 31) + ((colour >> 10) & 31)) / 6
          grey | (grey << 5) | (grey << 10)
        end

        # The text, of which each kind of report says the four parts about where the drift
        # was: `where_lines`, `played_lines`, `presses_lines` and `contents_lines`.
        def text
          [
            *where_lines,
            "The two screens differed in #{@pixels_differing.size} pixels there.",
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
