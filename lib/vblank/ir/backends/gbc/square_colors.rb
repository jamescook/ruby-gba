# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBC
        # THE COLOURS OF EACH SQUARE OF A PAINTED SCREEN, worked out while the game is built.
        #
        # A painted screen on a Game Boy Color is 360 tiles, an 8×8 square each (Runtime::Paint), and
        # a tile's pixels are two bits: each is one of four places in the list of colours its square
        # of the grid names, one of the background's eight. So a screen can show as many colours as
        # eight lists of four hold, as long as no square needs more than four.
        #
        # Which list each square names is decided here, once for each scene, and never while the game
        # runs — the way a Color cartridge's artist gave each tile of the art its palette. Every
        # drawing the game can paint says what colours it paints and the box of the screen it can
        # reach (Lowering::PaintReach). A square then needs every colour that can reach it in that
        # scene, and black, the colour the screen starts in. Squares that need the same colours, or
        # colours that fit in one list together, share a list, in any scene.
        #
        # A scene that does not clear the screen keeps the picture the scene before it left, so its
        # squares need what any scene can leave in them as well as what it paints itself: the
        # square it paints into is sent again in its own list, and the pixels left in the square
        # have to be in that list too.
        #
        # Painting takes one place for a colour wherever it lands (Runtime::Paint paints a place,
        # not a colour), so a colour keeps the same place in every list that holds it. That is also
        # what lets a scene arrive without a square being put wrong for a moment: a tile the new
        # scene has not painted yet keeps the list it was painted in, and a tile it paints is sent
        # in the new scene's list, which holds every colour left in it. Black is at place 0, as the
        # black tile past the screen's edges is drawn in. A colour the whole screen is cleared to is
        # in every list, since a square not painted again shows it whichever list it names.
        #
        # What cannot fit is refused, naming the square, its colours and the drawings that paint
        # there: a square that can need five, a screen that needs more than eight lists, or colours
        # that cannot each keep one place.
        class SquareColors
          COLUMNS = Runtime::Paint::COLUMNS
          ROWS = Runtime::Paint::ROWS
          SIDE = 8
          WIDTH = Console::GBCHardware::SCREEN_WIDTH
          HEIGHT = Console::GBCHardware::SCREEN_HEIGHT
          BLACK = 0

          # A box of the screen, from its left and top up to but not including its right and bottom.
          Box = Data.define(:left, :top, :right, :bottom) do
            def held_to(area)
              with(left: [left, area.left].max, top: [top, area.top].max, right: [right, area.right].min,
                   bottom: [bottom, area.bottom].min)
            end

            # The squares it covers on the screen, by number, row by row.
            def cells
              l, r = [left, right].map { |edge| edge.clamp(0, WIDTH) }
              t, b = [top, bottom].map { |edge| edge.clamp(0, HEIGHT) }
              return [] if l >= r || t >= b

              ((t / SIDE)..((b - 1) / SIDE)).flat_map do |row|
                ((l / SIDE)..((r - 1) / SIDE)).map { |column| (row * COLUMNS) + column }
              end
            end
          end

          # What one drawing can paint: its colours (15-bit), the box of the screen it can reach, and
          # the line of the game that draws it.
          Drawing = Data.define(:colors, :box, :source)

          # The lists, each four colours by place; and the maps of the screen, each the list each of
          # its 360 squares names, row by row — the first the map of what runs outside every scene,
          # and one more for each scene whose squares need another.
          attr_reader :palettes, :maps

          # The plain words saying why these drawings do not fit, or nil when they do.
          attr_reader :refusal

          # +layouts+ are each scene's drawings by its name, what runs outside every scene's first
          # under nil; +everywhere+ the colours every square needs, black among them; +keeping+ the
          # scenes that keep the picture the scene before them left.
          def initialize(layouts, everywhere:, keeping:, most_palettes:)
            @layouts = layouts
            @keeping = keeping
            @colors = layouts.values.flatten.flat_map(&:colors).map { |color| rgb(color) }.uniq
            everywhere = [BLACK, *everywhere.map { |color| rgb(color) }].uniq
            @needs = layouts.transform_values do |drawings|
              needs = Array.new(COLUMNS * ROWS) { everywhere.dup }
              drawings.each { |drawing| drawing.box.cells.each { |cell| needs[cell].concat(drawing.colors.map { |color| rgb(color) }) } }
              needs
            end
            add_kept_pictures
            @needs.transform_values! { |needs| needs.map { |colors| colors.uniq.sort_by { |color| [color == BLACK ? 0 : 1, color] } } }
            @refusal = crowded_square_message || lay_out_palettes(most_palettes)
          end

          # A colour painted only past the screen's edges paints nothing, so any place will do.
          def place(color)
            @places.fetch(rgb(color)) do
              raise LoweringError, "the colour #{color} is not among the painted ones" unless @colors.include?(rgb(color))

              0
            end
          end

          # The map scene +name+ shows (nil for outside every scene), by its number among #maps.
          def map_of(name) = @map_numbers.fetch(name)

          private

          def rgb(color) = color & 0x7FFF

          # A scene by the name the game gave it.
          def scene_name(scene) = Modes.strip_scene_prefix(scene).to_sym.inspect

          # A scene that keeps the picture before it needs whatever any scene can leave in each
          # square, and what that scene kept too, until nothing more is added.
          def add_kept_pictures
            loop do
              grown = false
              @keeping.each do |scene|
                @needs.each do |other, needs|
                  next if other == scene

                  @needs.fetch(scene).each_with_index do |colors, cell|
                    more = needs[cell] - colors
                    next if more.empty?

                    colors.concat(more)
                    grown = true
                  end
                end
              end
              break unless grown
            end
          end

          def crowded_square_message
            @needs.each do |scene, needs|
              cell = needs.index { |colors| colors.length > Art::PLACES }
              next unless cell

              row, column = cell.divmod(COLUMNS)
              x = column * SIDE
              y = row * SIDE
              colors = needs.fetch(cell)
              where = scene ? " in the scene #{scene_name(scene)}" : ""
              kept = @keeping.include?(scene) ? " The scene #{scene_name(scene)} does not clear the screen, so it keeps what the scene before it painted there." : ""
              return "the square of the screen from (#{x}, #{y}) to (#{x + SIDE - 1}, #{y + SIDE - 1})#{where} can get " \
                     "#{colors.length} colours: #{named(colors)}. A Game Boy Color holds #{Art::PLACES} colours in " \
                     "each 8×8 square of its screen, black among them.#{kept}#{drawings_there(cell)} If a game " \
                     "paints a colour at a place that it calculates as it runs, that colour can be in every square. " \
                     "To fix this, paint fewer colours in that square and near it."
            end
            nil
          end

          # The lines of the game whose drawings can paint square +cell+, in any scene.
          def drawings_there(cell)
            sources = @layouts.values.flatten.select { |drawing| drawing.box.cells.include?(cell) }.filter_map(&:source).uniq
            sources.empty? ? "" : " These lines paint there: #{sources.first(6).join(', ')}."
          end

          # The squares' needs gathered into lists that hold four each, a place for every colour that
          # is the same in each list it is in, and each scene's map of lists. Nil when that fits, the
          # refusal when it does not.
          def lay_out_palettes(most)
            groups = palette_groups
            return too_many_sets_message(groups.length, most) if groups.length > most

            @places = colour_places(groups)
            return clashing_places_message(groups) unless @places

            @palettes = groups.map do |group|
              Array.new(Art::PLACES, Art::BACKDROP).tap { |palette| group.each { |color| palette[@places.fetch(color)] = color } }
            end
            by_scene = @needs.transform_values do |needs|
              needs.map { |colors| groups.index { |group| (colors - group).empty? } }
            end
            @maps = by_scene.values.uniq
            @map_numbers = by_scene.transform_values { |map| @maps.index(map) }
            nil
          end

          # The sets of colours the squares need, the largest first and otherwise in the order the
          # scenes and their squares come, each put in the list it grows least, or a list of its own.
          def palette_groups
            groups = []
            @needs.values.flatten(1).uniq.each_with_index.sort_by { |colors, at| [-colors.length, at] }.each do |colors, _at|
              fits = groups.select { |group| (group | colors).length <= Art::PLACES }
              best = fits.min_by { |group| (group | colors).length - group.length }
              best ? best.replace(best | colors) : groups << colors.dup
            end
            groups
          end

          def too_many_sets_message(sets, most)
            "this game paints its screen in #{sets} different sets of colours, and a Game Boy Color holds #{most} " \
              "sets. Each set is four colours that share an 8×8 square somewhere on the screen. To fix this, " \
              "paint fewer colours, or paint the same colours next to each other in more places."
          end

          def clashing_places_message(groups)
            "a painted Game Boy Color screen keeps each colour at one place in every set of colours. These " \
              "colours do not fit that way: #{named(groups.flatten.uniq)}. To fix this, paint fewer colours."
          end

          # A place for each colour, black's 0, so that no two colours of one list share one: the
          # colours most often together placed first, each given the first place free of the colours
          # it shares a list with, and taken back when a later one finds none.
          def colour_places(groups)
            colors = groups.flatten.uniq
            beside = colors.to_h { |color| [color, groups.select { |group| group.include?(color) }.flatten.uniq - [color]] }
            order = [BLACK, *(colors - [BLACK]).sort_by { |color| -beside.fetch(color).length }]
            places_searched(order, beside, { BLACK => 0 })
          end

          def places_searched(order, beside, places)
            color = order.find { |each| !places.key?(each) }
            return places unless color

            taken = beside.fetch(color).filter_map { |other| places[other] }
            (0...Art::PLACES).each do |at|
              next if taken.include?(at)

              found = places_searched(order, beside, places.merge(color => at))
              return found if found
            end
            nil
          end

          def named(colors)
            colors.map do |value|
              name = Graphics::Color.name_for(value)
              name.is_a?(Symbol) ? name.inspect : name
            end.join(", ")
          end
        end
      end
    end
  end
end
