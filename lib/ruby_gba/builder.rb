# frozen_string_literal: true

# DSL verbs grouped into concern modules, each mixed into Builder below. They keep
# the flat DSL surface (every verb a top-level method) while letting each area live
# in its own file. New concerns get required here and included in the class body.
require_relative "builder/randomness"
require_relative "builder/sound"
require_relative "builder/music"
require_relative "builder/text"
require_relative "builder/images"
require_relative "builder/sprites"
require_relative "builder/sprite_import"
require_relative "builder/input"
require_relative "builder/drawing"
require_relative "builder/variables"
require_relative "builder/control_flow"
require_relative "builder/scenes"
require_relative "builder/collision"
require_relative "builder/tiled"
require_relative "builder/composition"
require_relative "builder/timers"
require_relative "builder/sampled_audio"
require_relative "builder/layers"

module RubyGBA
  # DSL context for building a GBA ROM.
  #
  # Each DSL method builds a node in an IR tree — an in-memory description of what
  # the program does — and returns. {RubyGBA.build} lowers the finished tree to a
  # ROM once the block ends. Building the whole tree before lowering any of it is
  # what lets a {#call} refer to a {#func} defined later in the block.
  #
  # @example Minimal ROM
  #   rom = RubyGBA.build("MYGAME", code: "BMGE", maker: "01") do
  #     entry { loop_forever }
  #   end
  #
  # @example Draw pixels
  #   rom = RubyGBA.build("PIXELS", code: "BPXL", maker: "01") do
  #     screen :bitmap
  #     pixel 120, 80, :red
  #     pixel 121, 80, color("#00FF00")
  #     fill_rect 50, 50, 30, 20, rgb(31, 31, 0)
  #     halt
  #   end
  class Builder
    include Constants

    include Randomness # seed, randomize, roll, rand, chance
    include Sound      # enable_sound, define_sound, beep
    include Music      # song, play_song, stop_music
    include Text       # draw_text, draw_number
    include Images     # image, blit, rgb, rgb8, color
    include Sprites    # sprite (software + hardware, facing/frames/clip animation, hitboxes)
    include SpriteImport # sprite art adapters (sheets, Aseprite) feeding the sprite builder
    include Input      # if_held, if_pressed, held, pressed
    include Drawing    # screen, pixel, fill_rect, clear_screen, dma_fill_rect, draw_rect_at
    include Variables  # set/var, add, sub, negate/flip, copy, abs, negate_abs, clamp, var_address, variables
    include ControlFlow # game_loop, wait_vblank, repeat, every, after, halt, debug_halt, if_eq..if_le
    include Scenes     # func, call, scene, case_var, dump_func
    include Collision  # box (overlaps? lives on the shape — Box/Sprite via Bounds)
    include Tiled      # tiles, background (tiled-graphics surface; hardware lowering to follow)
    include Composition # pool (a component + a pool of instances, per-instance update)
    include Timers     # timer (a hardware counter running at a chosen rate)
    include SampledAudio # sample (a recorded PCM sound, played via Direct Sound)
    include Layers     # layers, layer (a named place in the stack: what sits in front of what)

    # Shorthand for the IR node constructors, so DSL methods can build tree
    # nodes as terse Build.set(...) calls.
    Build = IR::Build

    # @param frame_sync [Symbol] :auto (the framework paces each game_loop) or
    #   :manual (the developer places `wait_vblank` themselves)
    # @param progress [RubyGBA::Progress] what a build says it is doing (see {#progress})
    def initialize(frame_sync: :auto, progress: Progress.silent)
      unless %i[auto manual].include?(frame_sync)
        raise ArgumentError, "frame_sync must be :auto or :manual, got #{frame_sync.inspect}"
      end

      @frame_sync = frame_sync
      @progress = progress
      @has_paced_loop = false  # set once a game_loop is pacing the program
      @dropped_syncs = 0       # `wait_vblank` calls the game loop already covers
      @variables = {}          # name → { address:, initial: } — introspection metadata
      @fraction_vars = {}      # name → fraction bits, for variables that hold a fraction (see Fraction)
      @next_var_addr = IWRAM_START
      @functions = {}          # name → deferred body block (evaluated at emit time)
      @func_fast = {}          # name → where the author insisted the routine live (func fast:)
      @dump_requests = []      # function names to disassemble from the lowered ROM
      @songs = {}              # name → Music::SongContext (for build-time validation)
      @sound_enabled = false
      @debug_halted = false
      @repeat_seq = 0          # counts repeat loops, to name each one's hidden index var
      @timer_seq = 0           # counts every/after timers, to name each one's hidden counter var
      @rng_seq = 0             # counts anonymous random draws, to name each one's hidden var
      @approach_seq = 0        # counts approach calls, to name each one's hidden delta var
      @number_seq = 0          # counts draw_number calls, to name each one's hidden digit vars
      @sprite_seq = 0          # counts sprites, to name each one's hidden position/backing vars
      @images = {}             # image name → [width, height], so a sprite can size itself from its art
      @image_bounds = {}       # image name → [x, y, w, h] box around its visible (non-transparent) pixels, for collision
      @tilesets = {}           # tileset name → { chars:, by_number:, tile_w:, tile_h:, solid_images: } — a tile-image map addressable by character or by number (a CSV cell)
      @screen_mode = nil       # the current display mode (set by `screen`), so `sprite` picks its backend
      @sprites = []            # live software sprites, repainted after every wait_vblank
      @hw_sprites = []         # live hardware sprites, drawn (into the sprite table) after every wait_vblank
      @pool_objects = []       # a spriteful pool's per-slot sprite object names, drawn among the game sprites
      @hud_objects = []        # tiled-mode text/number glyph sprites, drawn on top after every wait_vblank
      @glyph_images = {}       # [font, char, color] → a cached glyph image name (one 8x8 sprite tile per glyph)
      @verb_owns_text = nil    # the verb drawing its own text right now (a menu's rows), rather than the author placing it
      @animations = []         # flipbook sprites, whose pose is advanced on a beat after every wait_vblank
      @pool_animations = []    # ...and posed pools, which step every instance on their own beat
      @prng_used = false       # whether the program draws random numbers (seeds the stream once)
      @boot_inits = []         # statements hoisted to program start (hidden state that must start known)
      @pending_conditions = [] # Conditions built but not yet used; leftovers are orphans
      @present_nodes = []      # every frame's present-objects node, filled with the full object list at finalize
      @frame_boundaries = []   # each frame's wait node, the anchor the scroll writes are inserted after at finalize
      @scrolled_backgrounds = {} # name → [x var, y var] for every background the game scrolls
      @inline_scroll_nodes = []  # scroll nodes recorded at their call site, dropped once a frame boundary exists
      @bg_affine_vars = {}       # name → [angle var, scale var] for every screen :rotozoom background ever turned/resized
      @affine_backgrounds = {}   # name → [angle var, scale var], the affine counterpart to @scrolled_backgrounds
      @inline_affine_nodes = []  # affine_background nodes recorded at their call site, moved to the frame boundary
      @per_frame_routines = []   # func names `once_a_frame` declared, called at every frame boundary
      @each_frame_seq = 0        # counts once_a_frame bodies, to name each one's hidden routine
      @scene_gates = {}        # scene func name → [state_var, value] it's dispatched on (from case_var), for gating its presentation
      @current_scene_gate = nil # while a scene func's body is being built: the [state_var, value] its declarations belong to
      @building_scene = nil    # the scene func name currently being built (lets its presentation be declared inside it)
      @layer_stack = []        # the layers the program declared, back to front (see Builder::Layers)
      @layers_node = nil       # ...and the node holding them, so a `layer` block can mark one see-through
      @current_layer = nil     # while a `layer` block runs: the layer its declarations belong to
      @routine_layer = {}      # routine name → [layer, what the author wrote] when it was declared inside one
      @deferred_layer = nil    # while such a routine's body is built: that pair, so a declaration in it can be refused

      # The program the DSL builds: an IR tree of nodes that {RubyGBA.build}
      # lowers to a ROM. Each statement attaches to the container on top of the
      # stack — the program root, or an open control-flow block (a loop, an if, a
      # func body) while its block runs.
      @program = Build.program
      @container_stack = [@program]
      @shown_while = []        # the conditions open right here, for a declaration that is only presented under them

      # Persisted variables (from `save_var`), in declaration order — each is
      # { name:, default:, slot: }, the slot being its place in save memory. Drives
      # the one boot-time save_init and the auto-save after each change.
      @persisted = []
    end

    # The IR tree built so far (the whole program). Lets tests assert the DSL
    # constructs the right tree without lowering it to a ROM.
    attr_reader :program

    # WHAT THIS BUILD SAYS IT IS DOING, for whoever is doing real work while it runs.
    #
    #   progress.step "reading the six episodes"
    #   floors.each_with_index { |floor, n| progress.of n + 1, floors.length, floor.name; ... }
    #
    # A build is already a run of named phases saying how far each has got (see
    # {RubyGBA::Progress}). Anything a game or an effect pack does while the block runs
    # happens INSIDE one of those phases, and without this it happens namelessly — the
    # build stands there saying "reading the game" for a minute with no clue which minute
    # of it belongs to whom. This is the seam: a pack's verbs are mixed into this class,
    # and a game's block is evaluated on it, so `progress` resolves here for both, with no
    # plumbing to pass round. A game split across plain Ruby objects hands it on like any
    # other dependency.
    #
    # IT IS A NOUN, NOT A VERB, and that distinction is deliberate. `blit` and `sprite` are
    # things a GAME does and belong on the teaching-facing verb surface; progress is a thing
    # the BUILD has, and the surface a person learns should not grow a build-time member.
    #
    # THE DEFAULT SAYS NOTHING, so nobody has to ask whether anybody is listening, and
    # nothing reported here may change what gets built: this is an observation. A pack that
    # behaved differently when somebody was watching would be a bug that only shows up in
    # the mode nobody tests.
    attr_reader :progress

    # Function names queued by dump_func, disassembled from the lowered ROM.
    attr_reader :dump_requests

    # --- Lists ---

    # Declare a named list — a bounded, ordered collection whose length changes as
    # the game runs (a snake's body, a queue of shots). Returns a {List} handle you
    # push onto, drop from, index into, and iterate.
    #
    #   body = list :body, capacity: 256
    #   body.push head_cell
    #   body.shift unless growing
    #
    # `capacity` is the most it can ever hold; it's rounded up to a power of two so
    # the hardware can wrap an index cheaply, and every backend enforces that same
    # ceiling, so a program overflows at the same point everywhere.
    #
    # `estimate:` tells the COST ESTIMATE something it cannot work out for itself. It
    # changes nothing about how the game runs — it is not part of the program, and no
    # backend reads it — which is why it is nested rather than sitting beside `capacity:`.
    #
    # Today it takes one thing, `usually:`: how many items the list normally holds. A walk
    # over a list can only be bounded by the capacity, and that is the only number a build
    # can prove — a snake's body list is sized for every cell of the board and holds four
    # cells for most of a game. So the guardrail that warns when a growing list stops fitting
    # in a frame counts a walk at what you say it usually holds, and at the full capacity for
    # the worst it could reach.
    #
    #   body  = list :body,  capacity: 256, estimate: { usually: 12 }
    #   shots = list :shots, capacity: 32,  estimate: { usually: 3..6 }
    #
    # A RANGE says a length that moves, and the estimate counts its TOP — the dearest of
    # the frames that usually happen. That is also why a range cannot talk the estimate
    # down: a wider one always reads dearer, never cheaper.
    #
    # `holds:` says what KIND of number the list keeps, by showing one. Write a Float and
    # the list holds numbers with a fraction, exactly as writing one makes a variable hold
    # them: `list :speeds, capacity: 8, holds: 0.0`. Every value read out then carries the
    # scale and every value put in is checked against it, so a game with many of something
    # that moves in halves and quarters never has to pick a scale and carry it by hand. The
    # number itself is only an example — a list still starts empty.
    #
    # `width:` says HOW BIG ONE SLOT IS, and it is the difference between a list that fits in
    # the console's fast memory and one that does not. A slot is a whole 32-bit number unless
    # you say otherwise, and most lists do not hold anything like that much: `:byte` holds
    # -128..127 and `:half` holds -32768..32767, at a quarter and a half of the memory. A list
    # of flags, of directions, of which-picture-is-showing, of hit points, of countdowns —
    # every one of those is a byte, and a game with many of them gets that memory back for
    # other things.
    #
    #   list :hurt, capacity: 64, width: :byte   # 64 bytes, not 256
    #
    # A NARROW SLOT ALWAYS GOES BELOW NOTHING, and there is nothing to say about that — it is
    # not a choice you are given, because there is no way to make it correctly. The case that
    # decides it is a countdown: `wait.sub 7` followed by `(wait <= 0)` really does hold -4
    # while that test runs, and a slot that could not go below nothing would read -4 back as
    # 252 and the test would never fire — a game that quietly stops working. Nothing at build
    # time can see that coming, since the value is worked out as the game runs. So a `:byte`
    # holds -128..127, and a number that has to reach past 127 asks for `:half`.
    #
    # A number too big for its slot keeps the low bits that fit, exactly as the console does,
    # and both backends drop the same bits — 200 in a `:byte` reads back as -56 on each.
    # Reading and writing a narrow slot costs the same as a wide one; only the memory differs.
    #
    # @param name [Symbol] the list's name
    # @param capacity [Integer] the most items it can hold
    # @param estimate [Hash] what the estimate cannot know — today `usually:` (Integer or Range)
    # @param holds [Numeric] an example of what it holds; a Float means it holds fractions
    # @param width [Symbol] how big one slot is — :byte, :half or :word (the default)
    # @return [List] a handle to the list
    def list(name, capacity:, estimate: nil, holds: nil, width: :word)
      record(Build.list_new(name, capacity, usually: usual_length(estimate, capacity),
                                            width: width))
      List.new(self, name, fraction_bits: list_fraction_bits(name, holds))
    end

    # What `holds:` said, as a number of fraction bits. A whole number says the same as
    # saying nothing, so it is allowed and means what it looks like.
    def list_fraction_bits(name, holds)
      return nil if holds.nil?
      unless holds.is_a?(Numeric)
        raise ArgumentError,
              "`holds:` takes an example of what the list holds, like `holds: 0.0` for " \
              "numbers with a fraction. `list :#{name}` was given #{holds.inspect}."
      end

      Fraction.bits_of(holds)
    end

    # What the `estimate:` hint says this list usually holds, as the one number a walk is
    # counted at. A range gives its top; a number is already that; nothing said is nil, and
    # then the estimate guesses and says so.
    #
    # A KEY IT DOES NOT KNOW IS AN ERROR rather than a shrug. A hint that quietly does
    # nothing is worse than no hint at all: the report goes on calling the number a guess
    # while the author believes they answered it.
    # `most:` is only meaningful where nothing in the program bounds the thing — a `repeat`
    # counted by a value the game works out. Everywhere else the capacity or the count is the
    # ceiling and saying it again would be a second answer to a settled question.
    ESTIMATE_HINTS = %i[usually most].freeze

    def usual_length(estimate, capacity)
      return nil if estimate.nil?

      unless estimate.is_a?(Hash)
        raise ArgumentError, "`estimate:` takes a hint in braces. Write `estimate: { usually: 12 }`."
      end

      unknown = estimate.keys - ESTIMATE_HINTS
      unless unknown.empty?
        raise ArgumentError, "The hint `#{unknown.first}:` is not known. " \
                             "`estimate:` knows these hints: #{ESTIMATE_HINTS.join(', ')}."
      end

      usual_top(estimate[:usually], capacity)
    end

    # The top of a range, or the number itself.
    #
    # A range wider than half the capacity is refused. Not because it is dangerous —
    # counting the top means a vague range can only read dearer — but because it is not an
    # answer: `0..255` of 256 says "somewhere between empty and full", which is what the
    # estimate had to assume anyway, dressed up as a fact the author checked.
    def usual_top(usually, capacity)
      return usually unless usually.is_a?(Range)

      top = usually.max
      if top.nil?
        raise ArgumentError, "`usually: #{usually}` contains no lengths. " \
                             "Give a range that goes up, like 3..6."
      end

      # A ceiling the game works out has no number to measure a range against, so only its
      # direction can be checked.
      if usually.min.negative? || (capacity && (top - usually.min) * 2 > capacity)
        raise ArgumentError, "`usually: #{usually}` covers more than half of the capacity " \
                             "#{capacity}. A range that wide does not give a usual length. " \
                             "Give a narrower range, or one number."
      end

      top
    end

    # Ship a build-time array as a read-only ROM table, read at run time by a Value
    # index. The array is plain Ruby, evaluated as the program is built, so work the
    # console can't do cheaply every frame — sine, division — is precomputed once and
    # then just looked up:
    #
    #   sin = table :sin, (0...256).map { |a| (Math.sin(a * Math::PI / 128) * 256).round }, width: :half
    #   y.set sin[angle]   # y = sin[angle], a plain lookup
    #
    # `width` is the element size: :byte (8-bit), :half (16-bit), or :word (32-bit).
    # `signed` is inferred from the values (any negative makes it signed) unless you
    # set it. An out-of-range index is made safe by the read — a power-of-two table
    # wraps it (what an angle wants), any other size clamps it — so a lookup never
    # reads past the table.
    #
    # @param name [Symbol] the table's name
    # @param values [Array<Integer>] the whole numbers to store, computed at build time
    # @param width [Symbol] :byte, :half, or :word
    # @param signed [Boolean, nil] force signedness; nil infers it from the values
    # @return [Table] a handle to index with []
    def table(name, values, width: :half, signed: nil)
      values = validate_table_values!(name, values)
      bits = table_fraction_bits(values)
      # A table of numbers with a fraction is stored multiplied up, and a whole cell of
      # it no longer fits in a half — so it takes a word unless the program says
      # otherwise. Reads from it carry the fraction, so nothing downstream repeats it.
      width = :word if bits && width == :half
      values = values.map { |v| bits ? Fraction.scale(v, bits) : v }
      signed = values.any?(&:negative?) if signed.nil?
      check_table_values_fit!(name, values, width, signed)
      record(Build.table(name, values, width: width, signed: signed))
      Table.new(self, name, values.length, fraction_bits: bits)
    end

    # Define an entry point of raw ARM instructions — the escape hatch for
    # patterns the DSL can't express. The block runs in an {EntryContext} that
    # collects the emitted bytes into a raw IR node, which the backend appends to
    # the code verbatim.
    def entry(&block)
      ctx = EntryContext.new
      ctx.instance_eval(&block)
      record(Build.raw(ctx.bytes))
    end

    # --- Finalize (RubyGBA.build calls this once, after the DSL block) ---

    # Build the IR node for every deferred function body, then check that every
    # call and case target names a function that exists. Called automatically by
    # RubyGBA.build after the DSL block.
    def emit_pending_functions
      @scene_gates = scan_scene_gates # which state value each scene is shown for (from case_var)

      # The program's default display mode — whatever the top-level `screen` left set.
      # Each scene starts from this, so one scene's `screen` (a tiled game) can't leak
      # into the next (a bitmap title): a scene is bitmap or tiled by what IT declares,
      # or the default, never by which scene happened to be built before it. That's what
      # lets `sprite`/`draw_text`/`draw_number` pick software vs hardware per scene.
      default_screen_mode = @screen_mode

      # Drain rather than iterate: building one body can declare another routine — a
      # verb reached from inside a scene may declare a `once_a_frame` of its own — and
      # walking the hash directly would either miss it or raise for growing mid-loop.
      # Emitting until nothing new is pending covers however deep that goes.
      emitted = {}
      until (pending = @functions.reject { |name, _| emitted.key?(name) }).empty?
        pending.each do |name, block|
          emitted[name] = true
          # A scene's declarations belong to it: while its body is built, remember the
          # scene (so its HUD/sprites may be declared here) and the state gate that
          # scopes what it presents to when the scene is active.
          @building_scene = name if @scene_gates.key?(name)
          @current_scene_gate = @scene_gates[name]
          # ...and if this routine was WRITTEN inside a `layer` block, remember which, so
          # anything it declares that wants a depth can be refused rather than quietly
          # getting none (see Layers#refuse_deferred_layer!).
          @deferred_layer = @routine_layer[name]
          @screen_mode = default_screen_mode
          push_container(Build.func(name, fast: @func_fast[name])) do
            run_block(&block)
          end
        ensure
          @building_scene = nil
          @current_scene_gate = nil
          @deferred_layer = nil
        end
      end

      finalize_present_lists
      finalize_background_scrolls
      finalize_background_affine
      finalize_layer_blend
      finalize_per_frame_routines
      verify_targets_defined!
      verify_stack_fits!
      initialize_rng_stream
      register_save_init
      emit_boot_inits
    end

    # How many `wait_vblank` calls the game loop already covered. Read by
    # RubyGBA.build so Checks::DroppedFrameSync can report them.
    attr_reader :dropped_syncs

    # The software sprites, in the order they were declared — which on a bitmap
    # screen is the order they are painted in. Read by RubyGBA.build so
    # Checks::StackNotHonored can compare that order against the declared stack; a
    # software sprite's layer lives on the handle rather than in the tree, so a check
    # walking the tree alone cannot see it.
    attr_reader :sprites

    # Remember that +name+ is scrolled, so its position is written once a frame in
    # the gap between frames rather than wherever the game happened to compute it.
    # +node+ is the write recorded at the call site, which finalize drops once it
    # knows there is a frame boundary to move it to. A {Background} calls this.
    def scroll_each_frame(name, x_var, y_var, node)
      @scrolled_backgrounds[name] = [x_var, y_var]
      @inline_scroll_nodes << node
    end

    # The affine counterpart to {#scroll_each_frame}: remember that +name+ turns or
    # resizes, so its matrix is written once a frame in the gap between frames rather
    # than wherever the game happened to change its angle or size. Called once, as soon
    # as a background is made affine (see Builder::Tiled#make_background_affine) — not
    # only from `rotate`/`scale` themselves — so the matrix stays live even for a
    # program that reaches into the angle/scale {Value}s directly (`bg.scale.approach`)
    # rather than through those two verbs.
    #
    # Also captures the CURRENT scene gate (whatever scene this first `rotate`/`scale`/
    # `angle` call happens inside, if any — see #scene_gate), so a background declared
    # and turned only inside one scene writes its matrix only while that scene is
    # active. Without this, the write would land at every frame boundary in the whole
    # program regardless of which scene is running — and BG2's affine registers are
    # never inert the way a plain scroll's are: `screen :bitmap`'s Mode 3/4 framebuffer
    # is itself rendered through these same registers, so an untouched write from an
    # affine title screen would keep distorting a bitmap gameplay scene that never asked
    # for it.
    def affine_each_frame(name, angle_var, scale_var)
      @affine_backgrounds[name] = [angle_var, scale_var, @current_scene_gate]
    end

    # An affine_background write recorded at its call site (by {Background#rotate} /
    # {Background#scale}) — kept so {#finalize_background_affine} can drop it once it
    # knows there's a frame boundary to move the write to instead, the same as
    # {#scroll_each_frame}'s inline scroll nodes.
    def record_inline_affine_node(node)
      @inline_affine_nodes << node
    end

    # Remember this frame boundary, so the per-frame scroll writes can be inserted
    # just after it at finalize. Which backgrounds scroll isn't known yet — one may
    # be scrolled further down the loop body, or inside a scene built later — so the
    # spot is marked now and filled at the end.
    #
    # The wait itself is the anchor, not a position: other statements around it come
    # and go before finalize is done (a program with no sprites has its present-
    # objects statement removed), and an index recorded now would no longer point
    # where it was meant to.
    def mark_frame_boundary(wait_node)
      @frame_boundaries << wait_node
    end

    # --- Handle hooks ---
    # The Value / Condition / Branch / List classes call these back into the
    # builder to record their statements at the current build point.

    # The hook behind the expression DSL's `(cond).then { ... }`: record an `if`
    # node from an already-built condition node and gather the block's statements
    # into it, returning the node so an `.else` can attach to it. A {Condition}
    # calls this; user code writes `.then`, not this.
    #
    # The estimate hints (over/usually/of — see Build#if_) come in here rather than through
    # `.then`, because the one thing that sets them is a {Pool}'s walk over its slots, and
    # they would be noise on every conditional an author writes.
    def record_conditional(cond_node, over: nil, usually: nil, of: nil, runs: nil, per: nil, &block)
      if_node = Build.if_(cond_node, over: over, usually: usually, of: of, runs: runs, per: per)
      push_container(if_node) do
        run_block(&block)
      end
      if_node
    end

    # The hook a handle uses to append one of its own statement operations at the
    # current build point — a {List}'s push, a {Sprite} painting itself onto the screen
    # and taking itself off again — the counterpart to how a {Value}'s mutators record
    # through the builder's verbs.
    #
    # It skips the layer rules a flat DSL verb goes through, and that is the whole
    # difference between the two. A handle doing its own work is never a brushstroke
    # somebody wrote inside a `layer` block: a software sprite paints itself with the
    # same node an author's `blit` builds, and refusing the sprite for the sake of the
    # `blit` would refuse the very thing a layer is for.
    def record_statement(node)
      attach(node)
    end

    # Record a container node and run +block+ to fill its children — the hook a handle
    # reaches for to attach a body from outside the builder (e.g. Timer#on_tick). Lives
    # in the core, not a concern, so it isn't scanned as a DSL verb. Returns the node.
    def record_container(node, &block)
      push_container(node) { run_block(&block) }
      node
    end

    # A reusable hidden variable a handle can round-trip a read-modify-write through —
    # e.g. a {FieldRef} mutating a pool slot (load the slot, apply a Value mutator, store
    # it back). One is enough: such mutations are sequential statements, never nested.
    # An internal hook like #record_statement / #ensure_var, not a DSL verb.
    def field_scratch_var
      @field_scratch ||= begin
        name = :__field_scratch
        ensure_var(name)
        name
      end
    end

    # A {Condition} enters this "pending" set when it's built (Condition#initialize)
    # and leaves it when it's used (see #consume_condition). It's bookkeeping for
    # one guardrail only, never part of the program.
    def track_condition(condition)
      @pending_conditions << condition
    end

    # A {Condition} was used — branched on with `.then`, or folded into another via
    # `&` / `|` — so peel it back out of the pending set.
    def consume_condition(condition)
      @pending_conditions.delete(condition)
    end

    # The Conditions still pending at build's end: built but never used. Each did
    # nothing, which almost always means it was handed to a native `if` (a Condition
    # is truthy to Ruby, so the `if` body ran unconditionally and the comparison was
    # silently ignored). The orphaned-Condition guardrail reports these.
    def pending_conditions
      @pending_conditions
    end

    # The hook behind `.then { }.else { }`: gather the else block's statements
    # into an `else` node and attach it to the if node the `.then` produced.
    def record_else(if_node, &block)
      else_node = Build.else_
      @container_stack.push(else_node)
      # The other side of the same test: what is declared here is shown when the `if`'s
      # condition is FALSE. A copy of that condition, because a node belongs to one place
      # in the tree and this one already belongs to the `if`.
      @shown_while.push(Build.binop(:==, if_node.cond.copy, Build.int(0)))
      begin
        run_block(&block)
      ensure
        @shown_while.pop
        @container_stack.pop
      end
      if_node.else = else_node
    end

    private

    # --- Boot-time initialization ---

    # Register a statement to run once at program start, before anything else. It's
    # for hidden state that must begin from a known value because console RAM isn't
    # zero at power-on — the random seed, a timer's frame counter. #emit_boot_inits
    # hoists these to the very front at finalize, so they can be recorded from deep
    # inside a loop or scene yet still run once, up front.
    def at_boot(node)
      @boot_inits << node
    end

    # Hoist every registered boot statement to the front of the program, keeping
    # the order they were registered in, so all hidden state is set before the
    # game starts.
    def emit_boot_inits
      @boot_inits.reverse_each do |node|
        @program.children.unshift(node)
        node.parent = @program
      end
    end

    # A fixed marker written alongside the saved variables so a fresh cartridge
    # (whose save memory holds random power-on garbage) is told apart from one that
    # already holds real saved data. Any stable, unlikely value does; this spells
    # "SAV1" in bytes.
    SAVE_MAGIC = 0x53415631

    # If the program declared any `save_var`s, add the one boot step that loads them
    # (or writes their defaults on a fresh cartridge). Registered at boot like the
    # other hidden-state setup, so it runs once before the game starts.
    def register_save_init
      return if @persisted.empty?

      at_boot(Build.save_init(vars: @persisted, magic: SAVE_MAGIC))
    end

    # Record a mirror-to-save-memory right after a persisted variable changed, so
    # what's saved always matches what the game just did. A no-op for an ordinary
    # variable, so every mutation verb can call it without checking first.
    def mirror_save(name)
      entry = @persisted.find { |v| v[:name] == name }
      record(Build.save_store(name, entry[:slot])) if entry
    end

    # Whether +name+ is a persisted variable (declared with `save_var`).
    def persisted?(name)
      @persisted.any? { |v| v[:name] == name }
    end

    # Which scenes are shown for which state, read from the case_var dispatch(es):
    # a scene func named as a case target is presented only while the dispatched
    # variable holds that clause's value. Maps a scene func name → [state_var, value],
    # so a sprite/HUD declared inside that scene can be gated to when the scene is live.
    def scan_scene_gates
      gates = {}
      @program.walk do |node|
        next unless node.kind == :case

        node.clauses.each { |value, target| gates[target] ||= [node.var, value] }
      end
      gates
    end

    # Gate an object's visibility to its scene: a scene-owned object is shown only when
    # both its own shown-flag is set AND its scene is the active one. Rides the object's
    # existing per-frame `active` value, so presentation stays automatic — nothing new to
    # call, and no per-draw flag in game code. Outside a scene, visibility is unchanged.
    def scene_gate(active_node)
      return active_node unless @current_scene_gate

      state_var, value = @current_scene_gate
      Build.binop(:*, active_node, Build.binop(:==, Build.var_ref(state_var), Build.int(value)))
    end

    # Gate a declaration's visibility on the conditions it was WRITTEN under, so a
    # blinking prompt is the plain thing an author would write:
    #
    #   (blink == 1).then { draw_text "PRESS START", 76, 100, :gray }
    #
    # Text on a tiled screen is not painted where the call sits — it becomes little glyph
    # sprites the console composites every frame, from a list settled once at build time.
    # So the `.then` around the call would otherwise decide nothing at all: the glyphs are
    # declared inside it, and then shown on every frame regardless, which reads as a
    # prompt that never blinks. Carrying the condition onto the glyph itself is what makes
    # the two agree — it is shown exactly while the test holds, which is what the line says.
    #
    # A condition is 0 or 1, so several nested ones multiply together, the same way
    # #scene_gate folds in "and this scene is the live one". Each is copied because a node
    # belongs to one place in the tree, and these already belong to their `if`.
    def condition_gate(active_node)
      @shown_while.reduce(active_node) { |node, cond| Build.binop(:*, node, cond.copy) }
    end

    # Fill every frame's present-objects node with the complete object list once all
    # scenes are built — a scene declares its sprites/HUD inside its own body (built after
    # the game loop), so the list isn't known when wait_vblank records the node. A frame
    # that ends up with no objects drops the node, so an object-free program is unchanged.
    def finalize_present_lists
      names = in_stack_order(@hw_sprites.map(&:object_name) + @pool_objects + @hud_objects)
      @present_nodes.each do |node|
        if names.empty?
          node.parent&.children&.delete(node)
        else
          node.names = names
        end
      end
    end

    # The objects to draw, arranged the way the declared layers ask for. This is the
    # one place a frame's drawing order is settled: the list every backend is handed
    # already says what goes in front of what, so no backend works it out for itself
    # and two of them cannot come to different answers.
    #
    # The layer is read back off the objects in the tree rather than kept beside them
    # here, because the tree is where a backend will read it too — one fact, one place.
    def in_stack_order(names)
      layer_of = @program.walk.each_with_object({}) do |node, found|
        found[node.name] = node.layer if node.kind == :object
      end
      IR::Stacking.order(names, @layer_stack) { |name| layer_of[name] }
    end

    # Move every background's scroll write to the frame boundary.
    #
    # The display re-reads a background's scroll position for every line it draws, so
    # writing it while the picture is being drawn shifts only the lines below that
    # point and the screen tears in half. Writing it in the gap between frames
    # instead means a game can work out where its camera goes anywhere in the frame,
    # take as long as it likes, and never tear.
    #
    # The writes are placed here rather than where scroll was called because which
    # backgrounds scroll is only known now: a scene's body is built after the loop
    # that dispatches to it. Each boundary gets fresh nodes, so no node is shared
    # between two places in the tree.
    #
    # A program with no frame boundary (no game loop) keeps the writes where they
    # were called — nothing is pacing it, so there is no gap to move them to.
    def finalize_background_scrolls
      return if @scrolled_backgrounds.empty? || @frame_boundaries.empty?

      @inline_scroll_nodes.each { |node| node.parent&.children&.delete(node) }

      @frame_boundaries.each do |wait_node|
        container = wait_node.parent
        at = container&.children&.index(wait_node)
        next unless at

        @scrolled_backgrounds.reverse_each do |name, (x_var, y_var)|
          node = Build.scroll_background(name, x: Build.var_ref(x_var), y: Build.var_ref(y_var))
          container.children.insert(at + 1, node)
          node.parent = container
        end
      end
    end

    # Move every affine background's matrix write to the frame boundary — the same
    # reason {#finalize_background_scrolls} moves scroll writes there: the console reads
    # a background's rotate/scale registers for the whole frame it draws, so writing them
    # mid-frame would show two different pictures on one screen. See that method for the
    # rest of the reasoning; this is its `rotate`/`scale` sibling.
    #
    # Each write is gated to its owning scene's `active` condition (see #affine_each_frame),
    # the same as a scene-owned sprite or HUD glyph — a background turned only inside one
    # scene must stop writing BG2's registers once that scene isn't the live one.
    def finalize_background_affine
      return if @affine_backgrounds.empty? || @frame_boundaries.empty?

      @inline_affine_nodes.each { |node| node.parent&.children&.delete(node) }

      @frame_boundaries.each do |wait_node|
        container = wait_node.parent
        at = container&.children&.index(wait_node)
        next unless at

        @affine_backgrounds.reverse_each do |name, (angle_var, scale_var, gate)|
          active = gate ? Build.binop(:==, Build.var_ref(gate[0]), Build.int(gate[1])) : Build.int(1)
          node = Build.affine_background(name, angle: Build.var_ref(angle_var), scale: Build.var_ref(scale_var),
                                                active: active)
          container.children.insert(at + 1, node)
          node.parent = container
        end
      end
    end

    # Tell the display again how see-through the see-through layer is, once per frame.
    #
    # Only a picture whose amount the game works out needs this — fog that thickens,
    # water that gets murkier as you go down. A number the author wrote is written once
    # at boot and never again, and this puts nothing anywhere.
    #
    # It goes at the frame boundary for the reason the scroll writes do: that gap is the
    # one moment the display is not reading, so the whole picture is drawn at one amount
    # rather than half at each. And it goes FIRST, before the sprites are put where they
    # go, so the frame that is about to be drawn is drawn at the amount this frame has.
    def finalize_layer_blend
      return if @frame_boundaries.empty? || @layers_node.nil?
      return if Value.fixed_number(@layers_node.transparency) # a number needs telling once

      @frame_boundaries.each do |wait_node|
        container = wait_node.parent
        at = container&.children&.index(wait_node)
        next unless at

        node = Build.see_through(@layers_node.transparency.copy)
        container.children.insert(at + 1, node)
        node.parent = container
      end
    end

    # Run every per-frame routine at each frame boundary — ONCE PER FRAME THAT REALLY
    # PASSED, which on a program keeping up is once, and on one that overran its frame
    # is twice or three times.
    #
    # THAT REPEAT IS THE WHOLE OF THE PROMISE. A pass of the game loop is not a frame;
    # it is a frame on a program that fits and two frames on one that does not. So a
    # body called once per PASS and described as running every frame quietly runs at
    # half speed on a heavy game, and a fade told to take half a second takes a second
    # and a half. Counting the frames instead is what makes the word mean what it says.
    #
    # One loop around all of them rather than one each, so a late pass replays the frame
    # in order — every routine once, then every routine again — rather than running each
    # routine twice before starting the next.
    #
    # They go at the boundary for the same reason the scroll writes do: that is the
    # gap between frames, the one moment the display is not reading, so whatever they
    # change takes effect on the whole picture rather than half of it. And they go in
    # here rather than where `once_a_frame` was called because such a routine is
    # normally set off by an event — a brick breaking, a life lost — while what it
    # produces has to be applied on EVERY frame after that, including the frames the
    # triggering code does not run on.
    #
    # A program with no frame boundary (no game loop) never calls them at all. That
    # is a real footgun, so a verb built on this wants a guardrail for it — see
    # Effects::Packs::ScreenShake::NeedsGameLoop.
    def finalize_per_frame_routines
      return if @per_frame_routines.empty? || @frame_boundaries.empty?

      ensure_var(IR::Frames::STEP)
      @frame_boundaries.each_with_index do |wait_node, boundary|
        container = wait_node.parent
        at = container&.children&.index(wait_node)
        next unless at

        index = :"__once_a_frame_#{boundary}"
        ensure_var(index)
        calls = @per_frame_routines.map { |name| Build.call(name) }
        node = Build.repeat(Build.var_ref(IR::Frames::STEP), index, *calls)
        container.children.insert(at + 1, node)
        node.parent = container
      end
    end

    # Look up a variable's IWRAM address, raising if not declared.
    def var_address!(name)
      entry = @variables[name]
      raise ArgumentError, "The variable :#{name} is not defined. Use `set :#{name}, value` first." unless entry
      entry[:address]
    end

    # Allocate a variable on first mention, tracking its name and address for
    # introspection (var_address / variables). Only a Symbol names a variable, so
    # any other operand — a literal, an expression — is ignored: callers can pass a
    # value operand straight through without guarding, and a non-name never
    # allocates a phantom entry. (Operand types are already validated upstream at
    # the Value.node_for coercion boundary, so ensure_var needn't gate them.)
    def ensure_var(name)
      return unless name.is_a?(Symbol)
      return if @variables.key?(name)

      addr = @next_var_addr
      @next_var_addr += 4
      @variables[name] = { address: addr }
    end

    # --- Importing art from image files ---

    # This gem's own source directory. Frames of the call stack under here are
    # framework internals; the first frame outside it is the user's script — which
    # is where a relative image path should be resolved from (see #resolve_asset_path).
    SOURCE_ROOT = __dir__

    # Turn an image path the user wrote into a real file path. An absolute path is
    # taken as-is. A relative one is resolved *next to the script that named it* —
    # the natural expectation ("hero.png is beside my game") — falling back to the
    # working directory, and finally a plain-language error that names where it
    # looked. (Resolving against the current directory alone is a classic footgun:
    # it works when you run from the project root and mysteriously fails otherwise.)
    def resolve_asset_path(path)
      return path if File.absolute_path?(path)

      dir = caller_script_dir
      if dir
        beside_script = File.expand_path(path, dir)
        return beside_script if File.exist?(beside_script)
      end
      return path if File.exist?(path) # a working-directory-relative path that happens to resolve

      looked = [dir && File.expand_path(path, dir), File.expand_path(path)].compact.uniq
      raise ArgumentError,
            "Cannot find the image #{path.inspect}. Looked at #{looked.map(&:inspect).join(' and ')}. " \
            "Put the image next to your script, or pass a full path."
    end

    # The directory of the nearest caller that isn't framework code — i.e. the user's
    # script — so an asset path can be resolved relative to it. nil if the whole
    # stack is internal (nothing sensible to resolve against).
    def caller_script_dir
      frame = caller_locations.find do |loc|
        loc.absolute_path && !loc.absolute_path.start_with?(SOURCE_ROOT)
      end
      frame && File.dirname(frame.absolute_path)
    end

    # A sheet cell's pixel size: one number means a square cell, [w, h] a rectangle.
    def sheet_tile_size(name, tile)
      case tile
      when Integer then [tile, tile]
      when Array then tile
      when nil
        raise ArgumentError, "To import #{name} from an image, give tile:. tile: is the size of each cell in pixels."
      else
        raise ArgumentError, "tile: must be a number (square) or [width, height]. You gave #{tile.inspect}."
      end
    end

    # Where a cell sits in a sheet grid: [column, row], or a single number counting
    # cells left-to-right then top-to-bottom. +label+ names it in any error.
    def sheet_cell_at(label, where, cols)
      case where
      when Array then where
      when Integer then [where % cols, where / cols]
      else raise ArgumentError, "#{label} must be a cell number or [column, row]. You gave #{where.inspect}."
      end
    end

    # Element size in bytes for each table width.
    TABLE_WIDTHS = { byte: 1, half: 2, word: 4 }.freeze

    # A table's values must be a non-empty array of whole numbers.
    def validate_table_values!(name, values)
      unless values.is_a?(Array) && !values.empty?
        raise ArgumentError, "table #{name.inspect} needs a non-empty array of numbers."
      end
      unless values.all?(Numeric)
        raise ArgumentError,
              "table #{name.inspect} can hold numbers only. You gave #{values.find { |v| !v.is_a?(Numeric) }.inspect}."
      end
      values
    end

    # How many fraction bits a table's values carry: a table with a Float anywhere in
    # it holds numbers with a fraction, and every read from it hands back a value that
    # says so. This is what lets a sine table be written as plain trigonometry — the
    # scaling that used to be spelled out in the table's own definition is done here.
    def table_fraction_bits(values)
      Fraction::DEFAULT_BITS if values.any?(Float)
    end

    # Every value must fit the element width. A value that does not fit would be
    # cut down silently on the console, so stop the build and name the fix.
    def check_table_values_fit!(name, values, width, signed)
      bytes = TABLE_WIDTHS.fetch(width) do
        raise ArgumentError, "table #{name.inspect} width must be :byte, :half, or :word. You gave #{width.inspect}."
      end
      bits = bytes * 8
      low, high = signed ? [-(1 << (bits - 1)), (1 << (bits - 1)) - 1] : [0, (1 << bits) - 1]
      bad = values.find { |value| value < low || value > high }
      return unless bad

      kind = signed ? "signed" : "unsigned"
      raise ArgumentError,
            "table #{name.inspect} has the value #{bad}. It does not fit a #{kind} :#{width} element " \
            "(range #{low} to #{high}). Use a wider width, or make the values smaller."
    end

    # --- IR tree construction ---

    # Attach a freshly built IR node to the open container and return it — the route
    # every flat DSL verb takes, so it's also where an open `layer` block gets its say
    # about what was just written.
    def record(node)
      place_in_layer(node)
      attach(node)
    end

    # Put a node in the open container. Stamp it with the DSL call site that built it
    # (unless it already carries one), so a later guardrail finding can point the
    # author straight at the line.
    def attach(node)
      node.source ||= caller_source_location
      @container_stack.last.add_child(node)
      node
    end

    # The user's call site that led here — "hero.rb:42", the nearest caller that
    # isn't framework code — for diagnostics. nil if the whole stack is internal.
    def caller_source_location
      frame = caller_locations.find do |loc|
        loc.absolute_path && !loc.absolute_path.start_with?(SOURCE_ROOT)
      end
      frame && "#{File.basename(frame.absolute_path)}:#{frame.lineno}"
    end

    # Build a container node, attach it, and keep it open while the block runs so
    # nested statements land inside it — then close it. The block-taking control
    # methods (loops, conditionals, func bodies) use this.
    def push_container(node)
      record(node)
      @container_stack.push(node)
      # A test the block is written under is also a test anything DECLARED in the block is
      # only shown under (see #condition_gate) — the same statement reads both ways, and a
      # thing the framework redraws for you every frame has no other way to hear about it.
      @shown_while.push(node.cond) if node.kind == :if
      yield
    ensure
      @shown_while.pop if node.kind == :if
      @container_stack.pop
    end

    # Run a DSL block (a game loop body, a `.then`, a func body…) at the current build
    # point. It runs in the block's OWN context, not instance_eval'd onto the builder,
    # so its `self` stays wherever the block was written: this builder at the top level
    # (where these blocks live inside RubyGBA.build's instance_eval, so `self` already
    # is the builder), or a plain Ruby object when a game is split across files — there
    # the block still sees that object's @ivars, while its bare verbs resolve against the
    # build it was handed (see examples/shmup). +args+ pass through to a block that takes them (a loop
    # index). Sub-DSLs with their own vocabulary — `entry`, `case_var`, `font`, `song` —
    # keep instance_eval instead, since their blocks speak a different verb set.
    def run_block(*args, &block)
      block.call(*args)
    end

    # Low-level entry context for raw instruction emission.
    # Collects the raw ARM emitted inside an `entry` block into a byte string,
    # which becomes a raw IR node the backend appends verbatim.
    class EntryContext
      attr_reader :bytes

      def initialize
        @bytes = +"".b
      end

      def loop_forever
        @bytes << ASM.loop_forever
      end

      def nop
        @bytes << ASM.nop
      end
    end
  end
end
