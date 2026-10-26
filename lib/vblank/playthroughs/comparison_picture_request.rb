# frozen_string_literal: true

require "fileutils" # here and not where it is used: see the note at the top of the verifier

module VBlank
  module Playthroughs
    class Comparison
      # WHAT WAS ASKED FOR, OF ONE PICTURE OF ONE FRAME ON TWO CARTRIDGES: which frame it is
      # of, the file it goes to, and whether it marks where the two differ.
      #
      #   tape.write_side_by_side_picture(ours, theirs, "door.png", at: 46)
      #   walk.write_side_by_side_picture(ours, theirs, "door.png", at: :at_the_door)
      #
      # WHAT THE PICTURE IS FOR. A frame number says two cartridges parted and nothing about
      # how. The two screens beside each other, with the pixels that differ marked, is what
      # a person looks at to see it — and a drift report holds one for the frame it reports
      # (see ScreenPair, which puts the picture together). This is the same picture for any
      # frame somebody wants to look at, drift or not.
      #
      # WHAT CAN BE KNOWN TO BE WRONG IS FOUND BEFORE A FRAME IS PLAYED, since the frame may
      # be minutes of play in: what was asked for is read here, and the frame is looked for
      # on the tape before either console is switched on. A script is the one exception —
      # how long it plays is not known until it has been played, so a frame past its end is
      # found after the first cartridge has played it.
      #
      # +path+ is the file to write. +at+ is the frame: its number, counted from 1, or the
      # name of a moment, which is the frame that moment names. +difference+ says whether
      # the picture has its third panel, the one that marks where the two differ.
      class PictureRequest
        def initialize(path, at:, difference:)
          refuse_non_path!(path)
          refuse_unusable_place!(path.to_s)
          refuse_invalid_frame!(at)
          refuse_non_boolean_difference!(difference)
          @path = path.to_s
          @at = at
          @difference = difference
        end

        # The frame of +tape+ the picture is of, or a refusal: a moment the tape does not
        # name, or a frame it does not reach.
        def frame_on(tape)
          refuse_moment_not_among!(tape.moments.keys)
          frame = tape.moments.fetch(@at, @at)
          return frame if frame <= tape.frames

          give = tape.frames.zero? ? "It has no frame to make a picture of." : "Give a frame from 1 to #{tape.frames}."
          raise ArgumentError, "`at:` was #{@at}, and the playthrough is #{tape.frames} frames long. #{give}"
        end

        # +names+ is the moments a playthrough names. A script says them where it is
        # declared, so a moment it does not have is known before the script is played.
        def refuse_moment_not_among!(names)
          return unless @at.is_a?(Symbol) && !names.include?(@at)

          there_are = names.empty? ? "The playthrough names no moments." : "Its moments are #{names.map(&:inspect).join(', ')}."
          raise ArgumentError, "`at:` was #{@at.inspect}. The playthrough has no moment named #{@at.inspect}. #{there_are}"
        end

        # Write the picture of +screens+, a ScreenPair, making the folder it goes in when
        # that is not there. The path of the file is handed back.
        def write(screens)
          FileUtils.mkdir_p(File.dirname(@path))
          screens.write_side_by_side(@path, with_difference: @difference)
        end

        private

        def refuse_non_path!(path)
          return if (path.is_a?(String) && !path.empty?) || path.respond_to?(:to_path)

          raise ArgumentError, "The file for the picture was #{path.inspect}. It must be the path of a file, " \
                               'like "door.png".'
        end

        # Nothing is made here, so what is looked at is what would stop the file being
        # written. A file already there under its name is written over, so it has to be
        # one that can be. With none there, the nearest thing above it that is already
        # there is where its own folder would be made.
        def refuse_unusable_place!(place)
          why = unusable_place_reason(File.expand_path(place)) or return

          raise ArgumentError, "The file for the picture was #{place.inspect}. #{why} Give the path of a file in a " \
                               "folder that can be written to. If the folder is not there, the playthrough makes it."
        end

        # Why nothing can be written at +file+, a whole path — or nil when it can.
        def unusable_place_reason(file)
          return "That is a folder, and the picture needs a file." if File.directory?(file)
          return ("That file cannot be written to." unless File.writable?(file)) if File.exist?(file)

          above = File.dirname(file)
          above = File.dirname(above) until File.exist?(above)
          return "#{above} is a file, so no folder can be made inside it." unless File.directory?(above)

          "The folder #{above} cannot be written to." unless File.writable?(above)
        end

        # A frame missing altogether is refused here too, as the nothing it was given.
        def refuse_invalid_frame!(at)
          return if at.is_a?(Symbol) || (at.is_a?(Integer) && at >= 1)

          raise ArgumentError, "`at:` was #{at.inspect}. It must be the number of a frame, counted from 1, or the name " \
                               "of a moment, like `at: 46` or `at: :at_the_door`."
        end

        def refuse_non_boolean_difference!(given)
          return if [true, false].include?(given)

          raise ArgumentError, "`difference:` was #{given.inspect}. It must be true or false. Give `difference: false` " \
                               "to write the two screens with no third panel."
        end
      end
    end
  end
end
