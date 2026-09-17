# frozen_string_literal: true

module RubyGBA
  module IR
    # WHICH PART OF THE DISPLAY A FADE TO BLACK OR WHITE USES.
    #
    # There are two ways to darken a whole picture on this console, and a picture can
    # only be having one of them done to it at a time.
    #
    # The display can do it as it draws. One register says how far toward black or white
    # the picture goes, and every pixel is moved that far on its way to the screen.
    # Nothing in memory changes and nothing is redrawn, so it costs the same however much
    # is on screen. That is the free one, and it is what a fade has always been here.
    #
    # The other way is what the games on this console actually do: walk the colors. A
    # picture drawn from a table of colors fades by moving every entry of that table
    # toward black, a step at a time, and writing the table out in the gap between
    # frames. It costs a blend per color the game declared, on each frame the fade
    # actually moves — never per pixel, and nothing at all while it holds still.
    #
    # WHICH ONE A GAME GETS MATTERS because the display has ONE blend unit, and seeing
    # through a layer is the other thing that unit does. A fade that takes it leaves the
    # water solid until the fade lifts, and pops it back when it does. Walking the colors
    # leaves the unit alone, so the water goes on showing the floor underneath it and the
    # whole picture — water, floor and the mix of the two — darkens together.
    #
    # SO THE RULE IS: a fade walks the colors exactly when the game has a see-through
    # layer to keep, and takes the free blend otherwise. A game with nothing to see
    # through draws the same picture either way, so it pays nothing for a choice it
    # cannot observe.
    #
    # TWO CASES ARE DELIBERATELY NOT THIS, and both are about what a shared table of
    # colors cannot express.
    #
    #   A FADE PLACED IN THE STACK — `fade :black, 100, under: :ui` — keeps the blend
    #   unit. Being placed IS a blend-unit feature: the console can hide a brightness
    #   change from the layers in front of a line, where a table of colors is read by
    #   everything that draws and has no notion of who is reading it. So a game that
    #   places its fade and also sees through a layer still trades one for the other.
    #
    #   NEITHER BITMAP SCREEN CHANGES AT ALL. Seeing through a layer needs a tiled
    #   screen, so there is never anything on a bitmap one for a fade to protect — and
    #   the plain bitmap screen holds a whole color in every pixel and has no table to
    #   walk in the first place. The screen is asked anyway rather than assumed, because
    #   one game can put a bitmap scene and a tiled scene side by side.
    module Fading
      def self.resolve(program) = Answer.new(program)

      # IS THERE ANYTHING FOR A FADE TO KEEP in this declared stack? A layer NAMED as
      # see-through is not enough — one fixed at 0 is solid already, so walking the colors
      # for it would buy a picture nobody can tell from the free fade. An amount the game
      # works out is counted, since it is not 0 for long if it was worth writing.
      #
      # Public because the guardrail asks it too, and the two must agree: a game warned
      # about a trade it is not making, or making one it is not warned about, is exactly
      # the confusion this whole rule exists to remove.
      def self.can_be_seen_through?(layers_node)
        return false unless layers_node.transparency

        fixed = DSL::Value.fixed_number(layers_node.transparency)
        fixed.nil? || fixed.positive?
      end

      # Worked out once for a whole program, because every fade in it is decided by the
      # same two facts — is there a layer to keep, and which screen is this fade on — and
      # the interpreter would otherwise ask again on every frame that fades.
      class Answer
        def initialize(program)
          # Nodes are compared by identity here, not by what they hold. Two fades written
          # the same way in two scenes are the same node as far as `==` goes, and those
          # two scenes can be on different screens.
          @walking = {}.compare_by_identity
          @blend_fades = []
          sort_the_fades(program)
        end

        # Does this fade move the color table rather than the display's own blend?
        def walks_the_colors?(node) = @walking.key?(node)

        # Does any fade in this program? The color tables have to be kept readable in the
        # cartridge for one that does, and the build report names the mechanism it got.
        def any_color_walk? = !@walking.empty?

        # The fades that still take the display's blend on the screen a layer can be seen
        # through — the ones that leave that layer solid while they run, which is the only
        # thing left to warn a game about. Empty for a game with no layer to trade away.
        attr_reader :blend_fades

        private

        def sort_the_fades(program)
          return unless sees_through_a_layer?(program)

          modes = Modes.resolve(program)
          fades_on_the_tiled_screen(program, modes).each do |node|
            node.under ? @blend_fades << node : @walking[node] = true
          end
        rescue Modes::Conflict
          # A program whose screens disagree is refused elsewhere, with a message about
          # the screens rather than about fading. Until then every fade keeps the blend,
          # so both of these go back to empty however far the walk above had got.
          @walking.clear
          @blend_fades.clear
        end

        # Only a fade on the tiled screen is in this at all. A game can put a bitmap scene
        # beside a tiled one, and a fade written in the bitmap scene reaches neither the
        # see-through layer nor a color table it is drawn from.
        def fades_on_the_tiled_screen(program, modes)
          program.walk.select { |node| node.kind == :fade && modes.mode_at(node) == Modes::TILED }
        end

        def sees_through_a_layer?(program)
          program.walk.any? { |node| node.kind == :layers && Fading.can_be_seen_through?(node) }
        end
      end
    end
  end
end
