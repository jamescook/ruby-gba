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
    def initialize(builder, name, fields, capacity, image: nil, hitbox: nil, on_full: :drop)
      @builder = builder
      @name = name
      @fields = fields
      @capacity = capacity
      @image = image
      @hitbox = hitbox
      @on_full = on_full
    end

    # The sprite image live instances draw (nil for a pure-data pool), and the collision
    # box derived from it (nil when there's no size).
    attr_reader :image, :hitbox

    # Whether instances draw themselves as sprites (an image was given).
    def spriteful? = !@image.nil?

    # Whether a spawn onto a full pool reuses the oldest live instance (rather than
    # dropping the spawn). When true the pool keeps a little extra bookkeeping (below).
    def recycle_oldest? = @on_full == :recycle_oldest

    # The per-slot sprite object's name (one hardware sprite per slot).
    def object_name(slot) = :"__pool_#{@name}_obj_#{slot}"

    # --- backing-storage names (also used by Builder#pool to set the storage up) ---

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
        (active[i] == 1).then { block.call(Instance.new(pool, i)) }
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
      FieldRef.new(@builder, field_list(field), index.node)
    end

    private

    # The default policy: create in a free slot, or leave a full pool untouched. Guarded
    # on a free slot existing, so a full pool is a clean no-op (nothing half-written).
    def spawn_dropping(values)
      slot = Build.var_ref(slot_var)
      body = claim_free_slot(slot) + assign_fields(slot, values)
      record(Build.if_(free_available, *body))
    end

    # The :recycle_oldest policy: take a free slot when there is one, otherwise reuse the
    # longest-lived instance's slot — so a new spawn always appears. Either way the chosen
    # slot then takes the new instance's fields and a fresh age stamp (its spawn order),
    # which is what makes the *next* full spawn able to find the oldest again.
    def spawn_recycling(values)
      slot = Build.var_ref(slot_var)
      choose = Build.if_(free_available, *claim_free_slot(slot))
      choose[:else] = Build.else_(*take_oldest_slot)
      record(choose)
      assign_fields(slot, values).each { |node| record(node) }
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
        Build.list_set(field_list(field), slot, Value.node_for(values.fetch(field, default)))
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
    # are reached by name (`b.x`, `b.hp`) — each a mutable {FieldRef} at this slot — and
    # `b.remove` retires it. The instance is only valid inside the `each` iteration that
    # yielded it (it's bound to the loop's current slot), not something to keep around.
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
