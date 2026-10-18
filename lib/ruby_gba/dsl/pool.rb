# frozen_string_literal: true

module RubyGBA
  module DSL
    # A handle to a pool: a fixed-capacity set of instances of a "component" — many of a
    # thing that has state and behaves (bullets, enemies, particles, coins). `pool
    # :bullet, x: 0, y: 0, vy: 0, capacity: 64` hands one back. See Builder#pool.
    #
    #   bullets = pool :bullet, x: 0, y: 0, vy: 0, capacity: 64
    #   bullets.spawn x: ship.x, y: ship.y, vy: -4
    #   bullets.each { |b| b.y.add! b.vy; (b.y < 0).then { b.remove } }
    #
    # Behind the scenes each field is a backing {List}, one slot per instance, alongside
    # an `active` column (which slots are live) and a `free` stack (open slot indices). So
    # spawn and remove are O(1) — pop or push a free index — a live instance keeps its
    # slot (stable identity), and the fields can never desync because there's no way to
    # touch one without the others. It all desugars onto list ops + a `repeat`, so every
    # backend runs it and the cost model sees straight through it.
    #
    # WHICH SLOT A THING LANDS IN SAYS NOTHING ABOUT WHEN IT CAME, so the slots are not the
    # order a walk goes in. Every slot also says which slot came next and which came before
    # it, and the pool keeps the first and the last: a chain through the live things in the
    # order they were spawned, which is how a console game keeps the things in a room. A
    # spawn joins the end of it and a removal closes the gap, so `each` visits the oldest
    # first and the newest last, and walks only what is in the chain rather than every slot.
    # That order is what a player can see: things that each roll a random number roll them
    # one after another, and the first to reach something gets it. A pool that draws is
    # drawn in it too, the oldest thing in front (see #stacked_list).
    class Pool
      Build = IR::Build

      # The slot number that means "no slot": the end of the chain, and an empty pool's
      # first and last.
      NONE = -1

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
      # @param art [Builder::Composition::PoolArt, nil] what the instances look like — the
      #   pictures they can show and how a slot picks one (nil for a pure-data pool)
      def initialize(builder, name, fields, capacity, image: nil, hitbox: nil, on_full: :drop, art: nil)
        @builder = builder
        @name = name
        @fields = fields
        @capacity = capacity
        @image = image
        @hitbox = hitbox
        @on_full = on_full
        @art = art
        @fast = nil
        # A field declared with a NAME — `state: :idle` — holds one of a set of them, exactly as
        # a variable declared with one does, and each instance keeps its own. The set belongs to
        # the field rather than to an instance: thirty guards can each be in a different state,
        # and there is one list of what those states are.
        @field_names = fields.filter_map do |field, default|
          next unless default.is_a?(Symbol)

          held = NameSet.new("the #{field.inspect} field of `pool :#{name}`")
          held.number_for(default) # the name it was declared with is the first of them
          [field, held]
        end.to_h
      end

      # The sprite image live instances draw (nil for a pure-data pool), and the collision
      # box derived from it (nil when there's no size).
      attr_reader :image, :hitbox, :art

      # Which of the console's two work memories the pool's lists are kept in, the way a
      # list's `fast:` says it: false for out of the quick one, true to insist on it, nil
      # for the build to decide. Settled by the build once it knows how big the pool is (see
      # Builder::Composition#pool), and read by the lists a pool only gains later.
      attr_accessor :fast

      # The scene a pool that draws was declared in, as the variable the game picks its scenes
      # with and the value that picks this one; nil for a pool declared outside every scene.
      # Its things show only while that scene is up, so that is when they are put in order.
      attr_accessor :scene_gate

      # Whether instances draw themselves as sprites.
      def spriteful? = !@art.nil?

      # Whether a spawn onto a full pool reuses the oldest live instance (rather than
      # dropping the spawn). When true the pool keeps a little extra bookkeeping (below).
      def recycle_oldest? = @on_full == :recycle_oldest

      # The name of one of the pool's sprite objects. There is one for each thing that can be
      # live at once, and +place+ counts them back to front.
      def object_name(place) = part_name("obj_#{place}")

      # WHAT EACH OF THE POOL'S SPRITES SHOWS IS WORKED OUT EVERY FRAME, from the chain.
      #
      # A pool that draws has one sprite for each thing that can be live at once, and where
      # two sprites overlap the one declared later is in front. If each sprite always showed
      # the same slot, which of two things was in front would follow the slots they landed
      # in, and a slot says nothing about when its thing came: a slot given back is the next
      # one handed out, so the newest thing would sometimes cover an older one and sometimes
      # not.
      #
      # So a sprite shows a PLACE IN THE ORDER rather than a slot. Before each frame is
      # drawn the chain is walked once, oldest first, and what each live thing looks like —
      # where it is, which picture, which colours — is copied into lists kept in that order.
      # The frontmost sprite then shows the first entry, the next one back the second, and a
      # sprite with no entry left to show is hidden. The oldest thing is in front of every
      # thing spawned after it, whatever slots they are in.
      #
      # THE COPY IS ONE LOOP FOR THE WHOLE POOL, and that is why it is a copy. Each sprite
      # could instead look up which slot stands at its place and read that slot's fields, but
      # a sprite's code is written out once per sprite, so every read through a second list
      # is paid in code for every slot the pool has, in the memory the frame's own code has
      # to fit — a pool's cost in code would grow with its capacity. Copied, each sprite
      # reads its own entry exactly as it used to read its own slot, and the pool pays one
      # loop however big it is, and a few bytes of memory a slot.
      #
      # +stacked_list+ names those lists and +stacked_var+ says how many entries they hold.
      def stacked_list(part) = part_name("stacked#{part}")
      def stacked_var = part_name(:stacked)
      def stacking_cursor_var = part_name(:stacking_at)
      def stacking_index_var = part_name(:stacking_pass)

      # What a pool copies for each thing: where it is, then its picture when there is more
      # than one to choose from, then its colours when it was ever told to draw with others.
      def stacked_parts
        parts = %i[x y]
        parts << :pose if posed?
        parts << :colors if recolorable?
        parts << :order_key if ordered?
        parts
      end

      # PUT THIS POOL'S THINGS IN AN ORDER THE GAME WORKS OUT (see Builder#draw_in_order).
      # +key+ is handed an instance and gives back the number that thing is ordered by, so
      # the number is worked out per thing as the copy above walks them and copied for its
      # place beside where it is.
      def order_by(key)
        @order_key = key
      end

      # Whether this pool is in a draw order.
      def ordered? = !@order_key.nil?

      # Whether a thing's picture is something to read at all: a pool given one picture
      # always shows it.
      def posed? = @art.faces? || @art.animates?

      # The routine that makes the copy (see #stacking_nodes), called before each frame is
      # drawn.
      def stacking_routine = Messages::MadeNames.make(:pool_stacking, pool: @name)

      # How many things are older than the one the sprite at +place+ shows. The sprites are
      # declared back to front, so the last of them shows the oldest thing.
      def rank_at_place(place) = @capacity - 1 - place

      # One part of the thing with +rank+ older things before it, as a value node.
      def stacked_at(part, rank) = Build.list_get(stacked_list(part), Build.int(rank))

      # Whether any live thing has +rank+ older things before it, as a value node.
      def rank_taken(rank) = Build.binop(:>, Build.var_ref(stacked_var), Build.int(rank))

      # The statements that make the copy: walk the chain from its first thing and copy each
      # live one into the next entry. A dead thing can still be in the chain — one removed
      # during a walk that a save was made in the middle of — and is passed over.
      def stacking_nodes
        at = -> { Build.var_ref(stacking_cursor_var) }
        copies = stacked_parts.map do |part|
          Build.list_set(stacked_list(part), Build.var_ref(stacked_var), part_of_slot(part, at))
        end
        live = Build.binop(:==, Build.list_get(active_list, at.call), Build.int(1))
        [Build.set(stacked_var, Build.int(0)),
         Build.set(stacking_cursor_var, Build.var_ref(head_var)),
         Build.repeat(Build.int(@capacity), stacking_index_var,
                      Build.if_(live, *copies, Build.add(stacked_var, Build.int(1))),
                      Build.set(stacking_cursor_var, Build.list_get(next_list, at.call)),
                      stop_when: Build.binop(:==, at.call, Build.int(NONE)))]
      end

      # One part of the thing in the slot +at+ gives, read from the pool's own lists. +at+ is
      # called for a fresh node at each use, since a node belongs to one statement.
      def part_of_slot(part, at)
        case part
        when :pose then pose_of_slot(at)
        when :colors then Build.list_get(colors_list, at.call)
        when :order_key
          # The thing is handed over, and a key the same for every thing of the pool never reads it.
          Value.node_for(@order_key.call(Instance.new(self, Value.handed_to_block(@builder, at.call))))
        else Build.list_get(field_list(part), at.call)
        end
      end

      # --- backing-storage names ---------------------------------------------------
      #
      # Framework-internal: `Builder#pool` (builder/composition.rb) calls these to wire
      # the pool's storage up. They are not part of the pool authoring interface — a
      # game reaches an instance's data through `each`/`spawn`/`field_ref`, never these.
      #
      # A FIELD'S LIST AND THE POOL'S OWN ARE SPELLED APART (see Messages::MadeNames), so a
      # field can be called what the pool calls one of its own — `frame`, `active`, `count` —
      # and still be a list of its own. +part_name+ is every name of the pool's own: a list,
      # a variable or a routine.

      def field_list(field) = Pool.field_list(@name, field)
      def part_name(part) = Pool.part_name(@name, part)
      def self.field_list(name, field) = Messages::MadeNames.make(:pool_field, pool: name, field: field)
      def self.part_name(name, part) = Messages::MadeNames.make(:pool_part, pool: name, part: part)

      def current_var = part_name(:current)
      def active_list = Pool.active_list(@name)
      def free_list = Pool.free_list(@name)
      def count_var = Pool.count_var(@name)

      # The three that say how many instances are live, by the pool's name alone: which slots
      # are (a byte each, 1 for live), the stack of slots that are free, and the count. They are
      # what a finished cartridge is written to hold a pool full (see
      # Diagnostics::FullCollections), so they are spelled here once for both.
      def self.active_list(name) = part_name(name, :active)
      def self.free_list(name) = part_name(name, :free)
      def self.count_var(name) = part_name(name, :count)

      # The pool whose live-slot column +list+ is, or nil when it is not one.
      def self.named_by_active_list(list)
        kind, parts = Messages::MadeNames.read(list)
        parts[:pool].to_sym if kind == :pool_part && parts[:part] == "active"
      end

      def slot_var = part_name(:slot)

      # The chain the walk follows: for each slot, the slot spawned after it and the one
      # spawned before it, and the first and last of the chain.
      # Spelled here by the pool's name alone too, for the same reason as the three above.
      def next_list = Pool.next_list(@name)
      def prev_list = Pool.prev_list(@name)
      def head_var = Pool.head_var(@name)
      def tail_var = Pool.tail_var(@name)
      def self.next_list(name) = part_name(name, :next)
      def self.prev_list(name) = part_name(name, :prev)
      def self.retired_list(name) = part_name(name, :retired)
      def self.head_var(name) = part_name(name, :head)
      def self.tail_var(name) = part_name(name, :tail)

      # A THING REMOVED WHILE THE POOL IS BEING WALKED STAYS IN THE CHAIN until the walk is
      # over, and its slot is not free until then either. A walk is following the chain, and
      # if a removal closed the gap at once — or a spawn reused the slot — the walk could step
      # off the end early or onto a thing spawned during the walk. So a removal during a walk
      # only marks the thing dead and puts its slot here, and the outermost walk, as it ends,
      # takes each one out of the chain and frees its slot. +walking_var+ counts the walks of
      # this pool in progress, since one can run inside another.
      def retired_list = Pool.retired_list(@name)
      def walking_var = part_name(:walking)
      def unlink_var = part_name(:unlink)
      def unlink_before_var = part_name(:before)
      def unlink_after_var = part_name(:after)
      def release_index_var = part_name(:release)

      # The variables the chain's routines work in, for the build to set aside.
      def chain_scratch_vars = [slot_var, unlink_var, unlink_before_var, unlink_after_var, release_index_var]

      # What a variable of the pool holds at power-on: an empty chain has no first or last.
      def power_on_value(var) = [head_var, tail_var].include?(var) ? NONE : 0

      # Pose bookkeeping (allocated only for a pool whose instances face or animate): which
      # way each instance faces, where each is in its cycle, and the one counter that
      # decides when the whole pool steps.
      def facing_list = part_name(:facing)
      def frame_list = part_name(:frame)
      def tick_var = part_name(:tick)

      # Which of those two this pool actually keeps — so the boot fill gives every slot one
      # of each, the same way it does for a field.
      def pose_lists
        lists = []
        lists << facing_list if @art&.faces?
        lists << frame_list if @art&.animates?
        lists
      end

      # WHICH PICTURE THE THING WITH +rank+ OLDER THINGS BEFORE IT SHOWS, as a value node. A
      # pool given one picture always shows it; any other reads the picture copied for that
      # place in the order.
      def pose_node(rank) = posed? ? stacked_at(:pose, rank) : Build.int(0)

      # WHICH PICTURE THE THING IN ONE SLOT SHOWS, as a value node. A pool that faces reads
      # the slot's direction; one that animates reads its frame; one that does both composes
      # them — direction * frames-per-direction + frame, which is the order the pictures were
      # flattened in. +at+ gives the slot, called for a fresh node at each use.
      def pose_of_slot(at)
        facing = Build.list_get(facing_list, at.call) if @art.faces?
        frame = Build.list_get(frame_list, at.call) if @art.animates?
        return frame || facing unless facing && frame

        Build.binop(:+, Build.binop(:*, facing, Build.int(@art.per_dir)), frame)
      end

      # STOP EVERY INSTANCE OF THIS POOL FROM MOVING THROUGH +background+'s SOLID TILES —
      # the same verb a `sprite` takes, said once for the whole pool.
      #
      # It belongs to the pool rather than to an instance because an instance handle lives
      # only for the `each` iteration that yielded it, where the background is the same one
      # every time round. After this, an instance's `move` is checked and `can_move?` answers
      # — which is the whole point of the pool being able to have it at all: a game with many
      # movers is exactly the case that wants tile collision and exactly the case that used
      # to be unable to afford it.
      def blocked_by(background)
        @solid_cells = background.solid_lookup
        self
      end

      # The background's grid of solid cells, or nil if this pool was never blocked by one.
      attr_reader :solid_cells

      # The builder this pool was declared on — an instance reaches it to place the shared
      # tile-collision routine's call.
      attr_reader :builder

      # Which row of the pictures a direction name means, for Instance#face.
      def facing_row(direction) = @art&.dirs&.[](direction)
      def facing_names = @art&.dirs&.keys || []

      # Point one instance at a direction (its row among the pictures): a number, or a value node
      # the game works out.
      def set_facing(index, row)
        record(Build.list_set(facing_list, index.node, row.is_a?(Integer) ? Build.int(row) : row))
        self
      end

      # Which other list of colours each instance is drawn with (see Instance#draw_with), kept
      # only by a pool that was ever told to draw with one.
      def colors_list = part_name(:colors)

      # The sprites the pool's things are drawn as, back to front, for a pool whose instances
      # draw (see #stacked_list for which thing each one shows).
      def stacked_objects = @stacked_objects ||= []

      # Draw the instance at slot +index+ with other colours — the same verb a sprite has, and
      # the same rules (see HardwareSprite#draw_with). Each instance keeps its own choice.
      def draw_with(index, which, showing)
        @recolors ||= begin
          unless spriteful?
            raise ArgumentError,
                  "pool :#{@name} was told to draw_with other colors, but its instances draw nothing. " \
                  "Give the pool pictures with image:, facing: or frames:."
          end
          @builder.make_pool_recolorable(self)
          recolors = Recolors.new(@builder, subject: "pool :#{@name}", poses: @art.poses)
          stacked_objects.each { |node| recolors.attach_object(node) }
          recolors
        end
        choice = FieldRef.new(builder: @builder, list: colors_list, index: index.node, pool: @name, field: :colors)
        @recolors.draw_with(choice, which, showing)
        self
      end

      # A pool never told to draw with other colours takes back the writes every spawn made
      # just in case, so it emits nothing for colours at all. Called once the whole program is
      # built, when that is known.
      def drop_unused_color_resets
        return if @recolors

        color_resets.each { |node| node.parent&.children&.delete(node) }
      end

      # Whether any instance was ever told to draw with other colours, so the pool keeps a
      # colours column (see #colors_list).
      def recolorable? = !@recolors.nil?

      # ONE FIELD OF THE POOL, every slot's, as a thing a save_data record can keep on its
      # own: `keep guards.field(:hp)` keeps how hurt each guard is and nothing else about it.
      # A field the pool does not have is a friendly error.
      Column = Data.define(:pool, :field) do
        def inspect = "field :#{field} of pool :#{pool.name}"
      end

      def field(name)
        return Column.new(pool: self, field: name) if field?(name)

        raise ArgumentError, "pool :#{@name} has no field :#{name}. It has " \
                             "#{field_names.map { |one| ":#{one}" }.join(', ')}. To fix this, use one of those."
      end

      # EVERYTHING THAT MAKES THIS POOL WHAT IT IS, for a save_data record to keep the whole of
      # it: the lists — every field, which slots are live, the free slots, and each slot's
      # facing, place in its cycle and colours where the pool keeps them, and the chain that
      # says what order they came in, with the removals a walk has not yet taken out of it —
      # and then the variables — how many are live, the first and last of the chain, and the
      # step counter of one that animates. Asked once the program is built, since a pool keeps
      # its colours column only once something has told it to draw with others. What slot a
      # walk is on is not here: a save keeps what the pool holds, not where a walk stands.
      def saved_lists_and_vars
        lists = [*field_names.map { |one| field_list(one) }, active_list, free_list, *pose_lists,
                 next_list, prev_list, retired_list]
        lists << colors_list if recolorable?
        vars = [count_var, head_var, tail_var]
        vars << tick_var if @art&.animates?
        [lists, vars]
      end

      def inspect = "pool :#{@name}"

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

        record(release_when_idle)
        recycle_oldest? ? spawn_recycling(values) : spawn_dropping(values)
        self
      end

      # Run the block once per LIVE instance, oldest first, handing it a row handle whose
      # fields are mutable (`b.x.add!`, `b.y.set!`, read `b.x`) and which can retire itself
      # (`b.remove`).
      #
      # The walk follows the chain from its first thing and stops after the thing that was last
      # when it began, so a thing spawned during the walk is first visited by the next one. It
      # looks one step ahead before running the block, and nothing the block does can change
      # that step: a removal during a walk leaves the chain alone until the walk is over (see
      # #retired_list). A thing removed before its turn is still in the chain, dead, and is
      # passed over.
      #
      # `newest_first: true` walks the same chain from its other end, following each thing's
      # link back to the one added before it, for a game where the last thing added has to act
      # first. Everything above holds the same way round: the walk stops at the thing that was
      # first when it began, and a thing spawned during it is added after where it started, so
      # it is first visited by the next walk.
      def each(newest_first: false, &block)
        refuse_unknown_walk_order!(newest_first)
        pool = self
        active = List.new(@builder, active_list)
        at, ahead, last = walk_vars
        start, finish, links = newest_first ? [tail_var, head_var, prev_list] : [head_var, tail_var, next_list]
        record(Build.add(walking_var, Build.int(1)))
        preserving_current_slot do
          record(Build.set(ahead, Build.var_ref(start)))
          record(Build.set(last, Build.var_ref(finish)))
          finished = Value.new(@builder, Build.var_ref(ahead)) == NONE
          @builder.repeat(@capacity, stop_when: finished) do
            record(Build.set(at, Build.var_ref(ahead)))
            step = Build.if_(Build.binop(:==, Build.var_ref(at), Build.var_ref(last)), Build.set(ahead, Build.int(NONE)))
            step.else = Build.else_(Build.set(ahead, Build.list_get(links, Build.var_ref(at))))
            record(step)
            slot = Value.new(@builder, Build.var_ref(at), name: at)
            # The walk can pass a thing removed before its turn, so the body is only for a live
            # one.
            (active[slot] == 1).then do
              record_current_slot(slot)
              block.call(Instance.new(pool, slot))
            end
          end
        end
        record(Build.sub(walking_var, Build.int(1)))
        record(release_when_idle)
        self
      end

      def refuse_unknown_walk_order!(newest_first)
        return if [true, false].include?(newest_first)

        raise ArgumentError,
              "`each` on pool :#{@name} was given newest_first: #{newest_first.inspect}. It needs true or false. " \
              "With true, the walk " \
              "starts at the thing added last. With false, or with nothing said, it starts at the thing added first."
      end
      private :refuse_unknown_walk_order!

      # A ROUTINE THAT WORKS ON ONE INSTANCE — the body of `each` moved into a routine of its
      # own, which is where a game of any size puts it:
      #
      #   guards.func(:chase) { |g| g.x.approach! hero.x, 1 }
      #   guards.each { |g| call g.state }
      #
      # A routine is built ONCE, wherever it is called from, so it cannot close over the
      # instance the way the block above does — which is why a plain `func` has no way to say
      # which guard is chasing. This pool hands the routine the instance being walked right
      # now, and the walk itself is what says which that is (see #record_current_slot).
      #
      # Called from anywhere else, such a routine would run on whichever instance was walked
      # last, so it is refused at build time instead (Builder#verify_instance_routines!).
      def func(name, &block)
        raise ArgumentError, "`pool :#{@name}` needs a block to make a routine out of." unless block

        @builder.declare_instance_routine(self, name, &block)
        self
      end

      # The routines this pool declared for one instance at a time, in declaration order.
      def instance_routines = @instance_routines ||= []

      # One instance of this pool, as a routine of its own sees it: the one the walk is on.
      #
      # This is built for every such routine before its body runs, and a routine with nothing
      # to say about its instance never reads it. So its slot is a number handed over rather
      # than one worked out: left unused, it is not the game's to be blamed for.
      def current_instance = Instance.new(self, Value.handed_to_block(@builder, Build.var_ref(current_var)))

      # How many instances are live right now, as a {Value}.
      def count = Value.new(@builder, Build.var_ref(count_var))

      # Whether the pool is full (no free slot), as a {Condition} — branch with `.then`.
      # That is whether a free slot is left, rather than how many are live: during a walk a
      # thing removed is no longer counted but its slot is not free until the walk ends, and
      # `full?` says what a spawn will find.
      def full? = Condition.new(@builder, Build.binop(:==, Build.list_len(free_list), Build.int(0)))

      # Retire the instance at slot +index+ (a {Value}): it leaves the order and stops being
      # drawn and updated. Called by {Instance#remove}; safe to call mid-`each`, on any
      # instance of the pool. Outside a walk its slot is free at once; during one it is freed
      # as the walk ends (see #retired_list). A slot that is not live is left alone, so a thing
      # removed twice — a slot number kept after a walk, say — is not freed twice.
      #
      # The work is one routine of the pool's, called from every place a thing is removed,
      # since closing the gap in the chain is a dozen statements a game would otherwise carry
      # once per `remove` it writes.
      def remove_at(index)
        record(Build.set(unlink_var, index.node))
        @builder.call(removal_routine)
        self
      end

      # THE CHAIN IS KEPT BY FOUR ROUTINES OF THE POOL'S, each declared the first time it is
      # needed and called from every place that needs it: removing a thing, putting a spawn at
      # the end, taking a slot out of the middle, and freeing what a walk removed. Each is a
      # handful of statements a game would otherwise carry once per `spawn` and `remove` it
      # writes. They pass the slot they work on in slot_var or unlink_var.

      # Remove the thing whose slot is in unlink_var.
      def removal_routine
        pool_routine(:remove) do
          free_now = Build.if_(not_walking,
                               Build.call(unlink_routine), Build.list_push(free_list, Build.var_ref(unlink_var)))
          free_now.else = Build.else_(Build.list_push(retired_list, Build.var_ref(unlink_var)))
          live = Build.binop(:==, Build.list_get(active_list, Build.var_ref(unlink_var)), Build.int(1))
          [Build.if_(live,
                     Build.list_set(active_list, Build.var_ref(unlink_var), Build.int(0)),
                     Build.sub(count_var, Build.int(1)),
                     free_now)]
        end
      end

      # Take everything removed during the walks just ended out of the chain, and free its
      # slot, last removed first.
      def release_routine
        pool_routine(:release_removed) do
          index = release_index_var
          [Build.repeat(Build.list_len(retired_list), index,
                        Build.set(unlink_var, Build.list_get(retired_list,
                                                             Build.binop(:-, Build.list_len(retired_list), Build.int(1)))),
                        Build.list_drop(retired_list, from: :back),
                        Build.call(unlink_routine),
                        Build.list_push(free_list, Build.var_ref(unlink_var)))]
        end
      end

      # Put the slot in slot_var at the end of the chain: after the last thing, or as the
      # first and last of an empty one.
      def append_routine
        pool_routine(:append) do
          slot = -> { Build.var_ref(slot_var) }
          tail = -> { Build.var_ref(tail_var) }
          join = Build.if_(Build.binop(:==, tail.call, Build.int(NONE)), Build.set(head_var, slot.call))
          join.else = Build.else_(Build.list_set(next_list, tail.call, slot.call))
          [Build.list_set(next_list, slot.call, Build.int(NONE)),
           Build.list_set(prev_list, slot.call, tail.call),
           join,
           Build.set(tail_var, slot.call)]
        end
      end

      # Take the slot in unlink_var out of the chain, joining the things either side of it.
      # The slot's own links are left as they were.
      def unlink_routine
        pool_routine(:unlink) do
          # Each neighbour is read once into a variable: a read of a list is several
          # instructions, and this would otherwise make eight of them.
          before_var = unlink_before_var
          after_var = unlink_after_var
          before = -> { Build.var_ref(before_var) }
          after = -> { Build.var_ref(after_var) }
          front = Build.if_(Build.binop(:==, before.call, Build.int(NONE)), Build.set(head_var, after.call))
          front.else = Build.else_(Build.list_set(next_list, before.call, after.call))
          back = Build.if_(Build.binop(:==, after.call, Build.int(NONE)), Build.set(tail_var, before.call))
          back.else = Build.else_(Build.list_set(prev_list, after.call, before.call))
          [Build.set(before_var, Build.list_get(prev_list, Build.var_ref(unlink_var))),
           Build.set(after_var, Build.list_get(next_list, Build.var_ref(unlink_var))),
           front, back]
        end
      end

      # A test that holds while no walk of this pool is in progress.
      def not_walking = Build.binop(:==, Build.var_ref(walking_var), Build.int(0))

      # A statement that frees what earlier walks removed, when no walk is in progress and
      # something is waiting. A walk says it as it ends. A spawn says it too, because a save
      # made during a walk keeps things that walk had not yet let go of, and a game that loads
      # it and spawns before any walk ends would otherwise find those slots still taken.
      def release_when_idle
        waiting = Build.binop(:>, Build.list_len(retired_list), Build.int(0))
        Build.if_(Build.binop(:and, not_walking, waiting), Build.call(release_routine))
      end

      # The name of the pool's routine for +job+, declared with the statements the block
      # gives the first time it is asked for.
      def pool_routine(job)
        @pool_routines ||= {}
        @pool_routines[job] ||= begin
          name = part_name(job)
          nodes = yield
          builder = @builder
          builder.func(name) { nodes.each { |node| builder.record_statement(node) } }
          name
        end
      end
      private :removal_routine, :release_routine, :append_routine, :unlink_routine, :pool_routine, :not_walking, :release_when_idle

      # A mutable handle to +field+ of the instance at slot +index+ (a {Value}).
      def field_ref(field, index)
        field_ref_at_node(field, index.node)
      end

      # One field of one slot, with everything it needs to read, write and complain clearly.
      def field_ref_at_node(field, index_node)
        FieldRef.new(builder: @builder, list: field_list(field), index: index_node,
                     pool: @name, field: field, fraction_bits: field_bits(field),
                     names: @field_names[field])
      end

      # What a field keeps, without building a handle to ask it (see FieldRef.scale).
      def field_scale(field)
        FieldRef.scale(pool: @name, field: field, bits: field_bits(field), names: @field_names[field])
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
        body = claim_free_slot(slot) + [Build.call(append_routine)] + assign_fields(slot, values) + pose_reset_nodes(slot)
        record(Build.if_(free_available, *body))
      end

      # The :recycle_oldest policy: take a free slot when there is one, otherwise reuse the
      # longest-lived instance's slot — so a new spawn always appears. The oldest is the
      # first in the chain, so finding it is one read. Either way the slot then joins the end
      # of the chain, as the newest.
      #
      # The one place it cannot take the oldest is a walk of this same pool: the walk is
      # following the chain, and moving its first thing to the end would cut the walk short, or
      # carry a newest-first walk past the thing it stops at. There, a full pool drops the spawn, as a `:drop` pool always does.
      def spawn_recycling(values)
        slot = Build.var_ref(slot_var)
        take_oldest = Build.if_(not_walking,
                                Build.set(slot_var, Build.var_ref(head_var)),
                                Build.set(unlink_var, Build.var_ref(head_var)),
                                Build.call(unlink_routine))
        choose = Build.if_(free_available, *claim_free_slot(slot))
        choose.else = Build.else_(Build.set(slot_var, Build.int(NONE)), take_oldest)
        record(choose)
        body = [Build.call(append_routine)] + assign_fields(slot, values) + pose_reset_nodes(slot)
        record(Build.if_(Build.binop(:!=, Build.var_ref(slot_var), Build.int(NONE)), *body))
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
      #
      # It starts in its own colours too. Whether the pool is ever recoloured is not known yet —
      # the spawn is usually written before the walk that recolours — so a pool whose instances
      # draw always writes it here, and #drop_unused_color_resets takes it out again if nothing needed it.
      def pose_reset_nodes(slot)
        nodes = []
        nodes << Build.list_set(facing_list, slot, Build.int(0)) if @art&.faces?
        nodes << Build.list_set(frame_list, slot, Build.int(0)) if @art&.animates?
        if spriteful?
          reset = Build.list_set(colors_list, slot, Build.int(Build::NO_RECOLOR))
          color_resets << reset
          nodes << reset
        end
        nodes
      end

      def color_resets = @color_resets ||= []

      # The list_set nodes that write each field of the instance at +slot+ (omitted fields
      # take their declared default).
      def assign_fields(slot, values)
        @fields.map do |field, default|
          given = values.fetch(field, default)
          # Checked against what the field holds, so spawning with a fraction into a whole
          # field — or the other way round — is the same friendly error as writing one later.
          node = field_scale(field).node_matching(given, "hold")
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

      # Three variables of one walk's own — the slot it is on, the one it goes to next, and
      # the last it will visit — so a walk inside another walk of this pool keeps its place.
      def walk_vars
        @walks = @walks.to_i + 1
        %i[at ahead last].map { |part| part_name("walk#{@walks}_#{part}") }
      end

      # WHICH INSTANCE A ROUTINE OF THIS POOL IS RUNNING FOR, written at the top of every live
      # pass of a walk. A routine is built once and called from wherever, so the one thing it
      # cannot be handed in its own code is which instance — this variable is how the walk tells
      # it, and `current_instance` is how the routine reads it.
      #
      # It costs a store per live instance per pass, and only a pool with such a routine pays it:
      # the write is recorded here and taken out again at the end of the build when nothing
      # wanted it (Builder#finalize_pool_walks).
      def record_current_slot(index)
        node = Build.set(current_var, index.node)
        record(node)
        @builder.record_walk_instance_writes(self, node)
      end

      # ...and a walk PUTS IT BACK as it leaves, because the walks nest. Two walks over one pool
      # — a pairwise test, or a routine that walks the pool it was called from — would otherwise
      # leave the outer one running on whatever instance the inner one finished at, for the rest
      # of that pass. A save and a restore per walk, not per instance, settles it whichever way
      # the nesting came about, including through a call this cannot see.
      def preserving_current_slot
        held = @builder.pool_walk_scratch_var
        saved = Build.set(held, Build.var_ref(current_var))
        record(saved)
        yield
        restored = Build.set(current_var, Build.var_ref(held))
        record(restored)
        @builder.record_walk_instance_writes(self, saved, restored)
      end

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

        # The build this pool belongs to, which {Bounds} asks for the screen.
        def collision_builder = @pool.builder

        # Draw this instance with another list of colours, or one of several picked by a
        # number, or its own again — what a sprite's `draw_with` does, for one instance.
        def draw_with(which, showing: nil)
          @pool.draw_with(@index, which, showing)
          self
        end

        # Retire this instance: free its slot, stop it next frame.
        def remove
          @pool.remove_at(@index)
        end

        # Turn this instance to face a direction — the same verb, spelled the same way, that
        # a `sprite` given `facing:` takes. Each instance holds its own direction, so ten
        # guards in one pool can face ten ways.
        #
        # `g.face [:a, :b], showing: g.step` picks one by a number the game works out, per
        # instance (see HardwareSprite#face).
        def face(direction, showing: nil)
          unless showing.nil?
            @pool.builder.write_picked_pose(direction, showing, subject: "pool :#{@pool.name}",
                                                                row_of: @pool.method(:facing_row)) do |row|
              @pool.set_facing(@index, row)
            end
            return self
          end
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
        def left = field(:x) + hitbox_part(0)
        def top = field(:y) + hitbox_part(1)
        def right = field(:x) + hitbox_part(0) + hitbox_part(2)
        def bottom = field(:y) + hitbox_part(1) + hitbox_part(3)

        # Move this instance, stopping at the scenery's solid tiles if the pool was told
        # `blocked_by` — the per-instance counterpart to {HardwareSprite#move}, spelled the
        # same way. Each axis is checked on its own, so an instance slides along a wall it is
        # pressed against instead of sticking to it.
        #
        #   guards.each { |g| g.move :left, by: 1 }
        #
        # A pool with `facing:` pictures turns the instance to face the way it moved, so one
        # line leaves ten guards leaning ten ways.
        def move(direction_or_dx, dy = nil, by: 1)
          if direction_or_dx.is_a?(Symbol)
            step_x, step_y = Direction.unit(direction_or_dx)
            step(:x, step_x * by) unless step_x.zero?
            step(:y, step_y * by) unless step_y.zero?
            face(direction_or_dx) if @pool.facing_row(direction_or_dx)
          else
            step(:x, direction_or_dx) if direction_or_dx != 0
            step(:y, dy) if dy && dy != 0
          end
          self
        end

        # Whether this instance could step +by+ pixels in +direction+ without meeting a solid
        # tile — a {Condition} to branch on, for taking it into your own hands. Needs the pool
        # to have been told `blocked_by`.
        def can_move?(direction, by: 1)
          cells = @pool.solid_cells or raise ArgumentError,
                                            "pool :#{@pool.name} was not told `blocked_by` a background, so an " \
                                            "instance has no solid tiles to test against."

          step_x, step_y = Direction.unit(direction)
          emit_tile_check(cells, field(:x) + (step_x * by), field(:y) + (step_y * by))
        end

        # Keep this instance fully on the screen, using the sprite's own size — the
        # per-instance counterpart to {Sprite#clamp_to_screen}. Clamps its x/y in place.
        def clamp_to_screen
          hit_x, hit_y, hit_w, hit_h = require_box!
          width, height = collision_builder.console.screen_size
          field(:x).clamp!(-hit_x, width - hit_x - hit_w)
          field(:y).clamp!(-hit_y, height - hit_y - hit_h)
          self
        end

        private

        # Move one axis: a plain nudge when nothing blocks this pool, else only if the
        # instance's box at the destination is clear of the scenery's solid tiles.
        def step(axis, delta)
          var = field(axis)
          cells = @pool.solid_cells
          return var.add!(delta) if cells.nil?

          target_x = axis == :x ? field(:x) + delta : field(:x)
          target_y = axis == :y ? field(:y) + delta : field(:y)
          emit_tile_check(cells, target_x, target_y).then { var.add!(delta) }
        end

        # The same shared routine a `sprite` calls — see Builder::Collision. A pool of
        # thirty-two instances and a hand-declared sprite of the same size consult one copy
        # of it between them.
        def emit_tile_check(cells, target_x, target_y)
          hit_x, hit_y, hit_w, hit_h = require_box!
          builder = @pool.builder
          routine = builder.tile_collision_routine(cells, hit_x, hit_y, hit_w, hit_h)
          builder.set!(routine[:x], Value.node_for(target_x))
          builder.set!(routine[:y], Value.node_for(target_y))
          builder.call(routine[:name])
          Value.new(builder, IR::Build.var_ref(routine[:clear]), name: routine[:clear]) == 1
        end

        def field(name) = @pool.field_ref(name, @index)

        def hitbox_part(component) = require_box![component]

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
end
