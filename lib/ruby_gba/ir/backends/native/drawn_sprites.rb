# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class Native
        # WHICH SPRITES A GAME DREW, as the C prints it and as a test reads it.
        #
        # The interpreter says what it drew by name (Reference#sprites): whose each sprite is,
        # under the name the game declared it with, and which of its pictures it is showing,
        # under the name the author gave that picture. The C prints the same rows as numbers
        # (runtime/rg_headless.c). Both sides number the names here, the lowering to write the
        # numbers in and the run to read them back, which is what keeps the two in step.
        class DrawnSprites
          # What stands for a name where there is none (RG_NO_NAME): a sprite the game named
          # nothing for, such as a letter of text, and a picture no sprite shows.
          NO_NAME = -1

          def initialize(program)
            sprites = program.walk.select { |node| node.kind == :object }.to_h { |node| [node.name, node] }.values
            @names = sprites.filter_map(&:declared).uniq
            @pictures = sprites.flat_map(&:poses).uniq
          end

          # The number the C prints for a sprite declared as +name+, and for one showing +picture+.
          # A pool is one name, however many of its things are drawn.
          def name_number(name) = @names.index(name) || NO_NAME
          def picture_number(picture) = @pictures.index(picture) || NO_NAME

          # The rows printed among +lines+, in the order they were drawn: back to front.
          def rows_in(lines) = lines.grep(/\Asprite /).map { |line| row_from(line) }

          # One printed line ("sprite" and four numbers: whose, which picture, and where) read as
          # the interpreter's row. A sprite may have no name; one that is drawn shows a picture.
          def row_from(line)
            name, picture, x, y = line.delete_prefix("sprite ").split(" ").map { |number| Integer(number) }
            if picture == NO_NAME
              raise ArgumentError, "the program printed a sprite showing a picture no sprite has: #{line}"
            end

            Diagnostics::DrawnSprite.new(name: name == NO_NAME ? nil : @names.fetch(name), x: x, y: y,
                                         picture: @pictures.fetch(picture))
          end

          # The ones of +rows+ that are the sprite the game declared as +name+, refusing a name
          # it declared no sprite under in the interpreter's words (Reference#sprites).
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
end
