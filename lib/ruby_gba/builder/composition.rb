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
      # @param name [Symbol] the pool's name
      # @param capacity [Integer] the most instances that can be live at once
      # @param image [Symbol, nil] the sprite image each live instance draws
      # @param on_full [Symbol] :drop (default) or :recycle_oldest — see above
      # @param estimate [Hash, nil] what the estimate cannot know — today `usually:` (Integer or Range)
      # @param fields [Hash{Symbol=>Object}] field name => default value
      # @return [Pool]
      def pool(name, capacity:, image: nil, on_full: :drop, estimate: nil, widths: {}, **fields)
        validate_pool!(name, capacity, fields)
        validate_on_full!(name, on_full)
        validate_pool_widths!(name, fields, widths)
        hitbox = image && spriteful_hitbox!(name, image, fields)
        handle = Pool.new(self, name, fields, capacity, image: image, hitbox: hitbox, on_full: on_full,
                                                        usually: usual_length(estimate, capacity))
        setup_pool_storage(handle, capacity, fields, widths)
        setup_pool_sprites(handle, capacity) if image
        handle
      end

      private

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

      # Validate a spriteful pool and return the collision box its image gives every
      # instance. Its instances are hardware sprites, so it needs a tiled screen and x/y
      # position fields, and the image must be defined.
      def spriteful_hitbox!(name, image, fields)
        unless @screen_mode == :tiled
          raise ArgumentError,
                "pool :#{name} has an image, so its instances are hardware sprites. Hardware sprites need a " \
                "`screen :tiled`. Declare the pool under one. Or remove image: and draw the pool yourself in " \
                "each on a bitmap screen."
        end
        missing = %i[x y] - fields.keys
        unless missing.empty?
          raise ArgumentError,
                "A spriteful pool needs x: and y: fields. They set the sprite position. pool :#{name} is " \
                "missing #{missing.map { |f| "#{f}:" }.join(' and ')}."
        end
        size = @images[image] or
          raise ArgumentError,
                "pool :#{name} draws image :#{image}, but no `image :#{image}` is defined yet. Define the " \
                "image before the pool."

        collision_box(name: image, images: [image], width: size[0], height: size[1], hitbox: nil)
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
        body << Build.list_push(pool.born_list, Build.int(0)) if pool.recycle_oldest?
        body << Build.list_push(pool.free_list, Build.var_ref(index))
        Build.repeat(Build.int(capacity), index, *body)
      end
    end
  end
end
