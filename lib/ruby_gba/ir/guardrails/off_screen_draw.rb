# frozen_string_literal: true

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # A draw whose whole footprint lands off the 240x160 screen paints nothing
        # — the "why is my sprite missing / why is the screen blank" mystery, with
        # no crash to point at it. The framework already clips draws to the screen
        # for safety (a ship sliding half off an edge is fine, and a draw at
        # (999, 999) can never corrupt memory), so a *partly* off-screen draw is
        # intentional and stays silent. But a draw that is *entirely* off-screen
        # only happens by mistake — a wrong number, a swapped x and y — so we point
        # it out. It stays a safe no-op; this is just the warning that saves you the
        # hunt.
        #
        # Only draws whose position and size are known as the program is built are
        # checkable. One placed at a variable position is decided at run time (and
        # clipped safely then), so it's left alone here.
        class OffScreenDraw
          NAME = :off_screen_draw

          SCREEN_W = Screen::WIDTH
          SCREEN_H = Screen::HEIGHT

          # Warn for every draw whose fully-known footprint misses the screen.
          def detect(program)
            bitmaps = index_bitmaps(program)
            program.each.filter_map do |node|
              bounds = constant_bounds(node, bitmaps)
              next unless bounds && entirely_off_screen?(*bounds)

              Finding.new(check: NAME, severity: :warning, message: message(node, bounds), fix: nil)
            end
          end

          private

          # name -> [width, height] for every embedded bitmap, so a blit's footprint
          # (which comes from its image, not the blit op) can be sized.
          def index_bitmaps(program)
            program.each
                   .select { |node| node.kind == :bitmap }
                   .to_h { |node| [node[:name], [node[:width], node[:height]]] }
          end

          # [x, y, w, h] of a draw whose whole footprint is known at build time, or
          # nil when the node isn't a positioned draw, or its position/size is a
          # run-time value we can't pin down here.
          def constant_bounds(node, bitmaps)
            case node.kind
            when :pixel
              at(node) { |x, y| [x, y, 1, 1] }
            when :fill_rect, :dma_fill_rect, :draw_rect_at
              rect_bounds(node)
            when :draw_text
              at(node) { |x, y| font = Fonts.get(node[:font]); [x, y, font.text_width(node[:text]), font.height] }
            when :draw_digit
              at(node) { |x, y| font = Fonts.get(node[:font]); [x, y, font.width, font.height] } # one glyph
            when :blit
              blit_bounds(node, bitmaps)
            end
          end

          def rect_bounds(node)
            x = const_int(node[:x])
            y = const_int(node[:y])
            w = const_int(node[:w])
            h = const_int(node[:h])
            [x, y, w, h] if x && y && w && h
          end

          def blit_bounds(node, bitmaps)
            width, height = bitmaps[node[:name]]
            return nil unless width

            at(node) { |x, y| [x, y, width, height] }
          end

          # Yield the node's constant (x, y) to build its bounds, or nil if either
          # coordinate is a run-time value.
          def at(node)
            x = const_int(node[:x])
            y = const_int(node[:y])
            yield(x, y) if x && y
          end

          # A constant integer from a raw Integer or an `int` value node; nil for a
          # run-time operand (a variable reference, an expression).
          def const_int(operand)
            case operand
            when Integer then operand
            when Node then operand[:value] if operand.kind == :int
            end
          end

          # The screen is the box [0, SCREEN_W) x [0, SCREEN_H). A footprint misses
          # it entirely when it's fully left of, right of, above, or below that box.
          def entirely_off_screen?(x, y, w, h)
            x + w <= 0 || x >= SCREEN_W || y + h <= 0 || y >= SCREEN_H
          end

          def message(node, bounds)
            x, y, w, h = bounds
            "#{describe(node)} at (#{x}, #{y}) sized #{w}x#{h} lands entirely off the " \
              "#{SCREEN_W}x#{SCREEN_H} screen, so nothing will show. The screen runs from " \
              "(0, 0) at the top-left to (#{SCREEN_W - 1}, #{SCREEN_H - 1}) at the " \
              "bottom-right — double-check the position (a swapped x and y is a common cause)."
          end

          def describe(node)
            case node.kind
            when :pixel then "a pixel"
            when :fill_rect, :dma_fill_rect then "a filled rectangle"
            when :draw_rect_at then "a rectangle"
            when :draw_text then "the text #{node[:text].inspect}"
            when :draw_digit then "a digit"
            when :blit then "the image #{node[:name].inspect}"
            end
          end
        end
      end
    end
  end
end
