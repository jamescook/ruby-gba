# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        class Lowering
          # WHETHER TWO SPRITES' DRAWN PIXELS TOUCH (`pixels_overlap`), lowered for a Super
          # Nintendo: a call into Runtime::Collide, and each picture a sprite can show made into a
          # mask of where it draws while the program is built. Mixed into Lowering.
          module Collision
            VALUES = Ractor.make_shareable({ pixels_overlap: :value_of_pixels_overlap })

            def prepare_collision
              @masks = {} # a picture's name -> its number among the masks
              @mask_lists = [] # each a list of masks' numbers, a sprite's pictures in order
            end

            # The tables Runtime::Collide reads, as sections for the Linker: where each mask is, its
            # width and height; each sprite's list of pictures; and the masks.
            def collision_sections
              tables = W65816.new("collision tables", holds: Picture::ART)
              tables.label("collision pictures")
              @masks.each_value do |number|
                tables.data_longs("collision mask #{number}")
                tables.data_bytes(0)
                image = Assets::Image.of(picture_named(@masks.key(number)))
                tables.data_words(image.width, image.height)
              end
              tables.label("collision lists")
              @mask_lists.each_index do |number|
                tables.data_longs("collision list #{number}")
                tables.data_bytes(0)
              end
              @mask_lists.each_with_index do |numbers, number|
                tables.label("collision list #{number}")
                tables.data_words(numbers.length, *numbers)
              end
              @masks.each do |name, number|
                tables.label("collision mask #{number}")
                tables.data_bytes(mask_bytes(Assets::Image.of(picture_named(name))))
              end
              [tables.section]
            end

            private

            # Reference#pixels_overlap?: 1 when they touch, 0 when they do not.
            def value_of_pixels_overlap(node)
              runtime_call("rt_pixels_overlap", [Build.int(mask_list(node.a_poses)), node.a_pose, node.a_x, node.a_y,
                                                 Build.int(mask_list(node.b_poses)), node.b_pose, node.b_x, node.b_y])
            end

            # The number of the list of masks for the pictures +poses+, made once.
            def mask_list(poses)
              numbers = poses.map { |name| @masks[name] ||= @masks.length }
              @mask_lists.index(numbers) || (@mask_lists << numbers).length - 1
            end

            # A bit for each pixel of +image+, set where it draws, eight to a byte, leftmost pixel in
            # the top bit, row by row.
            def mask_bytes(image)
              (0...image.height).flat_map do |y|
                (0...((image.width + 7) / 8)).map do |byte|
                  (0...8).sum do |bit|
                    x = (byte * 8) + bit
                    x < image.width && image.drawn_at?((y * image.width) + x) ? 0x80 >> bit : 0
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end
