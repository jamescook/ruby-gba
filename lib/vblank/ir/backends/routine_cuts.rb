# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      # A ROUTINE TOO BIG FOR A BANK, CUT INTO PARTS THAT EACH FIT ONE. A cartridge bigger than the
      # processor can see at once is seen a bank at a time, and a routine has to be in one bank
      # whole: the processor cannot run on from the end of a bank into the next. So a routine whose
      # code comes to more than a bank holds is cut. A run of statements side by side becomes a
      # routine of its own, called where they stood; a statement too big to move whole — an `if`, a
      # `loop`, a `repeat` — has what is inside it cut the same way instead. The parts share the
      # routine's own numbers, which are kept in work memory, so nothing is handed between them.
      #
      # How big a bank is, and so how big a routine may come to, is the console's; the lowering says
      # it, and says how many bytes a run of statements comes to by making them and throwing them
      # away (the block). Where to cut is the same on every console, and decided here.
      class RoutineCuts
        # A call of a part cut off a routine, standing where its statements stood.
        PartCall = Data.define(:label)

        # +most_routine_bytes+ is the most one routine's code may come to before it is cut, and
        # +most_part_bytes+ the most a part cut off it may; the block gives the bytes a list of
        # statements comes to.
        def initialize(plan:, most_routine_bytes:, most_part_bytes:, &measure)
          @plan = plan
          @most_routine_bytes = most_routine_bytes
          @most_part_bytes = most_part_bytes
          @measure = measure
          @cut = {} # a statement whose statements were cut into parts -> what stands for them
        end

        # +statements+ as a routine named +label+ holds them, and the parts cut off it to fit a bank:
        # [the routine's statements, [[a part's label, its statements], ...]]. A routine that fits is
        # its statements as they are, with no parts.
        def fit(label, statements)
          parts = []
          kept = @measure.call(statements) > @most_routine_bytes ? cut_list(statements, label, parts) : statements
          [kept, parts]
        end

        # The statements an `if`, a `loop` or a `repeat` holds, and an `if`'s `else`: its own, or
        # those they were cut into. A game loop's are what it runs each time round, in the console's
        # order (LoweringPlan#console_loop).
        def children_of(node)
          @cut.fetch(node.object_id) do
            body = node.kind == :loop ? @plan.console_loop(node).each_time : node.children
            [body, node.kind == :if ? node.else&.children || [] : []]
          end
        end

        private

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
            size = @measure.call([node])
            if size <= @most_part_bytes
              flush.call if run_bytes + size > @most_part_bytes
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
          cut = [cut_list(body, base, parts), cut_list(otherwise, base, parts)]
          @cut[node.object_id] = cut
          node
        end
      end
    end
  end
end
