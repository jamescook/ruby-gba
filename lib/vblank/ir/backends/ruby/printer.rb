# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Ruby
        # Turns the statement tree the lowering builds into Ruby: the body of the game's class.
        # The only place in the backend that writes Ruby.
        #
        # The tree has no operators in it — every number a game keeps goes through a runtime
        # function (runtime/rg_int32.rb) — so nothing here has to know Ruby's precedence. What it
        # does have to know:
        #
        # - A CONDITION IS A NUMBER, nought or not. In Ruby only nil and false are false, so a
        #   condition is written as a comparison with nought: `if rg_lt(a, b) != 0`, never
        #   `if rg_lt(a, b)`, which would always be taken.
        # - WHERE A NAME LIVES. Everything the game keeps — its variables, lists, tables, the
        #   arrays of routines it calls by number, the art the runtime reads — is an instance
        #   variable of the game, set in rg_game_setup; a routine's own locals are Ruby locals.
        # - A ROUTINE IS A METHOD, called by name, and one picked from an array by number is
        #   called with __send__.
        class Printer
          C = Native::C
          INDENT = "  "

          # The most numbers a table is written out as; a bigger one is written as base64.
          MOST_WRITTEN_AS_NUMBERS = 256

          # How each C type a table is kept in packs its numbers into bytes, for a big table
          # written as base64: little-endian, the width the type holds.
          PACKING = Ractor.make_shareable({ "int8_t" => "c*", "uint8_t" => "C*", "char" => "C*",
                                            "int16_t" => "s<*", "uint16_t" => "S<*", "int32_t" => "l<*" })

          # Every function the printed code calls by name, so the build can say which of them the
          # runtime does not have (Lowering#runtime_gaps).
          attr_reader :called

          def initialize
            @out = +""
            @setup = []
            @called = Set.new
          end

          # The body of the game's class: rg_game_setup, which gives every instance variable its
          # starting value, and then a method for every routine. +items+ is the top level.
          def print_file(items)
            @lists = items.grep(C::ListStorage).to_set { |list| list.name.text }
            routines = +""
            @out = routines
            items.each { |item| print_top(item) }
            @out = +""
            line(0, "def rg_game_setup")
            @setup.each { |text| @out << text }
            line(0, "end")
            line(0, "")
            @out << routines
          end

          private

          # --- the top level ---

          def print_top(item)
            case item
            when C::Include, C::Prototype then nil # a method is found wherever it is defined
            when C::Global then add_starting_value("@#{item.name.text} = #{integer(item.value)}")
            when C::ConstArray then print_const_array(item)
            when C::Function then print_function(item)
            when C::FunctionTable then add_starting_value("@#{item.name.text} = [#{item.functions.map { |name| ":#{name.text}" }.join(', ')}].freeze")
            when C::ListStorage then add_starting_value("@#{item.name.text} = RgList.new(#{integer(item.capacity)}, #{integer(item.width)}, #{string(item.label)})")
            when C::Comment then nil # the tree's own heading; the file has Ruby::WRITTEN_BY
            else raise LoweringError, "the printer has no top-level form for #{item.class}"
            end
          end

          def add_starting_value(text) = @setup << "#{INDENT}#{text}\n"

          def print_function(item)
            @locals = Set.new
            line(0, "def #{item.name.text}")
            statements(1, item.body)
            line(0, "end")
            line(0, "")
          end

          # A small table is its numbers, sixteen a line. A big one is its bytes in base64, read
          # back when the game starts, which keeps a picture of thousands of pixels to a few lines.
          def print_const_array(item)
            values = item.values.map { |value| integer(value) }
            name = "@#{item.name.text}"
            if values.size > MOST_WRITTEN_AS_NUMBERS
              packing = PACKING.fetch(item.type) { raise LoweringError, "the printer has no packing for C's #{item.type}" }
              bytes = [item.values.pack(packing)].pack("m0")
              add_starting_value("#{name} = #{string(bytes)}.unpack1(\"m\").unpack(#{string(packing)}).freeze")
            elsif values.empty?
              add_starting_value("#{name} = [0].freeze")
            else
              rows = values.each_slice(16).map { |row| "#{INDENT * 2}#{row.join(', ')},\n" }.join
              @setup << "#{INDENT}#{name} = [\n#{rows}#{INDENT}].freeze\n"
            end
          end

          # --- statements ---

          def statements(depth, list)
            list.each { |statement| statement(depth, statement) }
          end

          def statement(depth, item)
            case item
            when C::Eval then line(depth, expression(item.call))
            when C::Assign then line(depth, "#{expression(item.target)} = #{expression(item.value)}")
            when C::Local then @locals << item.name.text
                               line(depth, "#{item.name.text} = #{expression(item.value)}")
            when C::If then print_if(depth, item)
            when C::While then print_block_statement(depth, "while #{condition(item.condition)}", item.body)
            when C::Break then line(depth, "break")
            when C::Return then line(depth, "return")
            when C::Block then statements(depth, item.body) # a Ruby method's locals are its own already
            when C::Comment then comment(depth, item.text)
            else raise LoweringError, "the printer has no statement form for #{item.class}"
            end
          end

          def print_if(depth, item)
            line(depth, "if #{condition(item.condition)}")
            statements(depth + 1, item.body)
            unless item.otherwise.empty?
              line(depth, "else")
              statements(depth + 1, item.otherwise)
            end
            line(depth, "end")
          end

          def print_block_statement(depth, opening, body)
            line(depth, opening)
            statements(depth + 1, body)
            line(depth, "end")
          end

          # A number taken as a condition: not nought.
          def condition(item) = "#{expression(item)} != 0"

          # --- expressions ---

          def expression(item)
            case item
            when C::Int then integer(item.value)
            when C::Name then name(item)
            when C::AddressOf then address_of(item.name)
            when C::Text then string(item.value)
            when C::Index then "#{expression(item.array)}[#{expression(item.index)}]"
            when C::Call then call(item)
            else raise LoweringError, "the printer has no expression form for #{item.class}"
            end
          end

          def name(item) = @locals.include?(item.text) ? item.text : "@#{item.text}"

          # A routine picked from an array by its number (rg_call_routine(table[which])) is the
          # method of that name.
          def call(item)
            function = item.function.text
            return "__send__(#{expression(item.args.first)})" if function == "rg_call_routine"

            @called << function
            "#{function}(#{item.args.map { |arg| expression(arg) }.join(', ')})"
          end

          # Where a global lives, for a runtime function that reads it later. A list is an object,
          # handed over as itself; a number is not, so a variable is handed over as a lambda that
          # reads it then.
          def address_of(name)
            @lists.include?(name.text) ? "@#{name.text}" : "-> { @#{name.text} }"
          end

          def integer(value)
            unless value.is_a?(Integer) && value.between?(Int32::MIN, Int32::MAX)
              raise LoweringError, "#{value.inspect} is not a 32-bit whole number, so it cannot be written as one"
            end

            value.to_s
          end

          # A Ruby string, every character outside plain ASCII escaped and nothing in it read as
          # code (String#dump escapes a # that would start an interpolation).
          def string(text) = text.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace).dump

          def comment(depth, text) = line(depth, "# #{text.to_s.tr("\n", ' ')}")

          def line(depth, text)
            @out << (INDENT * depth) << text << "\n"
          end
        end
      end
    end
  end
end
