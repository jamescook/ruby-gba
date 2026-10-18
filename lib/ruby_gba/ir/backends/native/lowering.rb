# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class Native
        # ONE PROGRAM, WRITTEN OUT AS C. Make one per program and ask for #source.
        #
        # The shape follows the interpreter's own (Backends::Reference): a table naming the
        # method for each kind of statement, and one for each kind of value, so the two read
        # side by side and a kind missing from either table is one line to find. A kind this
        # backend cannot write yet is refused by name at the start, rather than half the program
        # being written first.
        #
        # What the generated file holds, top to bottom: the game's variables, every routine, the
        # program itself as rg_game_main (the runtime calls it once, at power-on), and
        # rg_game_dump_state, which a test build uses to print where every variable and list stands.
        class Lowering
          include Picture
          include Sound
          include Saving

          # The variables the framework keeps the frame count in (see IR::Frames). Written at
          # every frame boundary, where the interpreter writes them.
          FRAME_VARIABLES = [Frames::COUNT, Frames::SEEN, Frames::STEP].freeze

          # The operators of a binop, by the rg_int32.h function that does each one.
          OPERATORS = Ractor.make_shareable({
                                              :+ => "rg_add", :- => "rg_sub", :* => "rg_mul",
                                              :/ => "rg_div", :% => "rg_mod",
                                              :& => "rg_and", :| => "rg_or", :^ => "rg_xor",
                                              :<< => "rg_shl", :>> => "rg_shr",
                                              :< => "rg_lt", :<= => "rg_le", :> => "rg_gt",
                                              :>= => "rg_ge", :== => "rg_eq", :!= => "rg_ne",
                                              and: "rg_both", or: "rg_either"
                                            })

          # Which kinds of statement name a variable, and where. The interpreter keeps a
          # variable that has never been written as 0, so every one of these becomes a global
          # starting at 0 and the program's own `set`s give it its first value.
          VARIABLES_OF = Ractor.make_shareable({
                                                 set: ->(n) { [n.var] }, add: ->(n) { [n.var] },
                                                 sub: ->(n) { [n.var] }, negate: ->(n) { [n.var] },
                                                 abs: ->(n) { [n.var] }, negate_abs: ->(n) { [n.var] },
                                                 clamp: ->(n) { [n.var] }, copy: ->(n) { [n.dest, n.src] },
                                                 var_ref: ->(n) { [n.name] }, repeat: ->(n) { [n.index].compact },
                                                 every: ->(n) { [n.counter] }, after: ->(n) { [n.counter] },
                                                 case: ->(n) { [n.var] }, scroll_rows: ->(n) { [n.row] },
                                                 shade_outside: ->(n) { [n.row] },
                                                 copy_owed_tiles: ->(n) { n.masks },
                                                 save_init: ->(n) { n.vars.map(&:name) }, save_store: ->(n) { [n.var] }
                                               })

          STATEMENTS = Ractor.make_shareable({
                                               program: :lower_children, set: :lower_set, add: :lower_add,
                                               sub: :lower_sub, copy: :lower_copy, negate: :lower_negate,
                                               abs: :lower_abs, negate_abs: :lower_negate_abs,
                                               clamp: :lower_clamp, if: :lower_if, loop: :lower_loop,
                                               repeat: :lower_repeat, every: :lower_every,
                                               after: :lower_after, call: :lower_call,
                                               call_one_of: :lower_call_one_of, case: :lower_case,
                                               halt: :lower_halt, wait_vblank: :lower_wait_vblank,
                                               timer_start: :lower_timer_start, timer_stop: :lower_timer_stop,
                                               on_timer: :lower_nothing,
                                               list_new: :lower_list_new, list_push: :lower_list_push,
                                               list_drop: :lower_list_drop, list_set: :lower_list_set,
                                               list_fill: :lower_list_fill, list_copy: :lower_list_copy,
                                               # the picture (Picture)
                                               screen: :lower_screen, clear_screen: :lower_clear_screen,
                                               fill_rect: :lower_fill_rect, dma_fill_rect: :lower_dma_fill_rect,
                                               draw_rect_at: :lower_draw_rect_at, pixel: :lower_pixel,
                                               draw_text: :lower_draw_text, draw_digit: :lower_draw_digit,
                                               inside: :lower_inside, camera: :lower_camera,
                                               blit: :lower_blit, blit_pose: :lower_blit_pose,
                                               draw_column_at: :lower_draw_column_at,
                                               save_region: :lower_save_region,
                                               restore_region: :lower_restore_region,
                                               background: :lower_background,
                                               affine_background: :lower_affine_background,
                                               scroll_background: :lower_scroll_background,
                                               scroll_rows: :lower_scroll_rows,
                                               shade_outside: :lower_nothing,
                                               set_tile: :lower_set_tile, show_map: :lower_show_map,
                                               background_colors: :lower_background_colors,
                                               color_list_holds: :lower_color_list_holds,
                                               copy_tiles: :lower_copy_tiles,
                                               copy_owed_tiles: :lower_copy_owed_tiles,
                                               present_objects: :lower_present_objects,
                                               fade: :lower_fade, tint: :lower_tint,
                                               pixelate: :lower_pixelate,
                                               see_through: :lower_see_through,
                                               # sound (Sound)
                                               beep: :lower_beep, enable_sound: :lower_enable_sound,
                                               play_song: :lower_play_song, stop_music: :lower_stop_music,
                                               play_from_list: :lower_play_from_list,
                                               play_sound_effect: :lower_play_sound_effect,
                                               play_sample: :lower_play_sample, stop_sample: :lower_stop_sample,
                                               wave: :lower_wave, stop_wave: :lower_stop_wave,
                                               noise: :lower_noise,
                                               # save memory (Saving)
                                               save_init: :lower_save_init, save_store: :lower_save_store,
                                               save_write: :lower_save_write, save_erase: :lower_save_erase
                                             }.merge(Nodes.of_role(:declaration).to_h { |kind| [kind, :lower_nothing] }))

          VALUES = Ractor.make_shareable({
                                           int: :value_of_int, var_ref: :value_of_var_ref,
                                           binop: :value_of_binop, neg: :value_of_neg,
                                           bit_not: :value_of_bit_not, absolute: :value_of_absolute,
                                           clamped: :value_of_clamped, mul_fix: :value_of_mul_fix,
                                           div_fix: :value_of_div_fix, shift_right: :value_of_shift_right,
                                           held: :value_of_held, pressed: :value_of_pressed,
                                           chance: :value_of_chance, table_get: :value_of_table_get,
                                           data_byte: :value_of_data_byte, list_get: :value_of_list_get,
                                           list_len: :value_of_list_len, timer_ticks: :value_of_timer_ticks,
                                           # the picture (Picture)
                                           pixels_overlap: :value_of_pixels_overlap,
                                           # save memory (Saving)
                                           save_read: :value_of_save_read, save_sum: :value_of_save_sum
                                         })

          # EVERY KIND THIS BACKEND CANNOT WRITE YET, said out loud rather than found out. Native
          # trails the other two backends, so a kind may be missing here — but only on this list,
          # which test_native_kind_coverage.rb holds against every kind there is. A kind leaves
          # the list the day it gets a row in STATEMENTS or VALUES.
          NOT_LOWERED_YET = Ractor.make_shareable({})

          # How many bytes a slot of a list takes, by the width it was declared with.
          SLOT_BYTES = Ractor.make_shareable({ byte: 1, half: 2, word: 4, nil => 4 })

          # +title+ is the game's name, for the window.
          def initialize(program, title: "ruby-gba")
            @program = program
            @title = title
            @names = Names.new
            @locals = 0
            @funcs = by_name(program.walk, :func)
            # The bend each background's rows are given: the last one written for it, wherever
            # that is, since it stands from power-on (Reference#collect_definitions), in the
            # order the bends are first written, which is the order they are worked out in. One
            # written for a background the game does not have is never asked for.
            written = by_name(program.walk, :scroll_rows)
            declared = by_name(program.walk, :background)
            @bends = written.select { |name, _| declared.key?(name) }
            # The game's light: the last one written, wherever, since it stands from power-on
            # (Reference#collect_definitions), or nil for a game with none.
            @shade = program.walk.select { |node| node.kind == :shade_outside }.last
            # What each timer does when it ticks: its handler, wherever that is written, since it
            # is the timer's from power-on (Nodes::OnTimer.of). And the number the runtime knows
            # each timer by.
            @tick_handlers = Nodes::OnTimer.of(program)
            @timers = timer_numbers
            @called = called_routines
            # Everything a run can reach: the program, every routine it calls, however deep, and
            # what each bend runs as its lines are worked out. A routine nothing calls is left
            # out of the file altogether, so nothing in it (a table it reads, a routine it calls)
            # can leave something declared and unused.
            @reachable = statements_from(program, *@called.map { |name| @funcs.fetch(name) }, *@bends.values,
                                         *@tick_handlers.values)
            @tables = by_name(program.walk, :table)
            @data = by_name(program.walk, :data, :bitmap)
            # A list is there, empty, from power-on wherever it is declared (the interpreter
            # gathers them before running), so its storage is the first declaration's.
            @lists = by_name(@reachable.reverse, :list_new)
            @scenes = scene_numbers
            prepare_picture
            prepare_sound
          end

          # The program as one C file.
          def source
            refuse_unlowered_kinds!
            Printer.new.print_file(top_level)
          end

          # Every step a run of the program can reach, values inside them included: what is
          # written out, and what is refused when it cannot be. A check that has to say the same
          # as the lowering about a step in a routine nothing calls asks for this.
          def reachable_steps = @reachable

          private

          # --- the file ---

          # Only what a run can reach is written: the compiler is told to treat an unused routine
          # or table as a mistake, which it is in C somebody wrote, and a routine nothing calls
          # never runs (the build has already warned about it).
          #
          # The routines are written first, the ones the picture asks the game through among
          # them, because writing them is what finds the art they draw with; the art then goes
          # above them in the file.
          def top_level
            routines = @called.map { |name| C::Function.new(name: routine(name), body: body_of(@funcs.fetch(name))) }
            answers = [see_through_amounts, bend_offsets, work_out_bends, shade_span, shade_amount, timer_ticks]
            main = C::Function.new(name: @names.own("main"), body: [*power_on, *lower(@program)], exported: true)
            [C::Comment.new("Written by ruby-gba's native backend. Do not edit; build the game again."),
             C::Include.new("rg_int32.h"), C::Include.new("rg_runtime.h"), C::Include.new("rg_list.h"),
             C::Include.new("rg_screen.h"), C::Include.new("rg_sound.h"), C::Include.new("rg_mix.h"),
             C::Include.new("rg_save.h"),
             *variable_names.map { |name| C::Global.new(name: variable(name)) },
             *list_storage,
             *(@scenes.empty? ? [] : [C::Global.new(name: @names.own("scene"), value: -1)]),
             *held_colors_globals,
             *constant_arrays, *picture_data, *@drawing_arrays, title_array, *sound_tables,
             save_memory_table,
             *@called.map { |name| C::Prototype.new(name: routine(name)) },
             *routine_table_declarations,
             *routines, *answers, main,
             C::Function.new(name: @names.own("dump_state"), body: dump_state, exported: true)]
          end

          # The game's name as a C string. A character outside plain ASCII is written as '?', since
          # what C keeps a character in may not hold more.
          def title_array
            bytes = @title.to_s.each_char.map { |char| char.ord.between?(32, 126) ? char.ord : "?".ord }
            C::ConstArray.new(name: @names.own("title"), type: "char", values: bytes + [0], exported: true)
          end

          # A program that waits for frames shows nothing until its first frame is set up
          # (Reference#run): the console's picture is switched off until then.
          def power_on
            waits = @program.walk.any? { |node| node.kind == :wait_vblank }
            [*(waits ? [eval_call("rg_screen_hold", C::Int.new(1))] : []), *sound_power_on]
          end

          # The statements under +root+ and everything they hold, stopping at a routine's
          # declaration, at a bend and at what a timer does when it ticks: a routine's body runs
          # where it is called, a bend's as its lines are worked out and a tick's as its timer
          # ticks, not where any of them is written. The bend or the handler itself is still a
          # statement there; what it holds is found by asking for it as a root.
          def statements_under(root)
            found = [root]
            (root.children + root.operand_nodes).each do |node|
              found.concat(case node.kind
                           when :func then []
                           when :scroll_rows, :on_timer then [node]
                           else statements_under(node)
                           end)
            end
            found
          end

          def statements_from(*roots) = roots.flat_map { |root| statements_under(root) }

          # The routines named by the statements in +nodes+.
          def routines_named(nodes)
            nodes.flat_map do |node|
              case node.kind
              when :call then [node.target]
              when :call_one_of then node.targets
              when :case then node.clauses.map(&:last)
              else []
              end
            end
          end

          # Every routine a run can reach, following calls from the program, from what each bend
          # runs and from what each timer does when it ticks into the routines they call, in the
          # order the routines were declared.
          def called_routines
            reached = []
            waiting = routines_named(statements_from(@program, *@bends.values, *@tick_handlers.values))
            until waiting.empty?
              name = waiting.shift
              next if reached.include?(name) || !@funcs.key?(name)

              reached << name
              waiting.concat(routines_named(statements_under(@funcs.fetch(name))))
            end
            @funcs.keys & reached
          end

          def by_name(nodes, *kinds) = nodes.select { |node| kinds.include?(node.kind) }.to_h { |node| [node.name, node] }

          # Every variable the program names, framework's own included, in the order they
          # first appear.
          def variable_names
            names = FRAME_VARIABLES.dup
            @program.walk do |node|
              reader = VARIABLES_OF[node.kind]
              names.concat(reader.call(node)) if reader
              node.operand_nodes.each { |operand| names << operand if operand.is_a?(Symbol) }
            end
            names.uniq
          end

          # Every variable and then every list the game keeps, for a test build to print.
          def dump_state
            variable_names.map { |name| eval_call("rg_dump_variable", C::Text.new(name.to_s), variable(name)) } +
              @lists.keys.map { |name| eval_call("rg_dump_list", C::AddressOf.new(list(name))) }
          end

          # The numbers fixed when the program is built that a run reads: tables, and the bytes
          # of data and pictures.
          def constant_arrays
            read = @reachable.filter_map do |node|
              case node.kind
              when :table_get, :data_byte then node.name
              when :list_copy then node.table
              end
            end.uniq
            @tables.values.select { |table| read.include?(table.name) }.map do |table|
              C::ConstArray.new(name: @names.of(:table, table.name), type: table_type(table), values: table_entries(table))
            end + @data.values.select { |data| read.include?(data.name) }.map do |data|
              bytes = data.kind == :data ? data.bytes : data.pixels
              C::ConstArray.new(name: @names.of(:data, data.name), type: "uint8_t", values: bytes.bytes)
            end
          end

          # The C type a table's entries are kept in, by the width the game declared and whether
          # they are signed, with the range that type holds.
          TABLE_TYPES = Ractor.make_shareable({ [:byte, true] => ["int8_t", -128..127], [:byte, false] => ["uint8_t", 0..255],
                                                [:half, true] => ["int16_t", -32_768..32_767],
                                                [:half, false] => ["uint16_t", 0..65_535] })

          # Each of those as the number rg_list.h knows it by (RG_TABLE_INT8...).
          TABLE_KEPT_AS = Ractor.make_shareable({ "int8_t" => 0, "uint8_t" => 1, "int16_t" => 2, "uint16_t" => 3, "int32_t" => 4 })

          # A table kept at the width the game declared it, as the cartridge keeps it: a byte or a
          # half, signed or not, and a whole word otherwise. The build has already checked every
          # entry fits; a table built by hand that says nothing, or whose entries do not fit what it
          # says, keeps whole words. Reading an entry widens it back to a whole number, so nothing
          # that reads one changes.
          def table_type(table)
            type, range = TABLE_TYPES[[table.width, table.signed ? true : false]]
            type && table_entries(table).all? { |v| range.cover?(v) } ? type : "int32_t"
          end

          # A table's entries as the whole numbers a game reads.
          def table_entries(table) = table.values.map { |v| Int32.wrap(v) }

          def list_storage
            @lists.values.map do |node|
              C::ListStorage.new(name: list(node.name), items: @names.of(:list, "#{node.name}.items"),
                                 capacity: node.capacity, width: SLOT_BYTES.fetch(node.width), label: node.name.to_s)
            end
          end

          # One array of routines for each list a call-by-number picks from.
          def routine_table_declarations
            calls = @reachable.select { |node| node.kind == :call_one_of }
            calls.map(&:targets).uniq.map do |targets|
              C::FunctionTable.new(name: routine_table_name(targets), functions: targets.map { |name| routine(name) })
            end
          end

          # --- refusing what cannot be written yet ---

          # What a refusal calls the build this lowering makes. JS::Lowering says its own; every
          # refusal is otherwise the same for both.
          def build_name = "the desktop build"

          # What is refused is only what the program can reach: a console-only step in a routine
          # nothing calls never runs, so the game as C plays the same without it, as the
          # interpreter does, which complains of one only when it is reached.
          def refuse_unlowered_kinds!
            hardware = @reachable.map(&:kind).uniq.select { |kind| Portability.hardware_only?(kind) }
            unless hardware.empty?
              raise LoweringError,
                    "this program uses #{hardware.map(&:inspect).join(', ')}, which only means something on " \
                    "the console itself, so #{build_name} cannot make it."
            end

            missing = @reachable.map(&:kind).uniq.reject do |kind|
              STATEMENTS.key?(kind) || VALUES.key?(kind) || %i[else].include?(kind)
            end
            return if missing.empty?

            # Every kind is either written or listed as not yet (test_native_kind_coverage.rb
            # holds that), so a kind on neither is a mistake in this file, not in the game.
            unknown = missing - NOT_LOWERED_YET.values.flatten
            raise LoweringError, "the native backend has no row for #{unknown.map(&:inspect).join(', ')}" unless unknown.empty?

            raise LoweringError,
                  "this program uses #{missing.map(&:inspect).join(', ')}, which #{build_name} " \
                  "cannot make yet (#{NOT_LOWERED_YET.select { |_, kinds| kinds.intersect?(missing) }.keys.join(', ')}). " \
                  "The cartridge build can."
          end

          # --- statements ---

          def lower(node)
            send(STATEMENTS.fetch(node.kind), node)
          end

          # Each statement of a body, after where it was written — and, before any statement the
          # interpreter paints an owed rebuild of the picture for, the same painting (see
          # Reference.defers_repaint?, which this asks rather than keeping a copy of the rule).
          def body_of(node)
            node.children.flat_map do |child|
              paint = Reference.defers_repaint?(child) ? [] : [eval_call("rg_screen_paint_owed_rebuild")]
              [*source_comment(child), *paint, *lower(child)]
            end
          end

          # Where in the game a statement was written, for a person reading the C.
          def source_comment(node)
            node.source ? [C::Comment.new(node.source)] : []
          end

          def lower_children(node) = body_of(node)

          def lower_nothing(_node) = []

          # A variable set to itself changes nothing, and C's compiler refuses the statement
          # written out, so nothing is written for one. A game comes to it honestly: a helper
          # that takes where to keep its answer, handed the place the answer already is.
          def lower_set(node)
            return [] if node.value.is_a?(Node) && node.value.kind == :var_ref && node.value.name == node.var

            [assign(node.var, value(node.value))]
          end

          def lower_add(node) = [assign(node.var, call("rg_add", variable(node.var), value(node.operand)))]
          def lower_sub(node) = [assign(node.var, call("rg_sub", variable(node.var), value(node.operand)))]
          def lower_copy(node) = node.dest == node.src ? [] : [assign(node.dest, variable(node.src))]
          def lower_negate(node) = [assign(node.var, call("rg_neg", variable(node.var)))]
          def lower_abs(node) = [assign(node.var, call("rg_abs", variable(node.var)))]

          # -|v|: turned round only when it is above nought, so the lowest number stays itself.
          def lower_negate_abs(node)
            v = variable(node.var)
            [C::If.new(condition: call("rg_gt", v, C::Int.new(0)), body: [assign(node.var, call("rg_neg", v))])]
          end

          def lower_clamp(node)
            [assign(node.var, call("rg_clamp", variable(node.var), value(node.min), value(node.max)))]
          end

          def lower_if(node)
            otherwise = node.else ? body_of(node.else) : []
            [C::If.new(condition: value(node.cond), body: body_of(node), otherwise: otherwise)]
          end

          def lower_loop(node) = [C::While.new(condition: C::Int.new(1), body: body_of(node))]

          # A counted loop. The count is read once, before the first pass, as the interpreter
          # reads it; the index counts 0, 1, 2... and is stored in the game's variable at the
          # top of each pass; and +stop_when+ is asked BEFORE the body, so a loop already
          # finished on its first pass runs the body no times.
          def lower_repeat(node)
            count = local_name("count")
            index = local_name("index")
            pass = []
            pass << assign(node.index, index) if node.index
            pass << C::If.new(condition: value(node.stop_when), body: [C::Break.new]) if node.stop_when
            pass.concat(body_of(node))
            pass << C::Assign.new(index, call("rg_add", index, C::Int.new(1)))
            [C::Block.new([C::Local.new(name: count, value: value(node.count)),
                           C::Local.new(name: index, value: C::Int.new(0)),
                           C::While.new(condition: call("rg_lt", index, count), body: pass)])]
          end

          # A beat counted in frames. One pass of the game loop is one frame on a desktop, so
          # the counter moves by one; taking the period off rather than clearing it keeps any
          # remainder, as the interpreter does.
          def lower_every(node)
            counter = variable(node.counter)
            period = C::Int.new(node.period)
            [assign(node.counter, call("rg_add", counter, C::Int.new(1))),
             C::If.new(condition: call("rg_ge", counter, period),
                       body: [assign(node.counter, call("rg_sub", counter, period)), *body_of(node)])]
          end

          # Once, when the counter REACHES the number of frames.
          def lower_after(node)
            counter = variable(node.counter)
            frames = C::Int.new(node.frames)
            [C::If.new(condition: call("rg_lt", counter, frames),
                       body: [assign(node.counter, call("rg_add", counter, C::Int.new(1))),
                              C::If.new(condition: call("rg_ge", counter, frames), body: body_of(node))])]
          end

          def lower_call(node) = [C::Eval.new(C::Call.new(function: routine(node.target)))]

          def eval_call(function, *args) = C::Eval.new(call(function, *args))

          # One of a list of routines by a number the game works out. The number is checked
          # against the ends of the list before the array is read, so a number naming no
          # routine calls nothing.
          def lower_call_one_of(node)
            which = local_name("which")
            last = C::Int.new(node.targets.length - 1)
            in_range = call("rg_both", call("rg_ge", which, C::Int.new(0)), call("rg_le", which, last))
            picked = C::Index.new(routine_table_name(node.targets), which)
            [C::Block.new([C::Local.new(name: which, value: value(node.which)),
                           C::If.new(condition: in_range, body: [eval_call("rg_call_routine", picked)])])]
          end

          # Picks the scene to run by the variable, read ONCE: a scene usually ends by setting
          # the variable to the next scene, and reading it again per clause would run that one
          # too, in the same pass.
          def lower_case(node)
            state = local_name("state")
            clauses = node.clauses.map do |clause_value, target|
              C::If.new(condition: call("rg_eq", state, C::Int.new(clause_value)), body: scene_call_statements(target))
            end
            [C::Block.new([C::Local.new(name: state, value: variable(node.var)), *clauses])]
          end

          # The statements that run +scene+ for a pass. A scene taking over is remembered, so what
          # a scene does as it arrives — its screen, its scenery — happens on the frame it changes
          # and not again while it stays. A scene that loads first and is handed over to has that
          # pass to itself for its pictures, and its routine runs from the pass after; the scene up
          # at power-on, which nothing handed over to, runs on the first pass all the same (see
          # IR::SceneHandover::Arrival#loads_first?). Before any scene, the note holds -1.
          def scene_call_statements(scene)
            current = @names.own("scene")
            number = C::Int.new(@scenes.fetch(scene))
            work = [C::Eval.new(C::Call.new(function: routine(scene)))]
            arriving = [C::Assign.new(current, number), *scene_arrival(scene)]
            taking_over = call("rg_ne", current, number)
            return [C::If.new(condition: taking_over, body: arriving), *work] unless @handover.arrival(scene).loads_first?

            at_power_on = local_name("at_power_on")
            [C::If.new(condition: taking_over,
                       body: [C::Local.new(name: at_power_on, value: call("rg_eq", current, C::Int.new(-1))),
                              *arriving, C::If.new(condition: at_power_on, body: work)],
                       otherwise: work)]
          end

          def lower_halt(_node) = [eval_call("rg_halt")]

          # --- timers (Reference#exec_timer_start, #exec_timer_stop, #timer_ticks) ---

          # The most timers a game may have (RG_MAX_TIMERS).
          MAX_TIMERS = 32

          # Every timer the program names, by starting it, stopping it, reading it or saying what
          # it does when it ticks, and the number the runtime knows each by.
          def timer_numbers
            names = @program.walk.filter_map do |node|
              case node.kind
              when :timer_start, :timer_stop, :timer_ticks then node.name
              when :on_timer then node.timer
              end
            end.uniq
            if names.size > MAX_TIMERS
              raise LoweringError, "this program has #{names.size} timers, and #{build_name} has room for #{MAX_TIMERS}."
            end

            names.each_with_index.to_h
          end

          def timer_number(name) = C::Int.new(@timers.fetch(name))

          # The interpreter's sixty frames a second go with the rate, so the C divides by the
          # number Ruby divides by.
          def lower_timer_start(node)
            [eval_call("rg_timer_start", timer_number(node.name), C::Int.new(node.hz), C::Int.new(Reference::FRAME_RATE))]
          end

          def lower_timer_stop(node) = [eval_call("rg_timer_stop", timer_number(node.name))]
          def value_of_timer_ticks(node) = call("rg_timer_ticks", timer_number(node.name))

          # The routine the runtime calls for each tick of a timer (Reference#accrue_timer),
          # running what that timer does when it ticks. Where a handler is written, nothing
          # runs: it is its timer's, not the line's (Reference#exec_on_timer).
          def timer_ticks
            handlers = @tick_handlers.map do |timer, handler|
              C::If.new(condition: call("rg_timer_ticking", timer_number(timer)), body: body_of(handler))
            end
            C::Function.new(name: @names.own("timer_ticks"), body: handlers, exported: true)
          end

          # The runtime ends the frame (shows it, reads the buttons, keeps time), and the frame
          # counters the program can read move on, where the interpreter moves them. Last, a game
          # that bends a background it has works every bend's lines out for the pass to come
          # (Reference#work_out_bends), and a game with a light works out where it falls
          # (Reference#work_out_shade).
          def lower_wait_vblank(_node)
            count = variable(Frames::COUNT)
            [eval_call("rg_wait_vblank"),
             assign(Frames::COUNT, call("rg_add", count, C::Int.new(1))),
             assign(Frames::SEEN, count),
             assign(Frames::STEP, C::Int.new(1)),
             *(@bends.empty? ? [] : [eval_call("rg_screen_work_out_bends")]),
             *(@shade ? [eval_call("rg_screen_work_out_shade")] : [])]
          end

          # --- lists (runtime/rg_list.h does the work and the checking) ---

          def lower_list_new(node) = [list_call("rg_list_empty", node)]
          def lower_list_push(node) = [list_call("rg_list_push", node, value(node.value))]
          def lower_list_drop(node) = [list_call("rg_list_drop", node, C::Int.new(node.from == :front ? 1 : 0))]
          def lower_list_set(node) = [list_call("rg_list_set", node, value(node.index), value(node.value))]

          def lower_list_fill(node)
            [list_call("rg_list_fill", node, value(node.from), value(node.count), value(node.value))]
          end

          def lower_list_copy(node)
            table = @tables.fetch(node.table)
            kept = TABLE_KEPT_AS.fetch(table_type(table))
            [list_call("rg_list_copy", node, @names.of(:table, node.table), C::Int.new(kept), C::Int.new(table.values.length),
                       value(node.at), C::Int.new(node.count))]
          end

          def list_call(function, node, *args)
            C::Eval.new(call(function, C::AddressOf.new(list(node.name)), *args))
          end

          # --- values ---

          def value(operand)
            case operand
            when Integer then C::Int.new(Int32.wrap(operand))
            when Symbol then variable(operand)
            when Node then send(VALUES.fetch(operand.kind), operand)
            else raise LoweringError, "cannot write #{operand.inspect} as a number"
            end
          end

          def value_of_int(node) = C::Int.new(Int32.wrap(node.value))
          def value_of_var_ref(node) = variable(node.name)
          def value_of_binop(node) = call(OPERATORS.fetch(node.op), value(node.lhs), value(node.rhs))
          def value_of_neg(node) = call("rg_neg", value(node.operand))
          def value_of_bit_not(node) = call("rg_not", value(node.operand))
          def value_of_absolute(node) = call("rg_abs", value(node.operand))
          def value_of_clamped(node) = call("rg_clamp", value(node.operand), value(node.min), value(node.max))
          def value_of_mul_fix(node) = call("rg_mul_fix", value(node.lhs), value(node.rhs), fraction_bits(node))
          def value_of_div_fix(node) = call("rg_div_fix", value(node.lhs), value(node.rhs), fraction_bits(node))

          # How many bits of a number hold its fraction. rg_int32.h is written for 0 to 32,
          # which is every scale the framework uses; any other would shift past what its 64-bit
          # sums can hold.
          def fraction_bits(node)
            bits = node.fraction_bits
            raise LoweringError, "a fraction kept in #{bits} bits cannot be written as C (0 to 32 can)" unless bits.between?(0, 32)

            C::Int.new(bits)
          end
          def value_of_shift_right(node) = call("rg_shr", value(node.operand), C::Int.new(node.bits))
          def value_of_held(node) = call("rg_held", C::Int.new(button_number(node.button)))
          def value_of_pressed(node) = call("rg_pressed", C::Int.new(button_number(node.button)))

          # A chance holds when the random draw lands below the threshold.
          def value_of_chance(node) = call("rg_lt", value(node.draw), C::Int.new(node.percent))

          # A table read with an index out of range made safe the way the other backends make
          # it: a table whose length is a power of two wraps the index (what an angle wants),
          # any other clamps it to the ends.
          def value_of_table_get(node)
            values = @tables.fetch(node.name).values
            count = values.length
            index = value(node.index)
            safe = if count.positive? && (count & (count - 1)).zero?
                     call("rg_and", index, C::Int.new(count - 1))
                   else
                     call("rg_clamp", index, C::Int.new(0), C::Int.new(count - 1))
                   end
            C::Index.new(@names.of(:table, node.name), safe)
          end

          def value_of_list_get(node) = call("rg_list_get", C::AddressOf.new(list(node.name)), value(node.index))
          def value_of_list_len(node) = call("rg_list_length", C::AddressOf.new(list(node.name)))

          # One byte of a named piece of data. The index is a number written in the program, so
          # one past the end is refused here, where the interpreter would refuse it as it runs.
          def value_of_data_byte(node)
            data = @data.fetch(node.name) { raise LoweringError, "reference to undefined data #{node.name.inspect}" }
            length = (data.kind == :data ? data.bytes : data.pixels).bytesize
            unless node.index.between?(0, length - 1)
              raise LoweringError, "data_byte index #{node.index} is past the end of #{node.name.inspect}"
            end

            C::Index.new(@names.of(:data, node.name), C::Int.new(node.index))
          end

          # --- names and small pieces ---

          # The buttons in the order the console's key register holds them, which is also
          # IR::Buttons::NAMES's order; -1 means any of them.
          def button_number(button)
            return -1 if button == Buttons::ANY

            Buttons::NAMES.index(button) or raise LoweringError, "unknown button #{button.inspect}"
          end

          # Every scene a `case` can hand over to, numbered from 0 in the order they appear.
          def scene_numbers
            @program.walk.select { |node| node.kind == :case }.flat_map { |node| node.clauses.map(&:last) }
                    .uniq.each_with_index.to_h
          end

          def variable(name) = @names.of(:variable, name)
          def list(name) = @names.of(:list, name)
          def routine(name) = @names.of(:routine, name)
          def routine_table_name(targets) = @names.of(:table_of_routines, targets.join("_"))
          def assign(name, expression) = C::Assign.new(variable(name), expression)
          def call(function, *args) = C::Call.new(function: C::Name.new(function), args: args)

          def local_name(what)
            @locals += 1
            @names.of(:local, "#{what}#{@locals}")
          end
        end
      end
    end
  end
end
