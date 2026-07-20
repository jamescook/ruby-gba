# frozen_string_literal: true

require "set"

require_relative "ruby/framebuffer"

module RubyGBA
  module IR
    module Backends
      # The Ruby backend: runs an IR::Node program directly in Ruby, against
      # simulated hardware. It executes control flow, variable ops, and arithmetic
      # against an in-memory variable store, and it draws into a fake screen and
      # reads a fake gamepad — so a program's logic *and* its visible behavior can
      # be checked in-process. Being able to just *run* a program and read the
      # result is what makes testing a game cheap and headless, and it pins the
      # IR's meaning before a lowering backend (the console ROM backend) has to
      # reproduce it.
      #
      # The simulated hardware here is deliberately small: a bitmap #screen
      # (see Framebuffer) that the draw ops write into, and a set of held buttons
      # that the input ops read. Other hardware (sound, tiled backgrounds,
      # sprites, the paged bitmap modes) is layered on in its own right; each is
      # its own slice of work.
      #
      # It runs hand-built IR::Build trees today; it needs neither the DSL to
      # emit IR nor an emulator.
      class Ruby
        class ProgramError < StandardError; end

        # The buttons a program can read. Naming an unknown one is almost always
        # a typo, and a typo'd button would silently read as "never held" — so we
        # reject it with a friendly error instead of leaving a ghost bug.
        BUTTONS = %i[a b select start right left up down r l].freeze

        # A generous default so an accidental infinite loop can't hang a test
        # forever. Pass a small max_steps to deliberately run N steps of an
        # otherwise-endless game loop and then inspect the state.
        DEFAULT_MAX_STEPS = 1_000_000

        attr_reader :vars, :screen, :log, :frame, :display_mode, :audio

        def initialize
          @vars = Hash.new(0)      # variable store; an unwritten variable reads as 0
          @funcs = {}              # name -> :func node
          @screen = Framebuffer.new # the fake bitmap screen the draw ops write into
          @held = Set.new          # buttons down right now
          @prev_held = Set.new     # buttons down at the previous vblank (for edges)
          @input_script = nil      # optional ->(frame) { buttons } to drive input over time
          @frame = 0               # vblanks elapsed
          @display_mode = nil      # the mode a `display` op selected, if any
          @log = []               # observable events: [:vblank, n], [:halt]
          @defined_sounds = {}     # name -> musical params (from define_sound)
          @songs = {}              # name -> :song node (from song)
          @data = {}               # name -> bytes (embedded data blobs)
          @music_frames = Hash.new(0) # per-song frame counter for play_song
          @audio = []             # observable audio: [:enabled], [:beep, ..], [:note, ..]
        end

        # Execute a program (or any statement node) until it ends naturally, hits
        # a `halt`, or exhausts the step budget — whichever comes first. Returns
        # self so callers can chain and then inspect variables.
        def run(node, max_steps: DEFAULT_MAX_STEPS)
          @max_steps = max_steps
          @steps = 0
          @stopped_at_budget = false
          collect_definitions(node)
          catch(:halt) { exec(node) }
          self
        end

        # Read a variable's current value (0 if it was never written).
        def [](name)
          @vars[name]
        end

        # True if run() stopped because it hit the step budget rather than a
        # `halt` or the natural end — i.e. it was still looping when we cut it off.
        def stopped_at_budget?
          @stopped_at_budget
        end

        # Set which buttons are held down right now, replacing any previous set.
        # This is the simplest way for a test to supply input: hold some buttons,
        # then run. Returns self so it can be chained before #run.
        def hold(*buttons)
          @held = to_button_set(buttons)
          self
        end

        # Drive input that changes over time. The block is called at each vblank
        # with the frame number (1, 2, 3, …) and returns the buttons held for
        # that frame — the headless equivalent of a player working the pad frame
        # by frame. Needed to observe edges (see `pressed`). Returns self.
        def input_each_frame(&block)
          @input_script = block
          self
        end

        private

        # Register every definition in the tree up front — funcs, named sound
        # effects, and songs — so an op can refer to one defined later in the
        # program (a forward reference), the same resolve-names-first move the GBA
        # lowering makes with labels.
        def collect_definitions(node)
          node.walk do |n|
            case n.kind
            when :func
              @funcs[n[:name]] = n
            when :define_sound
              @defined_sounds[n[:name]] = {
                frequency: n[:frequency], duty: n[:duty],
                decay: n[:decay], volume: n[:volume]
              }
            when :song
              @songs[n[:name]] = n
            when :data
              @data[n[:name]] = n[:bytes]
            end
          end
        end

        def tick!
          @steps += 1
          return if @steps <= @max_steps

          @stopped_at_budget = true
          throw :halt
        end

        def exec(node)
          tick!
          case node.kind
          when :program
            node.children.each { |child| exec(child) }
          when :func
            # A func body runs only when something `call`s it, never inline here.
            nil
          when :set
            @vars[node[:var]] = eval_value(node[:value])
          when :add
            @vars[node[:var]] = Int32.add(@vars[node[:var]], eval_value(node[:operand]))
          when :sub
            @vars[node[:var]] = Int32.sub(@vars[node[:var]], eval_value(node[:operand]))
          when :copy
            @vars[node[:dest]] = @vars[node[:src]]
          when :negate
            @vars[node[:var]] = Int32.neg(@vars[node[:var]])
          when :abs
            # |v|: flip it only when it's negative.
            v = @vars[node[:var]]
            @vars[node[:var]] = v.negative? ? Int32.neg(v) : v
          when :negate_abs
            # -|v|: flip it only when it's positive.
            v = @vars[node[:var]]
            @vars[node[:var]] = v.positive? ? Int32.neg(v) : v
          when :clamp
            @vars[node[:var]] = clamp_value(@vars[node[:var]], node[:min], node[:max])
          when :if
            if eval_value(node[:cond]).zero?
              node[:else]&.children&.each { |child| exec(child) }
            else
              node.children.each { |child| exec(child) }
            end
          when :loop
            loop { node.children.each { |child| exec(child) } }
          when :call
            exec_call(node[:target])
          when :case
            exec_case(node)
          when :halt
            @log << [:halt]
            throw :halt
          when :wait_vblank
            advance_frame
          when :display
            # Just remember the chosen mode; the fake screen already models the
            # bitmap the draw ops assume.
            @display_mode = node[:mode]
          when :clear_screen
            @screen.clear(resolve_color(node[:color]))
          when :pixel
            @screen.set_pixel(eval_value(node[:x]), eval_value(node[:y]), resolve_color(node[:color]))
          when :fill_rect
            @screen.fill_rect(eval_value(node[:x]), eval_value(node[:y]),
                              eval_value(node[:w]), eval_value(node[:h]),
                              resolve_color(node[:color]))
          when :dma_fill_rect
            # Same picture as fill_rect — the "DMA" is only how a console fills it
            # fast; the pixels that land are identical.
            @screen.fill_rect(eval_value(node[:x]), eval_value(node[:y]),
                              eval_value(node[:w]), eval_value(node[:h]),
                              resolve_color(node[:color]))
          when :draw_rect_at
            # A rectangle whose position is computed at run time (x/y may be
            # variables); the size is a constant.
            @screen.fill_rect(eval_value(node[:x]), eval_value(node[:y]),
                              node[:w], node[:h], resolve_color(node[:color]))
          when :draw_text
            exec_draw_text(node)
          when :enable_sound
            @audio << [:enabled]
          when :define_sound, :song, :data
            # Definitions: gathered up front, so reaching one inline does nothing
            # (just like a func body).
            nil
          when :beep
            @audio << [:beep, resolve_effect(node)]
          when :play_song
            exec_play_song(node[:name])
          when :stop_music
            @audio << [:stop_music]
          when :raw
            raise ProgramError,
                  "raw is a GBA-only escape hatch — the interpreter can't run " \
                  "machine bytes, so avoid `entry` in code you want to run headlessly"
          else
            raise ProgramError,
                  "the Ruby backend cannot execute #{node.kind.inspect} " \
                  "(#{node.category}) yet"
          end
        end

        # One vblank: snapshot the current buttons as "previous" (so an edge can
        # be spotted), advance the frame counter, and pull the next frame's input
        # if a script is driving it.
        def advance_frame
          @prev_held = @held
          @frame += 1
          @held = to_button_set(Array(@input_script.call(@frame))) if @input_script
          @log << [:vblank, @frame]
        end

        def exec_call(name)
          func = @funcs[name] || raise(ProgramError, "call to undefined func #{name.inspect}")
          func.children.each { |child| exec(child) }
        end

        # Render a string with the built-in bitmap font: each set pixel of each
        # glyph becomes one painted cell, offset from the text's top-left origin.
        # Off-screen cells clip away in set_pixel, just as they do on hardware.
        def exec_draw_text(node)
          x = eval_value(node[:x])
          y = eval_value(node[:y])
          color = resolve_color(node[:color])
          Font.each_pixel(node[:text]) do |dx, dy|
            @screen.set_pixel(x + dx, y + dy, color)
          end
        end

        # Resolve a beep's tone + overrides into the concrete musical values that
        # played — the shared rule, so the interpreter and the ROM agree on what a
        # given beep means.
        def resolve_effect(node)
          Sound.resolve_effect(node[:tone], duty: node[:duty], decay: node[:decay],
                                            volume: node[:volume], defined: @defined_sounds)
        end

        # Advance a song by one frame and record any note that lands on this frame
        # (frequency 0 is a rest). The counter increments first, then wraps at the
        # song's length so it loops — matching how the ROM sequences the same song.
        def exec_play_song(name)
          song = @songs[name] || raise(ProgramError, "play_song for undefined song #{name.inspect}")
          frame = @music_frames[name] + 1
          song[:events].each do |offset, frequency|
            @audio << [:note, name, frequency] if offset == frame
          end
          frame = 0 if frame >= song[:total_frames]
          @music_frames[name] = frame
        end

        # Multi-way dispatch: call the scene/func for the clause whose value equals
        # the variable. Values are distinct, so this runs at most one scene.
        def exec_case(node)
          value = @vars[node[:var]]
          node[:clauses].each do |clause_value, target|
            exec_call(target) if value == clause_value
          end
        end

        # Evaluate an operand to a signed 32-bit integer. Operands are normally
        # value nodes; a bare Integer or Symbol is accepted too for convenience.
        def eval_value(operand)
          case operand
          when Integer then Int32.wrap(operand)
          when Symbol then @vars[operand]
          when Node then eval_node(operand)
          else raise ProgramError, "cannot evaluate operand #{operand.inspect}"
          end
        end

        def eval_node(node)
          case node.kind
          when :int then Int32.wrap(node[:value])
          when :var_ref then @vars[node[:name]]
          when :neg then Int32.neg(eval_value(node[:operand]))
          when :binop then eval_binop(node[:op], eval_value(node[:lhs]), eval_value(node[:rhs]))
          when :held then bool(button_held?(node[:button]))
          when :pressed then bool(button_pressed?(node[:button]))
          when :data_byte then data_byte(node[:name], node[:index])
          else raise ProgramError, "not a value node: #{node.kind.inspect}"
          end
        end

        # One byte (0..255) of a named embedded blob, read straight from the
        # stored bytes — no addresses here, just an index into the data.
        def data_byte(name, index)
          bytes = @data.fetch(name) do
            raise ProgramError, "reference to undefined data #{name.inspect}"
          end
          bytes.getbyte(index) ||
            raise(ProgramError, "data_byte index #{index} is past the end of #{name.inspect}")
        end

        # A button is "held" while it's down. It's "pressed" only on the edge —
        # the first frame it goes down, i.e. down now but up at the last vblank.
        # That edge is what a game uses to fire once per tap instead of every
        # frame the button is held.
        def button_held?(button)
          @held.include?(check_button!(button))
        end

        def button_pressed?(button)
          button = check_button!(button)
          @held.include?(button) && !@prev_held.include?(button)
        end

        def to_button_set(buttons)
          buttons.each { |b| check_button!(b) }
          Set.new(buttons)
        end

        def check_button!(button)
          return button if BUTTONS.include?(button)

          raise ProgramError,
                "unknown button #{button.inspect} — known buttons are #{BUTTONS.join(', ')}"
        end

        def resolve_color(color)
          Color.resolve(color)
        end

        # Arithmetic routes through Int32 (signed 32-bit wraparound); comparisons
        # use signed ordering and yield 1/0, so a condition is simply "non-zero".
        def eval_binop(op, lhs, rhs)
          case op
          when :+ then Int32.add(lhs, rhs)
          when :- then Int32.sub(lhs, rhs)
          when :* then Int32.mul(lhs, rhs)
          when :/ then Int32.div(lhs, rhs)
          when :> then bool(Int32.cmp(lhs, rhs) > 0)
          when :< then bool(Int32.cmp(lhs, rhs) < 0)
          when :>= then bool(Int32.cmp(lhs, rhs) >= 0)
          when :<= then bool(Int32.cmp(lhs, rhs) <= 0)
          when :== then bool(Int32.cmp(lhs, rhs).zero?)
          when :!= then bool(!Int32.cmp(lhs, rhs).zero?)
          # Condition composition: operands are already 0/1, so combine them.
          when :and then bool(!lhs.zero? && !rhs.zero?)
          when :or then bool(!lhs.zero? || !rhs.zero?)
          else raise ProgramError, "unknown binary operator #{op.inspect}"
          end
        end

        def clamp_value(value, min, max)
          return min if value < min
          return max if value > max

          value
        end

        def bool(flag)
          flag ? 1 : 0
        end
      end
    end
  end
end
