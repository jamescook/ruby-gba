# frozen_string_literal: true

require VBlank.root.join("lib/vblank/ir/stacking").to_s

module VBlank
  module IR
    module Guardrails
      module Checks
        # A status bar beside something that needs the same part of the display.
        #
        # ON THE ADVANCE the bar is one of the background layers, kept to the rows under its top by
        # one of the display's windows, which is told which layers show inside it and outside. A
        # light, a fade held to a rectangle and a fade placed in the stack tell the windows which
        # layers to show as well, and one answer for both cannot be given. So a game with a bar
        # does none of them, anywhere in it.
        #
        # ON THE COLOR the bar is the console's window: a layer of its own, read from the second
        # grid of cells. A painted screen keeps its picture in that same grid, so a game with a bar
        # paints no screen. And the console puts a sprite behind the background by putting it
        # behind every coloured pixel of the background AND the window, so a sprite stacked behind
        # a background would be behind the bar too, where the interpreter draws every sprite over
        # it.
        #
        # Both are asked of the console the program is built for (Console::Description
        # #bar_is_a_background tells the two apart), so the interpreter refuses what the
        # cartridge would get wrong, in the same words.
        class StatusBarCannotShare
          NAME = :status_bar_cannot_share
          PLAIN_NAME = "a status bar beside something that needs the same part of the display"

          def detect(program)
            bar = program.walk.find { |node| node.kind == :background && node.bar? }
            return [] unless bar

            console = program.described_console
            found = console.bar_is_a_background ? window_sharing(program, bar, console) : grid_sharing(program, bar, console)
            found ? [found] : []
          end

          # Why the bar is refused, or nil when it fits — the words the interpreter and each
          # lowering stop with too.
          def refusal_message(program)
            detect(program).first&.message
          end

          private

          def window_sharing(program, bar, console)
            other = program.walk.find do |node|
              node.kind == :shade_outside || (node.kind == :fade && (node.under || node.reaches))
            end
            return unless other

            what = if other.kind == :shade_outside then "a light (a `spotlight` or an `iris_out`)"
                   elsif other.under then "a fade under the layer :#{other.under}"
                   else "a fade held to part of the screen"
                   end
            refusal(other, "This game has the status bar :#{bar.name} and #{what}. On the #{console.title}, " \
                           "both need the same part of the display, and that part can do only one of the " \
                           "two. To fix this, remove the status bar, or remove #{what}.")
          end

          def grid_sharing(program, bar, console)
            painted = program.walk.find { |node| node.kind == :screen && node.mode == :bitmap }
            if painted
              return refusal(painted, "This game has the status bar :#{bar.name} and a `screen :bitmap`. On the " \
                                      "#{console.title}, the bar and a painted screen use the same memory. To fix " \
                                      "this, remove the status bar, or draw that screen with tiles: `screen :tiled`.")
            end

            sprite = sprite_behind_scenery(program)
            return unless sprite

            refusal(sprite, "This game has the status bar :#{bar.name}, and the layers put the sprite :#{sprite.declared || sprite.name} " \
                            "behind a background. On the #{console.title}, a sprite behind a background is behind " \
                            "the status bar too. To fix this, put the sprite in front of the backgrounds, or " \
                            "remove the status bar.")
          end

          # The first sprite a screen with a bar stacks behind one of its backgrounds, or nil.
          def sprite_behind_scenery(program)
            Stacking.screenfuls(program).each do |screenful|
              next unless screenful.scenery.any?(&:bar?)

              scenery = screenful.scenery.reject(&:bar?)
              next if scenery.empty?

              frontmost = scenery.map { |node| screenful.depths[node.name] }.max
              sprite = screenful.objects.find { |node| Stacking.levels_of(screenful.depths, node).min < frontmost }
              return sprite if sprite
            end
            nil
          end

          def refusal(node, message) = Finding.new(check: NAME, severity: :error, node: node, message: message)
        end
      end
    end
  end
end
