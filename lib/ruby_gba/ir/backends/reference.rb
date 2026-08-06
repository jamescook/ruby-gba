# frozen_string_literal: true

require "set"

require_relative "reference/framebuffer"
require_relative "reference/list_value"

module RubyGBA
  module IR
    module Backends
      # The reference backend: runs an IR::Node program directly, in Ruby, against
      # simulated hardware:
      # control flow, variable ops and arithmetic against an in-memory variable
      # store, drawing into a fake screen, reading a fake gamepad. So a program's
      # logic *and* its visible behavior can be checked in-process, with no ROM and
      # no emulator.
      #
      # WHY THIS EXISTS WHEN WE HAVE A REAL EMULATOR
      #
      # The emulator tells you what the ROM *does*. On its own it cannot tell you
      # whether that is what the program *meant* — there is nothing to check the ROM
      # against, so the ROM defines its own correctness. A bug where the lowering
      # faithfully emits the wrong thing is then invisible: the emulator renders it,
      # the pixel is whatever the ROM drew, and the test is green. Running the same
      # program here gives a second, independent answer. Where the two disagree,
      # something is wrong and a person has to look. That is a whole class of bug
      # neither one can find alone, and it's what test/differential.rb is built on.
      #
      # It is also far cheaper: there is no ROM to assemble and no emulator to boot,
      # so a run costs a fraction of the console path. That is what lets the suite
      # check behavior in bulk instead of sparingly. And it is the only thing keeping
      # the IR honest about being target-agnostic: with a single backend, "the IR
      # doesn't assume ARM" is a hope, because nothing would notice if it did.
      #
      # One caveat worth knowing before you trust it. This is an oracle for what a
      # program MEANS, not a model of every rounding decision real hardware makes.
      # It can be the wrong one: where it and the console disagree, the bug is
      # sometimes here. Read a disagreement as "these two disagree", not as "the
      # console is wrong".
      #
      # The simulated hardware is deliberately small: a bitmap #screen (see
      # Framebuffer) that the draw ops write into, and a set of held buttons that
      # the input ops read. Other hardware (sound, tiled backgrounds, sprites, the
      # paged bitmap modes) is layered on in its own right.
      class Reference
        class ProgramError < StandardError; end

        # A generous cap so an accidental infinite loop can't hang a test forever.
        # It's the runaway guard, not the usual stop — see DEFAULT_FRAMES.
        DEFAULT_MAX_STEPS = 1_000_000

        # How many frames a game loop runs when the caller caps neither `frames:`
        # nor `max_steps:`. A non-halting loop otherwise grinds all the way to the
        # step budget (thousands of frames) when a handful is all a test needs — so
        # the default is small and deliberately cheap. A test that needs to play
        # further (gameplay reaching some state) passes a larger `frames:`.
        DEFAULT_FRAMES = 20

        # The frame rate this backend models: a timer running at H Hz overflows
        # H/FRAME_RATE times per frame. The console runs at ~59.7fps; 60 is the clean
        # model both backends treat "a frame" as, so their timer counts line up.
        FRAME_RATE = 60

        # A background's map is a fixed 32x32 grid of cells on the console, however
        # few the author actually filled in. That matters as soon as the background
        # scrolls: the visible window moves over the WHOLE 32x32 grid, so past the
        # filled-in part you see empty cells (the backdrop), and the picture only
        # comes round again after a full 32 cells. Wrapping at the author's own map
        # size instead would repeat a small map across the screen forever, which the
        # console never does.
        MAP_CELLS = 32

        attr_reader :vars, :screen, :log, :frame, :screen_mode, :buffered, :audio, :peak_voices, :save

        # The names of the samples sounding right now — one entry per voice, so the same
        # sample played twice shows up twice. Lets a test see that several sounds really
        # overlap in the mix instead of cutting each other off.
        def active_samples
          @voices.map { |v| v[:name] }
        end

        # The level a currently-sounding sample is playing at (its first voice), or nil if
        # it isn't playing — so a test can see `play(volume:)` took effect.
        def volume_of(name)
          @voices.find { |v| v[:name] == name }&.fetch(:volume)
        end

        # +save+ is the cartridge's save memory — an external store that outlives the
        # interpreter, so passing the SAME object to two Reference.new(...).run calls models
        # a power cycle (the second boot sees what the first one saved). Defaults to a
        # fresh, empty store: a brand-new cartridge, and untouched by programs that
        # persist nothing.
        def initialize(save: {})
          @save = save             # persisted variables, by slot; @save[:magic] marks it written
          @vars = Hash.new(0)      # variable store; an unwritten variable reads as 0
          @funcs = {}              # name -> :func node
          @screen = Framebuffer.new # the fake bitmap screen the draw ops write into
          @held = Set.new          # buttons down right now
          @prev_held = Set.new     # buttons down at the previous vblank (for edges)
          @input_script = nil      # optional ->(frame) { buttons } to drive input over time
          @frame = 0               # vblanks elapsed
          @screen_mode = nil       # the mode a `screen` op selected, if any
          @buffered = false        # whether that mode opted into double buffering
          @log = []               # observable events: [:vblank, n], [:halt]
          @defined_sounds = {}     # name -> musical params (from define_sound)
          @songs = {}              # name -> :song node (from song)
          @data = {}               # name -> bytes (embedded data blobs)
          @bitmaps = {}            # name -> { width:, height: } (a blob that has a shape)
          @tile_colors = {}        # name -> its pixels as colors, decoded once (nil = see-through)
          @backing = {}            # name -> { width:, height:, pixels: } (saved patch under a moving object)
          @objects = {}            # name -> :object node (a composited moving picture)
          @bg_nodes = []           # :background nodes, in order (the static scene under the objects)
          @bg_by_name = {}         # name -> :background node (for scrolling that background's window)
          @scene_fb = nil          # the settled scene (backdrop + backgrounds), built once, to restore under objects
          @obj_prev = {}           # object name -> [x, y] it was last drawn at (to erase before redrawing)
          @scrolling = false       # does this program scroll a background? (decided in collect_definitions)
          @bg_scroll = {}          # background name -> [x, y] its window is currently offset to
          @obj_layer = []          # sprites to composite over a scrolling scene, in draw order (later = in front)
          @lists = {}              # name -> ListValue (a bounded, run-time-sized collection)
          @tables = {}             # name -> { values:, signed: } (a read-only ROM table)
          @music_frames = Hash.new(0) # per-song frame counter for play_song
          @samples = {}           # name -> { rate:, length: } (a defined PCM sample)
          @voices = []            # the samples sounding right now, mixed together: [{ name:, loop:, frames_left:, frames_total: }, ...]
          @peak_voices = 0        # the most that ever sounded at once (how much polyphony the run used)
          @timers = {}            # name -> { hz:, running:, overflows: } (a hardware timer)
          @timer_handlers = {}    # name -> on_timer node whose body runs on each overflow
          @audio = []             # observable audio: [:enabled], [:beep, ..], [:note, ..]
          @on_vblank = nil         # optional ->(frame) { } called each vblank, to watch a run frame by frame
        end

        # Execute a program (or any statement node) until it ends naturally, hits
        # a `halt`, runs the requested number of `frames:`, or exhausts the step
        # budget — whichever comes first. Returns self so callers can chain and
        # then inspect variables.
        #
        # Pass `frames:` to play a game loop for exactly N frames and stop with the
        # Nth frame fully drawn (a settled screen, never a torn mid-frame) — the
        # natural way to say "play this far in", and how the gemba tests express it
        # too. It's the stop condition when given; `max_steps` then only guards the
        # runaway case of a frame that never reaches vblank.
        #
        # Cap neither and a game loop stops after DEFAULT_FRAMES — small and cheap,
        # since a handful of frames is all most tests need; pass a larger `frames:`
        # to play further. Passing `max_steps:` alone opts back into a step budget.
        def run(node, max_steps: nil, frames: nil)
          frames = DEFAULT_FRAMES if frames.nil? && max_steps.nil?
          @frames_limit = frames
          @max_steps = max_steps || DEFAULT_MAX_STEPS
          # Past the soft budget a frame-based program runs on to the next frame boundary
          # (so it stops on a complete screen, never a torn mid-frame); the hard cap bounds
          # the rare case where that boundary never comes (a loop that stops calling vblank).
          @hard_cap = @max_steps * 2
          @steps = 0
          @stopped_at_budget = false
          @over_budget = false
          @uses_frames = false # set once the program reaches its first vblank (advance_frame)
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

        # Watch a run frame by frame: the block is called at each vblank with the frame
        # number, with #screen holding the image that just settled — for capturing a run
        # to preview it (turn a sequence of frames into a picture or animation). Purely an
        # observer; it changes nothing about how the program runs. Returns self.
        def each_vblank(&block)
          @on_vblank = block
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
            when :sample
              @samples[n[:name]] = { rate: n[:rate], length: n[:bytes].bytesize, note: n[:note] }
            when :table
              @tables[n[:name]] = { values: n[:values], signed: n[:signed] }
            when :data
              @data[n[:name]] = n[:bytes]
            when :bitmap
              @data[n[:name]] = n[:pixels]
              @bitmaps[n[:name]] = { width: n[:width], height: n[:height], transparent: n[:transparent] }
            when :backing_buffer
              # Reserve the patch. `pixels` stays nil until the first save_region
              # fills it — a restore before any save has nothing to put back.
              @backing[n[:name]] = { width: n[:width], height: n[:height], pixels: nil }
            when :object
              # Register the object, so present_objects can find its picture and the
              # variables holding where it is and whether it's shown.
              @objects[n[:name]] = n
            when :background
              # Remember every background so present_objects can redraw them under the
              # objects each frame (that clean redraw is what erases the previous frame),
              # and by name so scroll_background can re-window that one.
              @bg_nodes << n
              @bg_by_name[n[:name]] = n
            when :scroll_background
              # A program that scrolls even once can put its background at a non-zero
              # offset, so the whole scene has to be repainted every frame — the static
              # save-under trick objects normally ride on no longer holds. Remember that
              # here so present_objects and scroll_background take the repaint path.
              @scrolling = true
            end
          end
        end

        def tick!
          @steps += 1
          return if @steps <= @max_steps

          @stopped_at_budget = true
          # A frame-based program doesn't stop here — mid-frame would leave a torn,
          # half-drawn screen. Mark it over budget and let it run on to the next frame
          # boundary, where advance_frame stops it with the in-flight frame complete. A
          # program with no frames, or one past the hard cap (its next vblank never came),
          # stops right here.
          @over_budget = true
          throw :halt unless @uses_frames && @steps <= @hard_cap
        end

        def exec(node)
          tick!
          # The interpreter is a portable-only backend: it faithfully models every
          # target-neutral op but refuses a hardware-only one (opaque native bytes it
          # can't run) rather than skipping it — a silent skip would make the oracle's
          # screen diverge from the console's. Which kinds are hardware-only comes from
          # IR::Portability, so a kind newly tagged there is refused here automatically,
          # with no new branch to add.
          if Portability.hardware_only?(node.kind)
            raise ProgramError,
                  "the reference backend can't run #{node.kind.inspect} — it's a hardware-only op the " \
                  "interpreter can't model; keep it out of code you run headlessly"
          end

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
            @vars[node[:var]] = clamp_value(@vars[node[:var]], eval_value(node[:min]),
                                            eval_value(node[:max]))
          when :save_init
            exec_save_init(node)
          when :save_store
            exec_save_store(node)
          when :if
            if eval_value(node[:cond]).zero?
              node[:else]&.children&.each { |child| exec(child) }
            else
              node.children.each { |child| exec(child) }
            end
          when :loop
            loop { node.children.each { |child| exec(child) } }
          when :repeat
            # A counted loop: the index counts 0..count-1. Evaluate count once,
            # like a for-loop bound. tick! guards the step budget even when the
            # body is empty.
            count = eval_value(node[:count])
            i = 0
            while i < count
              tick!
              @vars[node[:index]] = i
              node.children.each { |child| exec(child) }
              i += 1
            end
          when :every
            # A repeating timer: tick the hidden frame counter, and each time it
            # reaches the period, reset it and run the body — so the body fires once
            # per interval.
            @vars[node[:counter]] = Int32.add(@vars[node[:counter]], 1)
            if @vars[node[:counter]] >= node[:period]
              @vars[node[:counter]] = 0
              node.children.each { |child| exec(child) }
            end
          when :after
            # A one-shot timer: count up only until the target frame, running the
            # body on the single frame the counter lands exactly on it.
            if @vars[node[:counter]] < node[:frames]
              @vars[node[:counter]] = Int32.add(@vars[node[:counter]], 1)
              node.children.each { |child| exec(child) } if @vars[node[:counter]] == node[:frames]
            end
          when :list_new
            # Create (or reset) the named list, empty, with its rounded capacity.
            @lists[node[:name]] = ListValue.new(node[:capacity])
          when :list_push
            exec_list_push(node)
          when :list_drop
            exec_list_drop(node)
          when :list_set
            exec_list_set(node)
          when :blit
            exec_blit(node)
          when :blit_pose
            exec_blit_pose(node)
          when :save_region
            exec_save_region(node)
          when :restore_region
            exec_restore_region(node)
          when :call
            exec_call(node[:target])
          when :case
            exec_case(node)
          when :halt
            @log << [:halt]
            throw :halt
          when :wait_vblank
            advance_frame
          when :screen
            # Remember the chosen mode; the fake screen already models the bitmap the
            # draw ops assume. Double buffering (node[:buffered]) needs no different
            # handling here: it only changes *when* a drawn frame becomes visible on
            # real hardware, and this oracle already reads the settled end-of-frame
            # image — so a torn mid-frame never existed to begin with.
            #
            # Crossing between the bitmap display (a linear framebuffer) and the tiled
            # display (a tilemap plus hardware sprites) is different: the two reuse the
            # same video memory in incompatible ways, so the console shows one surface
            # or the other, never both. A bitmap title handing off to a tiled game means
            # the title's pixels stop being shown the instant the mode flips. Model that
            # by wiping the picture on the crossing, so a previous scene's mode can't
            # bleed through under the new one. A switch that stays within the bitmap
            # family (single- vs double-buffered) keeps the same surface, so it doesn't
            # wipe — the existing per-scene bitmap-mode behavior is unchanged.
            @screen.clear(0) if @screen_mode && tiled_mode?(node[:mode]) != tiled_mode?(@screen_mode)
            @screen_mode = node[:mode]
            @buffered = node[:buffered] || false
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
            # A rectangle whose position and height are computed at run time (x/y/h
            # may be variables or expressions); only the width is a constant. A height
            # of zero or less covers no rows, so nothing is drawn.
            @screen.fill_rect(eval_value(node[:x]), eval_value(node[:y]),
                              node[:w], eval_value(node[:h]), resolve_color(node[:color]))
          when :draw_text
            exec_draw_text(node)
          when :draw_digit
            exec_draw_digit(node)
          when :background
            exec_background(node)
          when :scroll_background
            exec_scroll_background(node)
          when :camera
            @screen.camera_to(eval_value(node[:x]), eval_value(node[:y]))
          when :fade
            @screen.fade_to(node[:toward], eval_value(node[:amount]))
          when :present_objects
            exec_present_objects(node)
          when :enable_sound
            @audio << [:enabled]
          when :define_sound, :song, :sample, :data, :bitmap, :backing_buffer, :object, :table
            # Definitions: gathered up front, so reaching one inline does nothing
            # (just like a func body).
            nil
          when :beep
            @audio << [:beep, resolve_effect(node)]
          when :noise
            @audio << [:noise, resolve_noise(node)]
          when :wave
            @audio << [:wave, { shape: node[:shape], frequency: node[:frequency], volume: node[:volume] }]
          when :stop_wave
            @audio << [:stop_wave]
          when :play_song
            exec_play_song(node[:name])
          when :stop_music
            @audio << [:stop_music]
          when :play_sample
            start_sample(node)
          when :stop_sample
            stop_sample(node)
          when :timer_start
            # Start (or restart) a timer: it now runs at hz overflows/sec, its elapsed
            # count reset to zero (advance_frame accrues the overflows each frame).
            @timers[node[:name]] = { hz: node[:hz], running: true, overflows: 0.0 }
          when :timer_stop
            @timers[node[:name]]&.[]=(:running, false)
          when :on_timer
            # Arm the handler: its body runs on each of the timer's overflows, which
            # advance_frame drives as the timer accrues them.
            @timer_handlers[node[:timer]] = node
          else
            raise ProgramError,
                  "the reference backend cannot execute #{node.kind.inspect} " \
                  "(#{node.category}) yet"
          end
        end

        # One vblank: snapshot the current buttons as "previous" (so an edge can
        # be spotted), advance the frame counter, and pull the next frame's input
        # if a script is driving it.
        def advance_frame
          # This is a frame boundary: if we're past the budget, stop HERE — the frame just
          # drawn is complete, and the next one's clear/draws haven't started, so the screen
          # is settled. Reaching a vblank also marks the program as frame-based (see tick!).
          throw :halt if @over_budget

          # Same settled-boundary stop once we've played the requested number of frames:
          # @frame counts frames already completed, so at == the limit the next frame's
          # draws haven't begun. Not a budget cutoff — it ran exactly as asked, so
          # #stopped_at_budget? stays false.
          throw :halt if @frames_limit && @frame >= @frames_limit

          @uses_frames = true
          @prev_held = @held
          @frame += 1
          # A running timer overflows hz times a second, so it accrues hz/FRAME_RATE
          # overflows this frame — that's what timer_ticks reads back, and each whole
          # overflow crossed this frame runs its on_tick handler once.
          @timers.each { |name, t| accrue_timer(name, t) if t[:running] }
          advance_voices
          @held = to_button_set(Array(@input_script.call(@frame))) if @input_script
          @log << [:vblank, @frame]
          @on_vblank&.call(@frame)
        end

        # The most samples the mixer sounds at once. A new play past this is dropped rather
        # than stealing one already sounding (safe and quiet — a game rarely needs more).
        MAX_VOICES = 8

        # Start a sample sounding: add a voice to the mix (samples play together, they do
        # not cut each other off), remembering how many frames it runs for (from its length
        # and rate) so a looping voice can re-trigger itself at the end. A one-shot voice
        # simply falls silent there. Past MAX_VOICES the new one is dropped.
        def start_sample(node)
          info = @samples[node[:name]] ||
                 raise(ProgramError, "play_sample of undefined sample #{node[:name].inspect}")
          @audio << [:sample, node[:name]]
          return if @voices.size >= MAX_VOICES

          # A pitched voice reads its sample faster (higher notes) or slower (lower), so it
          # plays out in proportionally fewer or more frames.
          ratio = pitch_ratio(node[:pitch], info[:note])
          frames = [(info[:length].to_f / (info[:rate] * ratio) * FRAME_RATE).ceil, 1].max
          @voices << { name: node[:name], loop: node[:loop], volume: node[:volume], pitch: node[:pitch],
                       frames_left: frames, frames_total: frames }
          @peak_voices = [@peak_voices, @voices.size].max
        end

        # How much faster (>1) or slower (<1) a voice reads its sample when played at +pitch+
        # instead of the sample's recorded note +base+ — the frequency ratio. nil pitch plays
        # it at its recorded pitch (ratio 1).
        def pitch_ratio(pitch, base)
          return 1.0 unless pitch

          notes = RubyGBA::Music::NOTE_FREQUENCIES
          notes.fetch(pitch).to_f / notes.fetch(base || :C4)
        end

        # Stop a sample: drop its voices from the mix (or every voice, if no name is given).
        def stop_sample(node)
          @voices.reject! { |v| node[:name].nil? || v[:name] == node[:name] }
          @audio << [:stop_sample]
        end

        # Age every sounding voice by one frame. When a voice plays out, a looping one
        # starts over — logged again, so the loop shows up in the audio log — and a one-shot
        # leaves the mix.
        def advance_voices
          @voices.each do |voice|
            voice[:frames_left] -= 1
            next if voice[:frames_left].positive?

            if voice[:loop]
              voice[:frames_left] = voice[:frames_total]
              @audio << [:sample, voice[:name]]
            else
              voice[:done] = true
            end
          end
          @voices.reject! { |voice| voice[:done] }
        end

        def exec_call(name)
          func = @funcs[name] || raise(ProgramError, "call to undefined func #{name.inspect}")
          func.children.each { |child| exec(child) }
        end

        # Advance one timer by a frame's worth of overflows, and run its on_tick handler
        # once for each whole overflow it crosses this frame.
        def accrue_timer(name, timer)
          before = timer[:overflows].floor
          timer[:overflows] += timer[:hz].to_f / FRAME_RATE
          handler = @timer_handlers[name] or return
          (timer[:overflows].floor - before).times do
            handler.children.each { |child| exec(child) }
          end
        end

        # Whether a display mode uses the tiled system (a tilemap plus hardware
        # sprites) rather than the bitmap one (a linear framebuffer). This is the
        # boundary that flips which surface the console shows — the same test the DSL
        # uses to decide whether a scene's sprites are hardware or software — so the
        # two agree on when a scene crosses from one display system to the other.
        def tiled_mode?(mode)
          mode == :tiled
        end

        # Render a string with the built-in bitmap font: each set pixel of each
        # glyph becomes one painted cell, offset from the text's top-left origin.
        # Off-screen cells clip away in set_pixel, just as they do on hardware.
        def exec_draw_text(node)
          x = eval_value(node[:x])
          y = eval_value(node[:y])
          color = resolve_color(node[:color])
          Fonts.get(node[:font]).each_pixel(node[:text]) do |dx, dy|
            @screen.set_pixel(x + dx, y + dy, color)
          end
        end

        # Draw the run-time digit: work out which of 0..9 the value is and render
        # that one glyph. A value outside 0..9 draws nothing (a digit column always
        # holds a single digit, so this only guards against misuse).
        def exec_draw_digit(node)
          digit = eval_value(node[:value])
          return unless (0..9).cover?(digit)

          color = resolve_color(node[:color])
          Fonts.get(node[:font]).each_pixel(digit.to_s) do |dx, dy|
            @screen.set_pixel(node[:x] + dx, node[:y] + dy, color)
          end
        end

        # Resolve a beep's tone + overrides into the concrete musical values that
        # played — the shared rule, so the interpreter and the ROM agree on what a
        # given beep means.
        def resolve_effect(node)
          Sound.resolve_effect(node[:tone], duty: node[:duty], decay: node[:decay],
                                            volume: node[:volume], defined: @defined_sounds)
        end

        # Resolve a noise hit's preset + overrides into the concrete musical values
        # that played — the shared rule, so the interpreter and the ROM agree on
        # what a given hit means.
        def resolve_noise(node)
          Sound.resolve_noise(node[:preset], pitch: node[:pitch], decay: node[:decay],
                                             volume: node[:volume], metallic: node[:metallic])
        end

        # Record any note that lands on the song's CURRENT frame (frequency 0 is a
        # rest), across every part of the song, then advance the shared frame counter,
        # wrapping at the song's length so it loops. The counter starts at 0 and the
        # notes are played *before* advancing, so a note at frame 0 — the downbeat
        # every tune begins on — sounds. A layered song records each part's note on a
        # frame, all against the one counter, so the parts stay in lock-step. This
        # matches how the ROM sequences the same song.
        def exec_play_song(name)
          song = @songs[name] || raise(ProgramError, "play_song for undefined song #{name.inspect}")
          frame = @music_frames[name]
          song[:voices].each do |voice|
            voice[:events].each do |offset, frequency|
              @audio << [:note, name, frequency] if offset == frame
            end
          end
          total = song[:total_frames]
          @music_frames[name] = total.zero? ? 0 : (frame + 1) % total
        end

        # Multi-way dispatch: call the scene/func for the clause whose value equals
        # the variable. Values are distinct, so this runs at most one scene.
        def exec_case(node)
          value = @vars[node[:var]]
          node[:clauses].each do |clause_value, target|
            exec_call(target) if value == clause_value
          end
        end

        # Copy a defined bitmap onto the fake screen at (x, y).
        def exec_blit(node)
          blit_image(node[:name], eval_value(node[:x]), eval_value(node[:y]))
        end

        # Draw a tiled background by stamping each cell's tile onto the fake screen.
        # The map holds an index into the tile list per cell (nil = leave it blank).
        # A tile pixel that's the backdrop color (0) is transparent — left unpainted so
        # a background layer already on screen shows through it. That's how the console
        # composites stacked layers: the backmost paints first, and each layer in front
        # only covers where it has solid pixels, letting the layers behind fill its gaps.
        def exec_background(node)
          tiles = node[:tiles]
          tile_w = node[:tile_w]
          tile_h = node[:tile_h]
          node[:map].each_with_index do |row, r|
            row.each_with_index do |index, c|
              next if index.nil?

              stamp_tile(tiles, index, c * tile_w, r * tile_h, tile_w, tile_h)
            end
          end
        end

        # Paint one tile at (x0, y0), skipping its backdrop-colored (transparent) pixels
        # so whatever's already there shows through — the per-pixel form of a tile blit
        # that layering needs.
        def stamp_tile(tiles, index, x0, y0, tile_w, tile_h)
          tile_h.times do |ty|
            tile_w.times do |tx|
              color = background_pixel(tiles, index, tx, ty)
              @screen.set_pixel(x0 + tx, y0 + ty, color) unless color.zero?
            end
          end
        end

        # Scroll a background: record where its window now sits (its run-time offset)
        # and recomposite the frame. On the console this is one register write and the
        # tile hardware redraws the layer from that offset — sprites still float on top
        # for free; here we reproduce that by repainting the scrolled scene and drawing
        # the sprites back over it (see #composite_scrolled_frame).
        def exec_scroll_background(node)
          @bg_by_name.fetch(node[:name]) { raise ProgramError, "scroll of undeclared background #{node[:name].inspect}" }
          @bg_scroll[node[:name]] = [eval_value(node[:x]), eval_value(node[:y])]
          composite_scrolled_frame
        end

        # Repaint one background's visible window at its current scroll offset. The map
        # is a torus, so an offset past an edge wraps around — the same thing tile
        # hardware does, done here by sampling the map (with wrapping). A background
        # that has never scrolled sits at offset (0, 0).
        #
        # This walks the screen one TILE at a time, not one pixel at a time: pixels
        # side by side in a screen row come from the same tile until the next cell
        # begins, so the map lookup is done once per cell and the pixels in between are
        # painted as a run. A scrolling scene is repainted in full every frame, so this
        # inner loop is where a whole run's time goes.
        def paint_background_window(bg)
          tiles = bg[:tiles]
          map = bg[:map]
          tile_w = bg[:tile_w]
          tile_h = bg[:tile_h]
          # Wrap over the console's whole 32x32 cell grid, not over the rows the
          # author wrote (see MAP_CELLS). Sampling a cell past those rows finds no
          # tile there, and an absent tile reads as the backdrop.
          map_w = MAP_CELLS * tile_w
          map_h = MAP_CELLS * tile_h
          off_x, off_y = @bg_scroll[bg[:name]] || [0, 0]
          off_x %= map_w # Ruby % wraps negatives into 0..map_w-1
          off_y %= map_h
          width = @screen.width

          @screen.height.times do |py|
            my = (off_y + py) % map_h
            row = map[my / tile_h]
            next unless row # no cell row here — the backdrop stays, and layers behind show

            ty = my % tile_h # which of the tile's own rows this screen row lands on
            px = 0
            while px < width
              mx = (off_x + px) % map_w
              tx = mx % tile_w
              span = [tile_w - tx, width - px].min # up to the next cell, or the screen edge
              index = row[mx / tile_w]
              # A tile's see-through pixels are nil in its decoded art, so they're left
              # alone and whatever is behind this layer keeps showing there.
              @screen.paint_row(px, py, tile_colors(tiles[index]), from: (ty * tile_w) + tx, count: span) if index
              px += span
            end
          end
        end

        # A tile's pixels as colors, ready to paint, row after row in one flat list —
        # so the pixel at (tx, ty) is at (ty * width) + tx. A see-through pixel is nil,
        # which is how paint_row knows to leave that cell as it is.
        #
        # Tiles are fixed at build time and a scrolling background repaints the same
        # handful of them for every row of every frame, so each one is decoded once and
        # kept. That turns the packed bytes into colors a few dozen times instead of a
        # few million.
        def tile_colors(name)
          @tile_colors[name] ||= begin
            bmp = @bitmaps.fetch(name)
            pixels = @data.fetch(name)
            Array.new(bmp[:width] * bmp[:height]) do |i|
              color = (pixels.getbyte(i * 2) | (pixels.getbyte((i * 2) + 1) << 8)) & 0x7FFF
              color.zero? ? nil : color
            end
          end
        end

        # Rebuild the whole visible screen the way tile-and-sprite hardware does: paint
        # the backdrop, then the background layers from back to front (each scrolled to
        # its own offset, so nearer layers can slide faster than far ones — parallax),
        # then the sprites over the top in draw order. A fresh repaint means last frame's
        # sprites vanish with it — no save-under needed. Both scroll_background and
        # present_objects call this, so whichever runs last in a frame leaves the
        # settled, correct image regardless of their order.
        def composite_scrolled_frame
          @screen.clear(0) # the backdrop the layers' transparent pixels reveal
          @bg_nodes.each { |bg| paint_background_window(bg) }
          @obj_layer.each do |obj|
            if obj[:angle]
              blit_image_rotated(obj[:image], obj[:x], obj[:y], obj[:angle])
            else
              blit_image(obj[:image], obj[:x], obj[:y])
            end
          end
        end

        # The color of a background cell's pixel: the tile's pixel there, or the black
        # backdrop where the cell is empty (a map hole, which the hardware shows as
        # background-palette entry 0). A tile pixel marked transparent (bit 15 set) reads
        # as the backdrop (0) too — the tile hardware treats both as palette entry 0, so
        # both let a layer behind show through. Masking to 15 bits is how we match that.
        def background_pixel(tiles, index, x, y)
          return 0 if index.nil?

          bmp = @bitmaps.fetch(tiles[index])
          pixels = @data.fetch(tiles[index])
          i = ((y * bmp[:width]) + x) * 2
          (pixels.getbyte(i) | (pixels.getbyte(i + 1) << 8)) & 0x7FFF
        end

        # Draw this frame's objects the way sprite hardware does: composite each one
        # over the settled scene, leaving no trail. A console redraws the whole
        # picture — scene and sprites — every frame; here we get the same result more
        # cheaply by putting the clean scene back where each object was last drawn,
        # then drawing every object at its current spot. Two passes (erase all, then
        # draw all) so overlapping objects can't erase each other.
        #
        # When a background scrolls, the scene under the objects isn't fixed, so the
        # save-under trick can't restore it — instead we snapshot which objects are on
        # screen this frame and recomposite the whole view (scrolled scene, then these
        # objects on top). See #composite_scrolled_frame.
        def exec_present_objects(node)
          if @scrolling
            snapshot_object_layer(node)
            composite_scrolled_frame
            return
          end

          scene = scene_framebuffer
          node[:names].each do |name|
            prev = @obj_prev[name]
            restore_scene_rect(scene, name, prev) if prev
          end
          node[:names].each do |name|
            obj = @objects.fetch(name) { raise ProgramError, "present of undeclared object #{name.inspect}" }
            @obj_prev[name] = nil
            next unless eval_value(obj[:active]) == 1

            image = object_pose_image(obj)
            next if image.nil? # a pose index out of range shows nothing this frame

            x = eval_value(obj[:x])
            y = eval_value(obj[:y])
            draw_object(obj, image, x, y)
            @obj_prev[name] = [x, y]
          end
        end

        # Draw one object's picture at (x, y): straight when it never turns, rotated to
        # its current heading when it does. Shared by the still-scene present path and
        # the scrolling-scene recomposite.
        def draw_object(obj, image, x, y)
          return blit_image(image, x, y) unless object_rotates?(obj)

          blit_image_rotated(image, x, y, eval_value(obj[:angle]))
        end

        # Does this object turn? It does unless its angle is the constant 0 it defaults
        # to — an object that never calls turn/face_angle keeps that constant and draws
        # upright, so we take the cheaper straight-blit path for it.
        def object_rotates?(obj)
          angle = obj[:angle]
          !(angle.kind == :int && angle[:value].zero?)
        end

        # Capture the objects that are on screen this frame — their current pose picture
        # and position, in draw order — as the sprite layer #composite_scrolled_frame
        # paints over the scrolled scene. A hidden object, or one whose pose index is out
        # of range, simply isn't in the layer this frame.
        def snapshot_object_layer(node)
          @obj_layer = node[:names].filter_map do |name|
            obj = @objects.fetch(name) { raise ProgramError, "present of undeclared object #{name.inspect}" }
            next unless eval_value(obj[:active]) == 1

            image = object_pose_image(obj)
            next if image.nil?

            snap = { image: image, x: eval_value(obj[:x]), y: eval_value(obj[:y]) }
            snap[:angle] = eval_value(obj[:angle]) if object_rotates?(obj)
            snap
          end
        end

        # Which of an object's poses to draw right now — its pose selector picks one
        # of its same-size pictures (facing a direction, or an animation frame). An
        # index outside the set selects nothing.
        def object_pose_image(obj)
          poses = obj[:poses]
          index = eval_value(obj[:pose])
          poses[index] if index >= 0 && index < poses.length
        end

        # The settled scene the objects sit on — the backdrop plus every background —
        # rendered once into its own framebuffer. Backgrounds don't change once drawn,
        # so this is the clean picture we restore under a moving object each frame.
        def scene_framebuffer
          @scene_fb ||= begin
            fb = Framebuffer.new(fill: 0) # 0 = the backdrop the empty parts of the scene show
            drawing_into(fb) { @bg_nodes.each { |bg| exec_background(bg) } }
            fb
          end
        end

        # Put the clean scene back where an object was last drawn, erasing it before it's
        # redrawn at its new spot. All of an object's poses are the same size, so the
        # first pose gives the patch to restore — its own size for an upright object, or
        # the bigger square a turning object can cover at any angle.
        def restore_scene_rect(scene, name, (x, y))
          obj = @objects.fetch(name)
          bmp = @bitmaps.fetch(obj[:poses].first)
          if object_rotates?(obj)
            rx, ry, side = rotated_footprint(x, y, bmp[:width], bmp[:height])
            restore_patch(scene, rx, ry, side, side)
          else
            restore_patch(scene, x, y, bmp[:width], bmp[:height])
          end
        end

        # Copy a width×height patch of the settled scene back onto the screen (skipping
        # any cell that falls off it), erasing whatever an object had drawn there.
        def restore_patch(scene, x, y, width, height)
          height.times do |row|
            width.times do |col|
              color = scene.stored_pixel(x + col, y + row)
              @screen.set_pixel(x + col, y + row, color) unless color.nil?
            end
          end
        end

        # Draw an image turned +degrees+ clockwise about its own center, its upright
        # top-left at (x, y) — the reference interpreter's stand-in for the console's
        # sprite rotate/scale.
        #
        # The hardware does not turn the picture and stamp it down. It walks the patch
        # of screen the sprite covers and, for each screen pixel, turns the OTHER way to
        # ask "which pixel of the picture lands here?" — a pixel whose answer falls
        # outside the picture simply isn't drawn. That is what gives a turned sprite its
        # stepped edge, and it's why this reads as an inverse rotation.
        #
        # Three details have to match the hardware exactly, or the two backends disagree
        # along that edge:
        #
        #   * The patch is twice the picture's width and height, centered on it, so a
        #     corner swung out by the turn still has room (the console's "double size").
        #   * The turn uses whole numbers in 256ths, from the same table of sines the
        #     ROM carries — not exact trigonometry.
        #   * A screen pixel is taken at its whole coordinate, NOT at its center, and
        #     the answer is rounded down. Sampling at pixel centers instead moves the
        #     whole shape half a pixel, which shows up as a one-pixel-thick disagreement
        #     all along one side.
        def blit_image_rotated(name, x, y, degrees)
          bmp = @bitmaps.fetch(name) { raise ProgramError, "blit of undefined image #{name.inspect}" }
          pixels = @data.fetch(name)
          transparent = bmp[:transparent]
          w = bmp[:width]
          h = bmp[:height]
          cos = fixed_sine(degrees + 90) # cos d is sin(d + 90) — one table serves both
          sin = fixed_sine(degrees)
          left = x - (w / 2) # the double-size patch: half a picture out on every side
          top = y - (h / 2)

          (h * 2).times do |iy|
            ddy = iy - h # offset from the patch's center, in whole pixels
            (w * 2).times do |ix|
              ddx = ix - w
              # Turn back to the picture. The matrix is in 256ths, so shifting down by
              # 8 both scales it back and rounds down, exactly as the console does.
              sx = (((cos * ddx) + (sin * ddy)) >> 8) + (w / 2)
              sy = (((-sin * ddx) + (cos * ddy)) >> 8) + (h / 2)
              next unless sx >= 0 && sx < w && sy >= 0 && sy < h

              i = ((sy * w) + sx) * 2
              color = pixels.getbyte(i) | (pixels.getbyte(i + 1) << 8)
              next if transparent && color == transparent

              @screen.set_pixel(left + ix, top + iy, color)
            end
          end
        end

        # sin(+degrees+) in 256ths, as a whole number — the same table the ROM carries,
        # so both backends turn a sprite through exactly the same matrix.
        def fixed_sine(degrees)
          (Math.sin((degrees % 360) * Math::PI / 180.0) * 256).round
        end

        # The square of screen a width×height picture can cover at any rotation about
        # its center: the side is the picture's diagonal (rounded up, plus a small
        # margin so a corner never clips), centered on the picture. This is the patch
        # put back under a turning object before it's redrawn — one square that holds
        # the picture at every angle, so the erase doesn't depend on the angle it was
        # last drawn at. A turned draw can never paint outside it: a source pixel is at
        # most half the picture's diagonal from the center, and turning doesn't change
        # that distance.
        def rotated_footprint(x, y, w, h)
          side = Integer.sqrt((w * w) + (h * h)) + 2
          cx = x + (w / 2)
          cy = y + (h / 2)
          [cx - (side / 2), cy - (side / 2), side]
        end

        # Run a block with the draw ops pointed at +target+ instead of the visible
        # screen, then restore. Lets scene-building reuse the ordinary draw path.
        def drawing_into(target)
          saved = @screen
          @screen = target
          yield
        ensure
          @screen = saved
        end

        # Draw whichever pose the run-time index selects — the sprite facing the way
        # it moves, or a frame of an animation. An index outside the set draws
        # nothing (the selector is always within range in practice).
        def exec_blit_pose(node)
          index = eval_value(node[:index])
          poses = node[:poses]
          return unless index >= 0 && index < poses.length

          blit_image(poses[index], eval_value(node[:x]), eval_value(node[:y]))
        end

        # Copy a defined bitmap onto the fake screen with its top-left at (x, y). Each
        # pixel is a little-endian 15-bit halfword in the stored bytes; set_pixel
        # clips any that fall off-screen, matching how the hardware framebuffer
        # behaves, and a transparent pixel is skipped so the background shows through.
        def blit_image(name, x, y)
          bmp = @bitmaps.fetch(name) { raise ProgramError, "blit of undefined image #{name.inspect}" }
          pixels = @data.fetch(name)
          transparent = bmp[:transparent]

          bmp[:height].times do |row|
            bmp[:width].times do |col|
              i = ((row * bmp[:width]) + col) * 2
              color = pixels.getbyte(i) | (pixels.getbyte(i + 1) << 8)
              next if transparent && color == transparent
              @screen.set_pixel(x + col, y + row, color)
            end
          end
        end

        # --- per-pixel collision (do two sprites' solid pixels actually touch?) ---

        # True when a non-transparent pixel of one posed sprite lands on a
        # non-transparent pixel of the other. Each side names its current picture (from
        # its poses and run-time pose), and where it sits; we walk only the rectangle
        # where their boxes overlap and stop at the first pixel solid in both.
        def pixels_overlap?(node)
          a = collision_sprite(node[:a_poses], node[:a_pose], node[:a_x], node[:a_y])
          b = collision_sprite(node[:b_poses], node[:b_pose], node[:b_x], node[:b_y])
          x0 = [a[:x], b[:x]].max
          y0 = [a[:y], b[:y]].max
          x1 = [a[:x] + a[:w], b[:x] + b[:w]].min
          y1 = [a[:y] + a[:h], b[:y] + b[:h]].min
          return false if x0 >= x1 || y0 >= y1

          (y0...y1).each do |y|
            (x0...x1).each do |x|
              return true if solid_pixel?(a, x - a[:x], y - a[:y]) && solid_pixel?(b, x - b[:x], y - b[:y])
            end
          end
          false
        end

        # The picture a posed sprite is showing right now, with where it sits — what
        # #pixels_overlap? needs to read its solid pixels.
        def collision_sprite(poses, pose_node, x_node, y_node)
          name = poses[eval_value(pose_node)]
          bmp = @bitmaps.fetch(name)
          { pixels: @data.fetch(name), w: bmp[:width], h: bmp[:height],
            transparent: bmp[:transparent], x: eval_value(x_node), y: eval_value(y_node) }
        end

        # Whether pixel (col, row) of a sprite's picture is drawn (not its see-through
        # colour) — the same "skip the transparent pixel" test the blit uses.
        def solid_pixel?(sprite, col, row)
          i = ((row * sprite[:w]) + col) * 2
          color = sprite[:pixels].getbyte(i) | (sprite[:pixels].getbyte(i + 1) << 8)
          transparent = sprite[:transparent]
          transparent.nil? || color != transparent
        end

        # --- backing store (save the pixels under a moving object, then put them back) ---

        # Copy the buffer-sized screen patch at (x, y) into the named backing buffer.
        # An off-screen cell reads as nil (there's nothing out there to remember);
        # restore skips those, so a patch hanging off an edge round-trips cleanly.
        # Boot-load the persisted variables from the save store. When the store
        # already carries this program's marker, each variable takes its saved value;
        # otherwise (a fresh cartridge) each takes its default, and the defaults plus
        # the marker are written so the next boot loads them. Mirrors the GBA lowering.
        def exec_save_init(node)
          if @save[:magic] == node[:magic]
            node[:vars].each { |v| @vars[v[:name]] = Int32.wrap(@save[v[:slot]]) }
          else
            node[:vars].each do |v|
              value = Int32.wrap(v[:default])
              @vars[v[:name]] = value
              @save[v[:slot]] = value
            end
            @save[:magic] = node[:magic]
          end
        end

        # Mirror one persisted variable's current value into its save slot.
        def exec_save_store(node)
          @save[node[:slot]] = @vars[node[:var]]
        end

        def exec_save_region(node)
          buf = backing_for(node[:buffer])
          x = eval_value(node[:x])
          y = eval_value(node[:y])
          w = buf[:width]
          h = buf[:height]
          cells = Array.new(w * h)
          h.times do |row|
            w.times { |col| cells[(row * w) + col] = @screen.stored_pixel(x + col, y + row) }
          end
          buf[:pixels] = cells
        end

        # Paint a saved patch back onto the screen at (x, y). A restore before any
        # save has nothing to put back (pixels still nil). Cells that were off-screen
        # when saved (nil) are skipped rather than painted with a guessed color.
        def exec_restore_region(node)
          buf = backing_for(node[:buffer])
          cells = buf[:pixels]
          return if cells.nil?

          x = eval_value(node[:x])
          y = eval_value(node[:y])
          w = buf[:width]
          h = buf[:height]
          h.times do |row|
            w.times do |col|
              color = cells[(row * w) + col]
              @screen.set_pixel(x + col, y + row, color) unless color.nil?
            end
          end
        end

        # The backing buffer stored under a name, or a friendly error if the program
        # never declared it.
        def backing_for(name)
          @backing[name] ||
            raise(ProgramError,
                  "backing buffer #{name.inspect} was used before it was created — " \
                  "declare it first (a sprite does this for you)")
        end

        # --- lists ---
        #
        # The bounds checks live here (not in ListValue) so a violation becomes one
        # friendly, plain-language error naming the list — the same "tell them what
        # happened and how to fix it" the DSL promises everywhere else.

        # The list stored under a name, or a friendly error if the program never
        # created it (a `list_get`/`push` before its `list :name, capacity: N`).
        def list_for(name)
          @lists[name] ||
            raise(ProgramError,
                  "list #{name.inspect} was used before it was created — " \
                  "create it first with `list #{name.inspect}, capacity: N`")
        end

        def exec_list_push(node)
          list = list_for(node[:name])
          if list.full?
            raise ProgramError,
                  "list #{node[:name].inspect} is full (capacity #{list.capacity}) — " \
                  "drop an item first (shift/pop) or create it with a larger capacity"
          end
          list.push(eval_value(node[:value]))
        end

        def exec_list_drop(node)
          list = list_for(node[:name])
          from = node[:from] # :front (a shift) or :back (a pop)
          if list.empty?
            raise ProgramError,
                  "list #{node[:name].inspect} is empty — " \
                  "there is nothing to #{from == :front ? 'shift' : 'pop'}"
          end
          from == :front ? list.shift : list.pop
        end

        def exec_list_set(node)
          list = list_for(node[:name])
          index = eval_value(node[:index])
          check_list_index!(list, node[:name], index)
          list.set(index, eval_value(node[:value]))
        end

        def eval_list_get(node)
          list = list_for(node[:name])
          index = eval_value(node[:index])
          check_list_index!(list, node[:name], index)
          list.get(index)
        end

        # Read table[index] from a ROM table. An out-of-range index is made safe the
        # same way the GBA lowering does it, so the two backends agree: a power-of-two
        # table wraps the index, any other size clamps it to the ends — the read always
        # lands on a real element. The value comes back exactly as authored (the table's
        # signedness only decides how the console stores/sign-extends it).
        def eval_table_get(node)
          table = @tables.fetch(node[:name]) do
            raise ProgramError, "reference to undefined table #{node[:name].inspect}"
          end
          values = table[:values]
          Int32.wrap(values[safe_table_index(eval_value(node[:index]), values.length)])
        end

        # Clamp/wrap an index into a table's bounds (the shared out-of-range rule).
        def safe_table_index(index, count)
          if count.positive? && (count & (count - 1)).zero?
            index & (count - 1) # power of two: wrap, like an angle
          else
            index.clamp(0, count - 1)
          end
        end

        def check_list_index!(list, name, index)
          return if list.index?(index)

          if list.empty?
            raise ProgramError,
                  "index #{index} is out of range — list #{name.inspect} is empty"
          end
          raise ProgramError,
                "index #{index} is out of range for list #{name.inspect} — " \
                "valid indexes are 0..#{list.length - 1}"
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
          # A hardware-only value (reading the live scanline) has no meaning off the
          # console — the interpreter has no real timing to report. Refuse it plainly
          # rather than invent a number, the same stance exec takes for hardware-only
          # statements. Which value kinds are hardware-only comes from IR::Portability.
          if Portability.hardware_only?(node.kind)
            raise ProgramError,
                  "the reference backend can't evaluate #{node.kind.inspect} — it's a hardware-only value the " \
                  "interpreter can't model; it only means something on real hardware"
          end

          case node.kind
          when :int then Int32.wrap(node[:value])
          when :var_ref then @vars[node[:name]]
          when :neg then Int32.neg(eval_value(node[:operand]))
          when :binop then eval_binop(node[:op], eval_value(node[:lhs]), eval_value(node[:rhs]))
          when :mul_fix
            Int32.mul_fix(eval_value(node[:lhs]), eval_value(node[:rhs]), node[:fraction_bits])
          when :shift_right
            Int32.shift_right(eval_value(node[:operand]), node[:bits])
          when :held then bool(button_held?(node[:button]))
          when :pressed then bool(button_pressed?(node[:button]))
          # A chance holds when the random draw lands below the threshold.
          when :chance then bool(eval_value(node[:draw]) < node[:percent])
          when :pixels_overlap then bool(pixels_overlap?(node))
          when :data_byte then data_byte(node[:name], node[:index])
          when :table_get then eval_table_get(node)
          when :list_get then eval_list_get(node)
          when :list_len then list_for(node[:name]).length
          when :timer_ticks then timer_ticks(node[:name])
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

        # How many whole times a timer has overflowed since it started, wrapped at
        # 65536 to match the 16-bit hardware counter. Zero for a timer never started.
        def timer_ticks(name)
          timer = @timers[name]
          Int32.wrap(timer ? timer[:overflows].floor % 65_536 : 0)
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

        # Naming an unknown button is almost always a typo, and one that would
        # silently read as "never held" — so reject it with a friendly error
        # instead of leaving a ghost bug. The vocabulary is the shared IR contract.
        def check_button!(button)
          return button if IR::Buttons.known?(button)

          raise ProgramError,
                "unknown button #{button.inspect} — known buttons are #{IR::Buttons::NAMES.join(', ')}"
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
