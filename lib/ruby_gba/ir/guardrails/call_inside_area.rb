# frozen_string_literal: true

require_relative "tiled_display"

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # `inside` clips what it draws, but only what it draws DIRECTLY. A `call` to
        # a routine is a branch to code built once, outside any area — so a routine
        # that draws, called from inside an `inside` block, stays clipped in the
        # reference interpreter (which re-checks the area every time it runs the
        # routine) but not on the console (which bakes the clip into the routine's
        # own instructions wherever THAT routine happens to be lowered, never at the
        # call site). The two backends would show a different picture, and nothing
        # crashes to say so.
        #
        # Refusing the combination is the fix: an author can always move the
        # `inside` block inside the routine itself, so the clip travels with the
        # routine everywhere it's called from instead of living at one call site.
        class CallInsideArea
          NAME = :call_inside_area
          PLAIN_NAME = "a routine called inside an area"

          # Every draw op `inside` actually clips on the console — see
          # IR::Backends::GBA::Lowering#draw_area and the framebuffer clip bounds it
          # feeds. Reusing TiledDisplay::BITMAP_DRAWS would miss draw_column_at (a
          # first-person view's stretched wall column), which is exactly the shape
          # of the bug this check exists for.
          CLIPPED_DRAWS = %i[pixel fill_rect dma_fill_rect draw_rect_at draw_column_at
                              blit blit_pose clear_screen draw_text draw_digit].freeze

          def detect(program)
            funcs = program.each.select { |node| node.kind == :func }.to_h { |func| [func.name, func] }

            program.each.select { |node| node.kind == :inside }.flat_map do |area|
              calls_that_draw(area, funcs).map do |call_node, drawn_by|
                Finding.new(check: NAME, severity: :error,
                            message: message(call_node.target, drawn_by), node: call_node)
              end
            end
          end

          private

          # Every `:call` inside +area+'s block whose target routine draws — paired
          # with the kind of draw that convicts it.
          def calls_that_draw(area, funcs)
            area.children.flat_map { |child| find_calls(child) }.filter_map do |call_node|
              drawn_by = routine_draws?(call_node.target, funcs)
              [call_node, drawn_by] if drawn_by
            end
          end

          # Every `:call` in a subtree — descends into `:if`/`:loop`/`:repeat`
          # bodies (real children of the `inside` block), never into a `:func`
          # definition (there isn't one inside a block; funcs are top-level).
          def find_calls(node)
            calls = node.kind == :call ? [node] : []
            calls + node.children.flat_map { |child| find_calls(child) }
          end

          # Does the func named +name+ draw on the bitmap screen OUTSIDE any area of its
          # own — directly, or through a routine it calls, however many hops away?
          # Returns the kind that drew (for the message), or nil. +seen+ stops a call
          # cycle.
          #
          # A draw the routine itself wraps in `inside` is not the hazard: that area is
          # baked into the routine's own instructions, so the console clips it there
          # exactly as the interpreter does — it is the fix this check recommends, and
          # a game that already did it must not be told to do it again.
          def routine_draws?(name, funcs, seen = Set.new)
            return nil if seen.include?(name)

            func = funcs[name] or return nil

            unclipped_draw_in(func, funcs, seen | Set[name])
          end

          def unclipped_draw_in(node, funcs, seen)
            return nil if node.kind == :inside
            return node.kind if CLIPPED_DRAWS.include?(node.kind)
            return routine_draws?(node.target, funcs, seen) if node.kind == :call

            node.children.each do |child|
              hit = unclipped_draw_in(child, funcs, seen)
              return hit if hit
            end
            nil
          end

          def message(target, drawn_by)
            verb = TiledDisplay.verb_for(drawn_by)
            "`inside` clips what it draws, but `call :#{target}` calls a routine built once, " \
              "outside any area. `:#{target}` draws with `#{verb}`, directly or through " \
              "another routine it calls, so that drawing will not stay inside this area on " \
              "the console. The interpreter clips it here; the console does not.\n\n" \
              "Put `inside x, y, w, h do ... end` inside `:#{target}` itself instead. Then the " \
              "clip applies everywhere that routine runs, not only from this one call."
          end
        end
      end
    end
  end
end
