# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      # WHAT A CARTRIDGE LOWERING WORKS OUT FROM A PROGRAM BEFORE IT WRITES ONE INSTRUCTION. The Color
      # and Super Nintendo lowerings (GBC::Lowering, SNES::Lowering) each turn a program into machine
      # code for a processor of their own, and both first have to answer the same questions about it:
      # which routines a run can reach and which statements, the number each timer and scene is
      # known by, which tables a run reads and how narrow each can be kept, what a sum written out
      # in numbers comes to, and whether the program asks for something the console cannot do at
      # all. None of those answers depends on the processor, so they are worked out here, once, and
      # read by both; a lowering keeps only what is its own — the instructions, and where its
      # console keeps things.
      #
      # Answered twice, the two copies drifted apart: one counted the routines a bend's steps call
      # and the other did not, one worked out a table read at a fixed index and the other read it
      # as the game ran. Kept here, a fix lands on every console at once.
      class LoweringPlan
        # How a table keeps its entries, by the width the game declared and whether they are
        # signed: bytes an entry, and the range that holds. Any other table keeps whole words.
        TABLE_WIDTHS = Ractor.make_shareable({ [:byte, true] => [1, -128..127], [:byte, false] => [1, 0..255],
                                               [:half, true] => [2, -32_768..32_767], [:half, false] => [2, 0..65_535] })

        # How many bytes a slot of a list takes, by the width it was declared with.
        SLOT_BYTES = Ractor.make_shareable({ byte: 1, half: 2, word: 4, nil => 4 })

        # What a sum or a comparison of numbers written in the program comes to, worked out while the
        # cartridge is built rather than as it runs: IR::Int32's own answer, which every runtime's is.
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

        # The console the cartridge is for (a Console::Description), whose answers and frame order
        # the plan follows.
        attr_reader :console

        # The program's routines by name; what each timer does when it ticks, by the timer, wherever
        # that is written; and the number each timer is known by, in the order the program first
        # names them.
        attr_reader :funcs, :tick_handlers, :timers

        # The routines a run can reach, by name, and every statement a run can reach.
        attr_reader :called, :reachable

        # The lists the program declares, by name: a list is there, empty, from power-on wherever it
        # is declared (the interpreter gathers them before running), so its storage is the first
        # declaration's. And every table, by name.
        attr_reader :declared_lists, :tables

        # What each scene hands the next across a change of screen (SceneHandover), and the number
        # each scene is known by, in the order the program first dispatches to them.
        attr_reader :handover, :scenes

        # +error+ is the lowering's own error class, which every refusal here raises.
        def initialize(program, console:, error:)
          @program = program
          @console = console
          @error = error
          @funcs = program.walk.select { |node| node.kind == :func }.to_h { |node| [node.name, node] }
          @tick_handlers = Nodes::OnTimer.of(program)
          @timers = program.walk.filter_map do |node|
            case node.kind
            when :timer_start, :timer_stop, :timer_ticks then node.name
            when :on_timer then node.timer
            end
          end.uniq.each_with_index.to_h
          # A bend's steps run at every frame boundary, wherever it is declared, so a routine they
          # call is reached as a timer's handler's is.
          bend_roots = program.walk.select { |node| node.kind == :scroll_rows }
          @called = Reach.routines(program, also: @tick_handlers.values + bend_roots)
          @reachable = Reach.statements_from(program, *@called.map { |name| @funcs.fetch(name) }, *@tick_handlers.values,
                                             *bend_roots)
          @declared_lists = @reachable.reverse.select { |node| node.kind == :list_new }.to_h { |node| [node.name, node] }
          @tables = program.walk.select { |node| node.kind == :table }.to_h { |node| [node.name, node] }
          @handover = SceneHandover.of(program)
          @scenes = program.walk.select { |node| node.kind == :case }.flat_map { |node| node.clauses.map(&:last) }
                           .uniq.each_with_index.to_h
        end

        # A routine of the game's, as the author names it: a scene as one.
        def routine_said(name) = @scenes.key?(name) ? "scene #{name.inspect}" : name.to_s

        # The tables a run reads, by an entry or by copying a run of them into a list.
        def tables_read
          @tables_read ||= begin
            read = @reachable.filter_map do |node|
              case node.kind
              when :table_get then node.name
              when :list_copy then node.table
              end
            end
            @tables.values.select { |table| read.include?(table.name) }
          end
        end

        # How +table+ keeps its entries — [bytes an entry, whether signed] — as the cartridge keeps
        # it: at the width the game declared when every entry fits it, and whole words otherwise.
        # Reading an entry widens it back to a whole number either way.
        def table_keeping(table)
          signed = table.signed ? true : false
          bytes, range = TABLE_WIDTHS[[table.width, signed]]
          return [bytes, signed] if bytes && table.values.all? { |entry| range.cover?(Int32.wrap(entry)) }

          [4, true]
        end

        # The number +node+ comes to when everything in it is written in the program, or nil.
        def folded(node)
          case node
          when Integer then Int32.wrap(node)
          when Node then folded_node(node)
          end
        end

        # Every game loop of the program.
        def game_loops = @game_loops ||= @program.walk.select { |node| node.kind == :loop }

        # +node+'s statements in the console's order (IR::Frames.loop_in_console_order): on a console
        # that sends its sprites and scroll from a copy as the wait ends, the frame's are placed
        # before its wait; on another, as written.
        def console_loop(node)
          (@console_loops ||= {})[node.object_id] ||= Frames.loop_in_console_order(node.children, @console)
        end

        # A step a run can reach that only means something on the Advance, refused by name. A step in
        # a routine nothing calls never runs, and is not refused.
        def refuse_hardware_only_kinds!
          hardware = @reachable.map(&:kind).uniq.select { |kind| Portability.hardware_only?(kind) }
          return if hardware.empty?

          raise @error, "This game uses #{hardware.map(&:inspect).join(', ')}, which only means something on the " \
                        "Game Boy Advance. The #{@console.title} build cannot make it. To fix this, build the game " \
                        "for the Game Boy Advance alone."
        end

        # What the console cannot do at all, and the layers one screen cannot have, refused as a
        # game's build refuses them (Checks::ConsoleAnswers, Checks::LayerRefusals). A program handed
        # straight to a lowering, as a test's is, never passes the build's checks; and one that names
        # no console, or another, is asked about as this one's.
        def refuse_what_console_lacks!
          asked = @program.console == @console.name ? @program : @program.copy.tap { |copy| copy.console = @console.name }
          refused = Guardrails::Checks::ConsoleAnswers.new.detect(asked).find { |finding| finding.severity == :error }
          refusal = refused&.message || Guardrails::Checks::LayerRefusals.message(asked)
          raise @error, refusal if refusal
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
                raise @error, "The routine #{start.inspect} can call itself again before it has finished. The " \
                              "#{@console.title} build cannot make that yet. To fix this, count with a loop in the " \
                              "routine instead."
              end
              next if seen.include?(name)

              seen << name
              waiting.concat(calls.fetch(name))
            end
          end
        end

        private

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
          when :table_get then folded_table_get(node)
          end
        end

        # Reference#value_of_table_get: a table never changes, so its entry at an index the program
        # writes is a number the program writes, and nothing is read as the game runs.
        def folded_table_get(node)
          index = folded(node.index)
          values = @tables[node.name]&.values
          return nil unless index && values&.any?

          count = values.length
          at = count.nobits?(count - 1) ? index & (count - 1) : index.clamp(0, count - 1)
          Int32.wrap(values[at])
        end

        # Reference#clamp_value: held at the floor, then at the ceiling.
        def folded_clamp(node)
          number, floor, ceiling = [node.operand, node.min, node.max].map { |part| folded(part) }
          return nil unless number && floor && ceiling

          [[number, floor].max, ceiling].min
        end
      end
    end
  end
end
