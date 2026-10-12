# frozen_string_literal: true

module RubyGBA
  class Builder
    # A LIST OF SPRITE COLOURS THAT HOLDS OTHER COLOURS WHILE THE GAME RUNS. A concern of
    # {Builder}, mixed in so `recolor` stays a flat DSL verb.
    #
    # WHY IT EXISTS. A sprite's pixels are places in a list of sixteen colours, and the
    # console has sixteen such lists for all its sprites at once. `draw_with` picks which
    # list a sprite reads — and every list it could pick is in the console the whole time,
    # so a game whose things between them wear twenty different sets of colours does not
    # fit, though no two rooms of it show more than a handful. The console's own games get
    # round that by treating a list as a slot: the things in the room draw with a few
    # lists, and walking into the next room puts that room's colours in them.
    module ColorLists
      # What the build keeps about one list told to hold other colours: the statement that
      # declares it to the backends, the sets it can hold (a {DSL::Recolors}, the list
      # playing the part a sprite plays there), and the writes recorded where the game said
      # `recolor`, which are moved to the gap between frames once the program is whole.
      ChangingList = Struct.new(:node, :recolors, :shown, :live, :writes, keyword_init: true)

      # SAY WHICH COLOURS A LIST HOLDS NOW. Every sprite and every pool instance drawn with
      # the list shows them, from the frame its position and pose next change.
      #
      #   colors :slot, [:transparent, :gray, :white, :black]     # what it holds at power-on
      #   guards.each { |g| g.draw_with :slot }
      #   recolor :slot, :goblin                                  # one other set
      #   recolor :slot, [:goblin, :bat, :crow], showing: room    # one of several, by a number
      #   recolor :slot, :own                                     # the colours it was declared with
      #
      # The sets are lists declared with `colors`, each with a colour for every place the
      # list itself has. A number outside the set is the colours it was declared with.
      #
      # It says which colours the list holds, the way `show_map` says which map is showing:
      # so it can be said once, or every frame, from a branch or a scene, and the colours
      # are copied in the gap between frames on the frame the answer changed and no other.
      #
      # @param name [Symbol] a list declared with `colors`
      # @param which [Symbol, Array<Symbol>] the list to hold, several to pick from, or :own
      # @param showing [Value, Symbol, Integer, nil] which of several, counting from 0
      # @return [Symbol] the list's name
      def recolor(name, which, showing: nil)
        list = changing_color_list!(name)
        choice = DSL::Value.new(self, Build.var_ref(list.shown), name: list.shown)
        list.recolors.draw_with(choice, which, showing)
        list.writes << record(Build.color_list_holds(name, which: Build.var_ref(list.shown)))
        name
      end

      # Keep track of a sprite's or a pool's other colours, so the lists that change can
      # find who is drawn with them once the whole program is declared. Called by
      # {DSL::Recolors} as one is made.
      def remember_sprite_recolors(recolors)
        @sprite_recolors << recolors
      end

      # Keep track of a list a background is drawn with, by what an error calls the
      # background. Called by {DSL::Background} as it takes the list's colours.
      def remember_background_draws_with(name, subject)
        @lists_backgrounds_draw_with[name] ||= subject
      end

      private

      # Everything kept about the list +name+, made the first time it is told `recolor`.
      #
      # Two of its variables start out agreeing, both meaning "the colours it was declared
      # with", so a list told nothing on a frame writes nothing — the same pair a
      # background's colours are held in (see Builder#make_background_recolorable). The
      # third is a backend's own (see IR::Nodes::ColorList.source_var).
      def changing_color_list!(name)
        @changing_color_lists[name] ||= begin
          declared = @color_lists.fetch(name) do
            raise ArgumentError,
                  "`recolor` names :#{name}, which is not a list of colors. " \
                  "Declare it first with `colors :#{name}, [:transparent, ...]`."
          end
          shown = :"__colors_#{name}"
          live = :"__colors_#{name}_live"
          at_boot(Build.set(shown, Build.int(IR::Build::NO_RECOLOR)))
          at_boot(Build.set(live, Build.int(IR::Build::NO_RECOLOR)))
          at_boot(Build.set(IR::Nodes::ColorList.source_var(name), Build.int(0)))
          [shown, live, IR::Nodes::ColorList.source_var(name)].each { |var| ensure_var(var) }

          node = Build.color_list(name, colors: declared)
          words = DSL::Recolors::Words.new(verb: "recolor", told: "hold", call: "recolor :#{name}, ")
          sets = DSL::Recolors.new(self, subject: changing_list_subject(name), poses: nil, words: words,
                                         colors_for: ->(names) { colors_to_hold(names, list: name) })
          ChangingList.new(node: node, recolors: sets.attach_object(node), shown: shown, live: live, writes: [])
        end
      end

      def changing_list_subject(name) = "The list of colors :#{name}"

      # The colours of the `colors` lists +names+, for the list +list+ to hold. Each needs a
      # colour for every place +list+ has, since a sprite drawn with +list+ was checked
      # against that many places and no more.
      def colors_to_hold(names, list:)
        places = @color_lists.fetch(list).length
        names.map do |name|
          set = @color_lists.fetch(name) do
            raise ArgumentError,
                  "#{changing_list_subject(list)} was told to hold :#{name}, which is not a list of " \
                  "colors. Declare it first with `colors :#{name}, [:transparent, ...]`."
          end
          next set if set.length >= places

          raise ArgumentError,
                "#{changing_list_subject(list)} was told to hold :#{name}, which has #{set.length} " \
                "colors. :#{list} has #{places}, and each place in it needs a color at the same place in " \
                ":#{name}. Give :#{name} #{places} colors or more."
        end
      end

      # ONCE THE WHOLE PROGRAM IS DECLARED: tell every sprite drawn with a changing list to
      # hold the list's name rather than its colours, declare each such list to the
      # backends, and move the writes to the gap between frames.
      #
      # It waits until now because `draw_with` and `recolor` can come in either order, and
      # a sprite that drew with a list before anything recoloured it took the colours the
      # list was declared with.
      def finalize_changing_color_lists
        return if @changing_color_lists.empty?

        @changing_color_lists.each do |name, list|
          refuse_background_drawn_with_changing_list!(name)
          users = @sprite_recolors.select { |recolors| recolors.draws_with?(name) }
          refuse_changing_list_without_sprites!(name) if users.empty?
          users.each { |user| refuse_sets_ambiguous_for!(user, name, list.recolors.names) }
          prepend_to_program(list.node)
        end
        @sprite_recolors.each { |recolors| recolors.name_changing_lists!(@changing_color_lists.keys) }
        write_changed_colors_between_frames
      end

      # A list no sprite is drawn with shows nothing whatever it holds, which is a name
      # spelled two ways far more often than it is meant.
      def refuse_changing_list_without_sprites!(name)
        raise ArgumentError,
              "#{changing_list_subject(name)} was told to hold other colors, but no sprite or pool draws " \
              "with it. So nothing shows the colors it holds. To fix this, tell a sprite " \
              "`draw_with :#{name}`, or correct the name."
      end

      # Each set the list +name+ can hold recolours +user+'s pictures by place, the way a
      # list the sprite named itself does — so it is held to the same rule about a colour
      # the sprite's own list has at two places (see Images#refuse_ambiguous_color_places!).
      def refuse_sets_ambiguous_for!(user, name, sets)
        own = shared_pose_colors!(user.poses, user.subject)
        sets.each do |set|
          refuse_ambiguous_color_places!(own: own, swapped: @color_lists.fetch(set), name: set,
                                         poses: user.poses, subject: user.subject, through: name)
        end
      end

      # A BACKGROUND TAKES A LIST'S COLOURS AS IT WAS DECLARED, into colours of its own: its
      # tiles are drawn from groups nothing else reads, which `recolor` never writes. So a
      # background drawn with a list that changes would go on showing the declared colours,
      # with nothing to say why. It has a word of its own for this, and the error names it.
      def refuse_background_drawn_with_changing_list!(name)
        background = @lists_backgrounds_draw_with[name]
        return unless background

        raise ArgumentError,
              "#{background} draws with :#{name}, and :#{name} was told to hold other colors. `recolor` " \
              "changes the colors of sprites only. To change the colors of a background, give it the " \
              "lists to step through: `draw_with [:#{name}, ...], showing: step`."
      end

      # COPY A LIST'S COLOURS IN THE GAP BETWEEN FRAMES, and only on a frame where the answer
      # changed — the same bargain, held in the same two variables, as a background's (see
      # Builder#finalize_background_colors). The gap is what makes the colours change on the
      # frame the sprites' positions and poses do: both are written there.
      def write_changed_colors_between_frames
        writes = @changing_color_lists.each_value.flat_map(&:writes)
        write_between_frames(writes, @changing_color_lists) do |name, list|
          write_if_changed(said: list.shown, in_force: list.live,
                           write: Build.color_list_holds(name, which: Build.var_ref(list.shown)))
        end
      end
    end
  end
end
