# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBC
        class Lowering
          # WHERE ON A PAINTED SCREEN EACH DRAWING CAN PAINT, and in what colours, worked out from
          # the program before any of it is lowered: what GBC::SquareColors picks each 8×8 square's
          # list of colours from. Mixed into Lowering.
          #
          # A place written in the program is a place; one worked out as the game runs can be
          # anywhere along that edge of the screen. Held to an `inside` area, a drawing reaches no
          # further than the area does.
          #
          # A sprite on a painted screen puts back the patch it covered (`restore_region`) at the
          # place it saved it from, before the scene paints, so it puts back colours that square
          # held already and needs nothing counted of its own.
          module PaintReach
            # Each kind that paints, and the method saying where it can and in what colours.
            REACH = Ractor.make_shareable({
                                            clear_screen: :clear_reach, fill_rect: :rect_reach,
                                            dma_fill_rect: :rect_reach, draw_rect_at: :rect_reach,
                                            pixel: :pixel_reach, draw_text: :text_reach,
                                            draw_digit: :digit_reach, blit: :blit_reach,
                                            blit_pose: :pose_reach, draw_column_at: :column_reach,
                                            background: :background_reach
                                          })

            private

            # The colour list each square of a painted screen names (GBC::SquareColors), from what
            # every drawing of the program can paint and where; nil for a program that paints nothing.
            #
            # Each scene's squares need what the scene paints, what runs outside every scene, and
            # what a scene it runs inside paints in the same pass. A scene that does not clear the
            # whole screen on every pass keeps the picture the scene before it left, so it needs
            # whatever any scene can leave too (SquareColors' +keeping+).
            def square_colors
              painting = @program.walk.select { |node| paints?(node) }
              return nil if painting.empty?

              held = {}.compare_by_identity # a drawing inside an area -> the area's box
              @program.walk.select { |node| node.kind == :inside }.each do |area|
                box = SquareColors::Box.new(left: area.x, top: area.y, right: area.x + area.w, bottom: area.y + area.h)
                area.walk { |node| held[node] = box unless node.equal?(area) }
              end
              painted = {}.compare_by_identity # a drawing statement -> what it paints
              painting.each { |node| painted[node] = drawings_of(node, held[node]) }
              cleared = painting.select { |node| node.kind == :clear_screen && !held[node] }
              SquareColors.new(paint_layouts.transform_values { |nodes| nodes.flat_map { |node| painted.fetch(node, []) } },
                               everywhere: cleared.map { |node| Graphics::Color.resolve(node.color) },
                               keeping: scenes_keeping_picture, most_palettes: Art::PALETTES)
            end

            def paints?(node) = REACH.key?(node.kind) && (node.kind != :background || painted_screen_for?(node))

            # The statements whose painting each scene's squares need (nil for outside every scene):
            # what runs outside every scene, the scene's own, and those of every scene it runs inside.
            def paint_layouts
              outside = statements_reached([@program, *@tick_handlers.values, *@program.walk.select { |node| node.kind == :scroll_rows }],
                                           past: @scenes.keys)
              own = @scenes.keys.to_h { |scene| [scene, statements_reached([@funcs.fetch(scene)], past: [])] }
              inside = own.transform_values { |nodes| Reach.routines_named(nodes) & @scenes.keys }
              layouts = { nil => outside }
              own.each do |scene, nodes|
                around = own.keys.select { |other| other != scene && inside.fetch(other).include?(scene) }
                layouts[scene] = outside + nodes + around.flat_map { |other| own.fetch(other) }
              end
              layouts
            end

            # The scenes that paint over the picture the scene before them left: all but those that
            # clear the whole screen on every pass, or all of them when the game loop does not.
            def scenes_keeping_picture
              loops = @program.children.select { |node| node.kind == :loop }
              return [] if loops.any? { |node| clears_every_pass?(node) }

              @scenes.keys.reject { |scene| clears_every_pass?(@funcs.fetch(scene)) }
            end

            def clears_every_pass?(routine) = routine.children.any? { |node| node.kind == :clear_screen }

            # The statements a run can reach from +roots+ and every routine they call, however deep,
            # except the routines named in +past+.
            def statements_reached(roots, past:)
              statements = Reach.statements_from(*roots)
              reached = []
              waiting = Reach.routines_named(statements)
              until waiting.empty?
                name = waiting.shift
                next if reached.include?(name) || past.include?(name) || !@funcs.key?(name)

                reached << name
                more = Reach.statements_under(@funcs.fetch(name))
                statements.concat(more)
                waiting.concat(Reach.routines_named(more))
              end
              statements
            end

            # What +node+ paints, as drawings, held to the box of +area+ when it is inside one.
            def drawings_of(node, area)
              send(REACH.fetch(node.kind), node).map do |colors, box|
                SquareColors::Drawing.new(colors: colors.map { |color| Graphics::Color.resolve(color) },
                                          box: area ? box.held_to(area) : box, source: node.source)
              end
            end

            # Each of these is [[colours, box], ...]: the box of the screen the drawing can reach.
            def clear_reach(node)
              left, top, right, bottom = Runtime::Paint::WHOLE_SCREEN
              [[[node.color], SquareColors::Box.new(left: left, top: top, right: right, bottom: bottom)]]
            end

            def rect_reach(node) = [[[node.color], reach_box(node.x, node.y, node.w, node.h)]]
            def pixel_reach(node) = [[[node.color], reach_box(node.x, node.y, 1, 1)]]

            def text_reach(node)
              letters_reach([node.color, node.picked].compact, node.x, node.y, node.fonts.get(node.font), node.text)
            end

            def digit_reach(node)
              (0..9).flat_map { |d| letters_reach([node.color], node.x, node.y, node.fonts.get(node.font), d.to_s) }
            end

            def blit_reach(node) = [picture_reach(node.name, node.x, node.y)]
            def pose_reach(node) = node.poses.map { |name| picture_reach(name, node.x, node.y) }

            def column_reach(node)
              [[picture_named(node.name).colors_drawn, reach_box(node.x, node.top, node.width || 1, node.height)]]
            end

            # A background painted into the picture paints each cell's tile where the cell is.
            def background_reach(bg)
              bg.map.each_with_index.flat_map do |row, r|
                Array(row).each_with_index.filter_map do |tile, c|
                  next if tile.nil? || tile.negative?

                  image = Assets::Image.of(@pictures.fetch(bg.tiles.fetch(tile)))
                  colors = (image.width * image.height).times.reject { |at| image.tile_see_through_at?(at) }
                                                       .map { |at| image.color_at(at) }.uniq
                  x = c * bg.tile_w
                  y = r * bg.tile_h
                  [colors, SquareColors::Box.new(left: x, top: y, right: x + bg.tile_w, bottom: y + bg.tile_h)] unless colors.empty?
                end
              end
            end

            def reach_box(x, y, width, height)
              left, right = reach_span(x, width, Console::GBCHardware::SCREEN_WIDTH)
              top, bottom = reach_span(y, height, Console::GBCHardware::SCREEN_HEIGHT)
              SquareColors::Box.new(left: left, top: top, right: right, bottom: bottom)
            end

            # From +start+ to past +length+ along an edge +limit+ long, as far as is known.
            def reach_span(start, length, limit)
              from = folded(start)
              return [0, limit] unless from

              long = folded(length)
              long ? [from, from + long] : [from, limit]
            end

            def letters_reach(colors, x, y, font, text)
              points = font.enum_for(:each_pixel, text).to_a
              return [] if points.empty?

              xs = points.map(&:first)
              ys = points.map(&:last)
              left, right = reach_span(moved(x, xs.min), xs.max - xs.min + 1, Console::GBCHardware::SCREEN_WIDTH)
              top, bottom = reach_span(moved(y, ys.min), ys.max - ys.min + 1, Console::GBCHardware::SCREEN_HEIGHT)
              [[colors, SquareColors::Box.new(left: left, top: top, right: right, bottom: bottom)]]
            end

            def picture_reach(name, x, y)
              image = picture_named(name)
              [image.colors_drawn, reach_box(x, y, image.width, image.height)]
            end

            # Each 8×8 square of a painted Color screen holds four colours, and the screen eight lists
            # of them (GBC::SquareColors), so a program whose painting does not fit is refused, naming
            # the square or the colours.
            def refuse_unfit_paint_squares!
              raise LoweringError, @square_colors.refusal if @square_colors&.refusal
            end
          end
        end
      end
    end
  end
end
