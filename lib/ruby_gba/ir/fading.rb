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
    #   screen, so there is never anything on a bitmap one for a fade to protect. That
    #   is the whole reason for the tear-free one, which does draw through a table and
    #   could walk it; the plain one holds a whole color in every pixel and has no table
    #   to walk in the first place. The screen is asked anyway rather than assumed, because
    #   one game can put a bitmap scene and a tiled scene side by side.
    #
    # HOW FINE A FADE GOES is the third thing this settles, and it is the other reason to
    # walk the colors. A display's own blend may count in coarser steps than the colors it
    # blends can show, and a fade walked over more frames than it has steps shows some of
    # them twice. Walking the colors can step as finely as a color can.
    #
    # So a fade whose amount holds a FRACTION asks for the finer steps, and a fade that asks
    # for them walks the colors wherever there is a table to walk: on a screen drawn through
    # one, and not placed in the stack. A whole-number amount keeps the steps it always had,
    # on every route, so asking for nothing changes nothing. How many steps each way has is
    # the backends' business (see Backends::FadeSteps), and when the screen fade verbs ask
    # is theirs (see Effects::Packs::ScreenFade).
    #
    # A placed fade cannot have them, for the reason above: only the display can place one.
    module Fading
      def self.resolve(program) = Answer.new(program)

      # IS THERE ANYTHING FOR A FADE TO KEEP in this see-through layer (a SeeThroughLayer)?
      # A layer NAMED as see-through is not enough — one fixed to show all of itself and
      # none of what is behind is solid already, so walking the colors for it would buy a
      # picture nobody can tell from the free fade. An amount the game works out is
      # counted, since it is not solid for long if it was worth writing.
      #
      # Public because the guardrail asks it too, and the two must agree: a game warned
      # about a trade it is not making, or making one it is not warned about, is exactly
      # the confusion this whole rule exists to remove.
      def self.can_be_seen_through?(layer)
        shows = DSL::Value.fixed_number(layer.shows)
        behind = DSL::Value.fixed_number(layer.behind)
        return true if shows.nil? || behind.nil?

        SeeThrough.weights(layer, shows, behind) != [SeeThrough::STEPS, 0]
      end

      # The first see-through layer of +program+ a fade has something to keep in, or nil.
      def self.layer_fade_preserves(program)
        SeeThrough.layers(program).find { |layer| can_be_seen_through?(layer) }
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
          @coarse_placed = []
          @fine = false
          classify_fades(program)
        end

        # Does this fade move the color table rather than the display's own blend? Asked of
        # a tint, which moves the table wherever there is one: is it counted in the walk's
        # thirty-seconds?
        def palette_walk?(node) = @walking.key?(node)

        # Does any fade walk the colors for the finer steps, whether or not a layer is seen
        # through? The build report says what that costs.
        def fine_palette_fade? = @fine

        # The fades that asked for the finer steps and cannot have them, being placed in the
        # stack — seventeen levels, so a long one changes the picture every other frame.
        attr_reader :coarse_placed

        # Does any fade in this program? The color tables have to be kept readable in the
        # cartridge for one that does, and the build report names the mechanism it got.
        def any_fade_walks_palette? = @walking.each_key.any? { |node| node.kind == :fade }

        # The fades that still take the display's blend on the screen a layer can be seen
        # through — the ones that leave that layer solid while they run, which is the only
        # thing left to warn a game about. Empty for a game with no layer to trade away.
        attr_reader :blend_fades

        private

        def classify_fades(program)
          fades = program.walk.select { |node| node.kind == :fade }
          tints = program.walk.select { |node| node.kind == :tint && node.fraction_bits }
          return if fades.empty? && tints.empty?

          modes = Modes.resolve(program)
          mark_fine_fades(fades, modes)
          mark_fine_tints(tints, modes)
          return unless sees_through_layer?(program)

          fades.select { |node| modes.mode_at(node) == Modes::TILED }.each do |node|
            node.under ? @blend_fades << node : @walking[node] = true
          end
        rescue Modes::Conflict
          # A program whose screens disagree is refused elsewhere, with a message about
          # the screens rather than about fading. Until then every fade keeps the blend,
          # so both of these go back to empty however far the walk above had got.
          @walking.clear
          @blend_fades.clear
          @coarse_placed.clear
          @fine = false
        end

        # A fade that asks for the finer steps walks the colors on a screen drawn through a
        # table. On the plain bitmap screen there is no table, and a placed fade has to be
        # the display's, so both of those keep the sixteenths — and the placed ones are
        # remembered, because that is a trade worth telling the author about.
        def mark_fine_fades(fades, modes)
          fades.select(&:fraction_bits).each do |node|
            next if modes.mode_at(node) == Modes::DIRECT
            next @coarse_placed << node if node.under

            @walking[node] = true
            @fine = true
          end
        end

        # A tint on a screen drawn through a table always walks it, so for a tint the only
        # question is the steps: a fraction counts in thirty-seconds there, and the display
        # blends a tint on the plain bitmap screen in sixteenths whatever it is given.
        def mark_fine_tints(tints, modes)
          tints.each do |node|
            @walking[node] = true unless modes.mode_at(node) == Modes::DIRECT
          end
        end

        def sees_through_layer?(program)
          !Fading.layer_fade_preserves(program).nil?
        end
      end
    end
  end
end
