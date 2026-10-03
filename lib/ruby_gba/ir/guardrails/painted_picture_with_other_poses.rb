# frozen_string_literal: true

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # A PICTURE THE GAME PAINTS FROM A LIST IS THE WHOLE OF THE SPRITE THAT SHOWS IT.
        #
        # The console keeps such a picture in one room of sprite memory, which the game's list
        # is copied into whenever it says `changed`, and the sprite points at that room. A
        # sprite that switches between poses points at a different picture for each, laid out
        # one after another; a painted picture among them would need a room of its own inside
        # that run, and nothing lays one out there. So the mix is refused, on both backends,
        # rather than building on one and stopping on the other.
        class PaintedPictureWithOtherPoses
          NAME = :painted_picture_with_other_poses
          PLAIN_NAME = "a painted picture beside other poses"

          def detect(program)
            painted = program.walk.filter_map { |node| node.picture if node.kind == :tile_run }
            return [] if painted.empty?

            program.walk.filter_map do |node|
              next unless node.kind == :object

              poses = node.poses.uniq
              picture = poses.find { |pose| painted.include?(pose) }
              next unless picture && poses.size > 1

              Finding.new(check: NAME, severity: :error, message: message(node.declared || node.name, picture), node: node)
            end
          end

          private

          def message(sprite, picture)
            "The sprite :#{sprite} shows the picture :#{picture}, which the game paints from a list. It also " \
              "shows other pictures. A painted picture must be the only picture of its sprite. To fix this, " \
              "show :#{picture} on a sprite of its own. Then show one of the two sprites at a time."
          end
        end
      end
    end
  end
end
