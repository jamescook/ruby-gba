# frozen_string_literal: true

require "zlib"

module RubyGBA
  module IR
    module Backends
      # WHAT TELLS A LOWERED GAME FROM THE SAME GAME ON THE INTERPRETER, the one comparison every
      # checked run makes: the game as C (Native::CheckedRun), as JavaScript (JS::CheckedRun) and as
      # a Game Boy Color cartridge (GBC::CheckedRun) each play their game, play the same buttons on
      # the interpreter, and hand the two runs' Moments to #first_difference. The rest say the
      # sound log, the mixed sound, the sounds lost and the save memory apart, at the end of a run.
      #
      # Each says what it found in words a person can act on, with the side being checked named
      # by #lowered_side, which a checked run gives its own name.
      module RunComparison
        # Where a game had got to at one frame boundary, or (+frame+ :end) when the run stopped:
        # every variable, the picture as a check number (see .picture_check), how long the sound
        # log was, the sprites it last drew, its lists and pools as Reference#game_state reads
        # them, and the recordings the mixer is sounding, a voice each in the order of the voices —
        # which says whose voice a new note took.
        Moment = Data.define(:frame, :variables, :picture, :sounds, :sprites, :collections, :sounding) do
          def initialize(frame:, variables:, picture:, sounds:, sprites:, collections: { lists: {}, pools: {} },
                         sounding: [])
            super
          end
        end

        # Raised for something a test asks of the interpreter that a lowered run cannot answer yet:
        # the lowering has a gap to fill, or that one test wants its lowering's skip.
        class CannotAnswer < StandardError; end

        # A picture as one number: the CRC-32 of its pixels, two bytes each with the low byte first.
        def self.picture_check(shown) = Zlib.crc32(shown.pack("v*"))

        # The first moment +got+ (the lowered side) disagrees with +want+ (the interpreter) on, said
        # as the frame and everything that differs there; nil when they agree throughout.
        def first_difference(want, got)
          if want.map(&:frame) != got.map(&:frame)
            return "how far the run went: the interpreter stopped after frame #{last_frame(want)}, " \
                   "the #{lowered_side} after frame #{last_frame(got)}"
          end

          want.zip(got).each do |reference, lowered|
            differences = variable_differences(reference.variables, lowered.variables)
            differences << "the picture differs" if reference.picture != lowered.picture
            if reference.sounds != lowered.sounds
              differences << "the sound log holds #{lowered.sounds} entries in the #{lowered_side} and " \
                             "#{reference.sounds} in Reference"
            end
            differences.concat([sprites_difference(reference.sprites, lowered.sprites)].compact)
            differences.concat(collections_differences(reference.collections, lowered.collections))
            if reference.sounding != lowered.sounding
              differences << "the mixer sounds #{lowered.sounding.inspect} in the #{lowered_side} and " \
                             "#{reference.sounding.inspect} in Reference"
            end
            return "#{heading(reference.frame)}: #{differences.join('; ')}" if differences.any?
          end
          nil
        end

        # Each list and each pool field +got+ holds differently from +want+, said with both.
        def collections_differences(want, got)
          lists = (want[:lists].keys | got[:lists].keys).filter_map do |name|
            mine, theirs = got[:lists][name], want[:lists][name]
            "list :#{name}: #{lowered_side} has #{mine.inspect}, Reference #{theirs.inspect}" if mine != theirs
          end
          fields = (want[:pools].keys | got[:pools].keys).flat_map do |pool|
            mine, theirs = got[:pools].fetch(pool, {}), want[:pools].fetch(pool, {})
            (theirs.keys | mine.keys).filter_map do |field|
              next if mine[field] == theirs[field]

              "pool :#{pool} field :#{field}: #{lowered_side} has #{mine[field].inspect}, Reference #{theirs[field].inspect}"
            end
          end
          lists + fields
        end

        # The first entry of the sound log the two disagree on, or nil when every entry is the same.
        def sounds_difference(want, got)
          at = (0...[want.size, got.size].max).find { |index| want[index] != got[index] }
          at && "entry #{at} of the sound log: #{lowered_side} has #{got[at].inspect}, Reference #{want[at].inspect}"
        end

        # The first frame's slice of mixed sound the two disagree on — the frame and the first
        # sample in it — or nil when they made the same bytes throughout.
        def mix_difference(want, got)
          return "how many frames were mixed: the #{lowered_side} mixed #{got.size}, Reference #{want.size}" if want.size != got.size

          frame = want.each_index.find { |index| want[index] != got[index] } or return nil
          sample = (0...[want[frame].size, got[frame].size].max).find { |index| want[frame][index] != got[frame][index] }
          "frame #{frame + 1} of the mix, sample #{sample}: #{lowered_side} has #{got[frame][sample].inspect}, " \
            "Reference #{want[frame][sample].inspect}"
        end

        # How many sounds each lost to a full mixer, and the most voices the music held at one of
        # those moments, when the two disagree.
        def drops_difference(want, got)
          return nil if [want.dropped, want.music_held] == [got.dropped, got.music_held]

          "the sounds lost to a full mixer: the #{lowered_side} lost #{got.dropped} with the music holding at most " \
            "#{got.music_held}, Reference #{want.dropped} with #{want.music_held}"
        end

        # The first byte of save memory the two ended a run disagreeing on, or nil when the two
        # chips hold the same bytes throughout.
        def save_difference(want, got)
          wanted = want.to_sav
          held = got.to_sav
          return nil if wanted == held

          at = (0...[wanted.bytesize, held.bytesize].max).find { |index| wanted.getbyte(index) != held.getbyte(index) }
          format("save memory at 0x%<at>X: #{lowered_side} has 0x%<got>02X, Reference 0x%<want>02X", at: at,
                                                                                        got: held.getbyte(at) || 0,
                                                                                        want: wanted.getbyte(at) || 0)
        end

        # The first of the sprites drawn that the two disagree on, counted from the back, or nil
        # when they drew the same ones in the same places showing the same pictures.
        def sprites_difference(want, got)
          at = (0...[want.size, got.size].max).find { |index| want[index] != got[index] }
          at && "sprite #{at} of those drawn: #{lowered_side} has #{sprite_in_words(got[at])}, Reference #{sprite_in_words(want[at])}"
        end

        # What the side being checked against the interpreter is called: the game as C, unless the
        # checked run says otherwise.
        def lowered_side = "C"

        def heading(frame) = frame == :end ? "the end of the run" : "frame #{frame}"
        def last_frame(moments) = moments.map(&:frame).grep(Integer).max || 0

        private

        def sprite_in_words(row) = row ? "#{row.name.inspect} at (#{row.x}, #{row.y}) showing #{row.picture.inspect}" : "none"

        # Every variable the two disagree on, said as "name: C has 2, Reference 1". Both ways: a
        # variable the interpreter wrote and the lowered side never kept is a variable the lowering
        # lost track of, which comparing only what the lowered side kept would never notice.
        def variable_differences(want, got)
          unkept = (want.keys - got.keys).map { |name| "#{name}: the #{lowered_side} does not keep it" }
          wrong = got.filter_map do |name, value|
            expected = want.fetch(name, 0)
            "#{name}: #{lowered_side} has #{value}, Reference #{expected}" if expected != value
          end
          unkept + wrong
        end
      end
    end
  end
end
