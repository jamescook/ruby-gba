# frozen_string_literal: true

module VBlank
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
        # It makes the kinds in its two tables, and refuses by name a program that reaches one it does
        # not make yet (NOT_LOWERED_YET) or one a Color cannot do at all (REFUSED).
        class Lowering
          STATEMENTS = Ractor.make_shareable({
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
                                               save_init: :emit_save_init, save_store: :emit_save_store,
                                               save_write: :emit_save_write, save_erase: :emit_save_erase,
                                               timer_start: :emit_timer_start, timer_stop: :emit_timer_stop,
                                               # a timer's handler runs as its timer ticks, not where it is written
                                               on_timer: :emit_nothing,
                                               # the light is not made yet (shade_outside), and a game
                                               # without one works nothing out again
                                               show_light_now: :emit_nothing
                                             }.merge(Picture::STATEMENTS).merge(Sound::STATEMENTS).merge(Clock::STATEMENTS)
                                              .merge(TileRuns::STATEMENTS)
                                              .merge(Nodes.of_role(:declaration).to_h { |kind| [kind, :emit_nothing] }))

          VALUES = Ractor.make_shareable({
                                           int: :value_of_int, var_ref: :value_of_var_ref, binop: :value_of_binop,
                                           neg: :value_of_neg, bit_not: :value_of_bit_not,
                                           absolute: :value_of_absolute, clamped: :value_of_clamped,
                                           mul_fix: :value_of_mul_fix, div_fix: :value_of_div_fix,
                                           shift_right: :value_of_shift_right, held: :value_of_held,
                                           pressed: :value_of_pressed, list_get: :value_of_list_get,
                                           list_len: :value_of_list_len, table_get: :value_of_table_get,
                                           save_read: :value_of_save_read, save_sum: :value_of_save_sum,
                                           timer_ticks: :value_of_timer_ticks, chance: :value_of_chance,
                                           data_byte: :value_of_data_byte
                                         }.merge(Picture::VALUES).merge(Clock::VALUES))

          include Picture
          include PaintReach
          include Sound
          include TileRuns
          include Clock

          # EVERY KIND THIS LOWERING CANNOT MAKE YET, by what it is part of. A kind leaves the list the
          # day the Color does it; test_gbc_kind_coverage.rb holds the list and the tables above to
          # every kind there is.
          NOT_LOWERED_YET = Ractor.make_shareable({})

          # The kinds the Color's hardware cannot do at all, refused in the words its answers have
          # (#refuse_what_color_lacks!): a layer seen through another, a light, a mosaic, a turned
          # or resized background, a recording.
          REFUSED = %i[see_through shade_outside pixelate affine_background play_sample stop_sample].freeze

          # How many bytes of save memory a read or a write moves, by the width it names.
          SAVE_BYTES = Ractor.make_shareable({ byte: 1, half: 2, word: 4 })

          # How a table keeps its entries, by the width the game declared and whether they are
          # signed: bytes an entry, and the range that holds. Any other table keeps whole words.
          TABLE_WIDTHS = Ractor.make_shareable({ [:byte, true] => [1, -128..127], [:byte, false] => [1, 0..255],
                                                 [:half, true] => [2, -32_768..32_767], [:half, false] => [2, 0..65_535] })

          # The number the runtime knows each way of keeping an entry by (Runtime::Lists' copy reads
          # it), and the routine that reads an entry kept that way, by its bytes and its sign.
          TABLE_KEPT = Ractor.make_shareable({ [1, true] => [0, "rt_read_int8"], [1, false] => [1, "rt_read_uint8"],
                                               [2, true] => [2, "rt_read_int16"], [2, false] => [3, "rt_read_uint16"],
                                               [4, true] => [4, "rt_read_int32"] })

          # How many bytes a slot of a list takes, by the width it was declared with.
          SLOT_BYTES = Ractor.make_shareable({ byte: 1, half: 2, word: 4, nil => 4 })

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

          # The game's routines, each section's label beside what that routine is to the author — a
          # scene or a routine by the name the game gave it, the game loop, a timer — once #sections
          # has made them. A part of a routine cut to fit a bank is that routine.
          attr_reader :section_routines

          # Values this lowering makes for itself beside the IR's, each worked out into BCDE as one of
          # the IR's is: where a label is (a table a runtime routine reads), and where with the bank
          # of the cartridge it is in above it (a table a runtime routine puts in view to read); the
          # entry of a table of the drawing's numbers at an index, +bytes+ wide and read with its
          # sign or not; what a runtime routine gives back for +args+; and a sum or a test of two of
          # any of these, as a binop of the IR's is worked out.
          Address = Data.define(:label)
          BankedAddress = Data.define(:label)
          Entry = Data.define(:label, :bytes, :signed, :index)
          RuntimeValue = Data.define(:routine, :args)
          Sum = Data.define(:op, :lhs, :rhs)

          # The routine the game names +name+.
          def self.routine_label(name) = "routine #{name}"

          # Where each of the game's variables went, by its name, and each of its lists — [its place,
          # its capacity, the bytes a slot, its name] — once #sections has placed them; and the label
          # of the routine the runtime runs at each frame boundary, or nil for a game with no timers.
          attr_reader :variables, :lists, :frame_begins

          # +lends_sprite_colors+ builds the game with its sprites' lists of colours borrowing the
          # console's eight as it runs (Art::TooManySpriteLists).
          def initialize(program, memory:, lends_sprite_colors: false)
            @program = program
            @memory = memory
            @lends_sprite_colors = lends_sprite_colors
            @funcs = program.walk.select { |node| node.kind == :func }.to_h { |node| [node.name, node] }
            # What each timer does when it ticks, wherever that is written, and the number each is
            # known by here, in the order the program first names them.
            @tick_handlers = Nodes::OnTimer.of(program)
            @timers = program.walk.filter_map do |node|
              case node.kind
              when :timer_start, :timer_stop, :timer_ticks then node.name
              when :on_timer then node.timer
              end
            end.uniq.each_with_index.to_h
            @called = Reach.routines(program, also: @tick_handlers.values)
            # A bend's steps run at every frame boundary (Picture#emit_bends), wherever it is declared.
            bends = program.walk.select { |node| node.kind == :scroll_rows }
            @reachable = Reach.statements_from(program, *@called.map { |name| @funcs.fetch(name) }, *@tick_handlers.values,
                                               *bends)
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
            @cut_children = {} # a statement whose statements were cut into parts -> what stands for them
            @section_routines = {} # each routine's section, by its label -> what it is to the author
            prepare_picture
            prepare_sound
            prepare_clock
          end

          # The game's code, as sections for the Linker: its data, every routine a run can reach, and
          # the program itself.
          def sections
            refuse_unlowered_kinds!
            refuse_what_color_lacks!
            refuse_unsupported_save_memory!
            refuse_unfit_paint_squares!
            refuse_lists_in_use_past_eight!
            refuse_routines_that_call_themselves!
            Reach.variables(@program).each { |name| @variables[name] = @memory.reserve("the variable #{name.inspect}", 4) }
            @declared_lists.each_value do |node|
              width = SLOT_BYTES.fetch(node.width)
              # Named as the game names it, since running out of room says which list asked.
              place = @memory.reserve("the list #{node.name.inspect}", Runtime::Lists::HEADER + (node.capacity * width))
              @lists[node.name] = [place, node.capacity, width, node.name.to_s]
            end
            @scene = keep_local(:scene, start: -1) unless @scenes.empty?
            keep_timer_numbers
            keep_held_colors
            keep_group_numbers
            keep_sprites_hidden_flag
            keep_patches
            keep_tile_runs
            keep_drawn_palettes
            keep_big_map_places
            keep_column_numbers
            keep_clock_readings
            routines = @called.flat_map do |name|
              routines_fitting(self.class.routine_label(name), @funcs.fetch(name).children, routine: routine_said(name))
            end
            timers = timer_sections
            main = routines_fitting(MAIN, [*clock_at_power_on, *@program.children], routine: "the game loop")
            # The routines the drawing asked for as the rest was made, and then the data last of
            # all, since the routines are what find the tables in it.
            columns = column_sections
            [data_section, *banked_table_sections, *routines, *timers, *main, *clock_sections, *columns]
          end

          private

          # --- refusals ---

          # What a run can reach and this lowering cannot make, refused by name before anything is
          # made: a step that only means something on the Advance, and one the Color does not do
          # yet. A step in a routine nothing calls never runs, and is not refused.
          def refuse_unlowered_kinds!
            kinds = @reachable.map(&:kind).uniq
            hardware = kinds.select { |kind| Portability.hardware_only?(kind) }
            unless hardware.empty?
              raise LoweringError, "this program uses #{hardware.map(&:inspect).join(', ')}, which only means " \
                                   "something on the Game Boy Advance, so the Game Boy Color build cannot make it."
            end

            missing = NOT_LOWERED_YET.select { |_, listed| listed.intersect?(kinds) }
            return if missing.empty?

            uses = missing.values.flatten & kinds
            raise LoweringError, "this program uses #{uses.map(&:inspect).join(', ')}, which the Game Boy Color build " \
                                 "cannot make yet (#{missing.keys.join(', ')})."
          end

          # What a Color cannot do at all, and a second background showing at once, refused as a
          # game's build refuses them (Checks::ConsoleAnswers, Checks::TooManyBackgroundLayers). A
          # program handed straight to a lowering, as a test's is, never passes the build's checks;
          # and one that names no console, or another, is asked about as the Color's.
          def refuse_what_color_lacks!
            asked = @program.console == :gbc ? @program : @program.copy.tap { |copy| copy.console = :gbc }
            refused = Guardrails::Checks::ConsoleAnswers.new.detect(asked).find { |finding| finding.severity == :error }
            refusal = refused&.message || Guardrails::Checks::TooManyBackgroundLayers.new.refusal_message(asked)
            raise LoweringError, refusal if refusal
          end

          # A Game Boy Color cartridge saves in 32K of battery-backed memory (Runtime::Saving): a game
          # that asks for flash, an EEPROM or more memory is refused, naming what it asked for.
          def refuse_unsupported_save_memory!
            return unless SaveLayout.named_by?(@program)

            memory = SaveLayout.memory_of(@program)
            return if memory.chip == :battery && memory.size == Runtime::Saving::SIZE

            raise LoweringError, "this game saves in #{memory.kilobytes}K of #{memory.kind_words}, and a Game Boy Color " \
                                 "cartridge saves in 32K of battery-backed memory. To fix this, leave `save_memory:` " \
                                 "out of VBlank.game, or say 32."
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

          # The tables a run reads, the tables of routines a call picks from by number, the places
          # that do not start at nought, and each list's place, capacity and slot (Runtime#emit_start
          # reads the last two).
          def data_section
            asm = SM83.new("game data", home: :fixed, holds: DATA)
            tables_read.each do |table|
              if banked_tables.include?(table.name)
                asm.label(table_parts_label(table.name))
                table_parts(table).each_index do |part|
                  asm.data_words(table_part_label(table.name, part))
                  asm.data_bank_of(table_part_label(table.name, part))
                end
                next
              end

              asm.label(table_label(table.name))
              table_parts(table).each { |part| asm.data_bytes(part) }
            end
            @drawing_tables.reject(&:banked).each { |table| emit_drawing_table(asm, table) }
            emit_group_slots(asm)
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
            @lists.each_value do |place, capacity, width, _|
              asm.data_words(place)
              asm.data_words(capacity)
              asm.data_bytes(width)
            end
            asm.data_words(0)
            asm.section
          end

          # The tables a run reads, by an entry or by copying a run of them into a list.
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

          def table_parts_label(name) = "table #{name} parts"
          def table_part_label(name, part) = "table #{name} part #{part}"

          # THE TABLES KEPT OUT OF THE PART ALWAYS IN VIEW. That part is 16 kilobytes and holds the
          # runtime and everything read without switching a bank in, so a big table there — the
          # walls of a hundred-cell-square room are ten thousand bytes — leaves no room for the
          # rest. A table at least this big is kept in banks instead, cut into parts so that one
          # bigger than a bank still fits (Runtime::Calls::TABLE_PART_BYTES), and a read of it
          # finds its part and puts that part's bank in view (rt_far_read_parts): a few dozen more
          # instructions a read, and none for a small table. A table a list is filled from stays
          # in view, since the list's copy reads it in a loop of its own.
          BANKED_TABLE_BYTES = 1024

          # The names of the tables kept in banks of their own.
          def banked_tables
            @banked_tables ||= begin
              copied = @reachable.filter_map { |node| node.table if node.kind == :list_copy }
              tables_read.filter_map do |table|
                next if copied.include?(table.name)

                bytes, = table_keeping(table)
                table.name if bytes * table.values.length >= BANKED_TABLE_BYTES
              end
            end
          end

          # A section for each part of each table kept in banks.
          def banked_table_sections
            tables = tables_read.select { |table| banked_tables.include?(table.name) }.flat_map do |table|
              table_parts(table).each_with_index.map do |bytes, part|
                asm = SM83.new(table_part_label(table.name, part), home: :banked, holds: DATA)
                asm.label(table_part_label(table.name, part))
                asm.data_bytes(bytes)
                asm.section
              end
            end
            drawings = @drawing_tables.select(&:banked).map do |table|
              asm = SM83.new(table.label, home: :banked, holds: DATA)
              emit_drawing_table(asm, table)
              asm.section
            end
            tables + drawings
          end

          # A table of the drawing's numbers (Picture#drawing_table), each entry its low bytes.
          def emit_drawing_table(asm, table)
            asm.label(table.label)
            table.entries.each { |entry| asm.data_bytes(little_endian(Int32.wrap(entry), table.bytes)) }
          end

          # +table+'s bytes as the cartridge keeps them, in parts of Runtime::Calls::TABLE_PART_BYTES.
          def table_parts(table)
            bytes, = table_keeping(table)
            table.values.flat_map { |entry| little_endian(Int32.wrap(entry), bytes) }
                 .each_slice(Runtime::Calls::TABLE_PART_BYTES).to_a
          end

          # How +table+ keeps its entries — [bytes an entry, whether signed] — as the cartridge
          # keeps it: at the width the game declared when every entry fits it, and whole words
          # otherwise. Reading an entry widens it back to a whole number either way.
          def table_keeping(table)
            signed = table.signed ? true : false
            bytes, range = TABLE_WIDTHS[[table.width, signed]]
            return [bytes, signed] if bytes && table.values.all? { |entry| range.cover?(Int32.wrap(entry)) }

            [4, true]
          end

          def little_endian(value, size) = Array.new(size) { |i| (value >> (8 * i)) & 0xFF }

          # --- routines ---

          # A routine of +body+'s statements, or of what the block emits for one this lowering makes
          # for itself. +routine+ is what it is to the author — a routine of the game's by its name,
          # the game loop, a timer — which a profile says its time by (#section_routines).
          def routine_section(label, body, routine:)
            @section_routines[label] = routine
            @asm = SM83.new(label, home: :banked, holds: ROUTINES)
            @routine = label
            @labels = 0
            @constants = {}
            @asm.label(label)
            body.each { |node| statement(node) }
            yield if block_given?
            @asm.ret
            @constants.each do |value, at|
              @asm.label(at)
              @asm.data_bytes(little_endian(value, 4))
            end
            @asm.section
          end

          # A routine of the game's, as the author names it: a scene as one.
          def routine_said(name) = @scenes.key?(name) ? "scene #{name.inspect}" : name.to_s

          def fresh(what)
            @labels += 1
            "#{@routine}.#{what}#{@labels}"
          end

          # A number of the routine's own, kept in work memory, by a name of its own that a value
          # can read as a variable. +start+ is what it holds from power-on. Code made only to be
          # measured (#bytes_of) is given a place that is never kept.
          def keep_local(what, start: 0)
            name = :"#{@routine || 'game'}.#{what}#{@locals.length + 1}"
            return name.tap { @locals[name] = Memory::FIRST } if @measuring

            @locals[name] = @memory.reserve("the game's number #{name}", 4)
            @starts << [@locals[name], start] unless start.zero?
            name
          end

          # --- a routine too big for a bank, cut into parts ---

          # The most bytes one routine's code may come to before it is cut into parts, each a
          # routine of its own: a bank is 16K, and a routine and the numbers it uses go in one.
          MOST_ROUTINE_BYTES = 12_000

          # The most bytes a part cut off a routine may come to.
          MOST_PART_BYTES = 6_000

          # A call of a part cut off a routine, standing where its statements stood.
          PartCall = Data.define(:label)

          # The routine +label+ of +body+'s statements, and the parts cut off it to fit a bank. A
          # run of statements side by side becomes a routine of its own, called where they were; a
          # statement too big to move whole has what is inside it cut the same way instead. The
          # parts share the routine's own numbers, which are kept in work memory, so nothing is
          # handed between them.
          def routines_fitting(label, body, routine:)
            parts = []
            body = cut_list(body, label, parts) if bytes_of(body) > MOST_ROUTINE_BYTES
            [routine_section(label, body, routine: routine),
             *parts.map { |part, statements| routine_section(part, statements, routine: routine) }]
          end

          def cut_list(list, base, parts)
            kept = []
            run = []
            run_bytes = 0
            flush = lambda do
              next if run.empty?

              part = "#{base}_part#{parts.length + 1}"
              parts << [part, run]
              kept << PartCall.new(part)
              run = []
              run_bytes = 0
            end
            list.each do |node|
              size = bytes_of([node])
              if size <= MOST_PART_BYTES
                flush.call if run_bytes + size > MOST_PART_BYTES
                run << node
                run_bytes += size
              else
                flush.call
                kept << cut_inside(node, base, parts)
              end
            end
            flush.call
            kept
          end

          # A statement too big to move whole, with the statements it holds cut. Only an `if`, a
          # `loop` and a `repeat` hold statements that are made where they stand.
          def cut_inside(node, base, parts)
            return node unless %i[if loop repeat].include?(node.kind)

            body, otherwise = children_of(node)
            @cut_children[node.object_id] = [cut_list(body, base, parts), cut_list(otherwise, base, parts)]
            node
          end

          # How many bytes +list+ comes to, made on its own and thrown away.
          def bytes_of(list)
            saved = [@asm, @routine, @labels, @constants, @locals.dup, @drawing_tables.length]
            @measuring = true
            @asm = SM83.new("measuring", home: :banked)
            @labels = 0
            @constants = {}
            list.each { |node| statement(node) }
            @asm.here + (@constants.size * 4)
          ensure
            @measuring = false
            @asm, @routine, @labels, @constants, @locals, tables = saved
            @drawing_tables.slice!(tables..)
          end

          def place_of(name)
            @variables.fetch(name) { @locals.fetch(name) { raise LoweringError, "#{name.inspect} is not a variable the program keeps" } }
          end

          # --- statements ---

          def statement(node)
            return call_routine(node.label) if node.is_a?(PartCall)

            send(STATEMENTS.fetch(node.kind), node)
          end

          # The statements an `if`, a `loop` or a `repeat` holds, and an `if`'s `else`: its own, or
          # those a routine too big for a bank cut them into (#cut_list).
          def children_of(node)
            @cut_children.fetch(node.object_id) { [node.children, node.kind == :if ? node.else&.children || [] : []] }
          end

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
            body, otherwise = children_of(node)
            known = folded(node.cond)
            return (known.zero? ? otherwise : body).each { |child| statement(child) } if known

            other = fresh("else")
            done = fresh("end_if")
            jump_unless(node.cond, other)
            body.each { |child| statement(child) }
            @asm.jump(done) unless otherwise.empty?
            @asm.label(other)
            otherwise.each { |child| statement(child) }
            @asm.label(done)
          end

          def emit_loop(node)
            top = fresh("loop")
            @asm.label(top)
            children_of(node).first.each { |child| statement(child) }
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
            children_of(node).first.each { |child| statement(child) }
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
              at_power_on = keep_local(:at_power_on)
              value(Build.binop(:==, Build.var_ref(@scene), Build.int(-1)))
              store(at_power_on)
              take_over(scene, number)
              jump_unless(Build.var_ref(at_power_on), done)
              call_routine(label)
              @asm.jump(done)
            else
              take_over(scene, number)
            end
            @asm.label(staying)
            call_routine(label)
            @asm.label(done)
          end

          # The scene numbered +number+ is the one running now, and what it does as it arrives is
          # done (Picture#emit_scene_arrival).
          def take_over(scene, number)
            load_constant(number)
            store(@scene)
            emit_scene_arrival(scene)
          end

          # A game that never waits for the screen has its bend worked out as it stops, for the
          # picture it stops on, as the interpreter works each row out as it paints it.
          def emit_halt(_node)
            emit_bends(painting: true) unless @program.walk.any? { |node| node.kind == :wait_vblank }
            @asm.call("rt_halt")
          end

          # The runtime ends the frame (shows it, reads the buttons, keeps time), and the frame
          # counters the program can read move on, where the interpreter moves them
          # (Reference#store_frame_counters): the frames shown by every frame the pass took, and what
          # the game catches up by held at the cap, both as the runtime counted them
          # (Runtime::Frame::FRAMES_TAKEN, STEP_TAKEN).
          def emit_wait_vblank(_node)
            @asm.call("rt_wait_vblank")
            emit_clock_each_pass
            @asm.load(:a, [@memory[Runtime::Frame::FRAMES_TAKEN]])
            @asm.load(:c, :a)
            @asm.load(:hl, place_of(Frames::COUNT))
            @asm.load(:a, [:hl])
            @asm.add_a(:c)
            @asm.load([:hli], :a)
            3.times do |i|
              @asm.load(:a, [:hl])
              @asm.adc_a(0)
              @asm.load(i == 2 ? [:hl] : [:hli], :a)
            end
            @asm.load(:hl, place_of(Frames::STEP))
            @asm.load(:a, [@memory[Runtime::Frame::STEP_TAKEN]])
            @asm.load([:hli], :a)
            @asm.xor_a(:a)
            3.times { @asm.load([:hli], :a) }
            value(Frames::COUNT)
            store(Frames::SEEN)
            emit_bends
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

          # A run of a table's entries copied into a list: the table's place and how it keeps its
          # entries, so the runtime reads them as a run does.
          def emit_list_copy(node)
            table = @tables.fetch(node.table) { raise LoweringError, "the table #{node.table.inspect} is copied and never declared" }
            kept, = TABLE_KEPT.fetch(table_keeping(table))
            list_call("rt_list_copy", node, Address.new(table_label(table.name)), Build.int(kept), Build.int(table.values.length),
                      node.at, Build.int(node.count))
          end

          # Reference::ListValue#[]. The index is worked out first, and then it and the list's place
          # are written straight where rt_list_get reads them, in quick memory, rather than pushed
          # for it to copy off the stack: a pool's every field is a list, read several times a thing
          # a pass, and the copy was a large part of each read.
          #
          # A LIST NOTHING TAKES FROM THE FRONT keeps its first item in its first slot for good, so
          # an item's slot is its index: such a list's item is read straight from its place, once
          # the index is held to the length the header says — every field of a pool is such a list.
          # An index out of range goes the whole way round, so the game stops as the interpreter's.
          def value_of_list_get(node)
            place, _capacity, width = list_placed(node)
            value(node.index)
            return list_get_through_routine(place) if front_dropped_lists.include?(node.name)

            out_of_range = fresh("list_index_out_of_range")
            done = fresh("list_item_read")
            emit_list_slot_address(place, width, out_of_range)
            @asm.call(TABLE_KEPT.fetch([width, true]).last) # a slot reads back with its top bit as the sign
            @asm.jump(done)
            @asm.label(out_of_range)
            list_get_through_routine(place)
            @asm.label(done)
          end

          # Reference#exec_list_set, the same way for a list nothing takes from the front: the index
          # worked out and held to the length, then the value worked out and written into the slot,
          # as wide as the slot is. An index out of range goes through rt_list_set_taken, which stops the
          # game before anything is written.
          def emit_list_set(node)
            return list_call("rt_list_set", node, node.index, node.value) if front_dropped_lists.include?(node.name)

            place, _capacity, width = list_placed(node)
            out_of_range = fresh("list_index_out_of_range")
            done = fresh("list_item_written")
            value(node.index)
            emit_list_slot_address(place, width, out_of_range)
            @asm.push(:hl)
            value(node.value)
            @asm.pop(:hl)
            %i[e d c b].first(width).each_with_index do |reg, i|
              @asm.inc(:hl) unless i.zero?
              @asm.load([:hl], reg)
            end
            @asm.jump(done)
            @asm.label(out_of_range)
            list_set_through_routine(place)
            @asm.label(done)
          end

          # HL = the slot the index in BCDE names in the list at +place+, whose slots are +width+
          # bytes, a list whose first item is in its first slot; a jump to +out_of_range+, BCDE as
          # it was, for an index past 16 bits, below nought, or not below the length its header says.
          def emit_list_slot_address(place, width, out_of_range)
            @asm.load(:a, :b)
            @asm.or_a(:c)
            @asm.jump(:nz, out_of_range)
            @asm.load(:hl, place + Runtime::Lists::LENGTH)
            @asm.load(:a, :e)
            @asm.sub_a([:hl])
            @asm.inc(:hl)
            @asm.load(:a, :d)
            @asm.sbc_a([:hl])
            @asm.jump(:nc, out_of_range)
            @asm.load(:h, :d)
            @asm.load(:l, :e)
            (width / 2).times { @asm.add_hl(:hl) } # × the slot's width: 1, 2 or 4
            @asm.load(:de, place + Runtime::Lists::HEADER)
            @asm.add_hl(:de)
          end

          # The index in BCDE and the list at +place+ written where rt_list_set reads them, and the
          # write gone through with it, for an index out of range: the routine stops the game.
          def list_set_through_routine(place)
            emit_list_index_and_place(place, *Runtime::Lists.set_places(@memory))
            @asm.call("rt_list_set_taken")
          end

          # The lists some reachable step takes an item from the front of.
          def front_dropped_lists
            @front_dropped_lists ||= @reachable.filter_map { |node| node.name if node.kind == :list_drop && node.from == :front }.uniq
          end

          # The index in BCDE and the list at +place+ written where rt_list_get reads them, and read.
          def list_get_through_routine(place)
            emit_list_index_and_place(place, *Runtime::Lists.get_places(@memory))
            @asm.call("rt_list_get_taken")
          end

          # The index in BCDE at +index_at+ and the list's place at +list_at+, in quick memory.
          def emit_list_index_and_place(place, list_at, index_at)
            %i[e d c b].each_with_index do |reg, i|
              @asm.load(:a, reg)
              @asm.load_high(index_at + i, :a)
            end
            4.times do |i|
              @asm.load(:a, (place >> (8 * i)) & 0xFF)
              @asm.load_high(list_at + i, :a)
            end
          end

          def value_of_list_len(node) = list_call("rt_list_length", node)

          # The runtime's list routine +routine+ on the list +node+ names, the list's place first.
          def list_call(routine, node, *args)
            place, = list_placed(node)
            runtime_call(routine, [Build.int(place), *args])
          end

          # The list +node+ names, as #sections placed it: [its place, its capacity, the bytes a slot,
          # its name].
          def list_placed(node)
            @lists.fetch(node.name) { raise LoweringError, "the list #{node.name.inspect} is used and never declared" }
          end

          # Reference#exec_table_get: an index out of range made safe — a table whose length is a
          # power of two wraps it (what an angle wants), any other holds it to the ends.
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
            # HL = the table + the index × the entry's size; the index is never past 16 bits.
            (bytes / 2).times do
              @asm.sla(:e)
              @asm.rl(:d)
            end
            reader = TABLE_KEPT.fetch([bytes, signed]).last
            if banked_tables.include?(table.name)
              @asm.load(:hl, table_parts_label(table.name))
              @asm.load(:bc, reader)
              return @asm.call("rt_far_read_parts")
            end

            @asm.load(:hl, table_label(table.name))
            @asm.add_hl(:de)
            @asm.call(reader)
          end

          # --- save memory (Runtime::Saving), laid out as IR::SaveLayout says ---

          # Reference#exec_save_init: every `save_var` takes its saved number when save memory
          # carries the game's marker, and the number it was declared with when it does not. Each
          # is written back, and the marker after them, in that order, so a power cut lands on the
          # byte it lands on in the interpreter.
          def emit_save_init(node)
            saved = keep_local(:saved)
            marker_at = Build.int(SaveLayout::SAVE_VAR_MARKER_AT)
            marker = Int32.wrap(node.magic)
            value(Build.binop(:==, save_read(marker_at, :word), Build.int(marker)))
            store(saved)
            node.vars.each do |kept|
              at = Build.int(SaveLayout.save_var_at(kept.slot))
              declared = fresh("declared_number")
              chosen = fresh("number_chosen")
              jump_unless(Build.var_ref(saved), declared)
              value(save_read(at, :word))
              @asm.jump(chosen)
              @asm.label(declared)
              load_constant(Int32.wrap(kept.default))
              @asm.label(chosen)
              store(kept.name)
              runtime_call("rt_save_write", [at, kept.name, Build.int(SAVE_BYTES.fetch(:word))])
            end
            runtime_call("rt_save_write", [marker_at, Build.int(marker), Build.int(SAVE_BYTES.fetch(:word))])
            emit_clock_readings_from_save
          end

          # Reference#exec_save_store: one `save_var`'s number into its place.
          def emit_save_store(node)
            at = Build.int(SaveLayout.save_var_at(node.slot))
            runtime_call("rt_save_write", [at, node.var, Build.int(SAVE_BYTES.fetch(:word))])
          end

          # Reference#exec_save_write: the place worked out first and the value after it, as the
          # interpreter works them out, which is the order they are pushed in.
          def emit_save_write(node) = runtime_call("rt_save_write", [node.at, node.value, save_width(node)])

          # Reference#exec_save_erase: the wipe is waited for unless the node says not to.
          def emit_save_erase(node) = runtime_call("rt_save_erase", [node.at, Build.int(node.wait == false ? 0 : 1)])

          def value_of_save_read(node) = runtime_call("rt_save_read", [node.at, save_width(node)])
          def value_of_save_sum(node) = runtime_call("rt_save_sum", [node.at, node.length])

          def save_width(node) = Build.int(SAVE_BYTES.fetch(node.width))

          # A read of save memory, as a value for the statements above.
          def save_read(at, width) = Build.save_read(at, width: width)

          # --- timers ---
          #
          # A timer (`timer :beat, per_second: 10`) ticks so many times a second whatever the game is
          # doing, and runs what the game said to do on each tick. There is no clock in it: a frame is
          # the interpreter's sixtieth of a second, so at every frame boundary a running timer gains
          # its rate in sixtieths of a tick, and each whole tick that comes to is a tick
          # (Reference#accrue_timer). The Color's own hardware timer counts its own clock, which is
          # not the frame — a pass that runs late would tick it more than the interpreter ticks — so
          # this counts frames, as the interpreter does.
          #
          # Each timer keeps: when it was first started, as a count (nought for never), since timers
          # move on in the order they were first started, as the interpreter walks them; whether it is
          # running; its rate, as the whole ticks and the sixtieths of a tick a frame adds, kept apart
          # so that adding them never goes round at any rate a game can ask for; the sixtieths of a
          # tick it is through, always under sixty; and its whole ticks, coming round at 65536 as the
          # interpreter's count does. The runtime runs this lowering's routine at each frame boundary
          # (Runtime's rt_frame_begins), which moves every running timer on and runs its ticks.

          # The numbers each timer keeps (see above).
          TIMER_NUMBERS = %i[order running whole_rate part_rate parts ticks].freeze

          # A frame is a sixtieth of a second, as the interpreter counts one.
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
            add_in_place(place_of(@timers_started), 1)
            value(@timers_started)
            store(order)
            @asm.label(started)
            whole, part = node.hz.divmod(FRAMES_A_SECOND)
            { running: 1, whole_rate: whole, part_rate: part, parts: 0, ticks: 0 }.each do |what, number|
              load_constant(number)
              store(timer_number(node.name, what))
            end
          end

          # Reference#exec_timer_stop: its count is kept. A timer never started has nothing to stop.
          def emit_timer_stop(node)
            load_constant(0)
            store(timer_number(node.name, :running))
          end

          # Reference#timer_ticks: nought for a timer never started, which is what its count starts at.
          def value_of_timer_ticks(node) = value(timer_number(node.name, :ticks))

          # THE ROUTINES THE RUNTIME RUNS AT EACH FRAME BOUNDARY: one that moves every running timer
          # on, in the order the timers were first started — the k-th started is looked for k-th —
          # and one for each timer, which moves it on and runs its handler, so each handler is made
          # once however many timers there are. None for a game with no timers.
          def timer_sections
            return [] if @timers.empty?

            each_timer = @timers.map { |name, number| timer_section(name, number) }
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
          # that stops or restarts its own timer still finishes the ticks this frame crossed, as the
          # interpreter's does.
          def timer_section(name, _number)
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
                add_in_place(place_of(@timer_crossed), -1)
                @asm.jump(top)
                @asm.label(done)
              end
            end
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
            when Address then load_label(operand.label)
            when BankedAddress then load_banked_label(operand.label)
            when Entry then table_entry(operand)
            when RuntimeValue then runtime_call(operand.routine, operand.args)
            when Sum then value_of_binop(operand)
            else raise LoweringError, "cannot make #{operand.inspect} a number"
            end
          end

          def load_label(label)
            @asm.load(:bc, 0)
            @asm.load(:de, label)
          end

          def load_banked_label(label)
            @asm.load(:b, 0)
            @asm.load_bank_of(:c, label)
            @asm.load(:de, label)
          end

          # The entry of a table of the drawing's numbers at an index the program has already kept
          # inside it: HL = the table + the index × the entry's size.
          def table_entry(entry)
            value(entry.index)
            (entry.bytes / 2).times do
              @asm.sla(:e)
              @asm.rl(:d)
            end
            @asm.load(:hl, entry.label)
            @asm.add_hl(:de)
            @asm.call(TABLE_KEPT.fetch([entry.bytes, entry.signed]).last)
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
          # A chance holds when the random draw lands below the threshold.
          def value_of_chance(node) = value(Build.binop(:<, node.draw, Build.int(node.percent)))

          # One byte of a named piece of data. The index is a number written in the program, so one
          # past the end is refused here, where the interpreter would refuse it as it runs.
          def value_of_data_byte(node)
            data = @pictures.fetch(node.name) { raise LoweringError, "reference to undefined data #{node.name.inspect}" }
            bytes = (data.kind == :data ? data.bytes : data.pixels).bytes
            unless node.index.between?(0, bytes.length - 1)
              raise LoweringError, "data_byte index #{node.index} is past the end of #{node.name.inspect}"
            end

            value(Entry.new(drawing_table("data #{node.name}", 1, bytes), 1, false, Build.int(node.index)))
          end

          def value_of_held(node) = runtime_call("rt_held", [Build.int(button_number(node.button))])
          def value_of_pressed(node) = runtime_call("rt_pressed", [Build.int(button_number(node.button))])

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
            when :clamped then folded_clamp(node)
            end
          end

          # Reference#clamp_value: held at the floor, then at the ceiling.
          def folded_clamp(node)
            number, floor, ceiling = [node.operand, node.min, node.max].map { |part| folded(part) }
            return nil unless number && floor && ceiling

            [[number, floor].max, ceiling].min
          end

          # A product by a power of two up to 16 written in the program, as shifts of the four bytes
          # a place at a time rather than the runtime's multiply — none at all for a product by one.
          # True when it was done so.
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
