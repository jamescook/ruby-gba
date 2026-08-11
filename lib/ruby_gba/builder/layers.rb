# frozen_string_literal: true

module RubyGBA
  class Builder
    # THE STACK: naming the depths a picture is built from, and putting things in them.
    #
    # A game is drawn in layers — the scenery, the characters, the score on top — and
    # without a name for them the only way to say what sits in front of what is the
    # order the declarations happen to run in. That order is invisible, it lives in
    # prose comments, and in a game split across files it depends on which file was
    # required first. `layers` gives those depths names, and `layer do ... end` puts
    # things in them.
    #
    #   layers :sky, :world, :actors, :ui     # the stack, back to front
    #
    #   scene :playing do
    #     layer :world  do background :level, tiles: :world_tiles, map: LEVEL end
    #     layer :actors do hero = sprite :hero, at: [100, 60] end
    #     layer :ui     do draw_number :score, 8, 8, :white end
    #   end
    #
    # TWO CONSTRUCTS, AND THE SPLIT IS THE POINT. The ORDER is global, because "in front
    # of" is a relation across the whole screen — one line answers the question a reader
    # of somebody else's game actually has. The ASSIGNMENT is local, in a block, so
    # nothing has to carry a layer keyword and nobody has to reconstruct the order by
    # finding every declaration in every file.
    #
    # A LAYER HOLDS THINGS, NOT BRUSHSTROKES. The instinct people arrive with is that a
    # layer is a surface you draw on — clear this layer, put a pixel on this layer.
    # Nothing on this console works that way, and it is not close: a bitmap screen has
    # one framebuffer, and a tiled screen's layers are grids of references to shared
    # tiles rather than canvases of their own. Giving each layer its own pixels would
    # mean blending two full screens in software every frame, which costs more than
    # twice the time a frame has and eats the memory besides. So a layer orders the
    # things the framework draws again for you every frame — a background, a sprite,
    # tiled text — and anything that paints where it is called stays outside.
    #
    # A SCENE AND A LAYER ARE DIFFERENT AXES, and they never need to know about each
    # other. A scene is WHEN (which state of the game shows this); a layer is WHERE IN
    # THE STACK (what is in front of what). A HUD can be in `:ui` and in `:playing` —
    # on top, and only while playing.
    module Layers
      # WHAT A LAYER CAN HOLD, by the kind of node a verb records. Held things are the
      # ones the framework draws again every frame, so an order over them means
      # something. Painted ones happen where the call happens — by the time the next
      # frame is drawn they are already part of the picture, and no ordering can reach
      # back and change that.
      #
      # Locked against the whole drawing category by a test, so a new drawing kind has
      # to be classified here on purpose rather than falling into whichever answer the
      # lookup happens to default to.
      #
      # Painting is refused on EITHER screen, and that is a decision rather than an
      # oversight. On a bitmap screen a layer block full of straight-line drawing could
      # be read as paint order and quietly allowed — but only while the same layer is
      # written in one place. Write it in two, with a branch between them, and honoring
      # the order would mean moving emitted drawing across that branch, which cannot be
      # done. One answer everywhere beats one that holds until a game grows.
      IN_A_LAYER = {
        # held — declared once, drawn again every frame, so a layer can order them
        object: :held,
        background: :held,

        # painted — these happen where the call happens
        pixel: :painted,
        fill_rect: :painted,
        dma_fill_rect: :painted,
        draw_rect_at: :painted,
        clear_screen: :painted,
        blit: :painted,
        draw_text: :painted,
        draw_digit: :painted,

        # the whole screen — these describe what the display shows, not one thing in it
        camera: :whole_screen,
        fade: :whole_screen,

        # nothing a layer has an opinion about: the display mode, a background's window,
        # and the painting the framework itself does to put a software sprite on screen
        # and take it off again. A handle's own painting reaches the tree by another
        # route (Builder#record_statement) and never asks this question, so these are
        # here for completeness rather than because a layer block can meet one.
        screen: :free,
        present_objects: :free,
        scroll_background: :free,
        scroll_rows: :free,
        blit_pose: :free,
        save_region: :free,
        restore_region: :free,
      }.freeze

      # The verb an author writes for each kind that cannot go in a layer, so the error
      # names the line they wrote rather than the node it became.
      VERB_FOR = { draw_digit: :draw_number }.freeze

      # Declare the program's stack of layers, backmost first — the one line that says
      # what is in front of what.
      #
      #   layers :sky, :world, :actors, :ui
      #
      # Every layer a `layer` block names has to be in here. Declaring the stack changes
      # nothing on its own: it names depths, and things put themselves in them.
      #
      # @param names [Array<Symbol>] the layers, back to front
      # @return [Array<Symbol>] the stack
      def layers(*names)
        names = names.flatten
        check_stack_not_declared!
        check_stack_names!(names)

        @layer_stack = names
        record(Build.layers(names))
        names
      end

      # Put everything the block declares in one layer.
      #
      #   layer :actors do
      #     hero = sprite :hero, at: [100, 60]
      #     enemies = Enemies.new(self)
      #   end
      #
      # The block runs on the build, exactly like a `func` body or the build block
      # itself, so every DSL verb is available inside and the parts-in-files pattern
      # works (`Enemies.new(self)`). What changes is only that the things which have a
      # depth take this one.
      #
      # It hands back whatever the block ended on, so a layer holding one thing reads as
      # one line — `hero = layer(:actors) { sprite :hero, at: [100, 60] }` — and a layer
      # holding several is written the way anything else with a block is.
      #
      # @param name [Symbol] a layer named in {#layers}
      # @return [Object] the block's value
      def layer(name, &block)
        raise ArgumentError, "`layer :#{name}` needs a block: `layer :#{name} do ... end`." unless block

        check_layer_can_open!(name)

        @current_layer = name
        begin
          run_block(&block)
        ensure
          @current_layer = nil
        end
      end

      private

      # The layer being declared into right now, or nil outside a `layer` block. What
      # the declaring verbs read to put their handle at a depth.
      attr_reader :current_layer

      # Put a node in the layer that is open, or refuse it. Called for every statement
      # the DSL records, so a verb never has to remember to ask.
      def place_in_layer(node)
        return unless @current_layer

        case IN_A_LAYER.fetch(node.kind, :free)
        when :held then node.layer = @current_layer
        when :painted then refuse_painting_in_layer!(node)
        when :whole_screen then refuse_whole_screen_in_layer!(node)
        end
      end

      # A picture is normally scenery at the back and everything that moves in front of
      # it, and something that named no layer is left in that arrangement. Put a
      # background IN FRONT of a sprite and the arrangement is gone, and with it the
      # answer for anything that named no layer — there is no longer a "where it always
      # was" to leave it in. So that picture has to place everything.
      def verify_stack_fits!
        return if @layer_stack.empty?

        picture = IR::Stacking.picture(@program)
        return unless IR::Stacking.scenery_over_objects?(picture.depths,
                                                         scenery: picture.scenery,
                                                         objects: picture.objects)

        homeless = (picture.scenery + picture.objects).reject { |node| @layer_stack.include?(node.layer) }
        return if homeless.empty?

        raise ArgumentError,
              "This picture puts a background in front of a sprite, and #{homeless.length} thing" \
              "#{'s' if homeless.length > 1} in it name no layer. When a background is in front of " \
              "a sprite, every background and every sprite must say where it sits, or there is no " \
              "way to know what is in front of it. To fix this, put each one in a `layer` block. " \
              "The stack is #{list_of(@layer_stack)}, back to front."
      end

      def check_stack_not_declared!
        return if @layer_stack.empty?

        raise ArgumentError,
              "The layers are already declared: #{list_of(@layer_stack)}. A program declares " \
              "its stack one time. To fix this, put every layer in that one `layers` line."
      end

      def check_stack_names!(names)
        if names.empty?
          raise ArgumentError,
                "`layers` needs at least one name, like `layers :world, :ui`. Name them " \
                "back to front."
        end

        unless names.all?(Symbol)
          raise ArgumentError,
                "`layers` takes names, like `layers :world, :ui`. You gave " \
                "#{names.reject { |n| n.is_a?(Symbol) }.map(&:inspect).join(', ')}."
        end

        repeated = names.tally.select { |_name, count| count > 1 }.keys
        return if repeated.empty?

        raise ArgumentError,
              "`layers` names #{list_of(repeated)} more than one time. Each layer has its " \
              "own name and its own place in the stack. To fix this, remove the repeat."
      end

      def check_layer_can_open!(name)
        if @current_layer
          raise ArgumentError,
                "A `layer` block cannot hold another `layer` block. The stack is one list, " \
                "from back to front. To fix this, close the `layer :#{@current_layer}` block, " \
                "then open `layer :#{name}`."
        end

        if @layer_stack.empty?
          raise ArgumentError,
                "This program declares no layers, so :#{name} is not one. To fix this, declare " \
                "the stack first: `layers :#{name}`. Name every layer in that one line, back " \
                "to front."
        end

        return if @layer_stack.include?(name)

        raise ArgumentError,
              "There is no layer named :#{name}. The stack is #{list_of(@layer_stack)}, back " \
              "to front. To fix this, use one of those names, or add :#{name} to the `layers` line."
      end

      # A routine's body is built after the DSL block has run, when no layer is open, so
      # anything it declares would get no layer at all. That is the silent wrong picture
      # this whole feature exists to remove, so refuse it and say which way round works.
      # Only the routines an author writes reach here: the ones the framework declares
      # for you (an effect's per-frame body) go through #declare_func instead, because
      # a body that runs every frame is behavior and has no place in the picture.
      #
      # A `game_loop` inside a layer block is NOT refused, and the difference is worth
      # keeping straight. A func is a mechanical problem — the layer provably cannot
      # reach the body. A game loop's body runs right there, so the layer does reach it
      # and a sprite declared inside gets the depth it looks like it gets. Refusing that
      # would be a rule about tidiness, and a rule that costs somebody a working program
      # needs a better reason than tidiness.
      def refuse_routine_in_layer!(verb)
        return unless @current_layer

        raise ArgumentError, ROUTINE_IN_LAYER.fetch(verb).call(@current_layer)
      end

      ROUTINE_IN_LAYER = {
        func: lambda { |layer|
          "A `func` inside a `layer` block does not belong to the layer :#{layer}. The body " \
            "of a func runs later, when the ROM is built, and the layer is not in force then. " \
            "To fix this, put the `layer` block inside the func:\n" \
            "  func :setup do\n" \
            "    layer :#{layer} do ... end\n" \
            "  end"
        },
        scene: lambda { |layer|
          "A `scene` cannot go inside a `layer` block. A scene is a state of the game, and a " \
            "state holds things at many depths. A layer is one depth. To fix this, put the " \
            "`layer :#{layer}` block inside the scene."
        },
      }.freeze

      def refuse_painting_in_layer!(node)
        verb = VERB_FOR.fetch(node.kind, node.kind)
        raise ArgumentError,
              "`#{verb}` paints where you call it#{on_a_bitmap_screen(node)}, so it cannot " \
              "belong to the layer :#{@current_layer}. A layer holds the things the framework " \
              "draws again every frame — a `background`, a `sprite`, tiled text. To fix this, " \
              "call `#{verb}` outside the `layer` block."
      end

      # Text is the one verb whose nature changes with the screen. On a tiled screen the
      # console draws each character for you every frame, so it IS layerable and records
      # objects; on a bitmap screen it paints into the framebuffer and reaches here. Say
      # which of the two the author is in, or the rule looks arbitrary.
      def on_a_bitmap_screen(node)
        %i[draw_text draw_digit].include?(node.kind) ? " on a `screen :bitmap`" : ""
      end

      def refuse_whole_screen_in_layer!(node)
        raise ArgumentError,
              "`#{node.kind}` changes the whole screen, so it cannot belong to the layer " \
              ":#{@current_layer}. To fix this, call `#{node.kind}` outside the `layer` block."
      end

      def list_of(names)
        names.map { |name| ":#{name}" }.join(", ")
      end
    end
  end
end
