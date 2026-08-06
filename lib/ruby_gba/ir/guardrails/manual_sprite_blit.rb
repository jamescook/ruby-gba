# frozen_string_literal: true

require "set"

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # The double-drawn-sprite footgun: blitting, by hand, an image that's already
        # a sprite. A sprite draws itself every frame and remembers the pixels
        # underneath it so it leaves no trail; a hand `blit` of the same image stamps
        # a second copy that nothing ever erases, so it smears a trail — the very
        # thing the sprite was chosen to avoid. The fix is to move the sprite (its
        # x/y) rather than blit it, or to use a different image for a plain stamp.
        #
        # A sprite is recognized structurally, with no build-time bookkeeping: its
        # own draws — the one at creation and the per-frame repaint — always sit
        # beside a save/restore-region op (nothing else emits those), so those blits
        # are the framework's. Any OTHER blit of the same image is one the developer
        # wrote by hand. Advisory.
        class ManualSpriteBlit
          NAME = :manual_sprite_blit

          SPRITE_OPS = %i[save_region restore_region].freeze

          def detect(program)
            managed, framework_blits = classify_blits(program)

            program.each.filter_map do |node|
              next unless node.kind == :blit
              next unless managed.include?(node[:name])
              next if framework_blits.include?(node.object_id) # the sprite's own draw, not a hand one

              Finding.new(check: NAME, severity: :warning, message: message(node[:name]), node: node)
            end
          end

          private

          # Walk every container: a blit sitting beside a save/restore-region op is one
          # of the framework's sprite draws. Collect the images those manage, and the
          # identities of those blits, so the caller can tell a sprite's own draw from
          # a hand-written one.
          def classify_blits(program)
            managed = Set.new
            framework_blits = Set.new
            program.each do |node|
              siblings = node.children
              next unless siblings.any? { |child| SPRITE_OPS.include?(child.kind) }

              siblings.each do |child|
                next unless child.kind == :blit

                managed << child[:name]
                framework_blits << child.object_id
              end
            end
            [managed, framework_blits]
          end

          def message(name)
            "This game blits the image :#{name} by hand. But :#{name} is also a sprite. A sprite draws " \
              "itself every frame. It remembers the pixels under it, so it leaves no trail. When you also " \
              "blit it by hand, you stamp a second copy that nothing erases. So it smears a trail as it " \
              "moves. To fix this, move the sprite (change its x/y) and remove the `blit :#{name}`. Or, for " \
              "a plain stamp that does not move, give it a different image name, so it is not the sprite's image."
          end
        end
      end
    end
  end
end
