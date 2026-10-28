# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        # ONE PROGRAM, LOWERED STRAIGHT TO 65816 MACHINE CODE: the Super Nintendo's peer of the GBA
        # and Game Boy Color lowerings. It walks the IR with a table naming the method for each kind
        # of statement and each kind of value (the interpreter's own shape, Reference), and emits the
        # instructions through the assembler (W65816), calling the runtime (SNES::Runtime) for what
        # is too long to write in place.
        #
        # HOW A NUMBER IS WORKED OUT. Every value leaves its answer in R0, the first working number on
        # the direct page (Memory.register), its low half first. A sum of two works the left-hand side
        # out into R0 and takes the right-hand side from where it already is — a number written in
        # the program is part of the instruction, a variable is read where it lives — so `x + 1` is
        # six instructions and no call. A right-hand side that has to be worked out first is worked
        # out, pushed on the stack, and pulled into R1 once the left-hand side is in R0. A runtime
        # routine taking several numbers has them in R0, R1, R2... Nothing is kept in a register from
        # one statement to the next, so a statement never has to know what came before it. A and the
        # index registers are 16 bits wide throughout.
        #
        # WHERE THINGS LIVE. The game's variables, and each routine's own numbers — a loop's count, a
        # `case`'s reading — are places in the first 8K of work RAM (Memory), fixed while the program
        # is built, so a routine cannot call itself, and a program in which one can is refused. Lists
        # are in the rest of work RAM. Every routine is called with JSL and returns with RTL, so it can
        # be in any bank of the cartridge.
        #
        # It makes the kinds in its two tables, and refuses by name a program that reaches one it does
        # not make yet (NOT_LOWERED_YET) or one a Super Nintendo cannot do at all (REFUSED).
        class Lowering
          # A program refused because it reaches something the build does not make yet, with the
          # +part+ of the build that is missing ("the picture"), for a test run to count skips by.
          class NotMadeYet < LoweringError
            attr_reader :part

            def initialize(message, part:)
              super(message)
              @part = part
            end
          end

          STATEMENTS =Ractor.make_shareable({
                                               program: :emit_children, set: :emit_set, add: :emit_add,
                                               sub: :emit_sub, copy: :emit_copy, negate: :emit_negate,
                                               abs: :emit_abs, negate_abs: :emit_negate_abs, clamp: :emit_clamp,
                                               if: :emit_if, loop: :emit_loop, repeat: :emit_repeat,
                                               every: :emit_beat, after: :emit_beat, call: :emit_call,
                                               call_one_of: :emit_call_one_of, case: :emit_case,
                                               halt: :emit_halt, wait_vblank: :emit_wait_vblank,
                                               list_new: :emit_list_new, list_push: :emit_list_push,
                                               list_drop: :emit_list_drop, list_set: :emit_list_set,
                                               list_fill: :emit_list_fill, list_copy: :emit_list_copy,
                                               timer_start: :emit_timer_start, timer_stop: :emit_timer_stop,
                                               # a timer's handler runs as its timer ticks, not where it is written
                                               on_timer: :emit_nothing,
                                               # no light can be made on a Super Nintendo (REFUSED), and a game
                                               # without one works nothing out again
                                               show_light_now: :emit_nothing
                                             }.merge(Picture::STATEMENTS)
                                              .merge(Nodes.of_role(:declaration).to_h { |kind| [kind, :emit_nothing] }))

          include Picture

          VALUES = Ractor.make_shareable({
                                           int: :value_of_int, var_ref: :value_of_var_ref, binop: :value_of_binop,
                                           neg: :value_of_neg, bit_not: :value_of_bit_not,
                                           absolute: :value_of_absolute, clamped: :value_of_clamped,
                                           mul_fix: :value_of_mul_fix, div_fix: :value_of_div_fix,
                                           shift_right: :value_of_shift_right, held: :value_of_held,
                                           pressed: :value_of_pressed, list_get: :value_of_list_get,
                                           list_len: :value_of_list_len, table_get: :value_of_table_get,
                                           timer_ticks: :value_of_timer_ticks, chance: :value_of_chance
                                         })

          # EVERY KIND THIS LOWERING CANNOT MAKE YET, by what it is part of. A kind leaves the list the
          # day the Super Nintendo does it; test_snes_kind_coverage.rb holds the list and the tables
          # above to every kind there is.
          NOT_LOWERED_YET = Ractor.make_shareable({
                                                    "the picture" => %i[clear_screen fill_rect dma_fill_rect
                                                                        draw_rect_at pixel draw_text draw_digit inside
                                                                        blit blit_pose draw_column_at save_region
                                                                        restore_region place_bar background_colors
                                                                        scroll_rows camera show_picture_group
                                                                        color_list_holds fade tint pixels_overlap
                                                                        copy_tiles copy_owed_tiles data_byte],
                                                    "the sound" => %i[enable_sound beep noise wave stop_wave play_song
                                                                      stop_music play_from_list play_sound_effect
                                                                      play_sample stop_sample],
                                                    "save memory" => %i[save_init save_store save_write save_erase
                                                                        save_read save_sum]
                                                  })

          # The kinds the Super Nintendo cannot do at all, refused in the words its answers have
          # (#refuse_what_snes_lacks!): a layer seen through another by degrees, a light, a mosaic
          # over the sprites, a turned or resized background, and a clock chip.
          REFUSED = %i[see_through shade_outside pixelate affine_background set_clock clock].freeze

          # The verb whose answer (Console::SNESAnswers) says why, for each refused kind.
          REFUSED_VERBS = Ractor.make_shareable({ see_through: :layers, shade_outside: :spotlight, pixelate: :pixelate,
                                                  affine_background: :background, set_clock: :clock, clock: :clock })

          # How a table keeps its entries, by the width the game declared and whether they are
          # signed: bytes an entry, and the range that holds. Any other table keeps whole words.
          TABLE_WIDTHS = Ractor.make_shareable({ [:byte, true] => [1, -128..127], [:byte, false] => [1, 0..255],
                                                 [:half, true] => [2, -32_768..32_767], [:half, false] => [2, 0..65_535] })

          # How the runtime's list copy knows each way of keeping an entry (Runtime::Lists::KEPT), by
          # its bytes and its sign.
          TABLE_KEPT = Ractor.make_shareable({ [1, true] => :signed_byte, [1, false] => :byte, [2, true] => :signed_half,
                                               [2, false] => :half, [4, true] => :word })

          # How many bytes a slot of a list takes, by the width it was declared with.
          SLOT_BYTES = Ractor.make_shareable({ byte: 1, half: 2, word: 4, nil => 4 })

          # The runtime's routines for a binop worked out by a call, and the binops written in place.
          CALLED_SUMS = Ractor.make_shareable({ :* => "rt_mul32", :/ => "rt_div32", :% => "rt_mod32",
                                                :<< => "rt_shl32", :>> => "rt_shr32" })
          IN_PLACE_SUMS = Ractor.make_shareable({ :+ => %i[clc adc], :- => %i[sec sbc], :& => [nil, :and_a],
                                                  :| => [nil, :ora], :^ => [nil, :eor] })
          COMPARISONS = %i[< <= > >= == !=].freeze

          # What a sum or a comparison of numbers written in the program comes to, worked out here
          # rather than by the console: IR::Int32's own answer.
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
          DATA = W65816::Holding.new(what: "the game's tables", fix: "make its tables shorter, or use fewer of them")
          ROUTINES = W65816::Holding.new(what: "the game's routines", fix: "make its routines shorter, or use fewer of them")

          # The label of the routine the program itself is, which the runtime calls at power-on.
          MAIN = "main"

          R0 = Memory.register(0)
          R1 = Memory.register(1)

          # The routine the game names +name+.
          def self.routine_label(name) = "routine #{name}"

          # Where each of the game's variables went, by its name, and each of its lists — [its place,
          # its capacity, the bytes a slot, its name] — once #sections has placed them; the label of
          # the routine the runtime runs at each frame boundary, or nil for a game with no timers; and
          # each routine's section, by its label, beside what that routine is to the author.
          attr_reader :variables, :lists, :frame_begins, :section_routines

          def initialize(program, memory:)
            @program = program
            @memory = memory
            @funcs = program.walk.select { |node| node.kind == :func }.to_h { |node| [node.name, node] }
            @tick_handlers = Nodes::OnTimer.of(program)
            @timers = program.walk.filter_map do |node|
              case node.kind
              when :timer_start, :timer_stop, :timer_ticks then node.name
              when :on_timer then node.timer
              end
            end.uniq.each_with_index.to_h
            @called = Reach.routines(program, also: @tick_handlers.values)
            @reachable = Reach.statements_from(program, *@called.map { |name| @funcs.fetch(name) }, *@tick_handlers.values)
            # A list is there, empty, from power-on wherever it is declared (the interpreter gathers
            # them before running), so its storage is the first declaration's.
            @declared_lists = @reachable.reverse.select { |node| node.kind == :list_new }.to_h { |node| [node.name, node] }
            @tables = program.walk.select { |node| node.kind == :table }.to_h { |node| [node.name, node] }
            @lists = {}
            @handover = SceneHandover.of(program)
            @scenes = program.walk.select { |node| node.kind == :case }.flat_map { |node| node.clauses.map(&:last) }
                             .uniq.each_with_index.to_h
            @variables = {}
            @locals = {} # a routine's own numbers, by the name the lowering gave each
            @starts = [] # [address, value] for a place that does not start at nought
            @routine_tables = {} # a list of routines a call picks from by number -> its table's label
            @section_routines = {}
            prepare_picture
          end

          # The game's code, as sections for the Linker: its data, every routine a run can reach, and
          # the program itself.
          def sections
            refuse_unlowered_kinds!
            refuse_what_snes_lacks!
            refuse_routines_that_call_themselves!
            refuse_unmade_picture!
            Reach.variables(@program).each { |name| @variables[name] = @memory.reserve("the variable #{name.inspect}", 4) }
            @declared_lists.each_value do |node|
              width = SLOT_BYTES.fetch(node.width)
              place = @memory.reserve_far("the list #{node.name.inspect}", Runtime::Lists::HEADER + (node.capacity * width))
              @lists[node.name] = [place, node.capacity, width, node.name.to_s]
            end
            @scene = keep_local(:scene, start: -1) unless @scenes.empty?
            keep_timer_numbers
            routines = @called.map do |name|
              routine_section(self.class.routine_label(name), @funcs.fetch(name).children, routine: routine_said(name))
            end
            timers = timer_sections
            main = routine_section(MAIN, @program.children, routine: "the game loop")
            [data_section, *table_sections, *routines, *timers, main]
          end

          private

          # --- refusals ---

          # What a run can reach and this lowering cannot make, refused by name before anything is
          # made: a step that only means something on the Advance, and one the Super Nintendo build
          # does not make yet. A step in a routine nothing calls never runs, and is not refused.
          def refuse_unlowered_kinds!
            kinds = @reachable.map(&:kind).uniq
            hardware = kinds.select { |kind| Portability.hardware_only?(kind) }
            unless hardware.empty?
              raise LoweringError, "This game uses #{hardware.map(&:inspect).join(', ')}, which only means something " \
                                   "on the Game Boy Advance. The Super Nintendo build cannot make it. To fix this, " \
                                   "build the game for the Game Boy Advance alone."
            end

            missing = NOT_LOWERED_YET.select { |_, listed| listed.intersect?(kinds) }
            return if missing.empty?

            uses = missing.values.flatten & kinds
            raise NotMadeYet.new(
              "This game uses #{uses.map(&:inspect).join(', ')}, part of #{missing.keys.join(' and ')}. The Super " \
              "Nintendo build does not make that yet. To fix this, build the game for the Game Boy Advance alone " \
              "for now (`consoles: %i[gba]`).", part: missing.keys.join(" and ")
            )
          end

          # What a Super Nintendo cannot do at all, and the layers one screen cannot have, refused as a
          # game's build refuses them (Checks::ConsoleAnswers, Checks::LayerRefusals). A program
          # handed straight to a lowering, as a test's is, never passes the build's checks; and one
          # that names no console, or another, is asked about as the Super Nintendo's.
          def refuse_what_snes_lacks!
            asked = @program.console == :snes ? @program : @program.copy.tap { |copy| copy.console = :snes }
            refused = Guardrails::Checks::ConsoleAnswers.new.detect(asked).find { |finding| finding.severity == :error }
            refusal = refused&.message || Guardrails::Checks::LayerRefusals.message(asked)
            raise LoweringError, refusal if refusal

            lacking = REFUSED & @reachable.map(&:kind)
            return if lacking.empty?

            verb = REFUSED_VERBS.fetch(lacking.first)
            raise LoweringError, "This game uses `#{verb}`, and a Super Nintendo cannot: " \
                                 "#{Console::SNESAnswers.answer(verb).words}"
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
                  raise LoweringError, "The routine #{start.inspect} can call itself again before it has finished. The Super " \
                                       "Nintendo build cannot make that yet. To fix this, count with a loop in the routine instead."
                end
                next if seen.include?(name)

                seen << name
                waiting.concat(calls.fetch(name))
              end
            end
          end

          # --- the data ---

          # The places that do not start at nought, each list's place, capacity and slot (the
          # runtime's start reads them), and the tables of routines a call picks from by number.
          def data_section
            asm = W65816.new("game data", holds: DATA)
            asm.label("game_starts")
            @starts.each do |address, value|
              asm.data_words(address, value & 0xFFFF, (value >> 16) & 0xFFFF)
            end
            asm.data_words(0)
            asm.label("game_lists")
            @lists.each_value do |place, capacity, width, _|
              asm.data_bytes(place & 0xFF, (place >> 8) & 0xFF, place >> 16)
              asm.data_words(capacity, width)
            end
            asm.data_bytes(0, 0, 0)
            @routine_tables.each do |targets, label|
              asm.label(label)
              asm.data_longs(targets.map { |name| self.class.routine_label(name) })
            end
            asm.section
          end

          # Each table a run reads, in a section of its own, so a long one gets a bank to itself.
          def table_sections
            tables_read.map do |table|
              asm = W65816.new(table_label(table.name), holds: DATA)
              asm.label(table_label(table.name))
              bytes, = table_keeping(table)
              asm.data_bytes(table.values.flat_map { |entry| little_endian(Int32.wrap(entry), bytes) })
              asm.section
            end
          end

          def tables_read
            read = @reachable.filter_map do |node|
              case node.kind
              when :table_get then node.name
              when :list_copy then node.table
              end
            end
            @tables.values.select { |table| read.include?(table.name) }
          end

          def table_label(name) = "table #{name}"

          # How +table+ keeps its entries — [bytes an entry, whether signed] — as the cartridge keeps
          # it: at the width the game declared when every entry fits it, and whole words otherwise.
          def table_keeping(table)
            signed = table.signed ? true : false
            bytes, range = TABLE_WIDTHS[[table.width, signed]]
            return [bytes, signed] if bytes && table.values.all? { |entry| range.cover?(Int32.wrap(entry)) }

            [4, true]
          end

          def little_endian(value, size) = Array.new(size) { |i| (value >> (8 * i)) & 0xFF }

          # --- routines ---

          # A routine of +body+'s statements, or of what the block emits for one this lowering makes
          # for itself. +routine+ is what it is to the author.
          def routine_section(label, body, routine:)
            @section_routines[label] = routine
            @asm = W65816.new(label, holds: ROUTINES)
            @routine = label
            @labels = 0
            @asm.label(label)
            body.each { |node| statement(node) }
            yield if block_given?
            @asm.rtl
            @asm.section
          end

          # A routine of the game's, as the author names it: a scene as one.
          def routine_said(name) = @scenes.key?(name) ? "scene #{name.inspect}" : name.to_s

          def fresh(what)
            @labels += 1
            "#{@routine}.#{what}#{@labels}"
          end

          # A number of the routine's own, kept in work RAM, by a name of its own that a value can
          # read as a variable. +start+ is what it holds from power-on.
          def keep_local(what, start: 0)
            name = :"#{@routine || 'game'}.#{what}#{@locals.length + 1}"
            @locals[name] = @memory.reserve("the game's number #{name}", 4)
            @starts << [@locals[name], start] unless start.zero?
            name
          end

          def place_of(name)
            @variables.fetch(name) { @locals.fetch(name) { raise LoweringError, "#{name.inspect} is not a variable the program keeps" } }
          end

          # A routine of the game's, or the runtime's, called wherever it is.
          def call_routine(label) = @asm.jsl(@asm.long(label))

          # --- statements ---

          def statement(node) = send(STATEMENTS.fetch(node.kind), node)

          def emit_nothing(_node) = nil
          def emit_children(node) = node.children.each { |child| statement(child) }

          # R0 into the variable +name+.
          def store(name)
            at = place_of(name)
            @asm.lda(@asm.direct(R0))
            @asm.sta(@asm.abs(at))
            @asm.lda(@asm.direct(R0 + 2))
            @asm.sta(@asm.abs(at + 2))
          end

          # A variable set to itself changes nothing, so nothing is made for one.
          def emit_set(node)
            return if node.value.is_a?(Node) && node.value.kind == :var_ref && node.value.name == node.var

            known = folded(node.value)
            return store_number(place_of(node.var), known) if known

            value(node.value)
            store(node.var)
          end

          # A number written in the program, straight into the variable at +at+.
          def store_number(at, number)
            number &= 0xFFFF_FFFF
            [number & 0xFFFF, number >> 16].each_with_index do |half, i|
              if half.zero?
                @asm.stz(@asm.abs(at + (2 * i)))
              else
                @asm.lda(half)
                @asm.sta(@asm.abs(at + (2 * i)))
              end
            end
          end

          def emit_add(node) = emit_sum(node.var, :+, node.operand)
          def emit_sub(node) = emit_sum(node.var, :-, node.operand)

          # `x = x + n` and `x = x - n`, added where x is when n is a number written in the program or
          # a variable: six instructions and no call.
          def emit_sum(name, op, operand)
            right = operand_halves(operand)
            unless right
              value(Build.binop(op, Build.var_ref(name), operand))
              return store(name)
            end

            at = place_of(name)
            carry, sum = IN_PLACE_SUMS.fetch(op)
            @asm.public_send(carry)
            2.times do |i|
              @asm.lda(@asm.abs(at + (2 * i)))
              @asm.public_send(sum, right[i])
              @asm.sta(@asm.abs(at + (2 * i)))
            end
          end

          def emit_copy(node)
            return if node.dest == node.src

            value(node.src)
            store(node.dest)
          end

          def emit_negate(node)
            value(node.var)
            emit_negate_r0
            store(node.var)
          end

          def emit_abs(node)
            value(Build.absolute(Build.var_ref(node.var)))
            store(node.var)
          end

          # -|v|: turned round only when it is above nought, so the lowest number stays itself.
          def emit_negate_abs(node)
            done = fresh("not_above_nought")
            jump_unless(Build.binop(:>, Build.var_ref(node.var), Build.int(0)), done)
            emit_negate(node)
            @asm.label(done)
          end

          def emit_clamp(node)
            value(Build.clamped(Build.var_ref(node.var), node.min, node.max))
            store(node.var)
          end

          def emit_if(node)
            body = node.children
            otherwise = node.else&.children || []
            known = folded(node.cond)
            return (known.zero? ? otherwise : body).each { |child| statement(child) } if known

            other = fresh("else")
            done = fresh("end_if")
            jump_unless(node.cond, other)
            body.each { |child| statement(child) }
            @asm.brl(done) unless otherwise.empty?
            @asm.label(other)
            otherwise.each { |child| statement(child) }
            @asm.label(done)
          end

          def emit_loop(node)
            top = fresh("loop")
            @asm.label(top)
            node.children.each { |child| statement(child) }
            @asm.brl(top)
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
            store_number(place_of(index), 0)
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
            emit_sum(index, :+, Build.int(1))
            @asm.brl(top)
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
          # be negative, -1 is the biggest there is, so one test guards both ends. The routine is
          # reached through a table of their long addresses: its address pushed as RTL would find a
          # return address (one less, bank first), and RTL taken to it.
          def emit_call_one_of(node)
            table = @routine_tables[node.targets] ||= "routines #{@routine_tables.length + 1}"
            none = fresh("calls_none")
            back = fresh("called")
            value(node.which)
            @asm.lda(@asm.direct(R0 + 2))
            @asm.branch_long(:bne, none)
            @asm.lda(@asm.direct(R0))
            @asm.cmp(node.targets.length)
            @asm.branch_long(:bcs, none)
            @asm.asl # × 3: an entry is three bytes
            @asm.adc(@asm.direct(R0)) # the carry is clear: the index is below the list's length
            @asm.tax
            # Where the called routine's RTL comes back to: the instruction after the RTL below.
            @asm.phk
            @asm.pea(@asm.abs(back, -1))
            @asm.sep(0x20)
            @asm.lda(@asm.long_x(table, 2))
            @asm.pha
            @asm.rep(0x20)
            @asm.lda(@asm.long_x(table))
            @asm.dec
            @asm.pha
            @asm.rtl
            @asm.label(back)
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
              at_power_on = keep_local(:at_power_on)
              value(Build.binop(:==, Build.var_ref(@scene), Build.int(-1)))
              store(at_power_on)
              emit_scene_number(number)
              jump_unless(Build.var_ref(at_power_on), done)
              call_routine(label)
              @asm.brl(done)
            else
              emit_scene_number(number)
            end
            @asm.label(staying)
            call_routine(label)
            @asm.label(done)
          end

          # The note of the scene running now, set to +number+.
          def emit_scene_number(number) = store_number(place_of(@scene), number)

          def emit_halt(_node) = @asm.jml(@asm.long("rt_halt"))

          # The runtime ends the frame (shows it, reads the buttons, keeps time), and the frame
          # counters the program can read move on, where the interpreter moves them
          # (Reference#store_frame_counters): the frames shown by every frame the pass took, and what
          # the game catches up by held at the cap, both as the runtime counted them.
          def emit_wait_vblank(_node)
            call_routine("rt_wait_vblank")
            count = place_of(Frames::COUNT)
            @asm.clc
            @asm.lda(@asm.abs(count))
            @asm.adc(@asm.abs(@memory[Runtime::Frame::FRAMES_TAKEN]))
            @asm.sta(@asm.abs(count))
            @asm.lda(@asm.abs(count + 2))
            @asm.adc(0)
            @asm.sta(@asm.abs(count + 2))
            step = place_of(Frames::STEP)
            @asm.lda(@asm.abs(@memory[Runtime::Frame::STEP_TAKEN]))
            @asm.sta(@asm.abs(step))
            @asm.stz(@asm.abs(step + 2))
            value(Frames::COUNT)
            store(Frames::SEEN)
          end

          # --- lists (Runtime::Lists does the work and the checking) ---

          # Reference::ListValue.of: empty, or holding its capacity of the one number it is full of.
          def emit_list_new(node)
            return list_call("rt_list_empty", node) unless node.full_of

            list_call("rt_list_at_capacity", node)
            list_call("rt_list_fill", node, Build.int(0), Build.int(node.capacity), Build.int(node.full_of))
          end
          def emit_list_push(node) = list_call("rt_list_push", node, node.value)
          def emit_list_drop(node) = list_call("rt_list_drop", node, Build.int(node.from == :front ? 1 : 0))
          def emit_list_fill(node) = list_call("rt_list_fill", node, node.from, node.count, node.value)
          def emit_list_set(node) = list_call("rt_list_set", node, node.index, node.value)
          def value_of_list_get(node) = list_call("rt_list_get", node, node.index)
          def value_of_list_len(node) = list_call("rt_list_length", node)

          # A run of a table's entries copied into a list: the table's place and how it keeps its
          # entries, so the runtime reads them as a run does.
          def emit_list_copy(node)
            table = @tables.fetch(node.table) { raise LoweringError, "the table #{node.table.inspect} is copied and never declared" }
            kept = Runtime::Lists::KEPT.fetch(TABLE_KEPT.fetch(table_keeping(table)))
            list_call("rt_list_copy", node, LongAddress.new(table_label(table.name)), Build.int(kept),
                      Build.int(table.values.length), node.at, Build.int(node.count))
          end

          # The runtime's list routine +routine+ on the list +node+ names, the list's place first.
          def list_call(routine, node, *args)
            place, = @lists.fetch(node.name) { raise LoweringError, "the list #{node.name.inspect} is used and never declared" }
            runtime_call(routine, [Build.int(place), *args])
          end

          # Reference#exec_table_get: an index out of range made safe — a table whose length is a
          # power of two wraps it (what an angle wants), any other holds it to the ends. The entry is
          # read with a long address and X as the index, so the table can be in any bank.
          def value_of_table_get(node)
            table = @tables.fetch(node.name) { raise LoweringError, "the table #{node.name.inspect} is read and never declared" }
            count = table.values.length
            safe = if count.positive? && (count & (count - 1)).zero?
                     Build.binop(:&, node.index, Build.int(count - 1))
                   else
                     Build.clamped(node.index, Build.int(0), Build.int(count - 1))
                   end
            bytes, signed = table_keeping(table)
            value(safe)
            @asm.lda(@asm.direct(R0))
            (bytes / 2).times { @asm.asl }
            @asm.tax
            label = table_label(table.name)
            @asm.lda(@asm.long_x(label))
            @asm.sta(@asm.direct(R0))
            if bytes == 4
              @asm.lda(@asm.long_x(label, 2))
              @asm.sta(@asm.direct(R0 + 2))
            else
              emit_widen_r0(bytes, signed)
            end
          end

          # The low +bytes+ (1 or 2) of R0 made a whole number, with its sign or not.
          def emit_widen_r0(bytes, signed)
            done = fresh("widened")
            if bytes == 1
              @asm.lda(@asm.direct(R0))
              @asm.and_a(0x00FF)
              @asm.sta(@asm.direct(R0))
            end
            @asm.stz(@asm.direct(R0 + 2))
            return @asm.label(done) unless signed

            @asm.lda(@asm.direct(R0))
            @asm.cmp(bytes == 1 ? 0x0080 : 0x8000)
            @asm.bcc(done)
            if bytes == 1
              @asm.ora(0xFF00)
              @asm.sta(@asm.direct(R0))
            end
            @asm.dec(@asm.direct(R0 + 2))
            @asm.label(done)
          end

          # --- timers ---
          #
          # A timer (`timer :beat, per_second: 10`) ticks so many times a second whatever the game is
          # doing, and runs what the game said to do on each tick. A frame is the interpreter's
          # sixtieth of a second, so at every frame boundary a running timer gains its rate in
          # sixtieths of a tick, and each whole tick that comes to is a tick (Reference#accrue_timer).
          # Each timer keeps when it was first started (nought for never), since timers move on in the
          # order they were first started; whether it is running; its rate as whole ticks and
          # sixtieths a frame; the sixtieths of a tick it is through; and its whole ticks, coming
          # round at 65536 as the interpreter's count does.

          TIMER_NUMBERS = %i[order running whole_rate part_rate parts ticks].freeze
          FRAMES_A_SECOND = Reference::FRAME_RATE

          def keep_timer_numbers
            return if @timers.empty?

            @timer_numbers = @timers.values.to_h { |number| [number, TIMER_NUMBERS.to_h { |what| [what, keep_local(:"timer#{number}_#{what}")] }] }
            @timers_started = keep_local(:timers_started)
            @timer_crossed = keep_local(:timer_crossed)
          end

          def timer_number(name, what) = @timer_numbers.fetch(@timers.fetch(name)).fetch(what)

          # Reference#exec_timer_start: running at its rate, its count from nought — and, the first
          # time, given its place in the order the timers move on in.
          def emit_timer_start(node)
            order = timer_number(node.name, :order)
            started = fresh("started_before")
            jump_unless(Build.binop(:==, Build.var_ref(order), Build.int(0)), started)
            emit_sum(@timers_started, :+, Build.int(1))
            value(@timers_started)
            store(order)
            @asm.label(started)
            whole, part = node.hz.divmod(FRAMES_A_SECOND)
            { running: 1, whole_rate: whole, part_rate: part, parts: 0, ticks: 0 }.each do |what, number|
              store_number(place_of(timer_number(node.name, what)), number)
            end
          end

          # Reference#exec_timer_stop: its count is kept.
          def emit_timer_stop(node) = store_number(place_of(timer_number(node.name, :running)), 0)

          # Reference#timer_ticks: nought for a timer never started, which is what its count starts at.
          def value_of_timer_ticks(node) = value(timer_number(node.name, :ticks))

          # THE ROUTINES THE RUNTIME RUNS AT EACH FRAME BOUNDARY: one that moves every running timer
          # on, in the order the timers were first started, and one for each timer, which moves it on
          # and runs its handler. None for a game with no timers.
          def timer_sections
            return [] if @timers.empty?

            each_timer = @timers.map { |name, _| timer_section(name) }
            @frame_begins = "timers frame"
            in_order = routine_section(@frame_begins, [], routine: "the timers") do
              (1..@timers.size).each do |place_in_order|
                @timers.each_key do |name|
                  skip = fresh("not_this_one")
                  jump_unless(Build.binop(:==, Build.var_ref(timer_number(name, :order)), Build.int(place_in_order)), skip)
                  jump_unless(Build.var_ref(timer_number(name, :running)), skip)
                  call_routine(timer_label(name))
                  @asm.label(skip)
                end
              end
            end
            [*each_timer, in_order]
          end

          def timer_label(name) = "timer #{name} frame"

          # One timer, a frame on: its sixtieths, the whole ticks they come to, and its handler run
          # once for each. How many that is is settled before the first of them runs, so a handler
          # that stops or restarts its own timer still finishes the ticks this frame crossed.
          def timer_section(name)
            parts = timer_number(name, :parts)
            ticks = timer_number(name, :ticks)
            sixtieths = Build.binop(:+, Build.var_ref(parts), Build.var_ref(timer_number(name, :part_rate)))
            rate = Build.int(FRAMES_A_SECOND)
            routine_section(timer_label(name), [], routine: "timer #{name.inspect}") do
              value(Build.binop(:+, Build.var_ref(timer_number(name, :whole_rate)), Build.binop(:/, sixtieths, rate)))
              store(@timer_crossed)
              value(Build.binop(:%, sixtieths, rate))
              store(parts)
              value(Build.binop(:&, Build.binop(:+, Build.var_ref(ticks), Build.var_ref(@timer_crossed)), Build.int(0xFFFF)))
              store(ticks)
              handler = @tick_handlers[name]
              if handler
                top = fresh("tick")
                done = fresh("ticks_done")
                @asm.label(top)
                jump_unless(Build.binop(:>, Build.var_ref(@timer_crossed), Build.int(0)), done)
                handler.children.each { |child| statement(child) }
                emit_sum(@timer_crossed, :-, Build.int(1))
                @asm.brl(top)
                @asm.label(done)
              end
            end
          end

          # --- tests: jump unless one holds ---

          def jump_if(condition, label)
            known = folded(condition)
            return if known&.zero?
            return @asm.brl(label) if known

            go_on = fresh("holds_not")
            jump_unless(condition, go_on)
            @asm.brl(label)
            @asm.label(go_on)
          end

          # Jump to +label+ unless +condition+ holds. A comparison jumps on the flags it leaves, without
          # making a 1 or a 0 of it first.
          def jump_unless(condition, label)
            known = folded(condition)
            return (@asm.brl(label) if known.zero?) if known

            if binop?(condition, :and)
              # The interpreter works both sides out; the second is skipped here when the first does
              # not hold, which is the same thing, since working a side out changes nothing.
              jump_unless(condition.lhs, label)
              jump_unless(condition.rhs, label)
            elsif condition.is_a?(Node) && condition.kind == :binop && COMPARISONS.include?(condition.op)
              @asm.branch_long(compare(condition), label)
            else
              value(condition)
              @asm.lda(@asm.direct(R0))
              @asm.ora(@asm.direct(R0 + 2))
              @asm.branch_long(:beq, label)
            end
          end

          def binop?(node, op) = node.is_a?(Node) && node.kind == :binop && node.op == op

          # The two sides of a comparison compared, and the branch that is taken when it does NOT hold.
          #
          # Equal or not: the low halves compared and, when they match, the high halves; the zero flag
          # says. Less or more: the left subtracted from the right or the right from the left, the low
          # halves with CMP and the high halves with SBC and the borrow from the first, which leaves
          # the sign of the difference in the negative flag — unless the subtraction overflowed, in
          # which case the sign came out the wrong way round and is flipped back.
          def compare(node)
            op = node.op
            left, right = %i[> <=].include?(op) ? [node.rhs, node.lhs] : [node.lhs, node.rhs]
            with_right_halves(left, right) do |halves|
              if %i[== !=].include?(op)
                differ = fresh("differ")
                @asm.lda(@asm.direct(R0))
                @asm.cmp(halves[0])
                @asm.bne(differ)
                @asm.lda(@asm.direct(R0 + 2))
                @asm.cmp(halves[1])
                @asm.label(differ)
              else
                signed = fresh("signed")
                @asm.lda(@asm.direct(R0))
                @asm.cmp(halves[0])
                @asm.lda(@asm.direct(R0 + 2))
                @asm.sbc(halves[1])
                @asm.bvc(signed)
                @asm.eor(0x8000)
                @asm.label(signed)
              end
            end
            # The negative flag now says left < right, where for > and <= the two were swapped.
            { :== => :bne, :!= => :beq, :< => :bpl, :> => :bpl, :>= => :bmi, :<= => :bmi }.fetch(op)
          end

          # --- values: each leaves its number in R0 ---

          # A value the lowering makes for itself beside the IR's: where a label is, all 24 bits.
          LongAddress = Data.define(:label)

          def value(operand)
            known = folded(operand)
            return load_constant(known) if known

            case operand
            when Symbol then load_variable(operand)
            when Node then send(VALUES.fetch(operand.kind), operand)
            when LongAddress then load_long_address(operand.label)
            else raise LoweringError, "cannot make #{operand.inspect} a number"
            end
          end

          def load_long_address(label)
            @asm.lda(@asm.imm(label))
            @asm.sta(@asm.direct(R0))
            @asm.lda(@asm.bank_of(label))
            @asm.and_a(0x00FF)
            @asm.sta(@asm.direct(R0 + 2))
          end

          def value_of_int(node) = load_constant(node.value)
          def value_of_var_ref(node) = load_variable(node.name)

          def value_of_binop(node)
            return value_of_comparison(node) if COMPARISONS.include?(node.op)
            return value_of_both_or_either(node) if %i[and or].include?(node.op)
            return if node.op == :* && multiplied_by_power_of_two?(node)

            if (routine = CALLED_SUMS[node.op])
              return runtime_call(routine, [node.lhs, node.rhs])
            end

            carry, sum = IN_PLACE_SUMS.fetch(node.op)
            with_right_halves(node.lhs, node.rhs) do |halves|
              @asm.public_send(carry) if carry
              2.times do |i|
                @asm.lda(@asm.direct(R0 + (2 * i)))
                @asm.public_send(sum, halves[i])
                @asm.sta(@asm.direct(R0 + (2 * i)))
              end
            end
          end

          # A comparison as a 1 when it holds and a 0 when it does not.
          def value_of_comparison(node)
            fails = fresh("fails")
            done = fresh("compared")
            @asm.branch_long(compare(node), fails)
            @asm.lda(1)
            @asm.bra(done)
            @asm.label(fails)
            @asm.lda(0)
            @asm.label(done)
            @asm.sta(@asm.direct(R0))
            @asm.stz(@asm.direct(R0 + 2))
          end

          # `and` and `or` work both sides out, as the interpreter does, and give a 1 or a 0.
          def value_of_both_or_either(node)
            with_right_halves(node.lhs, node.rhs) do |halves|
              emit_truth_of_halves(halves, R0 + 4)
              emit_truth_of_halves([@asm.direct(R0), @asm.direct(R0 + 2)], R0)
              @asm.lda(@asm.direct(R0))
              @asm.public_send(node.op == :and ? :and_a : :ora, @asm.direct(R0 + 4))
              @asm.sta(@asm.direct(R0))
              @asm.stz(@asm.direct(R0 + 2))
            end
          end

          # The word at the direct page address +at+ made 1 when the number in +halves+ is not nought,
          # and 0 when it is.
          def emit_truth_of_halves(halves, at)
            nought = fresh("nought")
            @asm.lda(halves[0])
            @asm.ora(halves[1])
            @asm.beq(nought)
            @asm.lda(1)
            @asm.label(nought)
            @asm.sta(@asm.direct(at))
          end

          def value_of_neg(node)
            value(node.operand)
            emit_negate_r0
          end

          def value_of_bit_not(node)
            value(node.operand)
            [R0, R0 + 2].each do |at|
              @asm.lda(@asm.direct(at))
              @asm.eor(0xFFFF)
              @asm.sta(@asm.direct(at))
            end
          end

          def value_of_absolute(node)
            done = fresh("positive")
            value(node.operand)
            @asm.lda(@asm.direct(R0 + 2))
            @asm.bpl(done)
            emit_negate_r0
            @asm.label(done)
          end

          # Reference#clamp_value: held at the floor, then at the ceiling.
          def value_of_clamped(node)
            value(node.operand)
            [[node.min, :<], [node.max, :>]].each do |bound, op|
              halves = operand_halves(bound)
              unless halves
                # The bound worked out with the number so far kept on the stack, then into R1.
                @asm.pei(@asm.direct(R0 + 2))
                @asm.pei(@asm.direct(R0))
                value(bound)
                [0, 2].each do |half|
                  @asm.lda(@asm.direct(R0 + half))
                  @asm.sta(@asm.direct(R1 + half))
                end
                pull_into(R0)
                halves = [@asm.direct(R1), @asm.direct(R1 + 2)]
              end
              within = fresh("within")
              emit_compare_r0(op, halves, within)
              @asm.lda(halves[0])
              @asm.sta(@asm.direct(R0))
              @asm.lda(halves[1])
              @asm.sta(@asm.direct(R0 + 2))
              @asm.label(within)
            end
          end

          # A jump to +within+ unless R0 +op+ (< or >) the number in +halves+.
          def emit_compare_r0(op, halves, within)
            signed = fresh("signed")
            if op == :<
              @asm.lda(@asm.direct(R0))
              @asm.cmp(halves[0])
              @asm.lda(@asm.direct(R0 + 2))
              @asm.sbc(halves[1])
            else
              @asm.lda(halves[0])
              @asm.cmp(@asm.direct(R0))
              @asm.lda(halves[1])
              @asm.sbc(@asm.direct(R0 + 2))
            end
            @asm.bvc(signed)
            @asm.eor(0x8000)
            @asm.label(signed)
            @asm.branch_long(:bpl, within)
          end

          def value_of_mul_fix(node) = runtime_call("rt_mul_fix", [node.lhs, node.rhs, fraction_bits(node)])
          def value_of_div_fix(node) = runtime_call("rt_div_fix", [node.lhs, node.rhs, fraction_bits(node)])
          def value_of_shift_right(node) = runtime_call("rt_shr32", [node.operand, Build.int(node.bits)])

          # A chance holds when the random draw lands below the threshold.
          def value_of_chance(node) = value(Build.binop(:<, node.draw, Build.int(node.percent)))

          # How many bits of a number hold its fraction: the runtime's sums are written for 0 to 32,
          # every scale the framework uses.
          def fraction_bits(node)
            bits = node.fraction_bits
            unless bits.between?(0, 32)
              raise LoweringError, "a number with #{bits} bits of fraction is more than the Super Nintendo build can " \
                                   "work out. It can work out 0 to 32."
            end

            Build.int(bits)
          end

          # The buttons held, or pressed, through the pass: a bit each, in IR::Buttons's order, and
          # any of them for Buttons::ANY.
          def value_of_held(node) = emit_button_truth(Runtime::Frame::HELD, node.button)
          def value_of_pressed(node) = emit_button_truth(Runtime::Frame::PRESSED, node.button)

          def emit_button_truth(which, button)
            mask = if button == Buttons::ANY
                     (1 << Buttons::NAMES.length) - 1
                   else
                     1 << (Buttons::NAMES.index(button) or raise LoweringError, "unknown button #{button.inspect}")
                   end
            nought = fresh("not_down")
            @asm.lda(@asm.abs(@memory[which]))
            @asm.and_a(mask)
            @asm.beq(nought)
            @asm.lda(1)
            @asm.label(nought)
            @asm.sta(@asm.direct(R0))
            @asm.stz(@asm.direct(R0 + 2))
          end

          def load_variable(name)
            at = place_of(name)
            @asm.lda(@asm.abs(at))
            @asm.sta(@asm.direct(R0))
            @asm.lda(@asm.abs(at + 2))
            @asm.sta(@asm.direct(R0 + 2))
          end

          def load_constant(number)
            number &= 0xFFFF_FFFF
            [number & 0xFFFF, number >> 16].each_with_index do |half, i|
              if half.zero?
                @asm.stz(@asm.direct(R0 + (2 * i)))
              else
                @asm.lda(half)
                @asm.sta(@asm.direct(R0 + (2 * i)))
              end
            end
          end

          # R0 turned round: every bit flipped and one added, as two halves with a borrow between them.
          def emit_negate_r0
            @asm.sec
            [R0, R0 + 2].each do |at|
              @asm.lda(0)
              @asm.sbc(@asm.direct(at))
              @asm.sta(@asm.direct(at))
            end
          end

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
            when :clamped then folded_clamp(node)
            end
          end

          def folded_clamp(node)
            number, floor, ceiling = [node.operand, node.min, node.max].map { |part| folded(part) }
            return nil unless number && floor && ceiling

            [[number, floor].max, ceiling].min
          end

          def variable_named(node)
            return node if node.is_a?(Symbol)

            node.name if node.is_a?(Node) && node.kind == :var_ref
          end

          # Where the two halves of +node+ can be read without working anything out: the number itself
          # for one written in the program, the variable's place for a variable; or nil.
          def operand_halves(node)
            known = folded(node)
            return [@asm.imm(known & 0xFFFF), @asm.imm((known >> 16) & 0xFFFF)] if known

            name = variable_named(node)
            return nil unless name

            at = place_of(name)
            [@asm.abs(at), @asm.abs(at + 2)]
          end

          # The left side worked out into R0, and the block handed where the two halves of the right
          # side are: in place when it needs nothing worked out, and otherwise worked out first,
          # pushed, and pulled into R1 once the left side is in R0.
          def with_right_halves(left, right)
            halves = operand_halves(right)
            if halves
              value(left)
              return yield(halves)
            end

            push_value(right)
            value(left)
            pull_into(R1)
            yield [@asm.direct(R1), @asm.direct(R1 + 2)]
          end

          # The number +node+ worked out into R0 and pushed, high half first, so the stack holds it
          # low half on top.
          def push_value(node)
            value(node)
            @asm.pei(@asm.direct(R0 + 2))
            @asm.pei(@asm.direct(R0))
          end

          def pull_into(at)
            @asm.pla
            @asm.sta(@asm.direct(at))
            @asm.pla
            @asm.sta(@asm.direct(at + 2))
          end

          # A product by a power of two up to 16 written in the program, as shifts of the two halves —
          # none at all for a product by one. True when it was done so.
          def multiplied_by_power_of_two?(node)
            [[node.rhs, node.lhs], [node.lhs, node.rhs]].each do |by, other|
              number = folded(by)
              next unless number&.positive? && (number & (number - 1)).zero? && number <= 16

              value(other)
              number.bit_length.pred.times do
                @asm.asl(@asm.direct(R0))
                @asm.rol(@asm.direct(R0 + 2))
              end
              return true
            end
            false
          end

          # A runtime routine taking +args+ in R0, R1, R2... Each that needs working out is worked out
          # in order and pushed, then they are pulled into their working numbers, the last first; then
          # the ones that are only a number or a variable are put in theirs.
          def runtime_call(name, args)
            worked = args.each_index.reject { |i| operand_halves(args[i]) }
            worked.each { |i| push_value(args[i]) }
            worked.reverse_each { |i| pull_into(Memory.register(i)) }
            args.each_with_index do |arg, i|
              next if worked.include?(i)

              halves = operand_halves(arg)
              2.times do |half|
                if halves[half].mode == :imm && halves[half].value.zero?
                  @asm.stz(@asm.direct(Memory.register(i) + (2 * half)))
                else
                  @asm.lda(halves[half])
                  @asm.sta(@asm.direct(Memory.register(i) + (2 * half)))
                end
              end
            end
            call_routine(name)
          end
        end
      end
    end
  end
end
