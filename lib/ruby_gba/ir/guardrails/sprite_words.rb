# frozen_string_literal: true

module RubyGBA
  module IR
    module Guardrails
      # HOW THE SPRITE CHECKS NAME WHAT THEY FOUND, so every one of them names it the same way.
      #
      # A sprite the game declared is known by the name it was declared under. A pool is a
      # sprite for every instance it can hold, each with a name of the framework's own, and
      # the author declared one pool — so each of those reads as its pool.
      module SpriteWords
        module_function

        # "The sprite :ship", or "The pool :guard" for one of a pool's sprites.
        def owner_capitalized(node)
          "The #{pool?(node) ? 'pool' : 'sprite'} :#{node.declared || node.name}"
        end

        # What one of them is called: a pool's is an instance, any other is a sprite.
        def member_word(node) = pool?(node) ? "instance" : "sprite"

        # A pool's sprites carry the pool's name as the one they were declared under, and a
        # name of the framework's own.
        def pool?(node)
          kind, parts = Messages::MadeNames.read(node.name)
          kind == :pool_part && parts[:pool] == node.declared.to_s
        end
      end
    end
  end
end
