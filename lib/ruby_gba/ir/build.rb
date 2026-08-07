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

      # Hold a variable inside a range. The bounds are value operands, so they may be
      # fixed as the program is written or worked out while it runs (a limit that
      # depends on the level, a speed the game changes).
      def clamp(var, min, max)
        Node.new(:clamp, var: var, min: wrap(min), max: wrap(max))
      end

      # --- persistence (variables that survive power-off) ---
      #
      # Some variables are kept in the cartridge's save memory so their value is
      # still there next time the console powers on — a high score, unlocks,
      # settings. The two ops that realize that are portable intent: what to
      # remember, not how a particular machine stores it.

      # Load the persisted variables at boot. +vars+ is an ordered list of
      # `{ name:, default:, slot: }` — the variable's name, the value to use on a
      # brand-new cartridge with nothing saved yet, and its slot (0-based) in the
      # save layout. +magic+ is a marker written alongside the data: when it's
      # already there the saved values are loaded, otherwise the defaults are
      # written (so a fresh cartridge starts clean instead of loading garbage).
      def save_init(vars:, magic:)
        Node.new(:save_init, vars: vars, magic: magic)
      end

      # Write one persisted variable's current value back to its save slot — done
      # right after it changes, so what's saved always matches what's on screen.
      def save_store(name, slot)
        Node.new(:save_store, var: name, slot: slot)
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

      # Fill a rectangle whose position AND size are decided at run time: +x+, +y+,
      # +w+ and +h+ may each be a variable or an expression (or a constant). This is
      # the moving, changing draw — a paddle, a ball, a meter — as opposed to
      # +fill_rect+, which is fixed when the program is built.
      #
      # A size the program works out is what a bar or a column needs: a health meter
      # that empties sideways, a wall column in a first-person view, a tower rising
      # out of the ground. A width or height of zero or less draws nothing.
      def draw_rect_at(x, y, w, h, color)
        Node.new(:draw_rect_at, x: wrap(x), y: wrap(y), w: wrap(w), h: wrap(h), color: color)
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

      # Play a percussion / explosion hit on the noise voice now. +preset+ names a
      # built-in noise sound (or is nil for a plain hit); the keyword overrides
      # default to the preset's values when left nil, resolved by a backend.
      def noise(preset = nil, pitch: nil, decay: nil, volume: nil, metallic: nil)
        Node.new(:noise, preset: preset, pitch: pitch, decay: decay,
                         volume: volume, metallic: metallic)
      end

      # Play a sustained tone on the wave voice with a given +shape+ (a wavetable
      # timbre) at +frequency+ Hz and a fixed +volume+ level. It holds until
      # replaced or stopped — the wave voice has no envelope.
      def wave(shape:, frequency:, volume:)
        Node.new(:wave, shape: shape, frequency: frequency, volume: volume)
      end

      # Silence the wave voice.
      def stop_wave
        Node.new(:stop_wave)
      end

      # Define a named tune. A song is one or more parts (voices) played together.
      # Each part is { events:, duty:, volume: } where +events+ is the resolved
      # score — a list of [frame_offset, frequency_hz] pairs, a rest being
      # frequency 0. +total_frames+ is the song's length, so it loops by wrapping
      # there; the frame timing is worked out once when the song is written, so
      # every backend replays the same score. The parts play in order on the
      # console's voices — which one is the backend's business, not the score's.
      #
      # For a one-part tune, pass +events:+ (plus optional +duty:+/+volume:+)
      # directly instead of a +voices:+ list — it's taken as the single part.
      def song(name, total_frames:, voices: nil, events: nil, duty: :half, volume: 12)
        voices ||= [{ events: events, duty: duty, volume: volume }]
        Node.new(:song, name: name, voices: voices, total_frames: total_frames)
      end

      # Advance the named tune by one frame — call once per frame in the loop.
      def play_song(name)
        Node.new(:play_song, name: name)
      end

      # Silence the music.
      def stop_music
        Node.new(:stop_music)
      end

      # --- sampled (PCM) audio ---
      #
      # A recorded sound, played back through the sampled-audio hardware rather than
      # synthesized on a PSG voice. `sample` is a definition — it names the raw sound
      # data (8-bit signed PCM) and the rate it was recorded at; +play_sample+ triggers
      # it, +stop_sample+ cuts it off.

      # Define a named PCM sample: +bytes+ is its 8-bit signed samples (a binary string),
      # +rate+ how many of them play per second (its recording rate in Hz). +note+ is the
      # musical pitch it was recorded at — the reference `play(pitch:)` shifts from.
      def sample(name, bytes, rate, note: :C4)
        Node.new(:sample, name: name, bytes: bytes, rate: rate, note: note)
      end

      # Play the named sample from the start. +loop+ true replays it seamlessly on a
      # loop (background music); false plays it once and stops (a one-shot sound).
      # +volume+ is a level name (:full, :half, …) — how loud this voice sits in the mix.
      # +pitch+ is a note name to play it at (shifted from the sample's own note); nil plays
      # it at its recorded pitch.
      def play_sample(name, loop: false, volume: :full, pitch: nil)
        Node.new(:play_sample, name: name, loop: loop, volume: volume, pitch: pitch)
      end

      # Stop a playing sample. With +name+, silences that sample's voices; without one,
      # stops everything on the sampled-audio output.
      def stop_sample(name = nil)
        Node.new(:stop_sample, name: name)
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

      # --- hardware timers ---
      #
      # A named counter that runs at a chosen rate: it overflows +hz+ times a second.
      # Used for timed work and (later) to clock sampled audio. The rate is a plain
      # frequency in Hz — portable intent — so each backend realizes it its own way
      # (the GBA picks a prescaler + reload; the interpreter models a frame clock).

      # Start (or restart) the named timer running at +hz+ overflows per second. Restart
      # resets its elapsed-overflow count to zero.
      def timer_start(name, hz)
        unless hz.is_a?(Integer) && hz.positive?
          raise ArgumentError, "a timer's rate must be a positive whole number of Hz, got #{hz.inspect}"
        end
        Node.new(:timer_start, name: name, hz: hz)
      end

      # Stop the named timer (it stops counting; its last count is frozen).
      def timer_stop(name)
        Node.new(:timer_stop, name: name)
      end

      # Run +body+ every time the named timer overflows — a handler driven by the timer
      # itself, so it runs at the timer's rate independent of the frame loop (where every/
      # after are frame-paced). The body's statements are the node's children.
      def on_timer(timer, *body)
        Node.new(:on_timer, children: body, timer: timer)
      end

      # How many times the named timer has overflowed since it started — a value, so it
      # can drive an operand. Wraps at 65536 (a 16-bit count), like the hardware counter.
      def timer_ticks(name)
        Node.new(:timer_ticks, name: name)
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

      # A run-time test: do the visible (non-transparent) pixels of two posed things
      # actually overlap? Each side is its set of same-size +poses+ (image names), the
      # +pose+ index it's showing now, and the +x+/+y+ where it sits. Yields 1 when a
      # solid pixel of one lands on a solid pixel of the other, else 0 — the
      # shape-accurate, animation-aware core of sprite collision (a cheap box overlap
      # gates it, so this only runs for things already close). A backend reads each
      # side's own picture to know which pixels are solid, so both agree on the shape.
      def pixels_overlap(a_poses:, a_pose:, a_x:, a_y:, b_poses:, b_pose:, b_x:, b_y:)
        Node.new(:pixels_overlap,
                 a_poses: a_poses, a_pose: wrap(a_pose), a_x: wrap(a_x), a_y: wrap(a_y),
                 b_poses: b_poses, b_pose: wrap(b_pose), b_x: wrap(b_x), b_y: wrap(b_y))
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

      # Show the named background scrolled to the offset (+x+, +y+) in pixels — the
      # top-left of the visible window over the map. x/y are value operands (variables
      # the game moves), so the view slides as they change; a map is a torus, so an
      # offset past its edge wraps around. This says *where the window sits*, not how a
      # machine scrolls: one backend re-renders the window, another nudges the tile
      # hardware's scroll offset.
      def scroll_background(name, x:, y:)
        Node.new(:scroll_background, name: name, x: wrap(x), y: wrap(y))
      end

      # Move the whole displayed picture. x/y are where the visible window's top-left
      # sits over the drawn image, in pixels, as run-time values — so (0, 0) shows the
      # picture as drawn, and a small changing offset jitters it (a screen shake).
      #
      # Unlike scroll_background, which re-windows ONE map, this offsets everything the
      # display shows, and it needs no redrawing: the picture is not moved, only the
      # window onto it. Where the window falls outside the drawn image there is nothing
      # to show, so the backdrop appears along that edge.
      def camera(x:, y:)
        Node.new(:camera, x: wrap(x), y: wrap(y))
      end

      # Blend the whole displayed picture toward a color. +toward+ is :black or :white
      # (fixed as the program is written); +amount+ is how far, from 0 (the picture as
      # drawn) to 100 (nothing left but that color), as a run-time value — so a value
      # walked from 0 to 100 over some frames is a fade, and one snapped to 100 and
      # back is a flash.
      #
      # Like camera, this describes what the DISPLAY shows and needs no redrawing:
      # nothing that was drawn is changed, so the cost is the same whatever is on
      # screen. One backend leans on blend hardware, another blends as it reads.
      def fade(toward:, amount:)
        Node.new(:fade, toward: toward, amount: wrap(amount))
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

      # Declare an object: one of its +poses+ (a list of same-size pictures) shown at
      # the position held in the +x+ and +y+ variables, drawn while +active+ is 1
      # (0 = hidden). +pose+ is a value operand selecting which picture to show right
      # now (0-based) — that's how an object faces a direction or animates: a plain
      # object has one pose and holds `pose` at 0, a facing/animated one drives it with
      # a variable. x/y/active/pose are value operands (variables the game steers).
      #
      # +angle+ is a value operand: the object's rotation in degrees (clockwise,
      # pivoting on its own center). It defaults to a constant 0 — upright — which is
      # how an object that never turns draws, and a backend can see that constant and
      # pay nothing for rotation. An object that turns holds a variable here instead,
      # and a backend rotates the picture to that angle each frame (the display's own
      # rotate/scale on hardware, a rotated sample in the reference interpreter).
      # Reserves the object; #present_objects is what actually draws it for a frame.
      def object(name, poses:, pose:, x:, y:, active:, angle: 0)
        Node.new(:object, name: name, poses: poses, pose: wrap(pose),
                          x: wrap(x), y: wrap(y), active: wrap(active), angle: wrap(angle))
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

      # Embed a build-time array as a read-only ROM table. +values+ is a Ruby array
      # of whole numbers computed at build time (a trig curve, a level row, ...).
      # +width+ is the element size (:byte / :half / :word) and +signed+ says whether
      # the values are signed (a read sign-extends). A definition — it emits nothing on
      # its own; table_get reads it.
      def table(name, values, width:, signed:)
        Node.new(:table, name: name, values: values, width: width, signed: signed)
      end

      # Read table[index] at run time — a value, so it can drive an operand or a
      # coordinate. +index+ is itself a value operand. An out-of-range index is made
      # safe by the read: a power-of-two table wraps it (a free mask), any other size
      # clamps it, so a read never reaches outside the table.
      def table_get(name, index)
        Node.new(:table_get, name: name, index: wrap(index))
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

      # Multiply two numbers that each carry +fraction_bits+ fraction bits, giving a
      # number carrying the same. The product is formed at full width before it is
      # brought back down, so an intermediate too big for 32 bits — which a plain
      # multiply would wrap and get wrong — comes out right. See Int32.mul_fix for
      # what fraction bits are and why the plain multiply can't do this.
      #
      # +fraction_bits+ is settled while building (0..32); the two operands are values.
      def mul_fix(lhs, rhs, fraction_bits)
        unless fraction_bits.is_a?(Integer) && (0..32).cover?(fraction_bits)
          raise ArgumentError, "fraction_bits must be a whole number from 0 to 32, got #{fraction_bits.inspect}"
        end

        Node.new(:mul_fix, lhs: wrap(lhs), rhs: wrap(rhs), fraction_bits: fraction_bits)
      end

      # Divide one number carrying a fraction by another, giving a number carrying one
      # too. The numerator is widened by +fraction_bits+ before anything is divided, so
      # the answer keeps a fraction instead of losing it — see Int32.div_fix for why the
      # widening is needed and what decides how far.
      #
      # +fraction_bits+ is settled while building (0..32); the two operands are values.
      def div_fix(lhs, rhs, fraction_bits)
        unless fraction_bits.is_a?(Integer) && (0..32).cover?(fraction_bits)
          raise ArgumentError, "fraction_bits must be a whole number from 0 to 32, got #{fraction_bits.inspect}"
        end

        Node.new(:div_fix, lhs: wrap(lhs), rhs: wrap(rhs), fraction_bits: fraction_bits)
      end

      # Divide +operand+ by 2**bits, rounding down (see Int32.shift_right for why down
      # and not toward zero). +bits+ is settled while building, 0..31.
      def shift_right(operand, bits)
        unless bits.is_a?(Integer) && (0..31).cover?(bits)
          raise ArgumentError, "shift_right's bits must be a whole number from 0 to 31, got #{bits.inspect}"
        end

        Node.new(:shift_right, operand: wrap(operand), bits: bits)
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
                "can't use #{operand.inspect} as a value — expected a whole number, a " \
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
