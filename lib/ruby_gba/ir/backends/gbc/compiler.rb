# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBC
        # THE NATIVE LOWERING'S STATEMENTS, AS SM83 MACHINE CODE.
        #
        # GBC::Lowering says a program as Native::C says it: globals, lists, tables of numbers,
        # routines made of assignments, ifs, loops and calls, every number a 32-bit whole number
        # that goes through a runtime function. This turns that tree into sections of machine code
        # for the Linker, the way Native::Printer turns it into C text.
        #
        # HOW A NUMBER IS WORKED OUT. Every expression leaves its answer in the four registers B C
        # D E (B the top byte), which is where every runtime routine takes and gives a number. A
        # sum of two works out the right-hand side first and pushes it on the stack — the stack
        # then holds it lowest byte first, which is how a number sits in memory — works out the
        # left-hand side, and hands the routine the right one's address (HL = SP). A call with
        # several numbers pushes them all, first first, and the routine reads them off the stack
        # (Runtime::Calls). Nothing is kept in a register from one statement to the next, so a
        # statement never has to know what came before it.
        #
        # WHERE THINGS LIVE. The game's variables, lists and each routine's own numbers (a loop's
        # count, say) are places in work memory (Memory), fixed while the program is built. A
        # routine's own numbers are fixed too, not kept on the stack, so a routine cannot call
        # itself; the lowering refuses a program that does. Tables of numbers go in the part of the
        # cartridge always in view, so any routine can read them; the routines go in the banks,
        # and one in another bank is called through bank 0 (Runtime::Banks#far_call).
        class Compiler
          C = Native::C

          # The sums a routine of the runtime does on BCDE and the number at HL.
          WITH_HL = {
            "rg_add" => "rt_add32", "rg_sub" => "rt_sub32", "rg_mul" => "rt_mul32", "rg_div" => "rt_div32",
            "rg_mod" => "rt_mod32", "rg_and" => "rt_and32", "rg_or" => "rt_or32", "rg_xor" => "rt_xor32",
            "rg_shl" => "rt_shl32", "rg_shr" => "rt_shr32", "rg_both" => "rt_both32", "rg_either" => "rt_either32"
          }.freeze

          # ...on BCDE alone.
          ALONE = { "rg_neg" => "rt_neg32", "rg_not" => "rt_not32", "rg_abs" => "rt_abs32" }.freeze

          # ...on BCDE and two numbers at HL, one after the other.
          WITH_TWO = { "rg_mul_fix" => "rt_mul_fix", "rg_div_fix" => "rt_div_fix", "rg_clamp" => "rt_clamp32" }.freeze

          # A comparison, by what rt_cmp32 leaves in A (0 equal, 1 less, 2 greater): the number to
          # compare A with, and whether the comparison holds when they are equal (:z) or not (:nz).
          COMPARISONS = Ractor.make_shareable({
            "rg_lt" => [1, :z], "rg_le" => [2, :nz], "rg_gt" => [2, :z],
            "rg_ge" => [1, :nz], "rg_eq" => [0, :z], "rg_ne" => [0, :nz], "rg_below" => [1, :z]
          })

          # The comparisons that take both numbers from nought up (rt_cmpu32): `rg_below(n, size)`
          # is "n is from nought up to, but not, size", one comparison where it would be two.
          UNSIGNED = %w[rg_below].freeze

          # WHAT A SUM OF NUMBERS WRITTEN IN THE PROGRAM COMES TO, worked out here rather than by the
          # runtime as the game runs: IR::Int32's own answer, which is what the runtime's would be.
          # A test of a number the game never changes (a sprite whose pose is always 0) then costs
          # nothing at all.
          FOLDED = Ractor.make_shareable({
            "rg_add" => ->(a, b) { Int32.add(a, b) }, "rg_sub" => ->(a, b) { Int32.sub(a, b) },
            "rg_mul" => ->(a, b) { Int32.mul(a, b) }, "rg_div" => ->(a, b) { Int32.div(a, b) },
            "rg_mod" => ->(a, b) { Int32.mod(a, b) }, "rg_and" => ->(a, b) { Int32.bit_and(a, b) },
            "rg_or" => ->(a, b) { Int32.bit_or(a, b) }, "rg_xor" => ->(a, b) { Int32.bit_xor(a, b) },
            "rg_shl" => ->(a, b) { Int32.shift_left(a, b) }, "rg_shr" => ->(a, b) { Int32.shift_right(a, b) },
            "rg_neg" => ->(a) { Int32.neg(a) }, "rg_not" => ->(a) { Int32.bit_not(a) },
            "rg_abs" => ->(a) { Int32.wrap(a).negative? ? Int32.neg(a) : Int32.wrap(a) },
            "rg_lt" => ->(a, b) { Int32.cmp(a, b).negative? ? 1 : 0 }, "rg_le" => ->(a, b) { Int32.cmp(a, b) <= 0 ? 1 : 0 },
            "rg_gt" => ->(a, b) { Int32.cmp(a, b).positive? ? 1 : 0 }, "rg_ge" => ->(a, b) { Int32.cmp(a, b) >= 0 ? 1 : 0 },
            "rg_eq" => ->(a, b) { Int32.cmp(a, b).zero? ? 1 : 0 }, "rg_ne" => ->(a, b) { Int32.cmp(a, b).zero? ? 0 : 1 },
            "rg_both" => ->(a, b) { !Int32.wrap(a).zero? && !Int32.wrap(b).zero? ? 1 : 0 },
            "rg_either" => ->(a, b) { !Int32.wrap(a).zero? || !Int32.wrap(b).zero? ? 1 : 0 },
            "rg_below" => ->(a, b) { (a & 0xFFFF_FFFF) < (b & 0xFFFF_FFFF) ? 1 : 0 }
          })

          # Each C type a table can keep its numbers in: bytes a number, and whether it is signed.
          TYPES = Ractor.make_shareable({ "int8_t" => [1, true], "uint8_t" => [1, false], "int16_t" => [2, true],
                    "uint16_t" => [2, false], "int32_t" => [4, true], "char" => [1, false] })

          class Error < StandardError; end

          # What compiling made: the sections for the Linker, and where each global and list went
          # (by its name in the C), for whatever reads a running game back.
          Compiled = Data.define(:sections, :globals, :lists, :starts)

          # +runtime+ says which of the runtime's routines a call may name (any rg_ name it has).
          def initialize(memory:)
            @memory = memory
            @globals = {}      # C name -> address
            @lists = {}        # C name -> [address, capacity, width, label]
            @arrays = {}       # C name -> [label, type]
            @tables = {}       # C name -> label of a table of routines
            @routines = {}     # C name -> label
            @starts = []       # [address, value] for a global that does not start at nought
          end

          # +top_level+ is the program's tree, as Native::Lowering#top_level makes it. +banked+ puts
          # the routines in the banks; without it every routine goes in bank 0, which suits a small
          # program and a test.
          def compile(top_level)
            declare(top_level)
            data = data_section(top_level)
            routines = top_level.grep(C::Function).flat_map { |function| routine_sections(function) }
            Compiled.new(sections: [data, *routines], globals: @globals.dup, lists: @lists.dup, starts: @starts.dup)
          end

          private

          # --- the top level ---

          def declare(top_level)
            top_level.each do |item|
              case item
              when C::Global then declare_global(item)
              when C::ListStorage then declare_list(item)
              when C::ConstArray then @arrays[item.name.text] = ["data_#{item.name.text}", item.type, item.values]
              when C::FunctionTable then @tables[item.name.text] = "routines_#{item.name.text}"
              when C::Function then @routines[item.name.text] = "game_#{item.name.text}"
              end
            end
          end

          def declare_global(global)
            bytes = TYPES.fetch(global.type) { raise Error, "a global of type #{global.type} cannot be kept" }.first
            raise Error, "a global is kept in 4 bytes here, not #{bytes}" unless bytes == 4

            address = @memory.reserve("global #{global.name.text}", 4)
            @globals[global.name.text] = address
            value = global.value.is_a?(C::Int) ? global.value.value : global.value
            @starts << [address, value] unless value.zero?
          end

          # A list: its header (Runtime::Lists says what is in it) and then its slots, each the width
          # the game declared.
          def declare_list(storage)
            address = @memory.reserve("list #{storage.name.text}", Runtime::Lists::HEADER + (storage.capacity * storage.width))
            @lists[storage.name.text] = [address, storage.capacity, storage.width, storage.label]
          end

          # Tables of numbers, the tables of routines and the lists' headers' starting values, all
          # in bank 0.
          def data_section(top_level)
            asm = SM83.new("game data", home: :fixed)
            top_level.grep(C::ConstArray).each do |array|
              asm.label(@arrays.fetch(array.name.text).first)
              size, = TYPES.fetch(array.type)
              array.values.each { |value| asm.data_bytes(little_endian(value, size)) }
            end
            top_level.grep(C::FunctionTable).each do |table|
              asm.label(@tables.fetch(table.name.text))
              table.functions.each do |function|
                label = @routines.fetch(function.text)
                asm.data_words(label)
                asm.data_bank_of(label)
              end
            end
            asm.label("game_starts")
            @starts.each do |address, value|
              asm.data_words(address)
              asm.data_bytes(little_endian(value, 4))
            end
            asm.data_words(0)
            asm.label("game_lists")
            @lists.each_value do |address, capacity, width, _|
              asm.data_words(address)
              asm.data_words(capacity)
              asm.data_bytes(width)
            end
            asm.data_words(0)
            asm.section
          end

          def little_endian(value, size) = Array.new(size) { |i| (value >> (8 * i)) & 0xFF }

          # --- routines ---

          # The most bytes one routine's code may come to before it is cut into parts, each a
          # routine of its own: a bank is 16K, and a routine and the numbers it uses go in one.
          MOST_ROUTINE_BYTES = 12_000

          # The most bytes a part cut off a routine may come to.
          MOST_PART_BYTES = 6_000

          def routine_sections(function)
            routines = cut_to_fit(function)
            routines.each { |part| @routines[part.name.text] ||= "game_#{part.name.text}" }
            routines.map { |part| routine_section(part) }
          end

          def routine_section(function)
            label = @routines.fetch(function.name.text)
            begin_routine(label, function.name.text)
            @asm.label(label)
            statements(function.body)
            finish_routine
          end

          def begin_routine(label, name)
            @asm = SM83.new(label, home: :banked)
            @function = name
            @loops = []
            @labels = 0
            @constants = {}
            @return_label = fresh("return")
          end

          # The routine's end, and the numbers it named, kept beside it in its bank.
          def finish_routine
            @asm.label(@return_label)
            @asm.ret
            @constants.each do |value, label|
              @asm.label(label)
              @asm.data_bytes(little_endian(value, 4))
            end
            @asm.section
          end

          # A ROUTINE TOO BIG FOR A BANK, CUT INTO PARTS. A run of statements side by side becomes a
          # routine of its own, called where they were; a statement that leaves its routine part
          # way (a `break` out of a loop around it, a `return`) stays, and what is inside it is cut
          # the same way instead. The parts share the routine's own numbers, which are kept in work
          # memory and not on the stack, so nothing is handed between them.
          def cut_to_fit(function)
            return [function] if bytes_of(function.body) <= MOST_ROUTINE_BYTES

            parts = []
            body = cut_list(function.body, function.name.text, parts)
            [C::Function.new(name: function.name, body: body), *parts]
          end

          def cut_list(list, base, parts)
            kept = []
            run = []
            run_bytes = 0
            flush = lambda do
              unless run.empty?
                kept << part_call(run, base, parts)
                run = []
                run_bytes = 0
              end
            end
            list.each do |statement|
              size = bytes_of([statement])
              if movable?(statement) && size <= MOST_PART_BYTES
                flush.call if run_bytes + size > MOST_PART_BYTES
                run << statement
                run_bytes += size
              else
                flush.call
                kept << cut_inside(statement, base, parts)
              end
            end
            flush.call
            kept
          end

          # A statement that cannot move, or is too big to move whole, with its own lists cut.
          def cut_inside(statement, base, parts)
            case statement
            when C::If
              C::If.new(condition: statement.condition, body: cut_list(statement.body, base, parts),
                        otherwise: cut_list(statement.otherwise, base, parts))
            when C::While then C::While.new(condition: statement.condition, body: cut_list(statement.body, base, parts))
            when C::Block then C::Block.new(cut_list(statement.body, base, parts))
            else statement
            end
          end

          def part_call(statements, base, parts)
            name = C::Name.new("#{base}_part#{parts.length + 1}")
            parts << C::Function.new(name: name, body: statements)
            @routines[name.text] = "game_#{name.text}"
            C::Eval.new(C::Call.new(function: name))
          end

          # Whether a statement can be moved into a routine of its own: it never leaves the routine
          # it is in (a return) nor a loop it is not inside of (a break).
          def movable?(statement, loops = 0)
            case statement
            when C::Return then false
            when C::Break then loops.positive?
            when C::If then (statement.body + statement.otherwise).all? { |inner| movable?(inner, loops) }
            when C::While then statement.body.all? { |inner| movable?(inner, loops + 1) }
            when C::Block then statement.body.all? { |inner| movable?(inner, loops) }
            else true
            end
          end

          # How many bytes +list+ comes to, compiled on its own and thrown away.
          def bytes_of(list)
            saved = [@asm, @function, @loops, @labels, @constants, @return_label]
            begin_routine("measuring", "measuring")
            @loops = ["measuring"]
            statements(list)
            @asm.here + (@constants.size * 4)
          ensure
            @asm, @function, @loops, @labels, @constants, @return_label = saved
          end

          def fresh(what)
            @labels += 1
            "#{@function}.#{what}#{@labels}"
          end

          def statements(list) = list.each { |statement| statement(statement) }

          def statement(node)
            case node
            when C::Assign then assign(node.target, node.value)
            when C::Local then assign(C::Name.new(node.name.text), node.value, local: true)
            when C::Eval then evaluate_call(node.call)
            when C::If then if_statement(node)
            when C::While then while_statement(node)
            when C::Break then @asm.jump(@loops.last || raise(Error, "a break outside a loop"))
            when C::Return then @asm.jump(@return_label)
            when C::Block then statements(node.body)
            when C::Comment then nil
            else raise Error, "a statement the Game Boy Color build cannot make: #{node.class}"
            end
          end

          def assign(target, value, local: false)
            raise Error, "only a variable can be assigned here" unless target.is_a?(C::Name)

            address = local ? local_address(target.text) : place_of(target.text)
            return add_in_place(address, value) if adds_in_place?(target, value)

            value(value)
            @asm.load(:hl, address)
            @asm.call("rt_store32")
          end

          # `x = x + n` and `x = x - n` for a number n written in the program: the four bytes of x
          # are added to where they are, which is a dozen instructions and no call.
          def adds_in_place?(target, value)
            value.is_a?(C::Call) && %w[rg_add rg_sub].include?(value.function.text) &&
              value.args.first == target && folded(value.args.last)
          end

          def add_in_place(address, value)
            amount = folded(value.args.last)
            amount = Int32.neg(amount) if value.function.text == "rg_sub"
            amount &= 0xFFFF_FFFF
            @asm.load(:hl, address)
            4.times do |i|
              byte = (amount >> (8 * i)) & 0xFF
              @asm.load(:a, [:hl])
              i.zero? ? @asm.add_a(byte) : @asm.adc_a(byte)
              @asm.load(i == 3 ? [:hl] : [:hli], :a)
            end
          end

          def local_address(name)
            @globals[name] || @memory.reserve("local #{name}", 4)
          end

          def place_of(name)
            @globals.fetch(name) do
              return @memory["local #{name}"] if @memory.reserved?("local #{name}")

              raise Error, "#{name} is not a variable the program keeps"
            end
          end

          def if_statement(node)
            known = folded(node.condition)
            return statements(known.zero? ? node.otherwise : node.body) if known

            otherwise = fresh("else")
            done = fresh("end_if")
            jump_unless(node.condition, otherwise)
            statements(node.body)
            @asm.jump(done) unless node.otherwise.empty?
            @asm.label(otherwise)
            statements(node.otherwise)
            @asm.label(done)
          end

          def while_statement(node)
            top = fresh("loop")
            done = fresh("end_loop")
            @asm.label(top)
            jump_unless(node.condition, done) unless node.condition == C::Int.new(1)
            @loops.push(done)
            statements(node.body)
            @loops.pop
            @asm.jump(top)
            @asm.label(done)
          end

          # Jump to +label+ unless +condition+ holds. A comparison jumps on rt_cmp32's answer
          # straight away, without making a 1 or a 0 of it first.
          def jump_unless(condition, label)
            condition = simplified(condition)
            known = folded(condition)
            if known
              @asm.jump(label) if known.zero?
            elsif (equal = equality_with_number(condition))
              compare_with_number(*equal)
              @asm.jump(condition.function.text == "rg_eq" ? :nz : :z, label)
            elsif condition.is_a?(C::Call) && condition.function.text == "rg_both" && quiet?(condition.args.last)
              # The second side is skipped when the first does not hold: the interpreter works both
              # out, which is the same thing wherever working one out cannot stop the game.
              condition.args.each { |side| jump_unless(side, label) }
            elsif condition.is_a?(C::Call) && COMPARISONS.key?(condition.function.text)
              compare(condition)
              _, holds_when = COMPARISONS.fetch(condition.function.text)
              @asm.jump(holds_when == :z ? :nz : :z, label)
            else
              value(condition)
              @asm.call("rt_test32")
              @asm.jump(:z, label)
            end
          end

          # A variable said to equal (or not) a number written in the program: [its address, the
          # number], or nil for any other comparison.
          def equality_with_number(condition)
            return nil unless condition.is_a?(C::Call) && %w[rg_eq rg_ne].include?(condition.function.text)

            left, right = condition.args
            left, right = right, left if folded(left)
            number = folded(right)
            return nil unless number && left.is_a?(C::Name) && !@arrays.key?(left.text)

            [place_of(left.text), number & 0xFFFF_FFFF]
          end

          # The zero flag set when the four bytes at +address+ are +number+: byte by byte, leaving at
          # the first that differs.
          def compare_with_number(address, number)
            done = fresh("compared")
            @asm.load(:hl, address)
            4.times do |i|
              @asm.load(:a, i == 3 ? [:hl] : [:hli])
              @asm.cp_a((number >> (8 * i)) & 0xFF)
              @asm.jump_relative(:nz, done) unless i == 3
            end
            @asm.label(done)
          end

          # rt_cmp32 on the two sides of a comparison, and A compared with what the comparison
          # holds on, so the zero flag says.
          def compare(call)
            left, right = call.args
            with_hl_at(right) do |where|
              value(left)
              point_hl(where)
              @asm.call(UNSIGNED.include?(call.function.text) ? "rt_cmpu32" : "rt_cmp32")
            end
            k, = COMPARISONS.fetch(call.function.text)
            k.zero? ? @asm.and_a(:a) : @asm.cp_a(k)
          end

          # --- values: each leaves its number in BCDE ---

          # The comparisons and the tests built of them, which come to 1 or 0 and nothing else.
          YES_OR_NO = (COMPARISONS.keys + %w[rg_both rg_either]).freeze

          # Each comparison and the one that holds exactly when it does not.
          OPPOSITES = Ractor.make_shareable({ "rg_lt" => "rg_ge", "rg_ge" => "rg_lt", "rg_gt" => "rg_le",
                                              "rg_le" => "rg_gt", "rg_eq" => "rg_ne", "rg_ne" => "rg_eq" })

          # +node+ said more simply where a number written in the program makes part of it nothing:
          # x × 1 and x + 0 are x, and a test that comes to 1 or 0, asked whether it is 1 (or not
          # 0), is the test itself — so `active == 1` of a sprite whose `active` is `1 * (state ==
          # 0)` is one comparison of `state` with 0.
          def simplified(node)
            return node unless node.is_a?(C::Call)

            name = node.function.text
            args = node.args.map { |arg| simplified(arg) }
            numbers = args.map { |arg| folded(arg) }
            case name
            when "rg_mul"
              return args[1] if numbers[0] == 1
              return args[0] if numbers[1] == 1
            when "rg_add"
              return args[1] if numbers[0]&.zero?
              return args[0] if numbers[1]&.zero?
            when "rg_sub"
              return args[0] if numbers[1]&.zero?
            when "rg_eq", "rg_ne"
              test, number = numbers[1] ? [args[0], numbers[1]] : [args[1], numbers[0]]
              if yes_or_no?(test) && [0, 1].include?(number)
                holds = (name == "rg_eq") == (number == 1)
                return test if holds
                return C::Call.new(function: C::Name.new(OPPOSITES.fetch(test.function.text)), args: test.args) if OPPOSITES.key?(test.function.text)
              end
            end
            C::Call.new(function: node.function, args: args)
          end

          def yes_or_no?(node) = node.is_a?(C::Call) && YES_OR_NO.include?(node.function.text)

          # The runtime's sums that only ever answer — none of them can stop the game.
          QUIET = (FOLDED.keys + COMPARISONS.keys + %w[rg_clamp rg_held rg_pressed rg_mul_fix rg_div_fix]).freeze

          # Can working +node+ out never stop the game? Reading a list past its end can, and so
          # can a sprite's picture its pose does not name.
          def quiet?(node)
            case node
            when C::Int, Integer, C::Name then true
            when C::Index then quiet?(node.index)
            when C::Call then QUIET.include?(node.function.text) && node.args.all? { |arg| quiet?(arg) }
            else false
            end
          end

          # The number +node+ comes to when everything in it is written in the program, or nil.
          def folded(node)
            case node
            when C::Int then node.value
            when Integer then node
            when C::Call
              rule = FOLDED[node.function.text]
              return nil unless rule && rule.arity == node.args.length

              numbers = node.args.map { |arg| folded(arg) }
              numbers.all? ? Int32.wrap(rule.call(*numbers)) : nil
            when C::Index
              _, type, values = @arrays[node.array.text]
              at = values && folded(node.index)
              return nil unless at && at.between?(0, values.length - 1)

              size, signed = TYPES.fetch(type)
              entry = values[at] & ((1 << (8 * size)) - 1)
              signed && entry >= 1 << ((8 * size) - 1) ? entry - (1 << (8 * size)) : entry
            end
          end

          def value(node)
            node = simplified(node)
            known = folded(node)
            return load_constant(known) if known

            case node
            when C::Int then load_constant(node.value)
            when Integer then load_constant(node)
            when C::Name then load_name(node.text)
            when C::AddressOf then load_constant(address_of(node.name))
            when C::Index then table_entry(node)
            when C::Call then evaluate_call(node)
            else raise Error, "a value the Game Boy Color build cannot work out: #{node.class}"
            end
          end

          # A name as a number: a variable's value, or a table's address (for a runtime routine that
          # reads it).
          def load_name(text)
            return load_label(@arrays.fetch(text).first) if @arrays.key?(text)

            @asm.load(:hl, place_of(text))
            @asm.call("rt_load32")
          end

          def load_label(label)
            @asm.load(:bc, 0)
            @asm.load(:de, label)
          end

          def address_of(name)
            text = name.is_a?(C::Name) ? name.text : name.to_s
            return @lists.fetch(text).first if @lists.key?(text)

            place_of(text)
          end

          def load_constant(value)
            value &= 0xFFFF_FFFF
            @asm.load(:bc, value >> 16)
            @asm.load(:de, value & 0xFFFF)
          end

          # A number the routine names, kept once beside it, and the label of where.
          def constant_label(value)
            value &= 0xFFFF_FFFF
            @constants[value] ||= fresh("number")
          end

          # Run the block with the number +node+ somewhere HL can be pointed at, handing the block
          # where (for #point_hl): a variable or a number the routine keeps is pointed at where it
          # is, and anything else is worked out first and pushed, and taken off again after.
          def with_hl_at(node)
            known = folded(node)
            where = case node
                    when ->(_) { known } then [:label, constant_label(known)]
                    when C::Name then @arrays.key?(node.text) ? nil : [:address, place_of(node.text)]
                    end
            return yield(where) if where

            value(node)
            @asm.push(:bc)
            @asm.push(:de)
            yield [:stack]
            @asm.add_sp(4)
          end

          def point_hl((kind, at))
            kind == :stack ? @asm.load_hl_sp(0) : @asm.load(:hl, at)
          end

          # The entry of a table of numbers at an index the program has already kept inside it.
          def table_entry(node)
            label, type, = @arrays.fetch(node.array.text) { raise Error, "#{node.array.text} is not a table of numbers" }
            size, signed = TYPES.fetch(type)
            value(node.index)
            # HL = the table + the index × the entry's size; the index is never past 16 bits.
            (size / 2).times do
              @asm.sla(:e)
              @asm.rl(:d)
            end
            @asm.load(:hl, label)
            @asm.add_hl(:de)
            @asm.call(TABLE_READERS.fetch([size, signed]))
          end

          TABLE_READERS = Ractor.make_shareable({ [1, true] => "rt_read_int8", [1, false] => "rt_read_uint8", [2, true] => "rt_read_int16",
                            [2, false] => "rt_read_uint16", [4, true] => "rt_read_int32" })

          # A call. A routine of the game's is called through bank 0, which puts its bank in view; a
          # sum goes to the arithmetic; anything else to the runtime routine of the same name, with
          # its numbers pushed and taken off again afterwards.
          def evaluate_call(call)
            name = call.function.text
            if @routines.key?(name)
              raise Error, "a routine of the game takes no numbers" unless call.args.empty?

              return call_routine(@routines.fetch(name))
            end
            return call_one_of(call.args.first) if name == "rg_call_routine"

            if WITH_HL.key?(name) then binary(call, WITH_HL.fetch(name))
            elsif ALONE.key?(name)
              value(call.args.first)
              @asm.call(ALONE.fetch(name))
            elsif WITH_TWO.key?(name) then three(call, WITH_TWO.fetch(name))
            elsif COMPARISONS.key?(name)
              compare(call)
              _, holds_when = COMPARISONS.fetch(name)
              @asm.call(holds_when == :z ? "rt_bool_of_z" : "rt_bool_of_nz")
            else
              runtime_call(name, call.args)
            end
          end

          def binary(call, routine)
            left, right = call.args
            with_hl_at(right) do |where|
              value(left)
              point_hl(where)
              @asm.call(routine)
            end
          end

          # The first number in BCDE, the second at HL and the third just past it: both pushed.
          def three(call, routine)
            first, second, third = call.args
            [third, second].each do |node|
              value(node)
              @asm.push(:bc)
              @asm.push(:de)
            end
            value(first)
            @asm.load_hl_sp(0)
            @asm.call(routine)
            @asm.add_sp(8)
          end

          # A runtime routine taking +args+, each pushed in order, the first deepest: the routine
          # finds the last of them just past its return address.
          def runtime_call(name, args)
            args.each do |arg|
              value(arg)
              @asm.push(:bc)
              @asm.push(:de)
            end
            @asm.call(name)
            bytes = args.length * 4
            while bytes.positive?
              step = [bytes, 124].min
              @asm.add_sp(step)
              bytes -= step
            end
          end

          def call_routine(label)
            @asm.call("rt_far_call")
            @asm.data_bank_of(label)
            @asm.data_words(label)
          end

          # One of a table of routines, by an index already kept inside it: HL = the table's entry.
          def call_one_of(index)
            raise Error, "rg_call_routine takes an entry of a table of routines" unless index.is_a?(C::Index)

            label = @tables.fetch(index.array.text)
            value(index.index)
            @asm.load(:h, :d)
            @asm.load(:l, :e)
            @asm.add_hl(:hl)
            @asm.add_hl(:de) # × 3, an entry being an address and a bank
            @asm.load(:de, label)
            @asm.add_hl(:de)
            @asm.call("rt_far_call_hl")
          end
        end
      end
    end
  end
end
