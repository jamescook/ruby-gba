# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        class Lowering
          # A PAINTED SCREEN, lowered for a Super Nintendo: each drawing statement a call into
          # Runtime::Paint, and what it paints — its colours, its pictures, its text — made into
          # SNES::PaintedArt while the program is built. Mixed into Lowering.
          #
          # Text and digits are pictures too: the words of a `draw_text` are known when the game is
          # built, so they are drawn once, here, in their font and colour, and painted at run time as
          # any picture is. A digit is one of ten such pictures, picked by the number; text in a
          # colour picked as the game runs is one of two.
          module Paint
            STATEMENTS = Ractor.make_shareable({
                                                 clear_screen: :emit_clear_screen, fill_rect: :emit_fill_rect,
                                                 dma_fill_rect: :emit_fill_rect, draw_rect_at: :emit_fill_rect,
                                                 pixel: :emit_pixel, inside: :emit_inside, blit: :emit_blit,
                                                 blit_pose: :emit_blit_pose, draw_text: :emit_draw_text,
                                                 draw_digit: :emit_draw_digit, save_region: :emit_save_region,
                                                 restore_region: :emit_restore_region, camera: :emit_camera
                                               })

            # The kinds that paint, which make a screen painted when the game names none. The camera
            # only moves the view over what was painted.
            PAINTING = (STATEMENTS.keys - [:camera]).freeze

            # Whether +program+'s screen is painted: it says `screen :bitmap`, or it says no screen and
            # paints. A program can have only one kind (see #refuse_unmade_picture!).
            def self.painted?(program)
              modes = program.walk.select { |node| node.kind == :screen }.map(&:mode).uniq
              return modes.include?(:bitmap) unless modes.empty?

              program.walk.any? { |node| PAINTING.include?(node.kind) }
            end

            # The SNES::PaintedArt the game paints with.
            attr_reader :painted_art

            def prepare_paint
              @painted = Paint.painted?(@program)
              @painted_art = PaintedArt.new
              @picture_lists = [] # each a list of SNES::PaintedArt pictures' numbers
              @patches = {} # a backing buffer's name -> [its place, its width, its height]
            end

            def painted? = @painted

            # Every backing buffer — the patch of the screen under a sprite on a painted screen — given
            # its room in work RAM.
            def reserve_patches
              @program.walk.select { |node| node.kind == :backing_buffer }.each do |node|
                bytes = Runtime::Paint.patch_bytes(node.width, node.height)
                place = @memory.reserve_far("the patch under #{node.name.inspect}", bytes)
                @patches[node.name] = [place, node.width, node.height]
              end
            end

            # The tables Runtime::Paint reads, as sections for the Linker: the colours, every picture
            # and its rows, and the lists of pictures.
            def paint_sections
              tables = W65816.new("paint tables", holds: Picture::ART)
              tables.label("art colors")
              tables.data_bytes(@painted_art.cgram.bytes)
              tables.label("paint pictures")
              @painted_art.pictures.each do |picture|
                tables.data_longs("paint rows #{picture.number}")
                tables.data_bytes(0)
                tables.data_words(picture.across, picture.height)
              end
              tables.label("paint picture lists")
              @picture_lists.each_index do |number|
                tables.data_longs("paint picture list #{number}")
                tables.data_bytes(0)
              end
              @picture_lists.each_with_index do |numbers, number|
                tables.label("paint picture list #{number}")
                tables.data_words(numbers.length, *numbers)
              end
              @painted_art.pictures.each do |picture|
                tables.label("paint rows #{picture.number}")
                picture.height.times do |row|
                  tables.data_longs("paint row #{picture.number}.#{row}")
                  tables.data_bytes(0)
                end
              end
              [tables.section, *picture_row_sections]
            end

            # The most bytes of pictures' rows in one section: well inside a bank of the cartridge.
            ROWS_A_SECTION = 0x6000

            private

            # Each picture's rows, as many to a section as fit.
            def picture_row_sections
              sections = []
              asm = nil
              bytes = 0
              @painted_art.pictures.each do |picture|
                picture.rows.each_with_index do |row, number|
                  if asm.nil? || bytes + row.bytesize > ROWS_A_SECTION
                    sections << asm.section if asm
                    asm = W65816.new("paint rows #{sections.length}", holds: Picture::ART)
                    bytes = 0
                  end
                  asm.label("paint row #{picture.number}.#{number}")
                  asm.data_bytes(row.bytes)
                  bytes += row.bytesize
                end
              end
              sections << asm.section if asm
              sections
            end

            def value_node(operand) = operand.is_a?(Integer) ? Build.int(operand) : operand

            def place_of_color(color) = @painted_art.place_of(Graphics::Color.resolve(color))

            # Reference#exec_clear_screen.
            def emit_clear_screen(node)
              runtime_call("rt_paint_clear", [Build.int(place_of_color(node.color))])
            end

            # Reference#exec_fill_rect, #exec_dma_fill_rect and #exec_draw_rect_at: the same rectangle.
            def emit_fill_rect(node)
              runtime_call("rt_paint_fill", [*%i[x y w h].map { |edge| value_node(node.public_send(edge)) },
                                             Build.int(place_of_color(node.color))])
            end

            # Reference#exec_pixel: a rectangle one pixel square.
            def emit_pixel(node)
              runtime_call("rt_paint_fill", [value_node(node.x), value_node(node.y), Build.int(1), Build.int(1),
                                             Build.int(place_of_color(node.color))])
            end

            # Reference#exec_inside: painting held to the rectangle while the children run, and the
            # area there was before given back after, from the stack — so an `inside` in a routine
            # called from inside another's hands the caller's area back.
            def emit_inside(node)
              area = @memory[Runtime::Paint::AREA]
              4.times do |i|
                @asm.lda(@asm.abs(area + (i * 2)))
                @asm.pha
              end
              runtime_call("rt_paint_area", %i[x y w h].map { |edge| value_node(node.public_send(edge)) })
              emit_children(node)
              3.downto(0) do |i|
                @asm.pla
                @asm.sta(@asm.abs(area + (i * 2)))
              end
            end

            # Reference#exec_blit.
            def emit_blit(node)
              runtime_call("rt_paint_blit", [Build.int(picture_number(node.name)), value_node(node.x), value_node(node.y)])
            end

            # Reference#exec_blit_pose: one of the poses, by the number the game works out.
            def emit_blit_pose(node)
              list = picture_list(node.poses.map { |name| picture_number(name) })
              runtime_call("rt_paint_blit_one_of", [Build.int(list), node.index, value_node(node.x), value_node(node.y)])
            end

            # Reference#exec_draw_text: the words as a picture in their colour — or, with a colour
            # picked while the game runs, one of two pictures, the picked one when +showing+ is not
            # nought.
            def emit_draw_text(node)
              shown = text_picture(node.text, node.font, node.fonts, node.color)
              unless node.picked
                return runtime_call("rt_paint_blit", [Build.int(shown), value_node(node.x), value_node(node.y)])
              end

              picked = text_picture(node.text, node.font, node.fonts, node.picked)
              runtime_call("rt_paint_blit_one_of", [Build.int(picture_list([shown, picked])),
                                                    Build.binop(:!=, value_node(node.showing), Build.int(0)),
                                                    value_node(node.x), value_node(node.y)])
            end

            # Reference#exec_draw_digit: one of the ten digits' pictures; a number outside 0 to 9 none.
            def emit_draw_digit(node)
              digits = (0..9).map { |digit| text_picture(digit.to_s, node.font, node.fonts, node.color) }
              runtime_call("rt_paint_blit_one_of", [Build.int(picture_list(digits)), node.value,
                                                    value_node(node.x), value_node(node.y)])
            end

            # Reference#exec_camera: the view moved over the painted picture (Runtime::Paint's
            # rt_paint_camera). A tiled screen's view moves with its background's scroll instead, as
            # on the Advance.
            def emit_camera(node)
              raise LoweringError, CAMERA_ON_TILES unless painted?

              runtime_call("rt_paint_camera", [value_node(node.x), value_node(node.y)])
            end

            CAMERA_ON_TILES = "This game moves the camera on a tiled screen. The camera moves a painted " \
                              "(bitmap) screen only. To move a tiled background, use `scroll_to` or " \
                              "`scroll_by` on the background."

            # Reference#exec_save_region and #exec_restore_region.
            def emit_save_region(node) = emit_patch("rt_paint_save", node)
            def emit_restore_region(node) = emit_patch("rt_paint_restore", node)

            def emit_patch(routine, node)
              place, width, height = @patches.fetch(node.buffer) do
                raise LoweringError, "the backing buffer #{node.buffer.inspect} is used and never declared"
              end
              runtime_call(routine, [Build.int(place), value_node(node.x), value_node(node.y), Build.int(width),
                                     Build.int(height)])
            end

            # The number of the picture +name+ declares, made into SNES::PaintedArt's form.
            def picture_number(name)
              @painted_art.picture([:image, name]) do
                image = Assets::Image.of(picture_named(name))
                drawn = {}
                (image.width * image.height).times do |at|
                  drawn[[at % image.width, at / image.width]] = image.color_at(at) if image.drawn_at?(at)
                end
                [image.width, image.height, drawn]
              end.number
            end

            # The number of the picture of +text+ in +font+ and +color+.
            def text_picture(text, font, fonts, color)
              resolved = Graphics::Color.resolve(color)
              @painted_art.picture([:text, text, font, resolved]) do
                drawn = {}
                fonts.get(font).each_pixel(text) { |x, y| drawn[[x, y]] = resolved }
                width = (drawn.keys.map(&:first).max || 0) + 1
                height = (drawn.keys.map(&:last).max || 0) + 1
                [width, height, drawn]
              end.number
            end

            # The number of the list of pictures +numbers+, made once.
            def picture_list(numbers)
              @picture_lists.index(numbers) || (@picture_lists << numbers).length - 1
            end
          end
        end
      end
    end
  end
end
