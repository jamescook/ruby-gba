# frozen_string_literal: true

module RubyGBA
  module IR
    # WHAT A BUILD WORKS OUT FROM A PICTURE ALONE, kept for the next build on the same core.
    #
    # A game's test suite builds the same game many times over, a room or two at a time, and
    # nearly every one of those cartridges carries the same few hundred pictures of the hero.
    # Where each picture draws, which poses are another one turned, which colours it uses and
    # the tiles it is stored as all come out the same every time, and reading every pixel to
    # find them out was most of what a build did with its pictures. So each answer is kept
    # here, by what was asked and the picture's own contents, and a later build reads it back.
    #
    # BY CONTENTS, never by name: two games may call different art :hero, and one game may
    # give the same art two names. A picture is a value (see Assets::Image), so two that hold
    # the same pixels are the same key.
    #
    # ONE STORE PER CORE. A suite builds on several cores at once, and a store they all shared
    # would need a lock every build waited on. Each core keeps its own, so the first build on
    # each core works the answers out and the rest read them. What is kept is frozen, so a
    # caller cannot change an answer another build will be handed.
    #
    # A core that builds for a long time with ever new art would keep it all, so past
    # ENTRIES the store is emptied and starts again. Nothing depends on an answer being
    # there: one missing is worked out again, the same.
    module Remembered
      ENTRIES = 20_000

      module_function

      # The answer to +question+ about +key+ (a picture, or a picture and what else the
      # answer depends on): the one kept on this core, or the block's, kept for next time.
      def fetch(question, *key)
        store = Ractor.current[:ruby_gba_remembered] ||= {}
        asked = [question, *key]
        store.fetch(asked) do
          store.clear if store.size >= ENTRIES
          store[asked] = Ractor.make_shareable(yield)
        end
      end
    end
  end
end
