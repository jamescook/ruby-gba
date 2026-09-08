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
        draw_column_at: :painted,
        clear_screen: :painted,
        blit: :painted,
        draw_text: :painted,
        draw_digit: :painted,

        # the whole screen — these describe what the display shows, not one thing in it
        camera: :whole_screen,
        fade: :whole_screen,
        tint: :whole_screen,

        # nothing a layer has an opinion about: the display mode, a background's window,
        # and the painting the framework itself does to put a software sprite on screen
        # and take it off again. A handle's own painting reaches the tree by another
        # route (Builder#record_statement) and never asks this question, so these are
        # here for completeness rather than because a layer block can meet one.
        screen: :free,
        present_objects: :free,
        scroll_background: :free,
        affine_background: :free,
        scroll_rows: :free,
        blit_pose: :free,
        save_region: :free,
        restore_region: :free,
        # ...and how see-through the see-through layer is, which the framework puts at the
        # frame boundary. It already knows the layer it is about, so it belongs to none.
        see_through: :free,
      }.freeze

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
        # Held so a `layer` block can say later that its layer is see-through: the stack
        # is one thing and it is declared here, but which of its layers you can see
        # through is written where that layer is opened.
        @layers_node = record(Build.layers(names))
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
      # `transparency:` says how much of what is BEHIND this layer shows through it —
      # water, glass, fog, a dimmed backdrop behind a menu. 0 is solid (the picture as
      # drawn) and 100 is invisible:
      #
      #   layer :water, transparency: 40 do
      #     background :surface, tiles: :ripples, map: WATER
      #   end
      #
      # What it means is what it looks like. Whatever sits directly under the layer at a
      # pixel shows through it; anything in FRONT of it draws solid; and where the layer
      # itself has a see-through tile, what is behind shows plain. The display does the
      # blending as it draws, so nothing is redrawn and it costs nothing however much is
      # on screen.
      #
      # THE AMOUNT CAN BE SOMETHING THE GAME WORKS OUT, which is fog that thickens, water
      # that gets murkier as you go down, a menu backdrop that dims in:
      #
      #   mist = var :mist, 0
      #   layer :air, transparency: 100 - mist do
      #     background :fog, tiles: :weather, map: SKY
      #   end
      #
      # Write a variable where you would write a number and that is the whole of it. The
      # difference is what it costs: a number is sent to the display once and never again,
      # where an amount that can change has to be sent again before every frame. That is
      # one register write, nothing is redrawn either way, and `rom.explain` says which of
      # the two a picture got.
      #
      # A game has ONE see-through layer, and it says the amount one time — every example
      # opens a layer block exactly once, so that is the natural place. Needs
      # `screen :tiled`: a bitmap screen paints its whole picture into one place before
      # the display sees it, so by then there is nothing left to see through.
      #
      # @param name [Symbol] a layer named in {#layers}
      # @param transparency [Integer, Symbol, Value, nil] how much of what is behind shows
      #   through, 0 to 100 — a number, or something the game works out
      # @return [Object] the block's value
      def layer(name, transparency: nil, &block)
        raise ArgumentError, "`layer :#{name}` needs a block: `layer :#{name} do ... end`." unless block

        check_layer_can_open!(name)
        make_layer_transparent(name, transparency) unless transparency.nil?

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
        return refuse_deferred_layer!(node) unless @current_layer

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

      # An effect can be PLACED in the stack instead of covering the whole screen —
      # `fade :black, 100, under: :ui` fades the game and leaves the score showing. What
      # it names has to be a layer, and the screen has to be one that HAS a stack.
      #
      # A bitmap screen does not. Everything on it — the scenery, the software sprites,
      # the text — is painted into one picture before the display ever sees it, so by
      # the time an effect could apply there is nothing left to tell apart.
      def check_effect_layer!(verb, name)
        unless name.is_a?(Symbol)
          raise ArgumentError,
                "`#{verb}` takes a layer name after `under:`, like `under: :ui`. You gave " \
                "#{name.inspect}."
        end

        if @screen_mode != :tiled
          raise ArgumentError,
                "`#{verb} ... under: :#{name}` needs `screen :tiled`. On a bitmap screen the " \
                "whole picture is painted into one place before the display sees it, so an " \
                "effect cannot leave one part of it alone. To fix this, use `#{verb}` with no " \
                "`under:`, which changes the whole screen."
        end

        check_layer_named!(name)
      end

      # Record that this layer is see-through, and refuse every way of asking for one the
      # console cannot show.
      #
      # ONE SEE-THROUGH LAYER PER GAME, and the honest reason is not that the console
      # cannot do two. It shares the AMOUNT rather than the layer, so two layers at the
      # same number would work on hardware. It is that a see-through layer sitting
      # directly over another one gives two different pictures: the console blends the
      # top two things at a pixel, and the reference interpreter paints back to front and
      # would blend all three. One rule keeps the two honest, and a rule the author can
      # hold in their head beats one that holds until their layers happen to touch.
      def make_layer_transparent(name, amount)
        check_transparency_amount!(name, amount)
        check_transparency_screen!(name)
        check_one_transparent_layer!(name, amount)

        @layers_node.transparent = name
        @layers_node.transparency = Value.node_for(amount)
        @transparency_written = amount
        ensure_var(amount)
      end

      def check_transparency_amount!(name, amount)
        fixed = Value.fixed_number(amount)
        return if fixed.nil? && value_like?(amount) # the game works it out — checked as it runs
        return if fixed && (0..100).cover?(fixed)

        unless fixed
          raise ArgumentError,
                "`layer :#{name}, transparency:` takes a whole number from 0 to 100, or " \
                "something the game works out (a variable, or a sum of them). You gave " \
                "#{amount.inspect}."
        end

        raise ArgumentError,
              "`layer :#{name}, transparency: #{fixed}` is outside 0 to 100. 0 is solid and " \
              "100 lets everything behind show through."
      end

      def value_like?(amount)
        amount.is_a?(Symbol) || amount.is_a?(Value) || amount.is_a?(IR::Node)
      end

      # How see-through the layer was asked to be, as the author wrote it — a number, or
      # the name of what the game works it out from. For a message about it.
      def transparency_as_written
        Value.fixed_number(@transparency_written) || @transparency_written.inspect
      end

      # A bitmap screen paints its scenery, its sprites and its text into ONE picture
      # before the display ever sees it. By the time an effect could apply there is
      # nothing left to tell apart, so there is nothing to see through. Same shape of
      # answer as `fade ... under:` already gives.
      def check_transparency_screen!(name)
        return if @screen_mode == :tiled

        raise ArgumentError,
              "`layer :#{name}, transparency:` needs `screen :tiled`. On a bitmap screen the " \
              "whole picture is painted into one place before the display sees it, so there is " \
              "nothing left behind a layer to see through. To fix this, use `screen :tiled`, or " \
              "draw the see-through art into the picture yourself."
      end

      def check_one_transparent_layer!(name, amount)
        already = @layers_node.transparent
        return if already.nil?
        # The same thing said twice is one fact said twice. Compared as the author wrote
        # it, since two reads of the same variable build two equal-but-distinct nodes.
        return if already == name && @transparency_written.equal?(amount)

        if already == name
          raise ArgumentError,
                "The layer :#{name} is already #{transparency_as_written} see-through, and now " \
                "asks for #{amount.inspect}. A layer says how see-through it is one time. To fix " \
                "this, say `transparency:` on one of the `layer :#{name}` blocks."
        end

        raise ArgumentError,
              "This game already makes :#{already} see-through, and now asks for :#{name}. A game " \
              "has one see-through layer. The console blends one layer with what is behind it. " \
              "To fix this, remove `transparency:` from one of them."
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

        check_layer_named!(name)
      end

      # Is this a layer the program declared? Asked by everything that names one — a
      # `layer` block, and an effect placed with `under:`.
      def check_layer_named!(name)
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

      # A scene cannot go inside a layer, and the reason is about what the two ARE rather
      # than about when a body is built. A scene is a state of the game and a state holds
      # things at many depths; a layer is one depth. So this is refused where it is
      # written, whatever the scene turns out to declare.
      def refuse_scene_in_layer!
        return unless @current_layer

        raise ArgumentError,
              "A `scene` cannot go inside a `layer` block. A scene is a state of the game, " \
              "and a state holds things at many depths. A layer is one depth. To fix this, " \
              "put the `layer :#{@current_layer}` block inside the scene."
      end

      # A ROUTINE'S BODY IS BUILT LATER, when the `layer` block it was written inside has
      # closed, so anything in it that wants a depth would quietly get none. That is the
      # silent wrong picture this whole feature exists to remove.
      #
      # THE REFUSAL IS ON WHAT ACTUALLY HAPPENED, not on where the routine was written,
      # and that distinction is the whole design. Refusing every routine declared inside
      # a layer would refuse `pulse coin` on the line after the coin — which is exactly
      # where a game writes it — because `pulse`, `camera_follows`, `fade_out` and
      # `shake_screen` are all built on the public `once_a_frame` and a pack cannot be told
      # from an author by the verb it calls. Asking instead whether the body DECLARED
      # something with a depth lets every one of them through, since a per-frame body is
      # behavior and declares nothing that sits in the picture. It also lets a plain
      # `func` that declares nothing drawable live beside the sprite it moves.
      #
      # A `game_loop` inside a layer block never reaches here, and that is right: its
      # body runs where it is written, so the layer does reach it and a sprite declared
      # inside gets the depth it looks like it gets.
      def refuse_deferred_layer!(node)
        return if @deferred_layer.nil? || IN_A_LAYER.fetch(node.kind, :free) != :held

        layer, wrote = @deferred_layer
        raise ArgumentError,
              "#{HELD_THING.fetch(node.kind)} declared inside `#{wrote}` cannot take the " \
              "layer :#{layer}. The body of `#{wrote}` is built later, when the ROM is made, " \
              "and the layer is not in force then — so this would sit at no depth at all. " \
              "To fix this, #{deferred_layer_fix(wrote, layer)}"
      end

      # What a held node is, in the words the message needs. Text on a tiled screen is one
      # little sprite per character, so a glyph really is a sprite here.
      HELD_THING = { object: "A sprite", background: "A background" }.freeze

      # The way round that works, which is not the same for the two. A declaration inside
      # a per-frame body runs once wherever it is put, so moving it out is both the fix
      # and what the author meant. A func's body is the routine, so the layer goes in it.
      def deferred_layer_fix(wrote, layer)
        return "put the `layer` block inside the func:\n  #{wrote} do\n    layer :#{layer} do ... end\n  end" \
          if wrote.start_with?("func")

        "declare it outside the `#{wrote}` block. A per-frame body is behavior, and a " \
          "declaration in it runs one time wherever you put it."
      end

      def refuse_painting_in_layer!(node)
        # A verb drawing its own text names ITSELF here: a `menu`'s rows really cannot
        # belong to a layer on a bitmap screen, and the author wrote `menu`, not the
        # `draw_text` underneath it (see Text#verb_owns_its_text).
        verb = @verb_owns_text || PlainWords.verb(node.kind)
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

      # An effect is PLACED, not contained — which is a different thing from belonging to
      # a layer, and the difference is worth teaching here rather than leaving somebody to
      # find it. A layer holds things; a fade is not a thing in the picture, it is
      # something done to the picture from a place in the stack.
      def refuse_whole_screen_in_layer!(node)
        verb = PlainWords.verb(node.kind)
        raise ArgumentError,
              "`#{verb}` changes the whole screen, so it cannot belong to the layer " \
              ":#{@current_layer}. To fix this, call `#{verb}` outside the `layer` " \
              "block.#{fade_can_be_placed(node)}"
      end

      def fade_can_be_placed(node)
        return "" unless node.kind == :fade

        " A fade can still sit at a place in the stack: `fade :black, 100, " \
          "under: :#{@current_layer}` fades everything behind :#{@current_layer} and " \
          "leaves :#{@current_layer} alone."
      end

      def list_of(names)
        names.map { |name| ":#{name}" }.join(", ")
      end
    end
  end
end
