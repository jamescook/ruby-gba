# frozen_string_literal: true

module VBlank
  class Builder
    # The composition verb: `pool` — declare a component (named fields) and a
    # fixed-capacity set of instances of it in one call, the DSL's unit for
    # "many of a thing that has state and behaves." A concern of {Builder}, mixed in
    # so `pool` stays a flat DSL verb; the {Pool} handle it returns does the rest.
    #
    # A pool desugars entirely onto what already exists — one {List} per field, an
    # `active` column, a `free`-slot stack, and a `repeat` for iteration — so there's no
    # new IR and every backend runs it. This module just sets that storage up (once, at
    # boot) and hands back the handle.
    module Composition
      Build = IR::Build

      # What spawn does when the pool is full: :drop ignores it (a safe no-op),
      # :recycle_oldest reuses the longest-lived instance so a new one always appears.
      POOL_FULL_POLICIES = %i[drop recycle_oldest].freeze

      # THE MOST OF THE QUICK MEMORY ONE POOL MAY TAKE. The console has 32KB of it, and it is
      # also where the code a frame spends its time in is kept, so a pool that took most of
      # it would push that code out to the cartridge and slow the whole game, with nothing
      # in the program to say why. A pool bigger than this is kept in the console's other
      # work memory, which is eight times the size and slower to read (see #pool). A pool
      # bigger than that memory is refused at its own line, and a game whose collections do
      # not fit the two memories together is refused by the whole-program check
      # (IR::Guardrails::Checks::IwramBudget), which adds up everything it declares.
      POOL_MAX_QUICK_BYTES = 16 * 1024

      # Declare a pool of a component. Name the fields with their defaults and give a
      # capacity (the most instances live at once):
      #
      #   bullets = pool :bullet, x: 0, y: 0, vy: 0, capacity: 64
      #
      # Returns a {Pool} handle — spawn instances, iterate the live ones with `each`,
      # ask its `count` / `full?`.
      #
      # Give the pool an `image:` and each live instance draws itself as a hardware
      # sprite at its x/y (spawn shows one, remove hides it) and gains a collision box:
      #
      #   enemies = pool :enemy, x: 0, y: 0, hp: 3, capacity: 16, image: :ufo
      #   enemies.each { |e| e.y.add! 1; bullet.overlaps?(e).then { e.remove } }
      #
      # A spriteful pool needs x: and y: fields and a `screen :tiled` (its instances are
      # hardware sprites). Without an image it's a pure-data pool (draw it yourself in
      # `each`).
      #
      # By default a spawn onto a full pool is a safe no-op. Pass `on_full: :recycle_oldest`
      # (the usual choice for particles and effects) so a new spawn instead reuses the
      # longest-lived instance — a new one always appears:
      #
      #   sparks = pool :spark, x: 0, y: 0, life: 0, capacity: 32, on_full: :recycle_oldest
      #
      # `estimate:` does nothing but earn a warning (see Builder#record_estimate_line).
      #
      # A pooled thing FACES AND ANIMATES the way a sprite does, spelled the same way.
      # Give the pool `facing:` (a picture per direction, or a list of frames per
      # direction) or `frames:` (a flipbook) instead of `image:`, with `rate:` for
      # either animated form:
      #
      #   guards = pool :guard, x: 0, y: 0, capacity: 32, rate: 6,
      #                 facing: { left: [:walk_l1, :walk_l2], right: [:walk_r1, :walk_r2] }
      #   guards.each { |g| g.face :left; g.x.sub! 1 }
      #
      # Each instance holds its own direction and its own place in the cycle, so ten
      # guards face ten ways and do not march in step. That is the pool's own
      # bookkeeping — a hidden slot beside the fields, not something to declare.
      #
      # WHICH OF THE CONSOLE'S TWO WORK MEMORIES A POOL IS KEPT IN is the build's to decide,
      # as it is for a list: the quick one for what a frame touches while there is room, the
      # roomier one for the rest. `fast: false` says the pool is cold and gives the quick
      # memory back; `fast: true` insists on it. A pool bigger than POOL_MAX_QUICK_BYTES cannot
      # share the quick memory, so it is kept in the roomier one whatever a frame does with
      # it, and `fast: true` on such a pool is a friendly error.
      #
      # @param name [Symbol] the pool's name
      # @param capacity [Integer] the most instances that can be live at once
      # @param fast [Boolean, nil] false to keep it out of the quick memory, true to insist on it
      # @param image [Symbol, nil] the sprite image each live instance draws
      # @param facing [Hash{Symbol=>Symbol,Array}, nil] direction => picture, or => frames
      # @param frames [Array<Symbol>, nil] same-size pictures to cycle as an animation
      # @param rate [Integer, nil] game-frames per animation step (needed with an animation)
      # @param on_full [Symbol] :drop (default) or :recycle_oldest — see above
      # @param estimate [Object] does nothing but earn a warning
      # @param fields [Hash{Symbol=>Object}] field name => default value
      # @return [Pool]
      def pool(name, capacity:, image: nil, facing: nil, frames: nil, rate: nil,
               on_full: :drop, estimate: nil, widths: {}, fast: nil, **fields)
        validate_pool!(name, capacity, fields)
        validate_on_full!(name, on_full)
        validate_pool_widths!(name, fields, widths)
        refuse_field_spelled_as_pool_word!(name, facing: facing, frames: frames, rate: rate, fast: fast)
        art = pool_art!(name, image: image, facing: facing, frames: frames, rate: rate, fields: fields)
        record_estimate_line(estimate)
        handle = DSL::Pool.new(self, name, fields, capacity, image: image, hitbox: art&.hitbox, on_full: on_full,
                                                        art: art)
        # A pool too big to share the quick memory is kept out of it, as though the game had
        # said `fast: false` — unless it said `fast: true`, which is then a friendly error.
        bytes = pool_bytes(handle, fields, widths)
        refuse_pool_no_memory_holds!(handle, fields.size, bytes) if bytes > console.largest_memory_bytes
        if bytes > POOL_MAX_QUICK_BYTES
          refuse_oversized_fast_pool!(handle, fields.size, bytes) if fast
          fast = false
        end
        handle.fast = fast # the lists a pool gains later go where the rest of it went
        setup_pool_storage(handle, capacity, fields, widths, fast)
        setup_pool_art(handle, capacity, art, widths, fast) if art
        declared_pools << handle
        handle
      end

      # --- the seam between a pool and the build (see Pool#func) ---
      #
      # A pool declares its routines through here and says where its walks are; what those two
      # facts mean is settled at the end of the build, when every routine's body exists.

      # Declare +name+ as a routine of +pool+, working on one instance at a time. Its body is
      # built at the end like any routine's, and is handed the instance the pool is walking
      # when it runs — a routine is emitted once, so that is the only instance it can mean.
      def declare_instance_routine(pool, name, &block)
        pool.instance_routines << name
        instance_routines[name] = pool
        declare_func(name, wrote: "#{pool.name}.func :#{name}") { block.call(pool.current_instance) }
      end

      # A walk of +pool+ wrote down which instance it is on. Kept so the writes can be taken
      # out again if no routine of that pool ever reads them, and so the calls inside the walk
      # can be told from the calls outside it.
      def record_walk_instance_writes(pool, *nodes)
        (@pool_walks ||= []) << [pool, nodes]
      end

      # A fresh variable for one walk to keep the instance the walk around it was on.
      def pool_walk_scratch_var
        @pool_walk_seq = @pool_walk_seq.to_i + 1
        :"__pool_walk_#{@pool_walk_seq}"
      end

      # Give +pool+ a hidden slot per instance saying which other list of colours it is drawn
      # with, the first time one is told to draw with one (see Pool#draw_with). Every slot
      # starts in its own colours.
      def make_pool_recolorable(pool)
        at_boot(Build.list_new(pool.colors_list, pool.capacity, width: :byte, fast: pool.fast,
                                                                full_of: Build::NO_RECOLOR))
        # ...and each of the pool's sprites reads the colours copied for its place in the
        # drawing order (see Pool#stacked_list), which the copy fills from the slots.
        at_boot(Build.list_new(pool.stacked_list(:colors), pool.capacity, width: :byte, fast: pool.fast,
                                                                          full_of: Build::NO_RECOLOR))
        pool.stacked_objects.each_with_index do |node, place|
          node.recolor = pool.stacked_at(:colors, pool.rank_at_place(place))
        end
      end

      private

      # Every pool the game declared, in the order it declared them.
      def declared_pools = @declared_pools ||= []

      # A spriteful pool never told to draw with other colours takes back the writes its
      # spawns made in case it was (see Pool#drop_unused_color_resets).
      def finalize_pool_colors
        (@spriteful_pools || []).each(&:drop_unused_color_resets)
      end

      # Which pool each instance routine belongs to.
      def instance_routines = @instance_routines ||= {}

      # A WALK THAT NOBODY ASKED TO BE TOLD ABOUT COSTS NOTHING. Writing down which instance a
      # walk is on is only worth anything to a routine that reads it, so a pool with no routine
      # of its own has those writes taken out again here — a pool of sixty bullets drawn inline
      # is left exactly as it was before any of this.
      def finalize_pool_walks
        (@pool_walks || []).each do |pool, nodes|
          if pool.instance_routines.empty?
            nodes.each { |node| node.parent&.children&.delete(node) }
          else
            nodes.each { |node| ensure_var(node.var) }
          end
        end
      end

      # A routine that works on one instance runs on the instance its pool is walking. Called
      # from anywhere else there is no such instance, and it would quietly run on whichever one
      # was walked last — so that is refused here, where the whole program can be seen.
      #
      # The rule is the one that can be read off the page: call it from inside a walk of its
      # pool, or from another routine of that pool. A plain routine in between is refused too,
      # and the advice is to make that one a routine of the pool as well, which is what it is.
      def verify_instance_routines!
        return if instance_routines.empty?

        walks = walk_containers
        @program.walk do |node|
          node.callees.each do |target|
            pool = instance_routines[target] or next
            next if inside_walk?(node, walks[pool.name]) || instance_routines[enclosing_func(node)] == pool

            raise ArgumentError, outside_walk_message(target, pool)
          end
        end
      end

      # Where each pool's walks are in the tree: the statement that holds one walk's body. A
      # call under one of those is inside that walk.
      def walk_containers
        containers = Hash.new { |all, name| all[name] = [] }
        (@pool_walks || []).each do |pool, nodes|
          nodes.each { |node| containers[pool.name] << node.parent if node.parent }
        end
        containers
      end

      def inside_walk?(node, containers)
        return false if containers.nil? || containers.empty?

        up = node
        up = up.parent while up && !containers.include?(up)
        !up.nil?
      end

      # The routine a statement sits in, or nil for one in the program's own body.
      def enclosing_func(node)
        up = node.parent
        up = up.parent while up && up.kind != :func
        up&.name
      end

      def outside_walk_message(target, pool)
        "`call :#{target}` is outside a walk of `pool :#{pool.name}`. The routine :#{target} " \
          "works on one instance, and a walk is what says which instance that is. To fix this, " \
          "call it inside `#{pool.name}s.each { |#{pool.name}| ... }`. Or call it from another " \
          "routine of `pool :#{pool.name}`."
      end

      # WHAT A POOL'S INSTANCES LOOK LIKE, worked out once for the whole pool: the
      # pictures they can show, how a slot's own number picks one of them, and the
      # collision box they all share. Nil for a pure-data pool.
      #
      # +poses+ is every picture, flattened; +dirs+ maps a direction name to its row;
      # +per_dir+ is how many frames each direction has (1 for a still pose). Those three
      # are exactly what a `sprite` works out for itself — this is the same answer for
      # many of a thing at once.
      PoolArt = Data.define(:poses, :dirs, :per_dir, :rate, :hitbox) do
        # A pool faces when it was given a direction per picture, and animates when a slot
        # has more than one picture to run through — the frames of its direction for a
        # directional animation, or the whole flipbook where there are no directions.
        def faces? = !dirs.nil? && !dirs.empty?
        def animates? = cycle_length > 1

        def cycle_length = faces? ? per_dir : poses.length
      end

      def pool_art!(name, image:, facing:, frames:, rate:, fields:)
        posed = facing || frames
        reject_two_pool_pose_sources!(name, image: image, facing: facing, frames: frames)
        return nil unless image || posed

        refuse_unspritable_pool!(name, fields)
        return single_picture_art(name, image) unless posed

        validate_animation!(name, facing, frames, rate, subject: "pool")
        poses, dirs, width, height, per_dir = resolve_sprite_art(name, facing, frames, subject: "pool")
        PoolArt.new(poses: poses, dirs: dirs, per_dir: per_dir, rate: rate,
                    hitbox: collision_box(name: name, images: poses, width: width, height: height, hitbox: nil))
      end

      def reject_two_pool_pose_sources!(name, image:, facing:, frames:)
        given = { "image:" => image, "facing:" => facing, "frames:" => frames }.compact.keys
        return if given.length < 2

        raise ArgumentError,
              "pool :#{name} was given #{given.join(' and ')}. They all say which pictures the instances " \
              "show. Use only one."
      end

      def single_picture_art(name, image)
        size = @images[image] or
          raise ArgumentError,
                "pool :#{name} draws image :#{image}, but no `image :#{image}` is defined yet. Define the " \
                "image before the pool."

        PoolArt.new(poses: [image], dirs: nil, per_dir: 1, rate: nil,
                    hitbox: collision_box(name: image, images: [image], width: size[0], height: size[1],
                                          hitbox: nil))
      end

      # `widths:` names the fields that hold less than a whole 32-bit number, which is nearly
      # all of them in a real game — a direction, a state number, a countdown, how many hit
      # points are left, and every plain yes-or-no flag fit in a byte. A pool is one list per
      # field, so a byte-wide field is a quarter of the memory of a word-wide one, and on a
      # pool of any size that is the difference between the game's hot code fitting in the
      # console's fast memory and not.
      def validate_pool_widths!(name, fields, widths)
        unless widths.is_a?(Hash)
          raise ArgumentError,
                "pool :#{name} got widths: #{widths.inspect}. widths: names a field and how big it is, " \
                "like widths: { dir: :byte, hp: :byte }."
        end
        unknown = widths.keys - fields.keys
        unless unknown.empty?
          raise ArgumentError,
                "pool :#{name} gives a width for :#{unknown.first}, which is not one of its fields. " \
                "Its fields are #{fields.keys.join(', ')}."
        end
        bad = widths.find { |_, width| !Build::ELEMENT_BYTES.key?(width) }
        return if bad.nil?

        raise ArgumentError,
              "pool :#{name} gives field :#{bad.first} the width #{bad.last.inspect}. A width must be " \
              ":byte (0..255), :half (0..65535) or :word."
      end

      # A field that carries a fraction cannot be narrowed by this, and saying so is better
      # than a game quietly losing the bottom of every speed: the scale a fraction is kept at
      # already uses most of a word.
      def check_width_holds_fractions!(name, field, default, width)
        return if width == :word || DSL::Fraction.bits_of(default).nil?

        raise ArgumentError,
              "pool :#{name} gives field :#{field} the width :#{width}, but it was declared with " \
              "#{default.inspect}, so it holds a fraction. A fraction needs a whole word. Remove the " \
              "width, or declare the field with a whole number."
      end

      def validate_pool!(name, capacity, fields)
        raise ArgumentError, "A pool needs a name that is a Symbol. Got #{name.inspect}." unless name.is_a?(Symbol)
        unless DSL::Whole.positive?(capacity)
          raise ArgumentError, "pool :#{name} needs a positive capacity. Got #{capacity.inspect}."
        end

        refuse_pool_name_with_stray_underscores!(name)
        refuse_field_named_like_instance_method!(name, fields)
      end

      # HOW MUCH MEMORY A POOL TAKES, counted AS IT IS BUILT: every list it is made from, each
      # exactly `capacity` slots long and as wide as it was declared. Those are the lists
      # #pool_lists and #pool_stacking_lists hand to the build, read here rather than added up
      # a second way — a count kept on its own had drifted until it refused a pool a third the
      # size of the ceiling, by rounding the capacity up to a power of two (only a list the
      # game shifts is rounded, and a pool has none) and taking every field for a whole word.
      #
      # The one list not in it is the colours an instance is drawn with, a byte a slot, which
      # a pool gains only when some instance is first told `draw_with` — later than this.
      def pool_bytes(pool, fields, widths)
        lists = pool_lists(pool, fields, widths)
        lists = lists.merge(pool_stacking_lists(pool, widths)) if pool.spriteful?
        pool.capacity * lists.sum { |_, width| Build::ELEMENT_BYTES.fetch(width) }
      end

      # A POOL BIGGER THAN THE ROOMIEST MEMORY FITS NOWHERE. A pool is kept whole in one
      # memory (on the Advance, one over the quick memory's ceiling goes in the roomier one),
      # so this is the most one pool can be, whatever else the game declares. It is refused
      # here, at the line that wrote it and by its own name: the whole-program check asks only
      # whether everything fits the memories added together, which a pool a little over this
      # size still does. The size is the console's the game is built for
      # (Console::Description#largest_memory_bytes).
      def refuse_pool_no_memory_holds!(pool, field_count, bytes)
        raise ArgumentError,
              "pool :#{pool.name} has #{pool.capacity} instances of #{field_count} fields each. It needs about " \
              "#{bytes / 1024}KB. A pool is kept whole in one memory. The largest memory of a #{console.title} " \
              "holds #{console.largest_memory_bytes / 1024}KB. To fix this, use a smaller capacity. Or use fewer " \
              "fields. Or give fields a smaller width, like `widths: { hp: :byte }`."
      end

      # A POOL THAT INSISTS ON THE QUICK MEMORY AND IS TOO BIG TO SHARE IT. `fast: true` is
      # the game saying it knows better than the build where the pool goes, so the build does
      # not quietly put it somewhere else: it says why not, and what gives the pool room.
      def refuse_oversized_fast_pool!(pool, field_count, bytes)
        quick = Messages::PlainWords::QUICK_MEMORY
        raise ArgumentError,
              "pool :#{pool.name} has #{pool.capacity} instances of #{field_count} fields each. It needs about " \
              "#{bytes / 1024}KB. `fast: true` keeps a pool in the console's #{quick}, and a pool there can use " \
              "#{POOL_MAX_QUICK_BYTES / 1024}KB at most. The console has only 32KB of #{quick} in total, and " \
              "the game's code is kept there too. To fix this, remove `fast: true`. Then the build keeps the " \
              "pool in the roomier memory of the console, which is slower to read. Or use a smaller capacity. " \
              "Or use fewer fields. Or give fields a smaller width, like `widths: { hp: :byte }`."
      end

      # EVERY LIST A POOL KEEPS ITS INSTANCES IN, and how wide a slot of each is, in the
      # order they are made: list => width.
      #
      # A field is as wide as the game said, a whole word unless `widths:` narrowed it.
      #
      # THE POOL'S OWN BOOKKEEPING IS NARROWED WITHOUT BEING ASKED, because unlike a field
      # the framework knows exactly what these hold. The active column is a yes or a no, so
      # it is a byte whatever the pool is; the free stack holds slot numbers, so it is as
      # wide as the largest slot number needs and no wider. Together they are two of a
      # pool's lists — on one with a dozen fields that is a modest saving, and on a small
      # one it is a sixth of the whole pool, for nothing anybody has to write.
      #
      # A posed pool keeps two more hidden slots beside its fields: which way each instance
      # faces, and where each is in its cycle. Both are small counts, so both are a byte.
      #
      # The chain that says what order the things came in holds slot numbers too, and the
      # removals a walk has not yet taken out of it are a stack of them.
      def pool_lists(pool, fields, widths)
        slot = slot_width(pool.capacity)
        lists = fields.keys.to_h { |field| [pool.field_list(field), widths.fetch(field, :word)] }
        lists[pool.active_list] = :byte
        lists[pool.free_list] = slot
        pool.pose_lists.each { |list| lists[list] = :byte }
        [pool.next_list, pool.prev_list, pool.retired_list].each { |list| lists[list] = slot }
        lists
      end

      # WHAT EACH OF A POOL'S LISTS HOLDS AT POWER-ON, for the ones made full of one value: a
      # nought in every field, the active column and the poses, and "no slot" in both links of
      # the chain. The free stack is full of the slot numbers, a different one each, so it is
      # filled a slot at a time (see #build_pool_fill); the removals not yet taken out of the
      # chain start as none.
      def pool_list_starts(pool)
        starts = pool.field_names.to_h { |field| [pool.field_list(field), 0] }
        starts[pool.active_list] = 0
        pool.pose_lists.each { |list| starts[list] = 0 }
        starts[pool.next_list] = DSL::Pool::NONE
        starts[pool.prev_list] = DSL::Pool::NONE
        starts
      end

      # THE LISTS A DRAWN POOL'S THINGS ARE COPIED INTO EACH FRAME, in the order they are
      # drawn, as list => width: where each is, at the width its x and y fields have, and
      # which picture when there is a choice.
      def pool_stacking_lists(pool, widths)
        kept = { x: widths.fetch(:x, :word), y: widths.fetch(:y, :word) }
        kept[:pose] = pool.art.poses.length <= 128 ? :byte : :half if pool.posed?
        kept.transform_keys { |part| pool.stacked_list(part) }
      end

      # The names the framework makes for a pool put the pool's name before two underscores
      # (see Messages::MadeNames), so the name itself can hold no pair of them and cannot end
      # in one — or the lists of one pool could be read as another's.
      def refuse_pool_name_with_stray_underscores!(name)
        return if Messages::MadeNames::POOL_NAME.match?(name.to_s)

        raise ArgumentError,
              "pool #{name.inspect} cannot have that name. A pool name must not end with an underscore, " \
              "and must not contain two underscores together. Use a name like :guard or :guard_walk."
      end

      # A field is read off an instance by its name (`guard.hp`), so a field called what an
      # instance already answers to — `remove`, `index`, `left`, `move` — could never be
      # read: the name would mean the method. Those are the only names a field cannot have.
      def refuse_field_named_like_instance_method!(name, fields)
        taken = fields.keys & DSL::Pool::Instance.public_instance_methods
        return if taken.empty?

        raise ArgumentError,
              "pool :#{name} cannot have a field named :#{taken.first}. Each instance of a pool already has a " \
              "`#{taken.first}` of its own, and `instance.#{taken.first}` means that one. " \
              "Use a different name for the field."
      end

      # `pool` HAS WORDS OF ITS OWN — facing:, rate:, fast: and the rest — and a field is written
      # the same way, so a field spelled like one of them is taken for the pool's word. Most of
      # them say so where they are checked. These three did not: a number for facing: stopped
      # the build inside the framework, and a rate: with no pictures to step, or a fast: that is
      # not a yes or a no, was accepted and no field made.
      def refuse_field_spelled_as_pool_word!(name, facing:, frames:, rate:, fast:)
        said = if !facing.nil? && !facing.is_a?(Hash)
                 "facing: #{facing.inspect}. facing: is a word of the pool. It gives a picture for each " \
                   "direction, like facing: { left: :walk_left, right: :walk_right }."
               elsif !rate.nil? && facing.nil? && frames.nil?
                 "rate: #{rate.inspect}, but no facing: or frames: pictures. rate: is a word of the pool. " \
                   "It says how many frames each of those pictures is shown."
               elsif ![true, false, nil].include?(fast)
                 "fast: #{fast.inspect}. fast: is a word of the pool, and it must be true or false."
               end
        return if said.nil?

        raise ArgumentError, "pool :#{name} got #{said} If you want a field, use a different name for it."
      end

      def validate_on_full!(name, policy)
        return if POOL_FULL_POLICIES.include?(policy)

        raise ArgumentError,
              "pool :#{name} got on_full: #{policy.inspect}. on_full must be one of " \
              "#{POOL_FULL_POLICIES.map(&:inspect).join(', ')}. :drop ignores a spawn when the pool is full. " \
              ":recycle_oldest reuses the longest-lived instance, so a new one always appears."
      end

      # A pool whose instances draw themselves is a pool of hardware sprites, so it needs
      # a tiled screen and x/y position fields to place them by.
      def refuse_unspritable_pool!(name, fields)
        unless @screen_mode == :tiled
          raise ArgumentError,
                "pool :#{name} draws its instances, so they are hardware sprites. Hardware sprites need a " \
                "`screen :tiled`. Declare the pool under one. Or give it no pictures and draw the pool " \
                "yourself in each on a bitmap screen."
        end
        missing = %i[x y] - fields.keys
        return if missing.empty?

        raise ArgumentError,
              "A pool that draws its instances needs x: and y: fields. They set the sprite position. " \
              "pool :#{name} is missing #{missing.map { |f| "#{f}:" }.join(' and ')}."
      end

      # Declare one hardware-sprite object for each thing that can be live at once. Each
      # shows a PLACE IN THE ORDER the things were spawned in, not a slot (see
      # Pool#stacked_list): it reads the position and picture copied for its place, so
      # present_objects draws the live things oldest in front and hides the sprites left
      # over. The active flag is scene-gated, so a pool declared in a scene only shows while
      # that scene is live.
      #
      # WHICH PICTURE a thing shows comes out of the pool's own hidden slots the same way
      # its position does: the direction it faces and where it is in its cycle are
      # per-instance, so ten guards face ten ways and do not march in step.
      def setup_pool_art(pool, capacity, art, widths = {}, fast = nil)
        (@spriteful_pools ||= []) << pool
        pool.scene_gate = @current_scene_gate
        setup_pool_stacking(pool, capacity, widths, fast)
        capacity.times do |place|
          rank = pool.rank_at_place(place)
          name = pool.object_name(place)
          node = Build.object(name, poses: art.poses, pose: pool.pose_node(rank),
                                    x: pool.stacked_at(:x, rank), y: pool.stacked_at(:y, rank),
                                    active: gated_by_scene(pool.rank_taken(rank)),
                                    scene: declaring_scene, declared: pool.name)
          record(node)
          pool.stacked_objects << node
          @sprite_objects << name
        end
        register_pool_animation(pool, capacity, art) if art.animates?
      end

      # Make the lists a pool's things are copied into each frame (see #pool_stacking_lists).
      # Every entry exists from the start, so each can be written by its index. The colours
      # join them only if the pool is ever told to draw with others (see
      # #make_pool_recolorable).
      def setup_pool_stacking(pool, capacity, widths, fast)
        [pool.stacked_var, pool.stacking_cursor_var, pool.stacking_index_var].each { |var| ensure_var(var) }
        pool_stacking_lists(pool, widths).each do |list, width|
          at_boot(Build.list_new(list, capacity, width: width, fast: fast, full_of: 0))
        end
        at_boot(Build.set(pool.stacked_var, Build.int(0)))
      end

      # COPY EACH DRAWING POOL INTO ITS DRAWING ORDER IN THE GAP BEFORE EVERY FRAME, last of
      # everything that runs there and just before the sprites are drawn — so a thing a
      # `once_a_frame` body spawned, moved or removed in that same gap is drawn as it now is.
      #
      # Each pool's copy is a routine of its own rather than statements in the game loop: the
      # game loop's body is the first thing kept in the console's quick memory, and a routine
      # is placed by how much of a frame it takes like any other.
      #
      # Called before the passes that put the game's own per-frame work at the boundary, since
      # each of those inserts straight after the wait and so lands in front of this.
      def finalize_pool_stacking
        pools = @spriteful_pools || []
        return if pools.empty? || @frame_boundaries.empty?

        pools.each do |pool|
          @functions[pool.stacking_routine] = proc {}
          push_container(Build.func(pool.stacking_routine)) { pool.stacking_nodes.each { |node| record(node) } }
        end
        @frame_boundaries.each do |wait_node|
          container = wait_node.parent
          at = container&.children&.index(wait_node)
          next unless at

          pools.reverse_each do |pool|
            node = call_stacking_while_shown(pool)
            container.children.insert(at + 1, node)
            node.parent = container
          end
        end
      end

      # The call that puts +pool+ in order — asked only while its scene is up, for a pool
      # declared in one. Its things are shown only then, so on any other scene's frames the
      # copy would be work nobody sees. The scene is asked in the same gap the things are
      # drawn in, so a scene's first frame is put in order and drawn alike.
      def call_stacking_while_shown(pool) = while_scene_up(pool.scene_gate, Build.call(pool.stacking_routine))

      # THE POOL'S RHYTHM IS SHARED AND ITS PLACE IN THE CYCLE IS NOT, which is what makes
      # this cheap enough to put on every frame. One counter for the whole pool decides
      # WHEN a step happens; each instance keeps its own frame, so an instance spawned
      # later is at a different point in the same cycle and the pool does not pulse as one.
      #
      # So a frame that is not a step costs one compare, and a step costs a walk of the
      # slots — a rate of six makes that one walk in six.
      def register_pool_animation(pool, capacity, art)
        index = pool.part_name(:anim)
        ensure_var(index)
        # A fresh node per use: an IR node belongs to one parent, so the same read cannot
        # be handed to two statements.
        frame = -> { Build.list_get(pool.frame_list, Build.var_ref(index)) }
        # ...and the whole step is built again for each frame boundary it goes at, for the
        # same reason (see ControlFlow#finalize_animation_steps).
        step = lambda do
          wrap = Build.if_(Build.binop(:>=, frame.call, Build.int(art.cycle_length)),
                           Build.list_set(pool.frame_list, Build.var_ref(index), Build.int(0)))
          Build.repeat(Build.int(capacity), index,
                       Build.list_set(pool.frame_list, Build.var_ref(index),
                                      Build.binop(:+, frame.call, Build.int(1))),
                       wrap)
        end
        @pool_animations << { tick: pool.tick_var, rate: art.rate, step: step }
      end

      # Create the backing lists once at boot — not where `pool` is written, so a pool
      # declared inside a scene is still set up once rather than re-created every frame —
      # and fill every slot so each field is randomly addressable from the start.
      def setup_pool_storage(pool, capacity, fields, widths = {}, fast = nil)
        fields.each { |field, default| check_width_holds_fractions!(pool.name, field, default, widths.fetch(field, :word)) }
        starts = pool_list_starts(pool)
        pool_lists(pool, fields, widths).each do |list, width|
          at_boot(Build.list_new(list, capacity, width: width, fast: fast, full_of: starts[list]))
        end
        if pool.art&.animates?
          ensure_var(pool.tick_var)
          at_boot(Build.set(pool.tick_var, Build.int(0)))
        end
        [pool.count_var, pool.head_var, pool.tail_var, pool.walking_var].each do |var|
          ensure_var(var)
          at_boot(Build.set(var, Build.int(pool.power_on_value(var))))
        end
        pool.chain_scratch_vars.each { |var| ensure_var(var) }
        at_boot(build_pool_fill(pool, capacity))
      end

      public

      # THE POOL AS POWER-ON LEAVES IT, as statements run where they are recorded: every list
      # of it emptied and filled again the way #setup_pool_storage fills it, and its counters
      # back at nought. A save_data record's `reset` runs this for a pool it keeps, since
      # emptying a pool's lists the way a kept list is emptied would leave it with no slots.
      def pool_refill_nodes(pool)
        lists, vars = pool.saved_lists_and_vars
        index = pool.part_name(:refill)
        ensure_var(index)
        # A list made full of one value is made full again, the way power-on made it; the rest
        # are emptied, and the free stack filled again a slot at a time.
        refilled = lists.map do |list|
          made = declared_list_node(list)
          if made.full_of
            Build.list_new_like(made)
          else
            Build.repeat(Build.list_len(list), index, Build.list_drop(list, from: :back))
          end
        end
        [*refilled, build_pool_fill(pool, pool.capacity),
         *vars.map { |var| Build.set(var, Build.int(pool.power_on_value(var))) }]
      end

      private

      # How wide a slot NUMBER has to be for a pool of this size — the free stack and the
      # chain hold one per entry, and the largest is one less than the capacity. A narrow
      # slot reads back below nothing past half its range (a byte holds -128 to 127), and the
      # chain also holds -1 for "no slot", so a byte serves a pool of up to 128.
      def slot_width(capacity)
        return :byte if capacity <= 128
        return :half if capacity <= 32_768

        :word
      end

      # A boot loop that pushes each slot's own index onto the free stack, so every slot starts
      # free. The pool's other lists are made full as they are declared (see
      # #pool_list_starts), so every index of them is there to read from the start.
      def build_pool_fill(pool, capacity)
        index = pool.part_name(:fill)
        ensure_var(index)
        Build.repeat(Build.int(capacity), index, Build.list_push(pool.free_list, Build.var_ref(index)))
      end
    end
  end
end
