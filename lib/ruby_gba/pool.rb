# frozen_string_literal: true

module RubyGBA
  # A handle to a pool: a fixed-capacity set of instances of a "component" — many of a
  # thing that has state and behaves (bullets, enemies, particles, coins). `pool
  # :bullet, x: 0, y: 0, vy: 0, capacity: 64` hands one back. See Builder#pool.
  #
  #   bullets = pool :bullet, x: 0, y: 0, vy: 0, capacity: 64
  #   bullets.spawn x: ship.x, y: ship.y, vy: -4
  #   bullets.each { |b| b.y.add b.vy; (b.y < 0).then { b.remove } }
  #
  # Behind the scenes each field is a backing {List}, one slot per instance, alongside
  # an `active` column (which slots are live) and a `free` stack (open slot indices). So
  # spawn and remove are O(1) — pop or push a free index — a live instance keeps its
  # slot (stable identity), removing one mid-`each` is just clearing a flag, and the
  # fields can never desync because there's no way to touch one without the others. It
  # all desugars onto list ops + a `repeat`, so every backend runs it and the cost model
  # sees straight through it.
  class Pool
    Build = IR::Build

    # @return [Symbol] the pool's name
    attr_reader :name
    # @return [Integer] the most instances that can be live at once
    attr_reader :capacity

    # Built by Builder#pool, which allocates the backing lists and boot-fills them.
    #
    # @param builder [Builder] the build these operations record into
    # @param name [Symbol] the pool's name
    # @param fields [Hash{Symbol=>Object}] field name => default value
    # @param capacity [Integer] the live cap (the most instances at once)
    # @param image [Symbol, nil] the sprite image each live instance draws (nil = pure data)
    # @param hitbox [Array(Integer,Integer,Integer,Integer), nil] the collision box
    #   [x, y, w, h] relative to an instance's top-left, from the image (nil = no size)
    # @param on_full [Symbol] what spawn does when there's no free slot — :drop (ignore
    #   it, a safe no-op) or :recycle_oldest (reuse the longest-lived instance)
    # @param usually [Integer, nil] how many instances are normally live — for the cost
    #   estimate only (see Builder#pool), never for anything the program does
    # @param art [Builder::Composition::PoolArt, nil] what the instances look like — the
    #   pictures they can show and how a slot picks one (nil for a pure-data pool)
    def initialize(builder, name, fields, capacity, image: nil, hitbox: nil, on_full: :drop,
                   usually: nil, art: nil)
      @builder = builder
      @name = name
      @fields = fields
      @capacity = capacity
      @image = image
      @hitbox = hitbox
      @on_full = on_full
      @usually = usually
      @art = art
    end

    # The sprite image live instances draw (nil for a pure-data pool), and the collision
    # box derived from it (nil when there's no size).
    attr_reader :image, :hitbox, :art

    # Whether instances draw themselves as sprites.
    def spriteful? = !@art.nil?

    # Whether a spawn onto a full pool reuses the oldest live instance (rather than
    # dropping the spawn). When true the pool keeps a little extra bookkeeping (below).
    def recycle_oldest? = @on_full == :recycle_oldest

    # The per-slot sprite object's name (one hardware sprite per slot).
    def object_name(slot) = :"__pool_#{@name}_obj_#{slot}"

    # --- backing-storage names ---------------------------------------------------
    #
    # Framework-internal: `Builder#pool` (builder/composition.rb) calls these to wire
    # the pool's storage up. They are not part of the pool authoring interface — a
    # game reaches an instance's data through `each`/`spawn`/`field_ref`, never these.

    def field_list(field) = :"__pool_#{@name}_#{field}"
    def active_list = :"__pool_#{@name}_active"
    def free_list = :"__pool_#{@name}_free"
    def count_var = :"__pool_#{@name}_count"
    def slot_var = :"__pool_#{@name}_slot"

    # Recycle-oldest bookkeeping (allocated only for an :recycle_oldest pool): a
    # per-slot age stamp (born_list), a monotonic spawn counter that stamps it
    # (seq_var), and two scratch names the "find the oldest" scan works in.
    def born_list = :"__pool_#{@name}_born"
    def seq_var = :"__pool_#{@name}_seq"
    def oldest_born_var = :"__pool_#{@name}_oldest"
    def scan_index_var = :"__pool_#{@name}_scan"

    # Pose bookkeeping (allocated only for a pool whose instances face or animate): which
    # way each instance faces, where each is in its cycle, and the one counter that
    # decides when the whole pool steps.
    def facing_list = :"__pool_#{@name}_facing"
    def frame_list = :"__pool_#{@name}_frame"
    def tick_var = :"__pool_#{@name}_tick"

    # Which of those two this pool actually keeps — so the boot fill gives every slot one
    # of each, the same way it does for a field.
    def pose_lists
      lists = []
      lists << facing_list if @art&.faces?
      lists << frame_list if @art&.animates?
      lists
    end

    # WHICH PICTURE ONE SLOT SHOWS, as a value node. A plain pool always shows its one
    # picture. A pool that faces reads the slot's direction; one that animates reads its
    # frame; one that does both composes them — direction * frames-per-direction + frame,
    # which is the order the pictures were flattened in.
    def pose_node(slot)
      at = Build.int(slot)
      facing = Build.list_get(facing_list, at) if @art.faces?
      frame = Build.list_get(frame_list, at) if @art.animates?
      return frame || facing || Build.int(0) unless facing && frame

      Build.binop(:+, Build.binop(:*, facing, Build.int(@art.per_dir)), frame)
    end

    # Which row of the pictures a direction name means, for Instance#face.
    def facing_row(direction) = @art&.dirs&.[](direction)
    def facing_names = @art&.dirs&.keys || []

    # Point one instance at a direction (its row among the pictures).
    def set_facing(index, row)
      record(Build.list_set(facing_list, index.node, Build.int(row)))
      self
    end

    # The field names, in declaration order.
    def field_names = @fields.keys

    # Whether +name+ is one of this pool's fields (used by an instance handle).
    def field?(name) = @fields.key?(name)

    # Create a live instance, setting the named fields (any omitted use their declared
    # default). All fields are set together, so a half-populated instance is impossible.
    #
    # What happens when the pool is full depends on its `on_full:` policy: the default
    # `:drop` makes this a safe no-op (nothing is created and nothing is corrupted —
    # check #full? / #count if you need to know), while `:recycle_oldest` reuses the
    # longest-lived instance so a new one always appears.
    def spawn(**values)
      unknown = values.keys - @fields.keys
      unless unknown.empty?
        raise ArgumentError,
              "pool :#{@name} has no field #{unknown.first.inspect} — its fields are #{@fields.keys.join(', ')}"
      end

      recycle_oldest? ? spawn_recycling(values) : spawn_dropping(values)
      self
    end

    # Run the block once per LIVE instance, handing it a row handle whose fields are
    # mutable (`b.x.add`, `b.y.set`, read `b.x`) and which can retire itself (`b.remove`).
    # A removed or never-spawned slot is skipped. It walks all `capacity` slots (a cheap
    # active check on a dead one).
    def each(&block)
      pool = self
      active = List.new(@builder, active_list)
      @builder.repeat(@capacity) do |i|
        # Recorded through the builder rather than with `.then` so the guard can carry what
        # the cost estimate needs — the walk is over every slot, the body is only for a live
        # one — without that hint becoming something an author can write on any `.then`.
        live = active[i] == 1
        @builder.consume_condition(live)
        @builder.record_conditional(live.node, over: @name, usually: @usually, of: @capacity) do
          block.call(Instance.new(pool, i))
        end
      end
      self
    end

    # How many instances are live right now, as a {Value}.
    def count = Value.new(@builder, Build.var_ref(count_var))

    # Whether the pool is full (no free slot), as a {Condition} — branch with `.then`.
    def full? = count >= @capacity

    # Retire the instance at slot +index+ (a {Value}): free the slot and stop drawing/
    # updating it next frame. Called by {Instance#remove}; safe to call mid-`each`.
    def remove_at(index)
      record(Build.list_set(active_list, index.node, Build.int(0)))
      record(Build.list_push(free_list, index.node))
      record(Build.sub(count_var, Build.int(1)))
      self
    end

    # A mutable handle to +field+ of the instance at slot +index+ (a {Value}).
    def field_ref(field, index)
      field_handle(field, index.node)
    end

    # One field of one slot, with everything it needs to read, write and complain clearly.
    def field_handle(field, index_node)
      FieldRef.new(builder: @builder, list: field_list(field), index: index_node,
                   pool: @name, field: field, fraction_bits: field_bits(field))
    end

    # What a field holds, taken from the default it was declared with. Writing `vy: 0.0`
    # is how a pool says a field carries a fraction, exactly as writing `var :vy, 0.0` does
    # for a variable — so a game with sixty particles drifting at fractional speeds never
    # picks a scale of its own.
    def field_bits(field) = Fraction.bits_of(@fields[field])

    private

    # The default policy: create in a free slot, or leave a full pool untouched. Guarded
    # on a free slot existing, so a full pool is a clean no-op (nothing half-written).
    def spawn_dropping(values)
      slot = Build.var_ref(slot_var)
      body = claim_free_slot(slot) + assign_fields(slot, values) + reset_pose(slot)
      record(Build.if_(free_available, *body))
    end

    # The :recycle_oldest policy: take a free slot when there is one, otherwise reuse the
    # longest-lived instance's slot — so a new spawn always appears. Either way the chosen
    # slot then takes the new instance's fields and a fresh age stamp (its spawn order),
    # which is what makes the *next* full spawn able to find the oldest again.
    def spawn_recycling(values)
      slot = Build.var_ref(slot_var)
      choose = Build.if_(free_available, *claim_free_slot(slot))
      choose.else = Build.else_(*take_oldest_slot)
      record(choose)
      assign_fields(slot, values).each { |node| record(node) }
      reset_pose(slot).each { |node| record(node) }
      record(Build.list_set(born_list, slot, Build.var_ref(seq_var)))
      record(Build.add(seq_var, Build.int(1)))
    end

    # Pop the newest free slot into slot_var, mark it live, and grow the count — the "there
    # is room" path both policies share.
    def claim_free_slot(slot)
      [Build.set(slot_var, last_free_index),
       Build.list_drop(free_list, from: :back),
       Build.list_set(active_list, slot, Build.int(1)),
       Build.add(count_var, Build.int(1))]
    end

    # A new instance starts facing the first direction and at the start of its cycle,
    # whatever the slot it took was doing before. Instances spawned at different moments
    # therefore sit at different points in the same cycle, which is what stops a pool of
    # them pulsing as one.
    def reset_pose(slot)
      nodes = []
      nodes << Build.list_set(facing_list, slot, Build.int(0)) if @art&.faces?
      nodes << Build.list_set(frame_list, slot, Build.int(0)) if @art&.animates?
      nodes
    end

    # Statements that leave the oldest live instance's slot index in slot_var. Only reached
    # when the pool is full — every slot is live then — so it's a plain scan for the slot
    # with the smallest age stamp (ages rise with spawn order, so the smallest is the
    # oldest); no active check is needed. Bounded by the (small, fixed) capacity.
    def take_oldest_slot
      i = Build.var_ref(scan_index_var)
      [Build.set(slot_var, Build.int(0)),
       Build.set(oldest_born_var, Build.list_get(born_list, Build.int(0))),
       Build.repeat(Build.int(@capacity), scan_index_var,
                    Build.if_(Build.binop(:<, Build.list_get(born_list, i), Build.var_ref(oldest_born_var)),
                              Build.set(oldest_born_var, Build.list_get(born_list, i)),
                              Build.set(slot_var, i)))]
    end

    # The list_set nodes that write each field of the instance at +slot+ (omitted fields
    # take their declared default).
    def assign_fields(slot, values)
      @fields.map do |field, default|
        given = values.fetch(field, default)
        # Checked against what the field holds, so spawning with a fraction into a whole
        # field — or the other way round — is the same friendly error as writing one later.
        node = field_handle(field, slot).node_matching(given, "hold")
        Build.list_set(field_list(field), slot, node)
      end
    end

    # A condition that's true while the pool has a free slot.
    def free_available = Build.binop(:>, Build.list_len(free_list), Build.int(0))

    # The value node for the last free slot index: free[len - 1].
    def last_free_index
      Build.list_get(free_list, Build.binop(:-, Build.list_len(free_list), Build.int(1)))
    end

    def record(node) = @builder.record_statement(node)

    # One live instance, as the block sees it: a row handle over a pool slot. Its fields
    # are reached by name (`b.x`, `b.hp`) — each a mutable {FieldRef} at this slot —
    # `b.remove` retires it, and `b.index` hands back its slot as a Value, to remember
    # which instance won a comparison and act on it after the loop. The instance is only
    # valid inside the `each` iteration that yielded it (it's bound to the loop's current
    # slot), not something to keep around — but `index` is just a number, so keep that.
    #
    # A spriteful pool's instance also has a rectangle (its x/y fields plus the image's
    # collision box), so it gains `overlaps?`, the screen-edge tests, and
    # `clamp_to_screen` from {Bounds} — `bullet.overlaps?(enemy)`, `b.off_screen?`.
    class Instance
      include Bounds # overlaps? + off_screen?/edge tests, from left/top/right/bottom below

      def initialize(pool, index)
        @pool = pool
        @index = index # a Value: the loop's current slot
      end

      # Retire this instance: free its slot, stop it next frame.
      def remove
        @pool.remove_at(@index)
      end

      # Turn this instance to face a direction — the same verb, spelled the same way, that
      # a `sprite` given `facing:` takes. Each instance holds its own direction, so ten
      # guards in one pool can face ten ways.
      def face(direction)
        row = @pool.facing_row(direction)
        if row.nil?
          known = @pool.facing_names
          raise ArgumentError,
                "pool :#{@pool.name} has no direction #{direction.inspect}. " \
                "#{known.empty? ? 'It was not given facing: pictures.' : "It faces #{known.join(', ')}."}"
        end
        @pool.set_facing(@index, row)
        self
      end

      # This instance's own slot, as a Value. The instance handle itself doesn't survive
      # past the `each` iteration that yielded it, but a slot number is just a number —
      # save it in a variable to remember which instance won a comparison (the nearest
      # enemy, the one just hit) and act on it after the loop ends, with `pool.field_ref`.
      def index = @index

      # This instance's collision-box edges, as Values — its x/y fields plus the image's
      # box. These need a spriteful pool (one with an image, hence a size).
      def left = field(:x) + hit(0)
      def top = field(:y) + hit(1)
      def right = field(:x) + hit(0) + hit(2)
      def bottom = field(:y) + hit(1) + hit(3)

      # Keep this instance fully on the screen, using the sprite's own size — the
      # per-instance counterpart to {Sprite#clamp_to_screen}. Clamps its x/y in place.
      def clamp_to_screen
        hit_x, hit_y, hit_w, hit_h = require_box!
        field(:x).clamp(-hit_x, IR::Screen::WIDTH - hit_x - hit_w)
        field(:y).clamp(-hit_y, IR::Screen::HEIGHT - hit_y - hit_h)
        self
      end

      private

      def field(name) = @pool.field_ref(name, @index)

      def hit(component) = require_box![component]

      # The pool's collision box, or a friendly error if it has no size (no image).
      def require_box!
        @pool.hitbox || raise(ArgumentError,
                              "pool :#{@pool.name} has no size, so an instance has no rectangle — give the " \
                              "pool an `image:` to use overlaps? / the off-screen tests / clamp_to_screen")
      end

      # A field read like `b.x` becomes a FieldRef at this instance's slot.
      def method_missing(name, *args)
        return @pool.field_ref(name, @index) if args.empty? && @pool.field?(name)

        super
      end

      def respond_to_missing?(name, include_private = false)
        @pool.field?(name) || super
      end
    end
  end
end
