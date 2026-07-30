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
      # @param name [Symbol] the pool's name
      # @param capacity [Integer] the most instances that can be live at once
      # @param image [Symbol, nil] the sprite image each live instance draws
      # @param on_full [Symbol] :drop (default) or :recycle_oldest — see above
      # @param fields [Hash{Symbol=>Object}] field name => default value
      # @return [Pool]
      def pool(name, capacity:, image: nil, on_full: :drop, **fields)
        validate_pool!(name, capacity, fields)
        validate_on_full!(name, on_full)
        hitbox = image && spriteful_hitbox!(name, image, fields)
        handle = Pool.new(self, name, fields, capacity, image: image, hitbox: hitbox, on_full: on_full)
        setup_pool_storage(handle, capacity, fields)
        setup_pool_sprites(handle, capacity) if image
        handle
      end

      private

      def validate_pool!(name, capacity, fields)
        raise ArgumentError, "a pool needs a name (a Symbol), got #{name.inspect}" unless name.is_a?(Symbol)
        unless capacity.is_a?(Integer) && capacity.positive?
          raise ArgumentError, "pool :#{name} needs a positive capacity, got #{capacity.inspect}"
        end

        reserved = fields.keys & POOL_RESERVED_FIELDS
        unless reserved.empty?
          raise ArgumentError,
                "pool :#{name} can't have a field named :#{reserved.first} — that name is reserved (it would " \
                "clash with a pool method). Pick another field name."
        end

        # Insane capacity: a friendly build error rather than a silent IWRAM overrun.
        slots = Build.round_up_capacity(capacity)
        bytes = slots * (fields.size + 2) * 4 # field lists + active + free, 4 bytes per slot
        return unless bytes > POOL_MAX_BYTES

        raise ArgumentError,
              "pool :#{name} of #{capacity} x #{fields.size} fields needs about #{bytes / 1024}KB of fast RAM, " \
              "but a pool must stay well under #{POOL_MAX_BYTES / 1024}KB (the GBA has 32KB in total). Use a " \
              "smaller capacity or fewer fields."
      end

      def validate_on_full!(name, policy)
        return if POOL_FULL_POLICIES.include?(policy)

        raise ArgumentError,
              "pool :#{name} got on_full: #{policy.inspect}, but it must be one of " \
              "#{POOL_FULL_POLICIES.map(&:inspect).join(', ')} — :drop ignores a spawn when the pool is full, " \
              ":recycle_oldest reuses the longest-lived instance so a new one always appears."
      end

      # Validate a spriteful pool and return the collision box its image gives every
      # instance. Its instances are hardware sprites, so it needs a tiled screen and x/y
      # position fields, and the image must be defined.
      def spriteful_hitbox!(name, image, fields)
        unless @screen_mode == :tiled
          raise ArgumentError,
                "pool :#{name} has an image, so its instances are hardware sprites — declare it under a " \
                "`screen :tiled` (or drop image: and draw the pool yourself in each on a bitmap screen)."
        end
        missing = %i[x y] - fields.keys
        unless missing.empty?
          raise ArgumentError,
                "a spriteful pool needs x: and y: fields (its sprite's position) — pool :#{name} is missing " \
                "#{missing.map { |f| "#{f}:" }.join(' and ')}."
        end
        size = @images[image] or
          raise ArgumentError, "pool :#{name} draws image :#{image}, but no `image :#{image}` is defined yet."

        collision_box(image, [image], *size, nil)
      end

      # Declare one hardware-sprite object per slot, each bound to the field lists at its
      # fixed index — so present_objects draws every live slot at its x/y and hides the
      # dead ones for free. The active flag is scene-gated, so a pool declared in a scene
      # only shows while that scene is live.
      def setup_pool_sprites(pool, capacity)
        capacity.times do |slot|
          name = pool.object_name(slot)
          record(Build.object(name, poses: [pool.image], pose: Build.int(0),
                                    x: Build.list_get(pool.field_list(:x), Build.int(slot)),
                                    y: Build.list_get(pool.field_list(:y), Build.int(slot)),
                                    active: scene_gate(Build.list_get(pool.active_list, Build.int(slot)))))
          @pool_objects << name
        end
      end

      # Create the backing lists once at boot — not where `pool` is written, so a pool
      # declared inside a scene is still set up once rather than re-created every frame —
      # and fill every slot so each field is randomly addressable from the start.
      def setup_pool_storage(pool, capacity, fields)
        lists = fields.keys.map { |f| pool.field_list(f) } + [pool.active_list, pool.free_list]
        lists << pool.born_list if pool.recycle_oldest? # a per-slot age stamp for the oldest scan
        lists.each { |list_name| at_boot(Build.list_new(list_name, capacity)) }
        ensure_var(pool.count_var)
        ensure_var(pool.slot_var)
        at_boot(Build.set(pool.count_var, Build.int(0)))
        if pool.recycle_oldest?
          ensure_var(pool.seq_var)
          at_boot(Build.set(pool.seq_var, Build.int(0))) # the monotonic spawn counter starts at 0
        end
        at_boot(build_pool_fill(pool, capacity, fields))
      end

      # A boot loop that pushes one slot per iteration: 0 into every field and the active
      # column, and the slot's own index onto the free stack — so all `capacity` slots
      # exist (length == capacity, every index addressable) and every slot starts free.
      def build_pool_fill(pool, capacity, fields)
        index = :"__pool_#{pool.name}_fill"
        ensure_var(index)
        body = fields.keys.map { |f| Build.list_push(pool.field_list(f), Build.int(0)) }
        body << Build.list_push(pool.active_list, Build.int(0))
        body << Build.list_push(pool.born_list, Build.int(0)) if pool.recycle_oldest?
        body << Build.list_push(pool.free_list, Build.var_ref(index))
        Build.repeat(Build.int(capacity), index, *body)
      end
    end
  end
end
