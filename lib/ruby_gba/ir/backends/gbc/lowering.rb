# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBC
        # ONE PROGRAM, LOWERED STRAIGHT TO SM83 MACHINE CODE: the Color's peer of the GBA lowering,
        # which does the same in ARM. It walks the IR with a table naming the method for each kind of
        # statement and each kind of value (the interpreter's own shape, Reference), and emits the
        # instructions through the encoder (SM83), calling the runtime (GBC::Runtime) for what the
        # runtime does: the 32-bit arithmetic, the frame, the buttons.
        #
        # HOW A NUMBER IS WORKED OUT. Every value leaves its answer in the four registers B C D E, B
        # the top byte, which is where every runtime routine takes and gives a number. A sum of two
        # works out the right-hand side first and pushes it on the stack — which then holds it lowest
        # byte first, as a number sits in memory — works out the left-hand side, and hands the
        # routine the right one's address (HL = SP). A routine taking several numbers has them all
        # pushed, the first deepest (Runtime::Calls). Nothing is kept in a register from one
        # statement to the next, so a statement never has to know what came before it.
        #
        # WHERE THINGS LIVE. The game's variables, and each routine's own numbers — a loop's count, a
        # `case`'s reading — are places in work memory (Memory), fixed while the program is built, so
        # a routine cannot call itself, and a program in which one can is refused. Tables go in the
        # part of the cartridge always in view; routines go in the banks, and one in another bank is
        # called through bank 0 (Runtime::Calls's rt_far_call).
        #
        # It makes the kinds in its two tables so far. GBC#build hands any other program to the
        # statement path (StatementLowering) until this one makes it too.
        class Lowering
          STATEMENTS = Ractor.make_shareable({
                                               program: :emit_children, set: :emit_set, add: :emit_add,
                                               sub: :emit_sub, copy: :emit_copy, negate: :emit_negate,
                                               abs: :emit_abs, negate_abs: :emit_negate_abs, clamp: :emit_clamp,
                                               if: :emit_if, loop: :emit_loop, repeat: :emit_repeat,
                                               every: :emit_beat, after: :emit_beat, call: :emit_call,
                                               call_one_of: :emit_call_one_of, case: :emit_case,
                                               halt: :emit_halt, wait_vblank: :emit_wait_vblank
                                             }.merge(Nodes.of_role(:declaration).to_h { |kind| [kind, :emit_nothing] }))

          VALUES = Ractor.make_shareable({
                                           int: :value_of_int, var_ref: :value_of_var_ref, binop: :value_of_binop,
                                           neg: :value_of_neg, bit_not: :value_of_bit_not,
                                           absolute: :value_of_absolute, clamped: :value_of_clamped,
                                           mul_fix: :value_of_mul_fix, div_fix: :value_of_div_fix,
                                           shift_right: :value_of_shift_right, held: :value_of_held,
                                           pressed: :value_of_pressed
                                         })

          # The runtime's sums on BCDE and the number at HL, by the operator of a binop.
          SUMS = Ractor.make_shareable({ :+ => "rt_add32", :- => "rt_sub32", :* => "rt_mul32", :/ => "rt_div32",
                                         :% => "rt_mod32", :& => "rt_and32", :| => "rt_or32", :^ => "rt_xor32",
                                         :<< => "rt_shl32", :>> => "rt_shr32", and: "rt_both32", or: "rt_either32" })

          # A comparison, by what rt_cmp32 leaves in A (0 equal, 1 less, 2 greater): the number A is
          # compared with, and whether the comparison holds when they are equal (:z) or not (:nz).
          COMPARISONS = Ractor.make_shareable({ :< => [1, :z], :<= => [2, :nz], :> => [2, :z], :>= => [1, :nz],
                                                :== => [0, :z], :!= => [0, :nz] })

          # What a sum or a comparison of numbers written in the program comes to, worked out here
          # rather than by the runtime: IR::Int32's own answer, which is the runtime's.
          FOLDED = Ractor.make_shareable({
                                           :+ => ->(a, b) { Int32.add(a, b) }, :- => ->(a, b) { Int32.sub(a, b) },
                                           :* => ->(a, b) { Int32.mul(a, b) }, :/ => ->(a, b) { Int32.div(a, b) },
                                           :% => ->(a, b) { Int32.mod(a, b) }, :& => ->(a, b) { Int32.bit_and(a, b) },
                                           :| => ->(a, b) { Int32.bit_or(a, b) }, :^ => ->(a, b) { Int32.bit_xor(a, b) },
                                           :<< => ->(a, b) { Int32.shift_left(a, b) },
                                           :>> => ->(a, b) { Int32.shift_right(a, b) },
                                           :< => ->(a, b) { Int32.cmp(a, b).negative? ? 1 : 0 },
                                           :<= => ->(a, b) { Int32.cmp(a, b) <= 0 ? 1 : 0 },
                                           :> => ->(a, b) { Int32.cmp(a, b).positive? ? 1 : 0 },
                                           :>= => ->(a, b) { Int32.cmp(a, b) >= 0 ? 1 : 0 },
                                           :== => ->(a, b) { Int32.cmp(a, b).zero? ? 1 : 0 },
                                           :!= => ->(a, b) { Int32.cmp(a, b).zero? ? 0 : 1 },
                                           and: ->(a, b) { !Int32.wrap(a).zero? && !Int32.wrap(b).zero? ? 1 : 0 },
                                           or: ->(a, b) { !Int32.wrap(a).zero? || !Int32.wrap(b).zero? ? 1 : 0 }
                                         })

          # What the game's code is to the author, for a cartridge too full for it (Linker::TooBig).
          DATA = SM83::Holding.new(what: "the game's tables and its variables' starting values",
                                   fix: "make its tables shorter, or use fewer of them")
          ROUTINES = SM83::Holding.new(what: "the game's routines", fix: "make its routines shorter, or use fewer of them")

          # The label of the routine the program itself is, which the runtime calls at power-on.
          MAIN = "main"

          # The routine the game names +name+.
          def self.routine_label(name) = "routine #{name}"

          # Whether this lowering makes every step a run of +program+ can reach.
          def self.makes?(program)
            kinds = Reach.statements_from(program, *reached_routines(program)).map(&:kind)
            kinds.all? { |kind| STATEMENTS.key?(kind) || VALUES.key?(kind) || kind == :else }
          end

          def self.reached_routines(program)
            funcs = program.walk.select { |node| node.kind == :func }.to_h { |node| [node.name, node] }
            Reach.routines(program).map { |name| funcs.fetch(name) }
          end

          # Where each of the game's variables went, by its name, once #sections has placed them.
          attr_reader :variables

          def initialize(program, memory:)
            @program = program
            @memory = memory
            @funcs = program.walk.select { |node| node.kind == :func }.to_h { |node| [node.name, node] }
            @called = Reach.routines(program)
            @handover = SceneHandover.of(program)
            @scenes = program.walk.select { |node| node.kind == :case }.flat_map { |node| node.clauses.map(&:last) }
                             .uniq.each_with_index.to_h
            @variables = {}
            @locals = {} # a routine's own numbers, by the name the lowering gave each
            @starts = [] # [address, value] for a place that does not start at nought
            @routine_tables = {} # a list of routines a call picks from by number -> its table's label
          end

          # The art the game's pictures were made into: none, for a game this lowering makes so far.
          def art = @art ||= Art.new(paint_colors: nil)

          # The game's code, as sections for the Linker: its data, every routine a run can reach, and
          # the program itself.
          def sections
            refuse_color_answer_errors!
            refuse_routines_that_call_themselves!
            Reach.variables(@program).each { |name| @variables[name] = @memory.reserve("the variable #{name.inspect}", 4) }
            @scene = keep_local(:scene, start: -1) unless @scenes.empty?
            routines = @called.map { |name| routine_section(self.class.routine_label(name), @funcs.fetch(name).children) }
            main = routine_section(MAIN, @program.children)
            [data_section, *routines, main]
          end

          private

          # --- refusals ---

          # What a Color cannot do at all, refused as a game's build refuses it (Checks::ColorAnswers).
          # A program handed straight to a lowering, as a test's is, never passes the build's checks.
          def refuse_color_answer_errors!
            refused = Guardrails::Checks::ColorAnswers.new.detect(@program).find { |finding| finding.severity == :error }
            raise LoweringError, refused.message if refused
          end

          # A routine's own numbers are kept at fixed places, so a routine that can come round to
          # calling itself again would write over its own numbers while it still needs them.
          def refuse_routines_that_call_themselves!
            calls = @called.to_h { |name| [name, Reach.routines_named(Reach.statements_under(@funcs.fetch(name))).uniq & @called] }
            @called.each do |start|
              seen = []
              waiting = calls.fetch(start).dup
              until waiting.empty?
                name = waiting.shift
                if name == start
                  raise LoweringError, "the routine #{start.inspect} can call itself again before it has finished, " \
                                       "which the Game Boy Color build cannot make yet."
                end
                next if seen.include?(name)

                seen << name
                waiting.concat(calls.fetch(name))
              end
            end
          end

          # --- the data: in bank 0, where every routine can read it ---

          # The tables of routines a call picks from by number, the places that do not start at
          # nought (Runtime#emit_start reads them), and the lists' headers, none so far.
          def data_section
            asm = SM83.new("game data", home: :fixed, holds: DATA)
            @routine_tables.each do |targets, label|
              asm.label(label)
              targets.each do |name|
                routine = self.class.routine_label(name)
                asm.data_words(routine)
                asm.data_bank_of(routine)
              end
            end
            asm.label("game_starts")
            @starts.each do |address, value|
              asm.data_words(address)
              asm.data_bytes(little_endian(value, 4))
            end
            asm.data_words(0)
            asm.label("game_lists")
            asm.data_words(0)
            asm.section
          end

          def little_endian(value, size) = Array.new(size) { |i| (value >> (8 * i)) & 0xFF }

          # --- routines ---

          def routine_section(label, body)
            @asm = SM83.new(label, home: :banked, holds: ROUTINES)
            @routine = label
            @labels = 0
            @constants = {}
            @asm.label(label)
            body.each { |node| statement(node) }
            @asm.ret
            @constants.each do |value, at|
              @asm.label(at)
              @asm.data_bytes(little_endian(value, 4))
            end
            @asm.section
          end

          def fresh(what)
            @labels += 1
            "#{@routine}.#{what}#{@labels}"
          end

          # A number of the routine's own, kept in work memory, by a name of its own that a value
          # can read as a variable. +start+ is what it holds from power-on.
          def keep_local(what, start: 0)
            name = :"#{@routine || 'game'}.#{what}#{@locals.length + 1}"
            @locals[name] = @memory.reserve("the game's number #{name}", 4)
            @starts << [@locals[name], start] unless start.zero?
            name
          end

          def place_of(name)
            @variables.fetch(name) { @locals.fetch(name) { raise LoweringError, "#{name.inspect} is not a variable the program keeps" } }
          end

          # --- statements ---

          def statement(node) = send(STATEMENTS.fetch(node.kind), node)

          def emit_nothing(_node) = nil
          def emit_children(node) = node.children.each { |child| statement(child) }

          # BCDE into the variable +name+.
          def store(name)
            @asm.load(:hl, place_of(name))
            @asm.call("rt_store32")
          end

          # A variable set to itself changes nothing, so nothing is made for one.
          def emit_set(node)
            return if node.value.is_a?(Node) && node.value.kind == :var_ref && node.value.name == node.var

            value(node.value)
            store(node.var)
          end

          def emit_add(node) = emit_sum(node.var, :+, node.operand)
          def emit_sub(node) = emit_sum(node.var, :-, node.operand)

          # `x = x + n` and `x = x - n`. For a number n written in the program the four bytes of x are
          # added to where they are, a dozen instructions and no call.
          def emit_sum(name, op, operand)
            amount = folded(operand)
            return add_in_place(place_of(name), op == :- ? Int32.neg(amount) : amount) if amount

            sum_of_two(Build.var_ref(name), operand, SUMS.fetch(op))
            store(name)
          end

          def add_in_place(address, amount)
            amount &= 0xFFFF_FFFF
            @asm.load(:hl, address)
            4.times do |i|
              byte = (amount >> (8 * i)) & 0xFF
              @asm.load(:a, [:hl])
              i.zero? ? @asm.add_a(byte) : @asm.adc_a(byte)
              @asm.load(i == 3 ? [:hl] : [:hli], :a)
            end
          end

          def emit_copy(node)
            return if node.dest == node.src

            value(node.src)
            store(node.dest)
          end

          def emit_negate(node) = apply_to_variable(node.var, "rt_neg32")
          def emit_abs(node) = apply_to_variable(node.var, "rt_abs32")

          def apply_to_variable(name, routine)
            value(name)
            @asm.call(routine)
            store(name)
          end

          # -|v|: turned round only when it is above nought, so the lowest number stays itself.
          def emit_negate_abs(node)
            done = fresh("not_above_nought")
            jump_unless(Build.binop(:>, Build.var_ref(node.var), Build.int(0)), done)
            apply_to_variable(node.var, "rt_neg32")
            @asm.label(done)
          end

          def emit_clamp(node)
            sum_of_three(node.var, node.min, node.max, "rt_clamp32")
            store(node.var)
          end

          def emit_if(node)
            otherwise = node.else&.children || []
            known = folded(node.cond)
            return (known.zero? ? otherwise : node.children).each { |child| statement(child) } if known

            other = fresh("else")
            done = fresh("end_if")
            jump_unless(node.cond, other)
            node.children.each { |child| statement(child) }
            @asm.jump(done) unless otherwise.empty?
            @asm.label(other)
            otherwise.each { |child| statement(child) }
            @asm.label(done)
          end

          def emit_loop(node)
            top = fresh("loop")
            @asm.label(top)
            node.children.each { |child| statement(child) }
            @asm.jump(top)
          end

          # Reference#exec_repeat: the count worked out once, before the first pass; the index
          # counting 0, 1, 2... and stored in the game's variable at the top of each pass; and
          # +stop_when+ asked BEFORE the body, so a loop already finished on its first pass runs the
          # body no times.
          def emit_repeat(node)
            count = keep_local(:count)
            index = keep_local(:index)
            value(node.count)
            store(count)
            load_constant(0)
            store(index)
            top = fresh("repeat")
            done = fresh("end_repeat")
            @asm.label(top)
            jump_unless(Build.binop(:<, Build.var_ref(index), Build.var_ref(count)), done)
            if node.index
              value(index)
              store(node.index)
            end
            jump_if(node.stop_when, done)
            node.children.each { |child| statement(child) }
            add_in_place(place_of(index), 1)
            @asm.jump(top)
            @asm.label(done)
          end

          # A beat (`every`, `after`) is the plain statements IR::Frames says it means.
          def emit_beat(node) = Frames.beat_statements(node).each { |child| statement(child) }

          def emit_call(node)
            raise LoweringError, "the routine #{node.target.inspect} is called and never declared" unless @funcs.key?(node.target)

            call_routine(self.class.routine_label(node.target))
          end

          # Reference#exec_call_one_of: the number worked out once, and a number naming no routine of
          # the list — below nought or past its end — calls nothing. Compared as a number that cannot
          # be negative, -1 is the biggest there is, so one test guards both ends.
          def emit_call_one_of(node)
            which = keep_local(:which)
            value(node.which)
            store(which)
            none = fresh("calls_none")
            value(which)
            @asm.load(:hl, constant_label(node.targets.length))
            @asm.call("rt_cmpu32")
            @asm.cp_a(1) # below the list's length
            @asm.jump(:nz, none)
            table = @routine_tables[node.targets] ||= "routines #{@routine_tables.length + 1}"
            value(which)
            @asm.load(:h, :d)
            @asm.load(:l, :e)
            @asm.add_hl(:hl)
            @asm.add_hl(:de) # × 3, an entry being an address and a bank
            @asm.load(:de, table)
            @asm.add_hl(:de)
            @asm.call("rt_far_call_hl")
            @asm.label(none)
          end

          # Reference#exec_case: the variable read ONCE, before the first clause. A scene's usual last
          # act is to set it to the next scene, and reading it again per clause would run that one
          # too, in the same pass.
          def emit_case(node)
            state = keep_local(:state)
            value(node.var)
            store(state)
            node.clauses.each do |number, target|
              skip = fresh("next_clause")
              jump_unless(Build.binop(:==, Build.var_ref(state), Build.int(number)), skip)
              emit_scene(target)
              @asm.label(skip)
            end
          end

          # A scene taking over is remembered, so what a scene does as it arrives happens on the frame
          # it changes and not again while it stays. A scene that loads first and is handed over to has
          # that pass to itself, and its routine runs from the pass after; the scene up at power-on,
          # which nothing handed over to, runs on the first pass all the same
          # (IR::SceneHandover::Arrival#loads_first?). Before any scene, the note holds -1.
          def emit_scene(scene)
            number = @scenes.fetch(scene)
            label = self.class.routine_label(scene)
            staying = fresh("scene_staying")
            done = fresh("scene_done")
            jump_unless(Build.binop(:!=, Build.var_ref(@scene), Build.int(number)), staying)
            if @handover.arrival(scene).loads_first?
              handed_over = fresh("scene_handed_over")
              jump_unless(Build.binop(:==, Build.var_ref(@scene), Build.int(-1)), handed_over)
              load_constant(number)
              store(@scene)
              call_routine(label)
              @asm.jump(done)
              @asm.label(handed_over)
              load_constant(number)
              store(@scene)
              @asm.jump(done)
            else
              load_constant(number)
              store(@scene)
            end
            @asm.label(staying)
            call_routine(label)
            @asm.label(done)
          end

          def emit_halt(_node) = @asm.call("rg_halt")

          # The runtime ends the frame (shows it, reads the buttons, keeps time), and the frame
          # counters the program can read move on, where the interpreter moves them: a pass is one
          # frame here.
          def emit_wait_vblank(_node)
            @asm.call("rg_wait_vblank")
            add_in_place(place_of(Frames::COUNT), 1)
            value(Frames::COUNT)
            store(Frames::SEEN)
            load_constant(1)
            store(Frames::STEP)
          end

          # --- tests: jump unless one holds ---

          def jump_if(condition, label)
            known = folded(condition)
            return if known&.zero?
            return @asm.jump(label) if known

            go_on = fresh("holds_not")
            jump_unless(condition, go_on)
            @asm.jump(label)
            @asm.label(go_on)
          end

          # Jump to +label+ unless +condition+ holds. A comparison jumps on rt_cmp32's answer straight
          # away, without making a 1 or a 0 of it first.
          def jump_unless(condition, label)
            known = folded(condition)
            return (@asm.jump(label) if known.zero?) if known

            if (equal = equality_with_number(condition))
              compare_with_number(*equal)
              @asm.jump(condition.op == :== ? :nz : :z, label)
            elsif binop?(condition, :and)
              # The interpreter works both sides out; the second is skipped here when the first does
              # not hold, which is the same thing, since nothing this lowering makes can stop the game.
              jump_unless(condition.lhs, label)
              jump_unless(condition.rhs, label)
            elsif condition.is_a?(Node) && condition.kind == :binop && COMPARISONS.key?(condition.op)
              compare(condition)
              _, holds_when = COMPARISONS.fetch(condition.op)
              @asm.jump(holds_when == :z ? :nz : :z, label)
            else
              value(condition)
              @asm.call("rt_test32")
              @asm.jump(:z, label)
            end
          end

          def binop?(node, op) = node.is_a?(Node) && node.kind == :binop && node.op == op

          # A variable said to equal (or not) a number written in the program: [its place, the
          # number], or nil for any other test.
          def equality_with_number(condition)
            return nil unless binop?(condition, :==) || binop?(condition, :!=)

            left, right = condition.lhs, condition.rhs
            left, right = right, left if folded(left)
            number = folded(right)
            name = variable_named(left)
            return nil unless number && name

            [place_of(name), number & 0xFFFF_FFFF]
          end

          def variable_named(node)
            return node if node.is_a?(Symbol)

            node.name if node.is_a?(Node) && node.kind == :var_ref
          end

          # The zero flag set when the four bytes at +address+ are +number+, byte by byte, leaving at
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

          # rt_cmp32 on the two sides of a comparison, and A compared with what the comparison holds
          # on, so the zero flag says.
          def compare(node)
            with_hl_at(node.rhs) do |where|
              value(node.lhs)
              point_hl(where)
              @asm.call("rt_cmp32")
            end
            k, = COMPARISONS.fetch(node.op)
            k.zero? ? @asm.and_a(:a) : @asm.cp_a(k)
          end

          # --- values: each leaves its number in BCDE ---

          def value(operand)
            known = folded(operand)
            return load_constant(known) if known

            case operand
            when Symbol then load_variable(operand)
            when Node then send(VALUES.fetch(operand.kind), operand)
            else raise LoweringError, "cannot make #{operand.inspect} a number"
            end
          end

          def value_of_int(node) = load_constant(node.value)
          def value_of_var_ref(node) = load_variable(node.name)

          def value_of_binop(node)
            if COMPARISONS.key?(node.op)
              compare(node)
              _, holds_when = COMPARISONS.fetch(node.op)
              return @asm.call(holds_when == :z ? "rt_bool_of_z" : "rt_bool_of_nz")
            end
            return if node.op == :* && multiplied_by_power_of_two?(node)

            sum_of_two(node.lhs, node.rhs, SUMS.fetch(node.op))
          end

          def value_of_neg(node) = sum_of_one(node.operand, "rt_neg32")
          def value_of_bit_not(node) = sum_of_one(node.operand, "rt_not32")
          def value_of_absolute(node) = sum_of_one(node.operand, "rt_abs32")
          def value_of_clamped(node) = sum_of_three(node.operand, node.min, node.max, "rt_clamp32")
          def value_of_mul_fix(node) = sum_of_three(node.lhs, node.rhs, fraction_bits(node), "rt_mul_fix")
          def value_of_div_fix(node) = sum_of_three(node.lhs, node.rhs, fraction_bits(node), "rt_div_fix")
          def value_of_shift_right(node) = sum_of_two(node.operand, Build.int(node.bits), "rt_shr32")
          def value_of_held(node) = runtime_call("rg_held", [Build.int(button_number(node.button))])
          def value_of_pressed(node) = runtime_call("rg_pressed", [Build.int(button_number(node.button))])

          # How many bits of a number hold its fraction: the runtime's sums are written for 0 to 32,
          # every scale the framework uses.
          def fraction_bits(node)
            bits = node.fraction_bits
            unless bits.between?(0, 32)
              raise LoweringError, "a number with #{bits} bits of fraction is more than the Game Boy Color build can " \
                                   "work out. It can work out 0 to 32."
            end

            Build.int(bits)
          end

          # The buttons in the order the console's key register holds them (IR::Buttons::NAMES); -1
          # means any of them.
          def button_number(button)
            return -1 if button == Buttons::ANY

            Buttons::NAMES.index(button) or raise LoweringError, "unknown button #{button.inspect}"
          end

          def load_variable(name)
            @asm.load(:hl, place_of(name))
            @asm.call("rt_load32")
          end

          def load_constant(number)
            number &= 0xFFFF_FFFF
            @asm.load(:bc, number >> 16)
            @asm.load(:de, number & 0xFFFF)
          end

          # A number the routine names, kept once beside it, and the label of where.
          def constant_label(number) = @constants[number & 0xFFFF_FFFF] ||= fresh("number")

          # The number +node+ comes to when everything in it is written in the program, or nil.
          def folded(node)
            case node
            when Integer then Int32.wrap(node)
            when Node then folded_node(node)
            end
          end

          def folded_node(node)
            case node.kind
            when :int then Int32.wrap(node.value)
            when :binop
              lhs = folded(node.lhs)
              rhs = folded(node.rhs)
              lhs && rhs ? Int32.wrap(FOLDED.fetch(node.op).call(lhs, rhs)) : nil
            when :neg then folded(node.operand)&.then { |n| Int32.neg(n) }
            when :bit_not then folded(node.operand)&.then { |n| Int32.bit_not(n) }
            end
          end

          # A product by a power of two up to 16 written in the program, as shifts of the four bytes
          # a place at a time rather than the runtime's multiply. True when it was done so.
          def multiplied_by_power_of_two?(node)
            [[node.rhs, node.lhs], [node.lhs, node.rhs]].each do |by, other|
              number = folded(by)
              next unless number&.positive? && (number & (number - 1)).zero? && number <= 16

              value(other)
              number.bit_length.pred.times do
                @asm.sla(:e)
                @asm.rl(:d)
                @asm.rl(:c)
                @asm.rl(:b)
              end
              return true
            end
            false
          end

          def sum_of_one(operand, routine)
            value(operand)
            @asm.call(routine)
          end

          # The left number in BCDE and the right one at HL, for the runtime's +routine+.
          def sum_of_two(left, right, routine)
            with_hl_at(right) do |where|
              value(left)
              point_hl(where)
              @asm.call(routine)
            end
          end

          # The first number in BCDE, the second at HL and the third just past it: both pushed.
          def sum_of_three(first, second, third, routine)
            [third, second].each { |node| push_value(node) }
            value(first)
            @asm.load_hl_sp(0)
            @asm.call(routine)
            @asm.add_sp(8)
          end

          # Run the block with the number +node+ somewhere HL can be pointed at, handing it where (for
          # #point_hl): a variable or a number the routine keeps is pointed at where it is, and
          # anything else is worked out first and pushed, and taken off again after.
          def with_hl_at(node)
            known = folded(node)
            name = variable_named(node)
            where = if known then [:label, constant_label(known)]
                    elsif name then [:address, place_of(name)]
                    end
            return yield(where) if where

            push_value(node)
            yield [:stack]
            @asm.add_sp(4)
          end

          # The number +node+ worked out into BCDE and pushed, four bytes, high half first: the stack
          # then holds it as a number is kept anywhere else, lowest byte first.
          def push_value(node)
            value(node)
            @asm.push(:bc)
            @asm.push(:de)
          end

          def point_hl((kind, at)) = kind == :stack ? @asm.load_hl_sp(0) : @asm.load(:hl, at)

          # A runtime routine taking +args+, each pushed in order, the first deepest: the routine finds
          # the last of them just past its return address.
          def runtime_call(name, args)
            args.each { |arg| push_value(arg) }
            @asm.call(name)
            bytes = args.length * 4
            while bytes.positive?
              step = [bytes, 124].min
              @asm.add_sp(step)
              bytes -= step
            end
          end

          # A routine of the game's, called through bank 0, which puts its bank in view.
          def call_routine(label)
            @asm.call("rt_far_call")
            @asm.data_bank_of(label)
            @asm.data_words(label)
          end
        end
      end
    end
  end
end
