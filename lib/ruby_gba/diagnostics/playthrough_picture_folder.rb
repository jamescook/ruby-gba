# frozen_string_literal: true

require "fileutils" # here and not where it is used: see the note at the top of the verifier

module RubyGBA
  module Diagnostics
    class Playthrough
      # THE FOLDER A PLAYING WRITES ITS PICTURES INTO: the screen at each named moment, as a
      # PNG named for the moment.
      #
      # EVERYTHING THAT CAN BE WRONG WITH IT IS FOUND BEFORE A FRAME IS PLAYED, because the
      # first picture may be minutes of play in and that is a poor place to learn the folder
      # was never going to work. So the folder is made here, and the moments the playing
      # will name are looked at here too.
      #
      # A file already in the folder under a moment's name is written over, and files from an
      # earlier playing are left as they are.
      class PictureFolder
        # The folder at +path+ for a playing that will name the moments +names+ — or nothing
        # at all for no path, which is a playing that was not asked for files.
        def self.at(path, names) = path.nil? ? nil : new(path, names)

        def initialize(path, names)
          refuse_non_path!(path)
          refuse_moments_sharing_one_file!(names)
          @path = path.to_s
          make_folder!
        end

        # Write +pixels+, a screenful of colours, as the picture at the moment +name+. The
        # path of the file is handed back.
        def write(name, pixels)
          Graphics::PNG.write(File.join(@path, "#{name}.png"), width: Console::Hardware::SCREEN_WIDTH,
                                                               height: Console::Hardware::SCREEN_HEIGHT, pixels: pixels)
        end

        private

        def refuse_non_path!(path)
          return if (path.is_a?(String) && !path.empty?) || path.respond_to?(:to_path)

          raise ArgumentError, "`pictures_in:` was #{path.inspect}. It must be the path of a folder, " \
                               'like `pictures_in: "pictures"`.'
        end

        # A moment's name is its picture's file name, so it has to be a plain word, and no
        # two can be the same word but for their capitals: many disks do not tell a capital
        # from a small letter, and there the second picture would be written over the first.
        def refuse_moments_sharing_one_file!(names)
          odd = names.find { |name| !Moment::NAME.match?(name.to_s) }
          if odd
            raise ArgumentError, "The moment #{odd.inspect} cannot name a picture's file. A moment's name must be made of " \
                                 "letters, digits and underscores."
          end
          first, second = names.group_by { |name| name.to_s.downcase }.values.find { |alike| alike.size > 1 }
          return unless first

          raise ArgumentError, "The moments #{first.inspect} and #{second.inspect} differ only in their capital letters. " \
                               "Their pictures would be the same file on a disk that does not tell capital letters from " \
                               "small letters. To write pictures, give one of the two moments a different name."
        end

        def make_folder!
          raise_cannot_make_folder!("That is a file, and the pictures need a folder.") if File.file?(@path)

          FileUtils.mkdir_p(@path)
          raise_cannot_make_folder!("The folder cannot be written to.") unless File.writable?(@path)
        rescue SystemCallError => e
          raise_cannot_make_folder!("The folder could not be made: #{e.message}.")
        end

        def raise_cannot_make_folder!(why)
          raise ArgumentError, "`pictures_in:` was #{@path.inspect}. #{why} Give the path of a folder that can be " \
                               "written to. If the folder is not there, the playthrough makes it."
        end
      end
    end
  end
end
