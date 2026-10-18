# frozen_string_literal: true

require "json"

module RubyGBA
  module IR
    module Backends
      class JS
        # Turns the statement tree the lowering builds (Native::C) into JavaScript. The only place
        # in the backend that writes JavaScript.
        #
        # The tree has no operators in it — every number a game keeps goes through a runtime
        # function (runtime/rg_int32.js) — so nothing here has to know JavaScript's precedence, or
        # that its numbers are 64-bit floats. What it does have to know is the one thing C has that
        # JavaScript does not: a routine that STOPS PART WAY to wait for the next frame.
        #
        # WAITING FOR A FRAME. In C, rg_wait_vblank hands the frame to the driver and comes back
        # when the next one starts, from however deep in the game's routines it was called. A
        # browser cannot stop a script like that: a page that never gives control back never shows
        # a picture. So every routine that can reach a wait — itself, or through a routine it calls
        # — is written as a generator (`function*`), the wait as `yield`, and a call to one as
        # `yield*`. The driver then plays the game by asking the generator for its next frame, as
        # often as it likes, and the browser keeps control between frames. A routine that never
        # waits stays a plain function, which keeps the many small routines of a game cheap.
        #
        # The routines the runtime calls for an answer (a bend's offset, a see-through amount, a
        # timer's tick) must answer at once, so they are plain functions whatever they reach; a
        # routine of the game's that could wait is run to its end from them (rg_run_now), and
        # waiting there is a fault.
        class Printer
          C = Native::C
          INDENT = "  "

          # The JavaScript typed array each C type a table or a picture is kept in becomes.
          ARRAYS = Ractor.make_shareable({ "int8_t" => "Int8Array", "uint8_t" => "Uint8Array",
                                           "int16_t" => "Int16Array", "uint16_t" => "Uint16Array",
                                           "int32_t" => "Int32Array", "char" => "Uint8Array" })

          # The most numbers a table is written out as; a bigger one is written as base64.
          MOST_WRITTEN_AS_NUMBERS = 256

          # How each array's numbers are packed into bytes: little-endian, the width the array holds.
          PACKING = Ractor.make_shareable({ "Int8Array" => "c*", "Uint8Array" => "C*", "Int16Array" => "s<*",
                                            "Uint16Array" => "S<*", "Int32Array" => "l<*" })

          # The runtime's wait for the next frame, and its call of a routine picked from an array.
          WAIT = "rg_wait_vblank"
          CALL_ROUTINE = "rg_call_routine"
          # The routine the driver plays the game through: always a generator, so the driver has
          # one way to play every game, whether it waits for frames or not.
          MAIN = "rg_game_main"

          # +data+ is where a big table's numbers go: :inline, in the file as base64, or :separate, in
          # a data file of their own (#data_file), which the runtime fetches and hands to
          # rg_data_fill before the game's first frame.
          def initialize(data: :inline)
            raise ArgumentError, "data is :inline or :separate, not #{data.inspect}" unless %i[inline separate].include?(data)

            @out = +""
            @data = data
            @payload = +"".b
            @fills = []
          end

          # The whole file: +items+ is the top level, in the order it is to appear.
          def print_file(items)
            @functions = items.grep(C::Function).to_h { |function| [function.name.text, function] }
            @tables = items.grep(C::FunctionTable).to_h { |table| [table.name.text, table.functions.map(&:text)] }
            @lists = items.grep(C::ListStorage).to_set { |list| list.name.text }
            @waiting = waiting_functions
            items.each { |item| print_top(item) }
            print_data_fill unless @fills.empty?
            @out
          end

          # THE DATA FILE, with the data separate: a fingerprint of what it holds (DATA_STAMP_BYTES
          # of its SHA-256), then every big table's bytes one after another. The file's script
          # holds the same fingerprint and refuses a data file without it, so a data file left
          # from another build of the game is said to be one rather than played as this one's.
          # Nil with the data inline, and for a game with no table big enough to go there, which
          # then fetches nothing.
          def data_file
            return nil if @fills.empty?

            stamp + @payload
          end

          DATA_STAMP_BYTES = 8

          private

          # --- which routines can wait for a frame ---

          # Every routine that can reach a wait, found by following calls until nothing more
          # joins. A routine in an array with one that waits waits too, since a call through the
          # array cannot tell which it reaches; and the driver's own routine always is one.
          def waiting_functions
            waiting = Set[MAIN]
            loop do
              grown = @functions.each_key.select { |name| !waiting.include?(name) && reaches_wait?(@functions[name].body, waiting) }
              grown += @tables.values.select { |names| names.any? { |name| waiting.include?(name) } }.flatten
                             .reject { |name| waiting.include?(name) }
              break if grown.empty?

              waiting.merge(grown)
            end
            waiting
          end

          def reaches_wait?(statements, waiting)
            statements.any? do |statement|
              case statement
              when C::Eval then call_waits?(statement.call, waiting)
              when C::If then reaches_wait?(statement.body, waiting) || reaches_wait?(statement.otherwise, waiting)
              when C::While, C::Block then reaches_wait?(statement.body, waiting)
              else false
              end
            end
          end

          # Whether a call, written as a statement, can wait: the wait itself, a routine that waits,
          # or a routine picked from an array that holds one.
          def call_waits?(call, waiting)
            name = call.function.text
            return true if name == WAIT
            return Array(table_of(call)).any? { |routine| waiting.include?(routine) } if name == CALL_ROUTINE

            @functions.key?(name) && !@functions[name].exported && waiting.include?(name)
          end

          # The routines an array call (rg_call_routine(table[which])) picks among.
          def table_of(call) = @tables[call.args.first.array.text]

          # --- the top level ---

          def print_top(item)
            case item
            when C::Include, C::Prototype then nil # JavaScript finds a function wherever it is declared
            when C::Global then line(0, "let #{item.name.text} = #{integer(item.value)};")
            when C::ConstArray then print_const_array(item)
            when C::Function then print_function(item)
            when C::FunctionTable then line(0, "const #{item.name.text} = [#{item.functions.map(&:text).join(', ')}];")
            when C::ListStorage then print_list_storage(item)
            when C::Comment then comment(0, item.text)
            else raise LoweringError, "the printer has no top-level form for #{item.class}"
            end
          end

          # A routine the driver or the runtime calls by name (+exported+) is one of the runtime's
          # questions to the game: the driver's own routine waits like any, and the rest answer at
          # once.
          def print_function(item)
            name = item.name.text
            @answering = item.exported && name != MAIN
            star = @waiting.include?(name) && !@answering ? "*" : ""
            line(0, "function#{star} #{name}() {")
            statements(1, item.body)
            line(0, "}")
            line(0, "")
          end

          # A small table is its numbers, sixteen a line, as the C writes it. A big one is its
          # bytes in base64, read back when the script starts (rg_table_from_base64 says why: a
          # browser runs out of memory reading millions of numbers written out as code).
          def print_const_array(item)
            type = ARRAYS.fetch(item.type) { raise LoweringError, "the printer has no array for C's #{item.type}" }
            values = item.values
            if values.empty?
              line(0, "const #{item.name.text} = new #{type}(1);")
            elsif values.size > MOST_WRITTEN_AS_NUMBERS && @data == :separate
              print_table_in_data_file(item.name.text, type, values)
            elsif values.size > MOST_WRITTEN_AS_NUMBERS
              print_table_as_base64(item.name.text, type, values)
            else
              line(0, "const #{item.name.text} = new #{type}([")
              values.each_slice(16) { |row| line(1, "#{row.map { |v| integer(v) }.join(', ')},") }
              line(0, "]);")
            end
          end

          # The table's bytes in a template string, 76 characters a line, so the file stays one a
          # person can scroll. Base64 holds no backtick and no `${`, so nothing in it is read as
          # anything but text.
          def print_table_as_base64(name, type, values)
            values.each { |value| integer(value) } # refuses one that is not a 32-bit whole number
            bytes = values.pack(PACKING.fetch(type))
            line(0, "const #{name} = rg_table_from_base64(#{type}, `")
            [bytes].pack("m76").each_line { |row| @out << row }
            line(0, "`);")
          end

          # A table whose bytes are in the data file: empty until rg_data_fill puts them in, which is
          # before anything reads it, since no frame is played until the data is in.
          def print_table_in_data_file(name, type, values)
            values.each { |value| integer(value) } # refuses one that is not a 32-bit whole number
            @fills << "#{name} = rg_table_from_bytes(#{type}, bytes, #{@payload.bytesize + DATA_STAMP_BYTES}, #{values.size});"
            @payload << values.pack(PACKING.fetch(type))
            line(0, "let #{name} = null;")
          end

          def print_data_fill
            line(0, "const RG_DATA_STAMP = #{string(stamp.unpack1('H*'))};")
            line(0, "function rg_data_fill(bytes) {")
            @fills.each { |fill| line(1, fill) }
            line(0, "}")
          end

          def stamp = Digest::SHA256.digest(@payload)[0, DATA_STAMP_BYTES]

          def print_list_storage(item)
            line(0, "const #{item.name.text} = rg_list_new(#{integer(item.capacity)}, #{integer(item.width)}, " \
                    "#{string(item.label)});")
          end

          # --- statements ---

          def statements(depth, list)
            list.each { |statement| statement(depth, statement) }
          end

          def statement(depth, item)
            case item
            when C::Eval then print_eval(depth, item.call)
            when C::Assign then line(depth, "#{expression(item.target)} = #{expression(item.value)};")
            when C::Local then line(depth, "let #{item.name.text} = #{expression(item.value)};")
            when C::If then print_if(depth, item)
            when C::While then print_block_statement(depth, "while (#{expression(item.condition)}) {", item.body)
            when C::Break then line(depth, "break;")
            when C::Return then line(depth, "return;")
            when C::Block then print_block_statement(depth, "{", item.body)
            when C::Comment then comment(depth, item.text)
            else raise LoweringError, "the printer has no statement form for #{item.class}"
            end
          end

          # A call written as a statement: the place a routine can wait.
          def print_eval(depth, call)
            name = call.function.text
            if name == WAIT
              line(depth, @answering ? "rg_wait_vblank_while_answering();" : "rg_wait_vblank(); yield 0;")
            elsif name == CALL_ROUTINE
              picked = expression(call.args.first)
              line(depth, routine_call(picked, Array(table_of(call)).any? { |routine| @waiting.include?(routine) }))
            elsif @functions.key?(name) && !@functions[name].exported
              line(depth, routine_call("#{name}", @waiting.include?(name)))
            else
              line(depth, "#{expression(call)};")
            end
          end

          # A call of one of the game's routines: delegated to when it can wait, run to its end
          # here when this routine answers the runtime and cannot wait itself.
          def routine_call(callee, waits)
            return "#{callee}();" unless waits
            return "rg_run_now(#{callee}());" if @answering

            "yield* #{callee}();"
          end

          def print_if(depth, item)
            line(depth, "if (#{expression(item.condition)}) {")
            statements(depth + 1, item.body)
            unless item.otherwise.empty?
              line(depth, "} else {")
              statements(depth + 1, item.otherwise)
            end
            line(depth, "}")
          end

          def print_block_statement(depth, opening, body)
            line(depth, opening)
            statements(depth + 1, body)
            line(depth, "}")
          end

          # --- expressions ---

          def expression(item)
            case item
            when C::Int then integer(item.value)
            when C::Name then item.text
            when C::AddressOf then address_of(item.name)
            when C::Text then string(item.value)
            when C::Index then "#{expression(item.array)}[#{expression(item.index)}]"
            when C::Call then "#{item.function.text}(#{item.args.map { |arg| expression(arg) }.join(', ')})"
            else raise LoweringError, "the printer has no expression form for #{item.class}"
            end
          end

          # Where a global lives, for a runtime function that reads it later. A list is an object,
          # handed over as itself. JavaScript has no address of a number, so a variable is handed
          # over as a function that reads it now.
          def address_of(name)
            @lists.include?(name.text) ? name.text : "() => #{name.text}"
          end

          def integer(value)
            unless value.is_a?(Integer) && value.between?(Int32::MIN, Int32::MAX)
              raise LoweringError, "#{value.inspect} is not a 32-bit whole number, so it cannot be written as one"
            end

            value.to_s
          end

          # A JavaScript string, every character outside plain ASCII escaped, which JSON's rules do.
          def string(text) = JSON.generate(text.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace),
                                           ascii_only: true, script_safe: true)

          # A comment can hold anything except the sequence that ends it, so each "*/" is broken up;
          # and it is kept to the one line.
          def comment(depth, text)
            line(depth, "/* #{text.to_s.gsub('*/', '* /').tr("\n", ' ')} */")
          end

          def line(depth, text)
            @out << (INDENT * depth) << text << "\n"
          end
        end
      end
    end
  end
end
