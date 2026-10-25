# frozen_string_literal: true

module RubyGBA
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
        # reach: a rectangle at a place written in the program reaches the squares under it, one
        # whose place is worked out as the game runs can reach any square. A square then needs every
        # colour that can reach it in that scene, what runs outside every scene included, and black,
        # the colour the screen starts in. Squares that need the same colours, or colours that fit
        # in one list together, share a list, in any scene.
        #
        # Painting takes one place for a colour wherever it lands (Runtime::Paint paints a place,
        # not a colour), so a colour keeps the same place in every list that holds it. That is
        # also what lets a scene arrive without a square being put wrong for a moment: a tile left
        # as the scene before painted it shows the same colours from either scene's list, since both
        # hold them at the same places. Black is at place 0, as the black tile past the screen's
        # edges is drawn in. A colour the whole screen is cleared to is in every list, since a square
        # not painted again shows it whichever list it names.
        #
        # What cannot fit is refused, naming the square and its colours: a square that can need five,
        # or a screen that needs more than eight lists.
        class SquareColors
          COLUMNS = 20
          ROWS = 18
          SIDE = 8
          WIDTH = COLUMNS * SIDE
          HEIGHT = ROWS * SIDE
          BLACK = 0

          # What one drawing can paint: its colours (15-bit), and the box of the screen it can reach,
          # left, top, right and bottom with the right and bottom past it.
          Drawing = Data.define(:colors, :box)

          # The lists, each four colours by place; and the maps of the screen, each the list each of
          # its 360 squares names, row by row — the first the map of what runs outside every scene,
          # and one more for each scene whose squares need another.
          attr_reader :palettes, :maps

          # The plain words saying why these drawings do not fit, or nil when they do.
          attr_reader :refusal

          # +layouts+ are each scene's drawings by its name, what runs outside every scene's first
          # under nil; +everywhere+ the colours every square needs, black among them.
          def initialize(layouts, everywhere:, most_palettes:)
            @colors = layouts.values.flatten.flat_map(&:colors).map { |color| color & 0x7FFF }.uniq
            everywhere = [BLACK, *everywhere.map { |color| color & 0x7FFF }].uniq
            @needs = layouts.transform_values do |drawings|
              needs = Array.new(COLUMNS * ROWS) { everywhere.dup }
              drawings.each { |drawing| add(needs, drawing) }
              needs.map { |colors| colors.uniq.sort_by { |color| [color == BLACK ? 0 : 1, color] } }
            end
            @refusal = crowded_square_refusal || grouped(most_palettes)
          end

          # A colour painted only past the screen's edges paints nothing, so any place will do.
          def place(color)
            @places.fetch(color & 0x7FFF) do
              raise LoweringError, "the colour #{color} is not among the painted ones" unless @colors.include?(color & 0x7FFF)

              0
            end
          end

          # The map scene +name+ shows (nil for outside every scene), by its number among #maps.
          def map_of(name) = @map_numbers.fetch(name)

          private

          def add(needs, drawing)
            left, top, right, bottom = drawing.box
            left = left.clamp(0, WIDTH)
            right = right.clamp(0, WIDTH)
            top = top.clamp(0, HEIGHT)
            bottom = bottom.clamp(0, HEIGHT)
            return if left >= right || top >= bottom

            colors = drawing.colors.map { |color| color & 0x7FFF }
            ((top / SIDE)..((bottom - 1) / SIDE)).each do |row|
              ((left / SIDE)..((right - 1) / SIDE)).each { |column| needs[(row * COLUMNS) + column].concat(colors) }
            end
          end

          def crowded_square_refusal
            @needs.each do |scene, needs|
              cell = needs.index { |colors| colors.length > Art::PLACES }
              next unless cell

              row, column = cell.divmod(COLUMNS)
              x = column * SIDE
              y = row * SIDE
              colors = needs.fetch(cell)
              where = scene ? " in the scene #{scene.inspect}" : ""
              return "the square of the screen from (#{x}, #{y}) to (#{x + SIDE - 1}, #{y + SIDE - 1})#{where} can get " \
                     "#{colors.length} colours: #{named(colors)}. A Game Boy Color holds #{Art::PLACES} colours in " \
                     "each 8×8 square of its screen, black among them. If a game paints a colour at a place that it " \
                     "calculates as it runs, that colour can be in every square. To fix this, paint fewer colours in " \
                     "that square and near it."
            end
            nil
          end

          # The squares' needs gathered into lists that hold four each, and a place for every colour
          # that is the same in each list it is in. Nil when that fits, the refusal when it does not.
          def grouped(most)
            groups = []
            @needs.values.flatten(1).uniq.sort_by { |colors| -colors.length }.each do |colors|
              fits = groups.select { |group| (group | colors).length <= Art::PLACES }
              best = fits.min_by { |group| (group | colors).length - group.length }
              best ? best.replace(best | colors) : groups << colors.dup
            end
            if groups.length > most
              return "this game paints its screen in #{groups.length} different sets of colours, and a Game Boy Color " \
                     "holds #{most} sets. To fix this, put the same colours together in more squares."
            end

            @places = places_for(groups)
            return "a painted Game Boy Color screen keeps each colour at one place in every set of colours. These " \
                   "colours do not fit that way: #{named(groups.flatten.uniq)}. To fix this, paint fewer colours." unless @places

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

          # A place for each colour, black's 0, so that no two colours of one list share one: the
          # colours most often together placed first, each given the first place free of the colours
          # it shares a list with, and taken back when a later one finds none.
          def places_for(groups)
            colors = groups.flatten.uniq
            beside = colors.to_h { |color| [color, groups.select { |group| group.include?(color) }.flatten.uniq - [color]] }
            order = [BLACK, *(colors - [BLACK]).sort_by { |color| -beside.fetch(color).length }]
            placed(order, beside, { BLACK => 0 })
          end

          def placed(order, beside, places)
            color = order.find { |each| !places.key?(each) }
            return places unless color

            taken = beside.fetch(color).filter_map { |other| places[other] }
            (0...Art::PLACES).each do |at|
              next if taken.include?(at)

              found = placed(order, beside, places.merge(color => at))
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
