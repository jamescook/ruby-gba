# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      # WHICH SPRITES A LOWERED GAME DREW, by the numbers it keeps them by.
      #
      # The interpreter says what it drew by name (Reference#sprites): whose each sprite is, under
      # the name the game declared it with, and which of its pictures it is showing, under the name
      # the author gave that picture. A lowered game keeps the same rows as numbers — the C prints
      # them (Native::DrawnSprites), a Color cartridge keeps them in a table (GBC::Places). Both
      # sides number the names here, the lowering to write the numbers in and the run to read them
      # back, which is what keeps the two in step.
      class SpriteNames
        # What stands for a name where there is none: a sprite the game named nothing for, such as
        # a letter of text, and a picture no sprite shows.
        NO_NAME = -1

        def initialize(program)
          sprites = program.walk.select { |node| node.kind == :object }.to_h { |node| [node.name, node] }.values
          @names = sprites.filter_map(&:declared).uniq
          @pictures = sprites.flat_map(&:poses).uniq
        end

        # The number kept for a sprite declared as +name+, and for one showing +picture+. A pool is
        # one name, however many of its things are drawn.
        def name_number(name) = @names.index(name) || NO_NAME
        def picture_number(picture) = @pictures.index(picture) || NO_NAME

        # The interpreter's row for a sprite kept as the numbers +name+ and +picture+, standing at
        # (+x+, +y+). A sprite may have no name; one that is drawn shows a picture.
        def row(name, picture, x, y)
          raise ArgumentError, "the game kept a sprite showing a picture no sprite has (#{picture})" if picture == NO_NAME

          Diagnostics::DrawnSprite.new(name: name == NO_NAME ? nil : @names.fetch(name), x: x, y: y,
                                       picture: @pictures.fetch(picture))
        end

        # The ones of +rows+ that are the sprite the game declared as +name+, refusing a name it
        # declared no sprite under in the interpreter's words (Reference#sprites).
        def rows_named(rows, name)
          unless @names.include?(name)
            raise ArgumentError, "This game has no sprite #{name.inspect}. " \
                                 "Its sprites are: #{@names.map(&:inspect).join(', ')}."
          end
          rows.select { |row| row.name == name }
        end
      end
    end
  end
end
