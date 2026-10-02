# frozen_string_literal: true

module RubyGBA
  module DSL
    # WHAT A LIST OF SCORES PICKED BY NAME OR NUMBER HAS IN COMMON — the songs `songs` gives back and
    # the sound effects `sound_effects` does: how many there are, and a name or a written number
    # turned into a place in the list, with a friendly error for one the list does not have. A
    # number the game works out passes through untouched, for the player to check as it runs.
    #
    # The class including it says what one entry is called (#entry_noun), for the errors.
    module ScoreList
      def initialize(builder, name, keys)
        @builder = builder
        @name = name
        @keys = keys
      end

      attr_reader :name

      # How many the list holds.
      def count = @keys.length

      # The number of an entry the list was given by name (a Hash of Scores).
      def number_of(key)
        at = @keys.index(key)
        return at if at

        raise ArgumentError, "The #{entry_noun} list :#{@name} has no #{entry_noun} #{key.inspect}. " \
                             "It has #{@keys.map(&:inspect).join(', ')}."
      end

      private

      def entry_number(which)
        case which
        when Symbol then number_of(which)
        when Integer
          return which if which.between?(0, count - 1)

          raise ArgumentError, "The #{entry_noun} list :#{@name} has #{count} #{count == 1 ? entry_noun : "#{entry_noun}s"}, " \
                               "so it has no #{entry_noun} #{which}. The #{entry_noun}s are numbered from 0 to #{count - 1}."
        else which
        end
      end
    end
  end
end
