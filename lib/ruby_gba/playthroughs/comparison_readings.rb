# frozen_string_literal: true

module RubyGBA
  module Playthroughs
    class Comparison
      # THE NAMED READINGS OF A COMPARISON: things read off the two running cartridges on
      # every frame that is looked at, each under a name a person chose.
      #
      # WHAT THEY ARE FOR. Two games can show the same screen and be a long way apart
      # underneath — a position a pixel out behind a wall, a counter that will run out a
      # second early. And where the pictures do differ, "the hero is at 61 on one and 60 on
      # the other" says what went wrong where two screenshots only say that something did.
      #
      # A READING IS A NAME AND A WAY TO READ IT, and there are three ways to say the way:
      #
      #   readings: {
      #     paces:  :paces,                                             # a variable, on both
      #     where:  ->(game) { [game.var(:x), game.var(:y)] },          # one block, for both
      #     hero_x: [:px, ->(game) { game.mem16(0x0300_1234) }],        # one way for each
      #   }
      #
      # ONE WAY FOR EACH is the form that matters to somebody rebuilding a game, because the
      # two cartridges are not the same program: the rebuilt one keeps the hero's position
      # in a variable with a name, and the original keeps it at an address somebody found.
      # The reading is "the hero's position" all the same, and each side says where it is.
      #
      # A VARIABLE'S NAME only means something on a cartridge this framework built, since
      # which variable is where is what the build worked out and is kept beside a cartridge,
      # never in it. On any other cartridge it is refused, before a frame is played.
      #
      # What a block gives back can be anything two of which can be the same: a number, a
      # pair of numbers, a colour's name.
      #
      # +given+ is the readings as they were written.
      class Readings
        # A way to read that is a variable's name. It answers `call` as a block does, so
        # reading is the same whichever way was written.
        Variable = Data.define(:name) do
          def call(game) = game.var(name)
        end
        private_constant :Variable

        SIDES = %w[first second].freeze
        private_constant :SIDES

        def initialize(given)
          refuse_malformed_readings!(given)
          @ways = given.transform_values do |way|
            (way.is_a?(Array) ? way : [way, way]).map { |one| one.is_a?(Symbol) ? Variable.new(name: one) : one }
          end
        end

        def names = @ways.keys
        def any? = @ways.any?

        # A reading written as a variable's name is looked up here, on the two cartridges
        # that are about to be played: a cartridge with no record of its build, or with no
        # variable of that name, is refused now and not on the first frame.
        def refuse_unreadable_on!(cartridges)
          @ways.each do |name, ways|
            ways.zip(cartridges, SIDES).each do |way, cartridge, side|
              refuse_unknown_variable!(name, way.name, cartridge.var_addresses, side) if way.is_a?(Variable)
            end
          end
        end

        # Every reading on both of two running cartridges: each name with its pair of
        # values, the first cartridge's and the second's.
        def values_on(first, second)
          ours = values_from(first, 0)
          theirs = values_from(second, 1)
          ours.to_h { |name, value| [name, [value, theirs.fetch(name)]] }
        end

        # Every reading on one running cartridge, each name with its value. +side+ says
        # which of the two it is, 0 for the first and 1 for the second, since a reading
        # can be read its own way from each.
        def values_from(game, side)
          @ways.to_h { |name, ways| [name, value_read(name, ways.fetch(side), game, SIDES.fetch(side))] }
        end

        # The names of the readings whose two values are not the same, given the pairs
        # `values_on` hands back.
        def self.differing(values) = values.reject { |_name, (ours, theirs)| same?(ours, theirs) }.keys

        # Two values are the same when Ruby says they are equal — and when both are the
        # number that is not a number, which a block that divides nought by nought gives
        # back on both cartridges and which Ruby says is equal to nothing, itself included.
        def self.same?(ours, theirs)
          ours == theirs || [ours, theirs].all? { |value| value.is_a?(Float) && value.nan? }
        end

        private

        HOW_TO_WRITE_ONE = "A way to read is one of three things. It can be the name of a variable. It can be a block " \
                           "that is given the running cartridge. It can be a list of two of those, one for each cartridge. " \
                           "Write it like `readings: { hero_x: :px, hero_y: [:py, ->(game) { game.mem16(0x0300_1234) }] }`."
        private_constant :HOW_TO_WRITE_ONE

        # A block is somebody's own code, run against a cartridge part way through a
        # playthrough, so what goes wrong in one is said with the reading's name and the
        # cartridge it was reading — which its own error has no way to know.
        def value_read(name, way, game, side)
          way.call(game)
        rescue StandardError => e
          raise ReadingFailed, "The reading #{name.inspect} could not be read from the #{side} cartridge: #{e.message}"
        end

        def refuse_malformed_readings!(given)
          unless given.is_a?(Hash)
            raise ArgumentError, "`readings:` was #{given.inspect}. It must be names, each with a way to read it. #{HOW_TO_WRITE_ONE}"
          end
          given.each do |name, way|
            refuse_unusable_name!(name)
            next if way_to_read?(way) || (way.is_a?(Array) && way.size == 2 && way.all? { |one| way_to_read?(one) })

            raise ArgumentError, "`readings:` gives #{name.inspect} as #{way.inspect}. That is not a way to read it. #{HOW_TO_WRITE_ONE}"
          end
        end

        def way_to_read?(way) = way.is_a?(Symbol) || way.respond_to?(:call)

        def refuse_unusable_name!(name)
          unless name.is_a?(Symbol)
            raise ArgumentError, "`readings:` names a reading #{name.inspect}. A reading's name must be a symbol, like `:hero_x`."
          end
          meaning = { PICTURE => "the picture of the screen", FRAMES_APART => "how many frames apart the two cartridges are" }[name]
          return unless meaning

          raise ArgumentError, "`readings:` names a reading `#{name.inspect}`. That name means #{meaning}. " \
                               "Give the reading a different name."
        end

        # +known+ is where the cartridge's variables are, by name, or nil for a cartridge
        # this framework did not build.
        def refuse_unknown_variable!(name, variable, known, side)
          return if known&.key?(variable)

          said = "The reading #{name.inspect} reads the variable #{variable.inspect} from the #{side} cartridge."
          unless known
            raise ArgumentError, "#{said} That cartridge was not built here, so nothing says where its variables are. " \
                                 "Give the reading a block for that cartridge, which reads it from memory by its address: " \
                                 "`->(game) { game.mem16(address) }`."
          end
          own = known.keys.reject { |known_name| known_name.start_with?("_") }
          has = own.empty? ? "It has no variables." : "Its variables are #{own.map(&:inspect).join(', ')}."
          raise ArgumentError, "#{said} That cartridge has no variable of that name. #{has}"
        end
      end
    end
  end
end
