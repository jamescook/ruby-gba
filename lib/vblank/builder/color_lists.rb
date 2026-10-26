# frozen_string_literal: true

module VBlank
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

      # One set of lists `colors_in_use` named, the line that first named it, and which of
      # that line's sets it is, counting from 0 the way showing: does (nil for a line that
      # named one set).
      ListsInUse = Data.define(:names, :source, :place) do
        # The set in the author's words, for an error about it.
        def described
          names_said = names.map { |name| ":#{name}" }.join(", ")
          where = place ? "set #{place} of the sets at #{source}, counting from 0 as showing: does" : "the set at #{source}"
          "#{where}. It names #{names_said}"
        end
      end

      # The variable holding which set of lists is in use: a number counting through every
      # set named, in the order the game named them. A number naming none is the first set.
      LISTS_IN_USE = :__colors_in_use

      # SAY WHICH LISTS OF SPRITE COLOURS ARE IN USE NOW, as the game enters a room.
      #
      #   colors_in_use [:door, :zelda]                                    # these, from now on
      #   colors_in_use [[:door, :zelda], [:octorok, :bush]], showing: room  # one of several sets
      #
      # Every list a sprite can `draw_with` takes one of the console's groups of sprite
      # colours for as long as its scene is up, so a scene whose things between them wear
      # more lists than there are groups does not fit, though no one room of it shows more
      # than a few. Said here, the lists of one set are the only ones that have to be in the
      # console at once: lists never in use together take turns in one group, and the
      # colours of the set in use are copied in between frames on the frame it changes. So it
      # is the biggest set that has to fit, not the scene.
      #
      # A sprite drawn with a list that is not in use shows whatever its group holds now:
      # the colours of another list. So a room's things are the ones to take away as the
      # room is left. Until the game first says, the first set named is in use, and so it is
      # for a number naming no set.
      #
      # @param which [Array<Symbol>, Array<Array<Symbol>>] the lists in use, or several sets
      # @param showing [Value, Symbol, Integer, nil] which of several sets, counting from 0
      # @return [nil]
      def colors_in_use(which, showing: nil)
        sets = requested_lists_in_use!(which, showing)
        start = register_lists_in_use(sets, picked: !showing.nil?)
        choice = DSL::Value.new(self, Build.var_ref(LISTS_IN_USE), name: LISTS_IN_USE)
        if showing.nil?
          choice.set!(start)
        else
          write_picked_choice(choice, count: sets.length, start: start, showing: showing,
                                      outside: IR::Build::NO_RECOLOR, subject: "`colors_in_use`",
                                      verb: "use a set of lists")
        end
        nil
      end

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

      # The sets a `colors_in_use` call named, checked before anything is written: one set
      # without showing:, several with it.
      def requested_lists_in_use!(which, showing)
        names_list = ->(set) { set.is_a?(Array) && !set.empty? && set.all?(Symbol) }
        sets = showing.nil? ? [which] : which
        unless sets.is_a?(Array) && !sets.empty? && sets.all?(names_list)
          raise ArgumentError, lists_in_use_shape_message(which, showing)
        end

        sets.each do |set|
          set.each do |name|
            next if @color_lists.key?(name)

            raise ArgumentError,
                  "`colors_in_use` names :#{name}, which is not a list of colors. " \
                  "Declare it first with `colors :#{name}, [:transparent, ...]`."
          end
        end
        sets.map(&:uniq)
      end

      def lists_in_use_shape_message(which, showing)
        if showing.nil? && which.is_a?(Array) && which.all?(Array)
          return "`colors_in_use` was given a list of sets and nothing to pick between them. " \
                 "Say which one with showing:, like `colors_in_use [[:goblin], [:bat]], showing: room`."
        end
        if showing.nil?
          return "`colors_in_use` was given #{which.inspect}. It needs the names of lists of colors, " \
                 "like `colors_in_use [:goblin, :bat]`."
        end

        "`colors_in_use` was given #{which.inspect} with showing:. showing: picks one of several sets, " \
          "so give it a list of sets, like `colors_in_use [[:goblin, :bat], [:crow]], showing: room`."
      end

      # Count +sets+ among every set named so far, and return where they start: the same
      # sets named again side by side are counted once, and new ones go on the end. So a pick
      # by a number the game works out is that number plus where they start. The first call
      # also declares the variable saying which set is in use, holding "the first" at boot.
      # +picked+ says the sets were given with showing:, which is how an error names one.
      def register_lists_in_use(sets, picked:)
        if @lists_in_use.empty?
          at_boot(Build.set(LISTS_IN_USE, Build.int(IR::Build::NO_RECOLOR)))
          ensure_var(LISTS_IN_USE)
        end
        named = @lists_in_use.map(&:names)
        found = (0..(named.length - sets.length)).find { |at| named[at, sets.length] == sets }
        return found if found

        at = @lists_in_use.length
        source = caller_source_location
        @lists_in_use.concat(sets.each_with_index.map do |set, place|
          ListsInUse.new(names: set, source: source, place: picked ? place : nil)
        end)
        at
      end

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
        places = places_for_lists_in_use
        shared = shared_lists_in_use(places)
        return if @changing_color_lists.empty? && shared.empty?

        @changing_color_lists.each do |name, list|
          refuse_background_drawn_with_changing_list!(name)
          users = @sprite_recolors.select { |recolors| recolors.draws_with?(name) }
          refuse_changing_list_without_sprites!(name) if users.empty?
          users.each { |user| refuse_sets_ambiguous_for!(user, name, list.recolors.names) }
          prepend_to_program(list.node)
        end
        shared.each_value { |list| prepend_to_program(list.node) }

        held = @changing_color_lists.keys.to_h { |name| [name, name] }
        held.merge!(places)
        @sprite_recolors.each { |recolors| recolors.name_changing_lists!(held) }
        write_changed_colors_between_frames(@changing_color_lists.merge(shared))
      end

      # THE LISTS THAT LISTS NEVER IN USE TOGETHER TAKE TURNS IN, from +places+ (see
      # #places_for_lists_in_use): shared name -> a ChangingList whose sets are, set by set,
      # the list it holds while that set is in use. Empty for a game that never says
      # `colors_in_use`.
      #
      # A set that leaves a shared list out has it hold its resting list — the one it holds
      # for the first set, or failing that the first it holds at all — so moving to that set
      # puts back colours that list already showed rather than anything new.
      def shared_lists_in_use(places)
        places.values.uniq.to_h do |name|
          lists = places.select { |_list, shared| shared == name }.keys
          held = @lists_in_use.map { |set| (set.names & lists).first }
          resting = held.first || held.compact.first
          node = Build.color_list(name, colors: colors_padded_to_sixteen(resting),
                                        recolors: held.map { |list| colors_padded_to_sixteen(list || resting) })
          # What a build that runs out of room points at: the set that needs the most of the
          # lists taking turns alongside this one.
          node.busiest_set = @lists_in_use.max_by { |set| (set.names & alongside(places, name)).length }.described
          live = :"#{name}_live"
          at_boot(Build.set(live, Build.int(IR::Build::NO_RECOLOR)))
          at_boot(Build.set(IR::Nodes::ColorList.source_var(name), Build.int(0)))
          [live, IR::Nodes::ColorList.source_var(name)].each { |var| ensure_var(var) }
          [name, ChangingList.new(node: node, recolors: nil, shown: LISTS_IN_USE, live: live, writes: [])]
        end
      end

      # The lists placed with those that take turns in +name+: the same scene's, or the lists
      # every scene draws with.
      def alongside(places, name)
        family = IR::Nodes::ColorList.shared_family(name)
        places.select { |_list, shared| IR::Nodes::ColorList.shared_family(shared) == family }.keys
      end

      # The colours of the list +name+ with a colour at all sixteen places, the places past
      # its own end black. A shared list holds lists of different lengths, and a sprite left
      # standing from another room can read a place the list in use does not have; every
      # place having a colour means every build draws that sprite the same.
      def colors_padded_to_sixteen(name)
        colors = @color_lists.fetch(name)
        colors + ([0x0000] * (Images::OWN_COLORS - colors.length))
      end

      # WHICH SHARED LIST EACH LIST IN A SET IS DRAWN THROUGH: list name -> the shared list's
      # name. Empty for a game that never says `colors_in_use`.
      #
      # The lists are placed scene by scene: the lists only one scene's sprites draw with take
      # turns among themselves, so the groups they take are that scene's while it is up and
      # every other scene's afterwards, the way a scene's own lists always are. The lists
      # sprites of several scenes draw with are placed together, and keep their groups in
      # every scene. Within each, two lists of one set never share, and as few shared lists
      # are used as can be — as many as the biggest set has of those lists, for any game whose
      # sets do not overlap in a ring.
      def places_for_lists_in_use
        return {} if @lists_in_use.empty?

        listed = names_in_use
        refuse_lists_in_use_without_sprites!(listed)
        refuse_recolored_lists_in_use!(listed)
        places = {}
        listed.group_by { |name| scene_drawn_in(name) }.values.each_with_index do |lists, family|
          numbers = numbers_for_lists(@lists_in_use.map { |set| set.names & lists })
          numbers.each { |list, number| places[list] = IR::Nodes::ColorList.shared_name(family, number) }
        end
        places
      end

      def names_in_use = @lists_in_use.flat_map(&:names).uniq

      # The one scene whose sprites draw with the list +name+, or nil for a list sprites of
      # several scenes draw with, or a sprite every scene shows.
      def scene_drawn_in(name)
        scenes = @sprite_recolors.select { |recolors| recolors.draws_with?(name) }.flat_map(&:scenes).uniq
        scenes.one? ? scenes.first : nil
      end

      # A number for each list in +sets+, counting from 0, that no list sharing a set with it
      # has. It is a search, trying the lists that share a set with the most others first,
      # and a small one: a game names a few dozen lists at most.
      def numbers_for_lists(sets)
        beside = Hash.new { |hash, name| hash[name] = [] }
        sets.each { |set| set.each { |name| beside[name] |= set - [name] } }
        order = beside.keys.sort_by { |name| -beside[name].length }
        (sets.map(&:length).max..order.length).each do |count|
          found = place_lists(order, beside, count, {})
          return found if found
        end
      end

      # Give each of +order+ a number below +count+ that none of the lists beside it has,
      # going back on a choice that leaves a later list nowhere. nil when there is no way.
      def place_lists(order, beside, count, places)
        return places if places.length == order.length

        name = order[places.length]
        taken = beside[name].filter_map { |other| places[other] }
        (0...count).each do |number|
          next if taken.include?(number)

          found = place_lists(order, beside, count, places.merge(name => number))
          return found if found
        end
        nil
      end

      # A list in a set that no sprite or pool draws with shows nothing in any room: a name
      # spelled two ways far more often than it is meant.
      def refuse_lists_in_use_without_sprites!(listed)
        listed.each do |name|
          next if @sprite_recolors.any? { |recolors| recolors.draws_with?(name) }

          raise ArgumentError,
                "`colors_in_use` names :#{name}, but no sprite or pool draws with it. So it shows in no " \
                "room. To fix this, tell a sprite `draw_with :#{name}`, or correct the name."
        end
      end

      # A list in a set is copied into a shared list as the set comes into use, colours as it
      # was declared; told to `recolor` as well, it would have two answers to what it holds.
      def refuse_recolored_lists_in_use!(listed)
        listed.each do |name|
          next unless @changing_color_lists.key?(name)

          raise ArgumentError,
                "`colors_in_use` names :#{name}, and :#{name} was told to hold other colors with `recolor`. " \
                "A list can do one of these, not both. To fix this, take :#{name} out of `colors_in_use`, or " \
                "give the sets it holds to `colors_in_use` in its place."
        end
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
      def write_changed_colors_between_frames(lists)
        writes = lists.each_value.flat_map(&:writes)
        write_between_frames(writes, lists) do |name, list|
          write_if_changed(said: list.shown, in_force: list.live,
                           write: Build.color_list_holds(name, which: Build.var_ref(list.shown)))
        end
      end
    end
  end
end
