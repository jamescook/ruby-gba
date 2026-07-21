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
    #     display(:bitmap),
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

      # --- drawing / display operations ---

      def display(mode)
        Node.new(:display, mode: mode)
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

      # Write a line of text at a fixed top-left origin, drawn with the built-in
      # bitmap font. +x+/+y+ are compile-time constants.
      def draw_text(text, x, y, color)
        Node.new(:draw_text, text: text, x: x, y: y, color: color)
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
      # variables (a moving object). Keep it on-screen — off-screen parts aren't
      # clipped at run time yet.
      def blit(name, x, y)
        Node.new(:blit, name: name, x: wrap(x), y: wrap(y))
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
    end
  end
end
