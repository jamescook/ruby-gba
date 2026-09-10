# frozen_string_literal: true

module RubyGBA
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

      # Field names that would shadow a Pool/Instance method, so a component can't
      # declare one (it would clash with spawn/remove/each/count/…).
      POOL_RESERVED_FIELDS = %i[active free count slot spawn remove each full index name capacity].freeze

      # What spawn does when the pool is full: :drop ignores it (a safe no-op),
      # :recycle_oldest reuses the longest-lived instance so a new one always appears.
      POOL_FULL_POLICIES = %i[drop recycle_oldest].freeze

      # A single pool must fit comfortably within IWRAM (the GBA's 32KB of fast RAM).
      # This is the cheap first-line ceiling that turns an insane capacity into a
      # friendly build error; the thorough whole-program budget (vars + lists + several
      # pools adding up) is a separate guardrail.
      POOL_MAX_BYTES = 16 * 1024

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
      #   enemies.each { |e| e.y.add 1; bullet.overlaps?(e).then { e.remove } }
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
      # `estimate:` tells the COST ESTIMATE something it cannot work out for itself, the same
      # hint a {Builder#list} takes and with the same words. `usually:` is how many instances
      # are normally live. `each` walks every slot whatever happens — that part is real work
      # and is counted whole — but the BODY only runs for a live one, and a pool is sized for
      # the worst moment of a game rather than a normal one:
      #
      #   bullets = pool :bullet, x: 0, y: 0, vy: 0, capacity: 64, estimate: { usually: 6 }
      #
      # So the guardrails count the body six times a frame instead of sixty-four. A range
      # (`usually: 4..8`) counts at its top.
      #
      # A pooled thing FACES AND ANIMATES the way a sprite does, spelled the same way.
      # Give the pool `facing:` (a picture per direction, or a list of frames per
      # direction) or `frames:` (a flipbook) instead of `image:`, with `rate:` for
      # either animated form:
      #
      #   guards = pool :guard, x: 0, y: 0, capacity: 32, rate: 6,
      #                 facing: { left: [:walk_l1, :walk_l2], right: [:walk_r1, :walk_r2] }
      #   guards.each { |g| g.face :left; g.x.sub 1 }
      #
      # Each instance holds its own direction and its own place in the cycle, so ten
      # guards face ten ways and do not march in step. That is the pool's own
      # bookkeeping — a hidden slot beside the fields, not something to declare.
      #
      # @param name [Symbol] the pool's name
      # @param capacity [Integer] the most instances that can be live at once
      # @param image [Symbol, nil] the sprite image each live instance draws
      # @param facing [Hash{Symbol=>Symbol,Array}, nil] direction => picture, or => frames
      # @param frames [Array<Symbol>, nil] same-size pictures to cycle as an animation
      # @param rate [Integer, nil] game-frames per animation step (needed with an animation)
      # @param on_full [Symbol] :drop (default) or :recycle_oldest — see above
      # @param estimate [Hash, nil] what the estimate cannot know — today `usually:` (Integer or Range)
      # @param fields [Hash{Symbol=>Object}] field name => default value
      # @return [Pool]
      def pool(name, capacity:, image: nil, facing: nil, frames: nil, rate: nil,
               on_full: :drop, estimate: nil, widths: {}, **fields)
        validate_pool!(name, capacity, fields)
        validate_on_full!(name, on_full)
        validate_pool_widths!(name, fields, widths)
        art = pool_art!(name, image: image, facing: facing, frames: frames, rate: rate, fields: fields)
        handle = Pool.new(self, name, fields, capacity, image: image, hitbox: art&.hitbox, on_full: on_full,
                                                        usually: usual_length(estimate, capacity), art: art)
        setup_pool_storage(handle, capacity, fields, widths)
        setup_pool_art(handle, capacity, art) if art
        handle
      end

      private

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

        spriteful_pool!(name, fields)
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
        return if width == :word || Fraction.bits_of(default).nil?

        raise ArgumentError,
              "pool :#{name} gives field :#{field} the width :#{width}, but it was declared with " \
              "#{default.inspect}, so it holds a fraction. A fraction needs a whole word. Remove the " \
              "width, or declare the field with a whole number."
      end

      def validate_pool!(name, capacity, fields)
        raise ArgumentError, "A pool needs a name that is a Symbol. Got #{name.inspect}." unless name.is_a?(Symbol)
        unless Whole.positive?(capacity)
          raise ArgumentError, "pool :#{name} needs a positive capacity. Got #{capacity.inspect}."
        end

        reserved = fields.keys & POOL_RESERVED_FIELDS
        unless reserved.empty?
          raise ArgumentError,
                "pool :#{name} cannot have a field named :#{reserved.first}. That name is reserved because a " \
                "pool method uses it. Pick a different field name."
        end

        # Insane capacity: a friendly build error rather than a silent IWRAM overrun.
        slots = Build.round_up_capacity(capacity)
        bytes = slots * (fields.size + 2) * 4 # field lists + active + free, 4 bytes per slot
        return unless bytes > POOL_MAX_BYTES

        raise ArgumentError,
              "pool :#{name} has #{capacity} instances of #{fields.size} fields each. It needs about " \
              "#{bytes / 1024}KB of the console's #{PlainWords::QUICK_MEMORY}. This is too much. A pool must " \
              "use much less than #{POOL_MAX_BYTES / 1024}KB. The console has only 32KB of " \
              "#{PlainWords::QUICK_MEMORY} in total. Use a smaller capacity or fewer fields."
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
      def spriteful_pool!(name, fields)
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

      # Declare one hardware-sprite object per slot, each bound to the field lists at its
      # fixed index — so present_objects draws every live slot at its x/y and hides the
      # dead ones for free. The active flag is scene-gated, so a pool declared in a scene
      # only shows while that scene is live.
      #
      # WHICH PICTURE a slot shows is read out of the pool's own hidden slots the same
      # way its position is: the direction it faces and where it is in its cycle are
      # per-instance, so ten guards face ten ways and do not march in step.
      def setup_pool_art(pool, capacity, art)
        capacity.times do |slot|
          name = pool.object_name(slot)
          record(Build.object(name, poses: art.poses, pose: pool.pose_node(slot),
                                    x: Build.list_get(pool.field_list(:x), Build.int(slot)),
                                    y: Build.list_get(pool.field_list(:y), Build.int(slot)),
                                    active: scene_gate(Build.list_get(pool.active_list, Build.int(slot))),
                                    scene: declaring_scene))
          @pool_objects << name
        end
        register_pool_animation(pool, capacity, art) if art.animates?
      end

      # THE POOL'S RHYTHM IS SHARED AND ITS PLACE IN THE CYCLE IS NOT, which is what makes
      # this cheap enough to put on every frame. One counter for the whole pool decides
      # WHEN a step happens; each instance keeps its own frame, so an instance spawned
      # later is at a different point in the same cycle and the pool does not pulse as one.
      #
      # So a frame that is not a step costs one compare, and a step costs a walk of the
      # slots — a rate of six makes that one walk in six.
      def register_pool_animation(pool, capacity, art)
        index = :"__pool_#{pool.name}_anim"
        ensure_var(index)
        # A fresh node per use: an IR node belongs to one parent, so the same read cannot
        # be handed to two statements.
        frame = -> { Build.list_get(pool.frame_list, Build.var_ref(index)) }
        wrap = Build.if_(Build.binop(:>=, frame.call, Build.int(art.cycle_length)),
                         Build.list_set(pool.frame_list, Build.var_ref(index), Build.int(0)))
        step = Build.repeat(Build.int(capacity), index,
                            Build.list_set(pool.frame_list, Build.var_ref(index),
                                           Build.binop(:+, frame.call, Build.int(1))),
                            wrap)
        @pool_animations << { tick: pool.tick_var, rate: art.rate, step: step }
      end

      # Create the backing lists once at boot — not where `pool` is written, so a pool
      # declared inside a scene is still set up once rather than re-created every frame —
      # and fill every slot so each field is randomly addressable from the start.
      def setup_pool_storage(pool, capacity, fields, widths = {})
        fields.each_key do |field|
          check_width_holds_fractions!(pool.name, field, fields[field], widths.fetch(field, :word))
          at_boot(Build.list_new(pool.field_list(field), capacity,
                                 width: widths.fetch(field, :word)))
        end

        # THE POOL'S OWN BOOKKEEPING IS NARROWED WITHOUT BEING ASKED, because unlike a field
        # the framework knows exactly what these hold. The active column is a yes or a no, so
        # it is a byte whatever the pool is; the free stack holds slot numbers, so it is as
        # wide as the largest slot number needs and no wider. Together they are two of a
        # pool's lists — on one with a dozen fields that is a modest saving, and on a small
        # one it is a sixth of the whole pool, for nothing anybody has to write.
        at_boot(Build.list_new(pool.active_list, capacity, width: :byte))
        at_boot(Build.list_new(pool.free_list, capacity, width: slot_width(capacity)))
        # A posed pool keeps two more hidden slots beside its fields: which way each
        # instance faces, and where each is in its cycle. Both are small counts, so both
        # are narrowed without being asked, the same as the active column.
        pool.pose_lists.each { |list| at_boot(Build.list_new(list, capacity, width: :byte)) }
        if pool.art&.animates?
          ensure_var(pool.tick_var)
          at_boot(Build.set(pool.tick_var, Build.int(0)))
        end
        # ...but the age stamp is a spawn counter that rises for the whole game, so it stays
        # a word: narrowing it would wrap, and two instances would then look the same age.
        at_boot(Build.list_new(pool.born_list, capacity)) if pool.recycle_oldest?
        ensure_var(pool.count_var)
        ensure_var(pool.slot_var)
        at_boot(Build.set(pool.count_var, Build.int(0)))
        if pool.recycle_oldest?
          ensure_var(pool.seq_var)
          at_boot(Build.set(pool.seq_var, Build.int(0))) # the monotonic spawn counter starts at 0
        end
        at_boot(build_pool_fill(pool, capacity, fields))
      end

      # How wide a slot NUMBER has to be for a pool of this size — the free stack holds one
      # per entry, and the largest it ever holds is one less than the capacity.
      def slot_width(capacity)
        return :byte if capacity <= 256
        return :half if capacity <= 65_536

        :word
      end

      # A boot loop that pushes one slot per iteration: 0 into every field and the active
      # column, and the slot's own index onto the free stack — so all `capacity` slots
      # exist (length == capacity, every index addressable) and every slot starts free.
      def build_pool_fill(pool, capacity, fields)
        index = :"__pool_#{pool.name}_fill"
        ensure_var(index)
        body = fields.keys.map { |f| Build.list_push(pool.field_list(f), Build.int(0)) }
        body << Build.list_push(pool.active_list, Build.int(0))
        pool.pose_lists.each { |list| body << Build.list_push(list, Build.int(0)) }
        body << Build.list_push(pool.born_list, Build.int(0)) if pool.recycle_oldest?
        body << Build.list_push(pool.free_list, Build.var_ref(index))
        Build.repeat(Build.int(capacity), index, *body)
      end
    end
  end
end
