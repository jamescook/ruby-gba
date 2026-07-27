# frozen_string_literal: true

module RubyGBA
  module IR
    # Readable constructors for IR nodes. Each helper names a known kind and
    # fixes its operand names, so callers build trees tersely and typo-safely
    # without learning Node's attr conventions. The DSL layer (and the tests)
    # build through these.
    #
    #   include RubyGBA::IR::Build   # or call as Build.set(...)
    #
    #   program(
    #     screen(:bitmap),
    #     set(:x, 100),
    #     loop_(
    #       wait_vblank,
    #       if_(binop(:>, var_ref(:x), int(200)), set(:x, 0)),
    #       add(:x, 1),
    #     ),
    #   )
    #
    # Note the trailing underscores: +if_+, +loop_+, +case_+ — +if+/+loop+/+case+
    # are Ruby keywords, so the helpers can't reuse those bare names.
    module Build
      module_function

      # --- program root ---

      def program(*statements)
        Node.new(:program, children: statements)
      end

      # --- variable operations ---
      # An operand may be a bare Integer/Symbol (coerced to a value node by
      # #wrap) or an already-built value node.

      def set(var, value)
        Node.new(:set, var: var, value: wrap(value))
      end

      def add(var, operand)
        Node.new(:add, var: var, operand: wrap(operand))
      end

      def sub(var, operand)
        Node.new(:sub, var: var, operand: wrap(operand))
      end

      def copy(dest, src)
        Node.new(:copy, dest: dest, src: src)
      end

      def negate(var)
        Node.new(:negate, var: var)
      end

      # Absolute value: var = |var| (negates it only when it's negative).
      def abs(var)
        Node.new(:abs, var: var)
      end

      # Force negative: var = -|var| (negates it only when it's positive). Handy
      # for pinning a direction, e.g. making a velocity point one specific way.
      def negate_abs(var)
        Node.new(:negate_abs, var: var)
      end

      def clamp(var, min, max)
        Node.new(:clamp, var: var, min: min, max: max)
      end

      # --- drawing / screen operations ---

      # Pick a screen mode. +buffered+ opts a bitmap mode into double
      # buffering — drawing goes to a hidden page and is shown all at once, so the
      # picture can never tear no matter how much is drawn. It's off by default and
      # only meaningful for a bitmap mode; the flag rides on the node so a backend
      # (and the cost estimator) can tell the two apart. Absent when off, so an
      # ordinary screen node is unchanged.
      def screen(mode, buffered: false)
        attrs = { mode: mode }
        attrs[:buffered] = true if buffered
        Node.new(:screen, **attrs)
      end

      def pixel(x, y, color)
        Node.new(:pixel, x: wrap(x), y: wrap(y), color: color)
      end

      def fill_rect(x, y, w, h, color)
        Node.new(:fill_rect, x: x, y: y, w: w, h: h, color: color)
      end

      def clear_screen(color)
        Node.new(:clear_screen, color: color)
      end

      # Write a line of text at a fixed top-left origin, drawn with a named font
      # (+font+, a key in the Fonts registry). +x+/+y+ are compile-time constants.
      def draw_text(text, x, y, color, font: :default)
        Node.new(:draw_text, text: text, x: x, y: y, color: color, font: font)
      end

      # Draw the single decimal digit of +value+ (a run-time 0..9) at the fixed
      # origin +x+/+y+ in +color+, in the named +font+ — one glyph chosen at run
      # time. It exists as its own node so drawing a live digit stays one intent in
      # the tree (a backend may render it however it likes — a lookup and one blit,
      # or a fan-out).
      def draw_digit(value, x, y, color, font: :default)
        Node.new(:draw_digit, value: value, x: x, y: y, color: color, font: font)
      end

      # Fill a rectangle whose *position* is decided at run time: +x+/+y+ may be
      # variables (or constants), while the size +w+/+h+ is a compile-time
      # constant. This is the moving-object draw — paddles, a ball — as opposed to
      # +fill_rect+, whose position is fixed when the program is built.
      def draw_rect_at(x, y, w, h, color)
        Node.new(:draw_rect_at, x: wrap(x), y: wrap(y), w: w, h: h, color: color)
      end

      # Fill a rectangle at a fixed position and size — same picture as
      # +fill_rect+, but a backend is free to blast it in with a block transfer.
      # Everything (+x+/+y+/+w+/+h+) is a compile-time constant.
      def dma_fill_rect(x, y, w, h, color)
        Node.new(:dma_fill_rect, x: x, y: y, w: w, h: h, color: color)
      end

      # --- audio ---
      #
      # +define_sound+ and +song+ are definitions: they name a sound effect or a
      # tune without making noise on their own, and a later +beep+ / +play_song+
      # refers to that name — the same name-resolution +func+/+call+ use. +beep+
      # and +play_song+ are the ops that actually sound.

      # Power on the audio hardware. Nothing is audible until this runs.
      def enable_sound
        Node.new(:enable_sound)
      end

      # Name a reusable sound effect: a tone at +frequency+ Hz with a wave shape
      # (+duty+), fade speed (+decay+), and starting +volume+ (0–15). A later
      # +beep(name)+ plays it.
      def define_sound(name, frequency:, duty: :half, decay: :fast, volume: 15)
        Node.new(:define_sound, name: name, frequency: frequency,
                                duty: duty, decay: decay, volume: volume)
      end

      # Play a short sound effect now. +tone+ is either a defined-sound name or a
      # raw frequency in Hz. The keyword overrides default to the named sound's
      # values (or to the built-in defaults for a raw frequency) when left nil.
      def beep(tone, duty: nil, decay: nil, volume: nil)
        Node.new(:beep, tone: tone, duty: duty, decay: decay, volume: volume)
      end

      # Define a named tune. +events+ is the resolved score — a list of
      # [frame_offset, frequency_hz] pairs, a rest being frequency 0 — and
      # +total_frames+ is its length, so the tune loops by wrapping there. The
      # frame timing is worked out once when the song is written, so every backend
      # replays the same score. +duty+/+volume+ shape every note.
      def song(name, events:, total_frames:, duty: :half, volume: 12)
        Node.new(:song, name: name, events: events, total_frames: total_frames,
                        duty: duty, volume: volume)
      end

      # Advance the named tune by one frame — call once per frame in the loop.
      def play_song(name)
        Node.new(:play_song, name: name)
      end

      # Silence the music.
      def stop_music
        Node.new(:stop_music)
      end

      # --- control flow ---  (bodies are nested statements)

      def if_(cond, *body)
        Node.new(:if, children: body, cond: cond)
      end

      # The else-branch of an `if`: its statements run when the condition is
      # false. Held in the if node's :else attr, not built standalone.
      def else_(*body)
        Node.new(:else, children: body)
      end

      def loop_(*body)
        Node.new(:loop, children: body)
      end

      # A counted loop: run +body+ +count+ times, with +index+ (a variable name)
      # counting 0..count-1 at run time. The runtime counterpart to Ruby's
      # build-time N.times — where N.times unrolls the loop and its counter is a
      # plain Integer, this emits one loop whose count and counter live on the
      # console. +count+ is a value operand.
      def repeat(count, index, *body)
        Node.new(:repeat, children: body, count: wrap(count), index: index)
      end

      # A repeating timer: run +body+ once every +period+ frames. +counter+ names
      # the hidden frame counter (cleared once at boot) that a backend ticks each
      # frame and resets when it reaches the period. The whole point of it being a
      # node — not the counter+compare it lowers to — is that the tree still says
      # "every N frames", so the cost model and rom.explain read the intent.
      def every(counter, period, *body)
        Node.new(:every, children: body, counter: counter, period: period)
      end

      # A one-shot timer: run +body+ exactly once, +frames+ frames in, then never
      # again. +counter+ names the hidden frame counter (cleared at boot) that
      # counts up only until it lands on the target. Like +every+, kept as a node so
      # the tree still says "after N frames".
      def after(counter, frames, *body)
        Node.new(:after, children: body, counter: counter, frames: frames)
      end

      def func(name, *body)
        Node.new(:func, children: body, name: name)
      end

      def call(name)
        Node.new(:call, target: name)
      end

      # Multi-way dispatch on a variable: run the scene/func whose value matches.
      # A scene is just a func, so the targets are func names. +clauses+ maps each
      # value to a target name, e.g. case_(:state, 0 => :title, 1 => :playing).
      def case_(var, clauses)
        Node.new(:case, var: var, clauses: clauses.to_a)
      end

      def wait_vblank
        Node.new(:wait_vblank)
      end

      def halt
        Node.new(:halt)
      end

      # A raw escape hatch: pre-assembled target bytes a native backend appends
      # verbatim. Not portable — the interpreter refuses it, so a program using it
      # runs only on hardware. Reaching for this is a sign the IR has a gap: the
      # aim is that a developer never needs it, so grow a real node the backends
      # can lower and model rather than settling here.
      def raw(bytes)
        Node.new(:raw, bytes: bytes)
      end

      # --- embedded data ---

      # Embed a named blob of bytes in the ROM. Format-agnostic (a bitmap, a
      # song's score, ...): +bytes+ is a binary String. A definition — it emits
      # nothing on its own; a consumer reads it by name.
      def data(name, bytes)
        Node.new(:data, name: name, bytes: bytes)
      end

      # Read one byte (0..255) of a named blob at a fixed index — a value, so it
      # can drive an operand or a coordinate.
      def data_byte(name, index)
        Node.new(:data_byte, name: name, index: index)
      end

      # An embedded bitmap: +pixels+ is a binary String of width*height 15-bit
      # BGR555 colors (little-endian halfwords). Like +data+, but it carries the
      # shape a draw op needs. +transparent+, when set, is the pixel value that
      # means "don't draw" (so the background shows through); nil means opaque. A
      # definition — a later blit references it by name.
      def bitmap(name, width:, height:, pixels:, transparent: nil)
        Node.new(:bitmap, name: name, width: width, height: height,
                          pixels: pixels, transparent: transparent)
      end

      # Draw a defined bitmap with its top-left at (x, y). x/y may be constants or
      # variables (a moving object). A part pushed off a screen edge is clipped, not
      # wrapped.
      def blit(name, x, y)
        Node.new(:blit, name: name, x: wrap(x), y: wrap(y))
      end

      # Draw one of a set of same-size images, chosen by a run-time index — a sprite
      # showing the pose that matches which way it faces, or a frame of an animation.
      # +poses+ is a list of defined image names; +index+ selects one (0-based) at
      # run time. Like a run-time-selected blit: costs one draw, not the whole set.
      def blit_pose(poses, index, x, y)
        Node.new(:blit_pose, poses: poses, index: wrap(index), x: wrap(x), y: wrap(y))
      end

      # A tiled background: a whole grid drawn from a small set of reusable tiles.
      # +tiles+ is an ordered list of defined image names (the distinct tiles);
      # +map+ is the grid — an array of rows, each an array of indices into +tiles+
      # (or nil for an empty cell). +tile_w+/+tile_h+ are the tile size in pixels.
      # This says *what* the background is, not how a machine draws it: one backend
      # stamps the tiles pixel by pixel, another can hand the grid to tile hardware,
      # but the picture is the same.
      def background(name, tiles:, map:, tile_w:, tile_h:)
        Node.new(:background, name: name, tiles: tiles, map: map, tile_w: tile_w, tile_h: tile_h)
      end

      # --- display objects (a moving picture the display composites over the scene) ---
      #
      # An object is an image the display draws on top of the background every frame,
      # at a position that can change as the game runs — a hero, an enemy, a coin. It
      # composites over whatever's behind it (its see-through pixels let the scene
      # show) and leaves no trail, because the display redraws the whole picture each
      # frame rather than smearing pixels into a buffer. This says *what* the object
      # is; a backend realizes it however its target does (one composites in software,
      # another hands it to sprite hardware).

      # Declare an object: the picture +image+, shown at the position held in the +x+
      # and +y+ variables, drawn while +active+ is 1 (0 = hidden). x/y/active are
      # value operands (variables the game steers). Reserves the object; #present_objects
      # is what actually draws the declared objects for a frame.
      def object(name, image:, x:, y:, active:)
        Node.new(:object, name: name, image: image, x: wrap(x), y: wrap(y), active: wrap(active))
      end

      # Draw the named objects for this frame, on top of the background, in order
      # (later ones sit in front). Emitted once per frame at the moment it's safe to
      # change the screen — right after a vblank — so a moving object is redrawn each
      # frame from its current position with no trail. +names+ lists the objects to
      # present (each declared by #object).
      def present_objects(names)
        Node.new(:present_objects, names: names)
      end

      # --- backing store (remembering the pixels under a moving object) ---
      #
      # A named off-screen buffer big enough to hold a width×height patch of the
      # screen. It's how a moving object leaves no trail: before it's drawn, save
      # the pixels it's about to cover; when it moves away, paint them back. A
      # definition — it reserves the buffer but draws nothing on its own.
      def backing_buffer(name, width:, height:)
        Node.new(:backing_buffer, name: name, width: width, height: height)
      end

      # Copy the buffer-sized patch of the screen at (x, y) INTO the named backing
      # buffer — remember what's there before something is drawn over it. x/y may be
      # constants or variables; a part off a screen edge is skipped (nothing to
      # remember out there).
      def save_region(buffer, x, y)
        Node.new(:save_region, buffer: buffer, x: wrap(x), y: wrap(y))
      end

      # Paint a saved patch back onto the screen at (x, y) — restore what a moving
      # object had covered, so it leaves no trace. Pairs with {save_region}; restore
      # at the same spot it was saved. A part off a screen edge is clipped.
      def restore_region(buffer, x, y)
        Node.new(:restore_region, buffer: buffer, x: wrap(x), y: wrap(y))
      end

      # --- lists (a bounded, ordered collection) ---
      #
      # A named collection whose length changes as the program runs — a snake's
      # body, a queue of shots. Push onto it, drop from either end, index into it,
      # ask its length. `capacity` is the most it can ever hold; it's rounded up to
      # a power of two (see #round_up_capacity) so a backend can wrap an index with
      # a cheap mask, and every backend enforces that same rounded ceiling so they
      # agree on when it overflows.

      # Create a named list that can hold up to `capacity` items. The stored
      # capacity is the rounded value.
      def list_new(name, capacity)
        unless capacity.is_a?(Integer) && capacity.positive?
          raise ArgumentError,
                "a list's capacity must be a positive whole number, got #{capacity.inspect}"
        end
        Node.new(:list_new, name: name, capacity: round_up_capacity(capacity))
      end

      # Append a value at the end of the list (grows its length by one).
      def list_push(name, value)
        Node.new(:list_push, name: name, value: wrap(value))
      end

      # Remove one item from an end of the list: `from: :front` (a shift, dropping
      # the oldest) or `from: :back` (a pop, dropping the newest).
      def list_drop(name, from:)
        unless %i[front back].include?(from)
          raise ArgumentError, "a list drop is from: :front or :back, got #{from.inspect}"
        end
        Node.new(:list_drop, name: name, from: from)
      end

      # Overwrite the item at `index` with a new value (the slot must already hold
      # one). `index` is a value operand.
      def list_set(name, index, value)
        Node.new(:list_set, name: name, index: wrap(index), value: wrap(value))
      end

      # Read the item at `index` — a value, so it can drive an operand or a
      # coordinate. `index` is itself a value operand.
      def list_get(name, index)
        Node.new(:list_get, name: name, index: wrap(index))
      end

      # How many items the list holds right now — a value.
      def list_len(name)
        Node.new(:list_len, name: name)
      end

      # --- expression values (the AST an assignment or condition is built from) ---

      def int(number)
        Node.new(:int, value: number)
      end

      def var_ref(name)
        Node.new(:var_ref, name: name)
      end

      def binop(op, lhs, rhs)
        Node.new(:binop, op: op, lhs: wrap(lhs), rhs: wrap(rhs))
      end

      # Arithmetic negation of a value operand: -operand. This is the value-node
      # form (it produces a new value inside an expression), as opposed to the
      # `negate` statement, which flips a stored variable in place.
      def neg(operand)
        Node.new(:neg, operand: wrap(operand))
      end

      # --- input reads (value operands, e.g. inside an `if_` condition) ---

      # 1 while +button+ is down, else 0.
      def held(button)
        Node.new(:held, button: button)
      end

      # 1 only on the frame +button+ first goes down (a fresh press), else 0.
      def pressed(button)
        Node.new(:pressed, button: button)
      end

      # The scanline the display is drawing right now (0..227) — a hardware-only
      # value used to measure how far into a frame the drawing has got. There is no
      # such thing off-console (the headless interpreter has no real timing and
      # refuses it), so this only appears in debug/probe programs run on hardware.
      def read_scanline
        Node.new(:read_scanline)
      end

      # 1 +percent+% of the time, else 0 — a probability test as a value operand,
      # true when the random draw in +draw+ (a 0..99 value) lands below +percent+.
      # A value node in its own right (like +held+/+pressed+) so a reader — the cost
      # model, a diagnostic — can see it's a chance, not a bare comparison.
      def chance(draw, percent)
        Node.new(:chance, draw: draw, percent: percent)
      end

      # Coerce a bare operand into a value node so every operand is uniform: an
      # Integer becomes an +int+ literal, a Symbol becomes a +var_ref+, and a Node
      # passes through untouched. Anything else can't be a value here, so say so
      # plainly rather than letting a stray object slip into the tree and fail
      # cryptically later. (The DSL handle, Value, is unwrapped one layer up — the
      # IR core doesn't know about it — so it never reaches here.)
      def wrap(operand)
        case operand
        when Node then operand
        when Integer then int(operand)
        when Symbol then var_ref(operand)
        else
          raise ArgumentError,
                "can't use #{operand.inspect} as a value — expected a number, a " \
                "variable name (a Symbol), or a value expression"
        end
      end

      # Round a list's capacity up to the next power of two (4 stays 4, 5 becomes
      # 8, 100 becomes 128). A power-of-two size lets a backend wrap an index with
      # a single bitwise mask instead of a division, and fixing the rule here — not
      # in any one backend — is what keeps every backend enforcing the *same*
      # ceiling, so they agree on exactly when a list is full.
      def round_up_capacity(requested)
        return 1 if requested <= 1

        1 << (requested - 1).bit_length
      end
    end
  end
end
