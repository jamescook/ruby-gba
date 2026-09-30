# frozen_string_literal: true

module RubyGBA
  module DSL
    # What `random_numbers` hands back: the game's stream of random numbers, as a thing a
    # save_data record can keep — `keep hearts, random_numbers`. Kept, a save holds where the
    # stream had got to, and a load puts it back, so a game loaded mid-level rolls exactly
    # what it would have rolled from there.
    #
    # It is nothing else a game can use: the stream is still read through `rand`, `roll` and
    # `chance`, and moved with `seed` and `randomize`. There is one stream in a game, so this
    # is always the same one.
    class RandomNumbers
      # The variable the stream's state is kept in.
      attr_reader :name

      def initialize(name)
        @name = name
      end

      def inspect = "the random numbers"
    end
  end
end
