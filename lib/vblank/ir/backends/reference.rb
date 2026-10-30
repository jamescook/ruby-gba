# frozen_string_literal: true

require "set"

require_relative "reference/framebuffer"
require_relative "reference/list_value"
require_relative "reference/mixer"
require_relative "reference/player"
require_relative "reference/reading_back"
require_relative "reference/save_writing"
require_relative "reference/sprite_blocks"
require_relative "reference/turned_box"

module VBlank
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
        include SaveWriting

        # The error every backend raises for a program that goes wrong (IR::ProgramError), under
        # the name the interpreter has always given it.
        ProgramError = IR::ProgramError

        # A table as this backend needs it: the numbers themselves, because it reads them
        # to run the program. What the asset IS lives in IR::Assets, shared with every
        # backend; a table has no shared shape, since the one that lowers to a cartridge
        # keeps where the numbers were packed instead of the numbers.
        TableValues = Data.define(:values, :signed)

        # A generous cap so an accidental infinite loop can't hang a test forever.
        # It's the runaway guard, not the usual stop — see DEFAULT_FRAMES. A run counting
        # frames spends it per FRAME, and a frame that draws a whole view is a few thousand
        # steps, so there's room to spare in one and none of it can be taken from the frames
        # that come after.
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

        # A background's map is a fixed grid of cells on the console — 32 or 64 a side —
        # however few the author actually filled in. That matters as soon as the
        # background scrolls: the visible window moves over the WHOLE grid, so past the
        # filled-in part you see empty cells (the backdrop), and the picture only comes
        # round again at the grid's edge. Wrapping at the author's own map size instead
        # would repeat a small map across the screen forever, which the console never
        # does. Which size a map gets is {IR::TileMap}'s answer, shared with every other
        # backend so they cannot disagree about where a background comes round.

        attr_reader :vars, :log, :frame, :screen_mode, :buffered, :audio, :save

        # WHAT THE RUN MADE A NOISE ABOUT, read back through the mixer that kept it. The
        # interpreter holds no audio state of its own: {Mixer} keeps the voices and {Player}
        # keeps the tune, and these stay here because a test asks the interpreter what happened
        # rather than asking its parts.
        def peak_voices = @mixer.peak

        # The names of the samples sounding right now — see {Mixer#sounding}.
        def active_samples = @mixer.sounding

        # EVERY FRAME'S SLICE OF SOUND, oldest first, each the signed samples the cartridge's
        # mixer writes for that frame (see Mixer#mix). Empty for a program with no recording.
        def mixed_sound = @mixer.slices

        # ...and whose each of them is — see {Mixer#owners}.
        def sound_owners = @mixer.owners

        # What this run could not play — see {Mixer#drops}.
        def sound_drops = @mixer.drops

        # The level a currently-sounding sample is playing at — see {Mixer#volume_of}.
        def volume_of(name) = @mixer.volume_of(name)

        # How far through its own shape a sounding note is — see {Mixer#level_of}. What a test
        # reads to watch a note fall away rather than stop.
        def level_of(name) = @mixer.level_of(name)

        # THE SPRITES THIS RUN IS DRAWING, each knowing which one the game declared it for.
        #
        # One Hash per sprite on screen as the last frame left it — +:name+, +:x+, +:y+ and
        # +:picture+, which is the one of its pictures the pose selector picked. Name a sprite
        # and only its rows come back.
        #
        # Worth having because the finished picture cannot answer several ordinary questions: it
        # cannot tell a sprite the game switched off from one drawn in the backdrop colour, from
        # one behind a background, or from one a pixel off the edge. A sprite that is not being
        # drawn is left out, which is the answer a test wants.
        #
        # THE SAME QUESTION THE CONSOLE ANSWERS, so a test reads the same way against either
        # (see {Verifier#sprites}) — with one thing deliberately missing. The console has 128
        # places to put a sprite in and its table says which place each row is in; there are no
        # places here, and naming one was the thing worth removing. So a row says whose it is
        # and what it is showing, and nothing about where the framework put it.
        #
        # Rows this cannot name come back with a nil +:name+ — a glyph of tiled text, say, which
        # is drawn as a sprite the author named nothing for.
        #
        # @param name [Symbol, nil] keep only this declared sprite's rows; nil for every row
        # @return [Array<Hash>]
        def sprites(name = nil)
          rows = @drawn.map do |on|
            VBlank::Diagnostics::DrawnSprite.new(name: on[:name], x: on[:x], y: on[:y], picture: on[:picture])
          end
          return rows if name.nil?

          known = @objects.each_value.filter_map(&:declared).uniq
          unless known.include?(name)
            raise ArgumentError, "This game has no sprite #{name.inspect}. " \
                                 "Its sprites are: #{known.map(&:inspect).join(', ')}."
          end
          rows.select { |row| row.name == name }
        end

        # WHETHER THE CARTRIDGE'S MOTOR IS RUNNING on the frame the screen shows now (`rumble`,
        # #exec_rumble): never on a console whose cartridge has no motor.
        def motor_on? = @motor_on

        # +save+ is the cartridge's save memory (an IR::SaveImage) — it outlives the
        # interpreter, so passing the SAME one to two Reference.new(...).run calls models
        # a power cycle (the second boot sees what the first one saved). Defaults to a
        # fresh one: a brand-new cartridge, and untouched by programs that persist nothing.
        def initialize(save: SaveImage.new)
          unless save.is_a?(SaveImage)
            raise ArgumentError, "save: must be a VBlank::IR::SaveImage. To make an empty save memory, " \
                                 "write VBlank::IR::SaveImage.new."
          end

          @save = save
          @vars = Hash.new(0)      # variable store; an unwritten variable reads as 0
          @funcs = {}              # name -> :func node
          @console = Nodes::Program.unbound_console # until a program says which (see #size_screen_for)
          # the fake screen the draw ops write into
          @screen = Framebuffer.new(width: @console.screen_width, height: @console.screen_height)
          @held = Set.new          # buttons down right now
          @seen = Set.new          # buttons down at the last frame the screen showed
          @pressed = Set.new       # buttons that went down since the last pass took its presses
          @screen_frame = 0        # frames the screen has shown, which a pass may span several of
          @input_script = nil      # optional ->(frame) { buttons } to drive input over time
          @frames_script = nil     # optional ->(pass) { frames } to say a pass ran late
          @frames_setting_up = 0   # frames the screen was off for before the first (see #frames_setting_up)
          @motor_on = false        # the cartridge's motor, on the frame shown now (see #motor_on?)
          @clock_started = nil     # the moment the cartridge's clock read at power-on, or nil for no clock
          @clock_set = true        # ...and whether it was ever set (see #clock_at)
          @clock_keeps_date = nil  # ...and whether it keeps the date, when not the console's chip
          @frame = 0               # passes of the game loop finished (see @screen_frame for frames shown)
          @screen_mode = nil       # the mode a `screen` op selected, if any
          @backdrop = 0            # the colour shown wherever nothing is drawn (`screen ... backdrop:`), black unless said
          @buffered = false        # whether that mode opted into double buffering
          @log = []               # observable events: [:vblank, n], [:halt]
          @defined_sounds = {}     # name -> musical params (from define_sound)
          @data = {}               # name -> bytes (embedded data blobs)
          @bitmaps = {}            # name -> { width:, height: } (a blob that has a shape)
          @tile_runs = {}          # name -> the TileRun whose tiles are painted from a list
          @tile_colors = {}        # name -> its pixels as colors, decoded once (nil = see-through)
          @backing = {}            # name -> { width:, height:, pixels: } (saved patch under a moving object)
          @objects = {}            # name -> :object node (a composited moving picture)
          @recolor_maps = {}       # [a picture, a list it is drawn with] -> an Assets::Recolor
          @bg_swaps = {}           # [a background, which of its steps] -> each own list's colours in that step
          @bg_nodes = []           # :background nodes, in order (the static scene under the objects)
          @bg_by_name = {}         # name -> :background node (for scrolling that background's window)
          @scene_fb = nil          # the settled scene (backdrop + backgrounds), built once, to restore under objects
          @scene = nil             # the scene that last took over (see #take_over)
          @obj_prev = {}           # object name -> [x, y] it was last drawn at (to erase before redrawing)
          @drawn = []              # ...and what this frame put on screen: which picture, where, whose
          @sprites_hidden = false  # is the next frame drawn without its sprites? (see #exec_hide_sprites)
          @repaints = false        # must the whole view be rebuilt every frame? (decided in collect_definitions)
          @bg_scroll = {}          # background name -> [x, y] its window is currently offset to
          @bar_top = {}            # status bar name -> the screen row its top was last placed at
          @bg_maps = {}            # ...and this run's own copy of its cells, once any of them has changed
          @bg_from_corner = Set.new # backgrounds put up this pass, shown unscrolled (see #put_up_background)
          @bg_corners_expired = false # ...once their pass has ended, until its picture is painted
          @row_bends = {}          # background name -> :scroll_rows node giving each row its own offset
          @bend_rows = {}          # background name -> every row's offset, worked out once a pass
          @shade = nil             # the :shade_outside node of the game's light, if it has one
          @bg_affine = {}          # background name -> the Turn it is being drawn under this frame
          @bg_colors = {}          # ...and which of the lists of colours it was given is drawing it
          @color_lists = {}        # a list of colours that can hold other colours -> its declaration
          @picture_groups = {}     # sprite pictures in groups -> the declaration (see #refuse_pictures_not_up!)
          @groups_up = {}          # ...and the group each of its slots holds, PictureGroups::NONE for none
          @held_colors = {}        # ...and which of its other sets it holds now
          @obj_layer = []          # sprites to composite over a scrolling scene, in draw order (later = in front)
          @fade_placed = nil       # [layer, toward, amount] while a fade sits under a layer rather than over everything
          @names_at_or_above = {}  # layer -> the names of everything in it and in front of it
          @block = 1               # how many pixels a block of the picture is each way (see #exec_pixelate)
          @block_kept = []         # ...and the names of what is left as drawn all the same (see #place_blocks)
          @lists = {}              # name -> ListValue (a bounded, run-time-sized collection)
          @layer_stack = []        # the layers the program declared, backmost first
          @see_through = nil       # ...and which of them you can see through, and by how much
          @bg_shown = []           # the backgrounds painted onto the screen so far, in that order
          @tables = {}             # name -> { values:, signed: } (a read-only ROM table)
          @timers = {}            # name -> { hz:, running:, parts: } (a hardware timer; see #accrue_timer)
          @timer_handlers = {}    # name -> on_timer node whose body runs on each overflow
          @audio = []             # observable audio: [:enabled], [:beep, ..], [:note, ..]
          # SOUND IS NOT KEPT HERE. The voices several recorded sounds share are {Mixer}'s, and
          # the tune walking its parts is {Player}'s — which holds the mixer, because a recorded
          # part's note sounds on one of its voices. Both write what happened into the one audio
          # log above, so everything a run made a noise about stays in order.
          @mixer = Mixer.new(log: @audio)
          @player = Player.new(mixer: @mixer, log: @audio)
          @on_vblank = nil         # optional ->(frame) { } called each vblank, to watch a run frame by frame
        end

        # Execute a program (or any statement node) until it ends naturally, hits
        # a `halt`, runs the requested number of `frames:`, or exhausts the step
        # budget — whichever comes first. Returns self so callers can chain and
        # then inspect variables.
        #
        # Pass `frames:` to play a game loop for exactly N frames and stop with the
        # Nth frame fully drawn (a settled screen, never a torn mid-frame) — the
        # natural way to say "play this far in", and how the emulator tests express it
        # too. It's the stop condition when given, and every one of those frames is
        # played however much work each takes: `max_steps` is then the budget for ONE
        # frame (it starts again at each vblank), guarding the runaway case of a frame
        # that never reaches one. A frame that spends the whole budget raises, since
        # there's no boundary ahead to stop cleanly on. The exception is a program that
        # never reaches a vblank at all (an unpaced `frame_sync: :manual` loop): it has no
        # frames for `frames:` to count, so the budget stops it and #stopped_at_budget?
        # says so.
        #
        # Cap neither and a game loop stops after DEFAULT_FRAMES — small and cheap,
        # since a handful of frames is all most tests need; pass a larger `frames:`
        # to play further. Passing `max_steps:` alone opts back into a whole-run step
        # budget: it stops the run wherever it has got to (at the next frame boundary
        # if the program has frames), and #stopped_at_budget? says that's what happened.
        def run(node, max_steps: nil, frames: nil)
          frames = DEFAULT_FRAMES if frames.nil? && max_steps.nil?
          @frames_limit = frames
          @max_steps = max_steps || DEFAULT_MAX_STEPS
          # Past a whole-run budget a frame-based program runs on to the next frame boundary
          # (so it stops on a complete screen, never a torn mid-frame); the hard cap bounds
          # the rare case where that boundary never comes (a loop that stops calling vblank).
          # Neither applies to a run counting frames, which has a per-frame budget instead.
          @hard_cap = @max_steps * 2
          @steps = 0
          @stopped_at_budget = false
          @over_budget = false
          @uses_frames = false # set once the program reaches its first vblank (advance_frame)
          @setting_up_uncounted = @frames_setting_up # counted at the first frame (#store_frame_counters)
          @placing_at_pass_end = false # while a boundary write placed at the end of a pass runs (#exec_loop)
          @loops_running = [] # the game loops running, innermost last (#place_pass_end_before_halt)
          @rumble_left = 0 # frames the motor has still to run for (#exec_rumble)
          @rumble_bits = 0 # ...and its pattern, the next frame's bit at the top
          @motor_on = false
          size_screen_for(node)
          collect_definitions(node)
          start_mixer_clock(node)
          @save.use_memory!(SaveLayout.memory_of(node))
          refuse_too_many_layers!(node)
          refuse_too_many_sprites!(node)
          refuse_poses_with_different_colors!(node)
          refuse_two_see_through_layers!(node)
          # How the picture stacks: what scenery and objects there are, in what order,
          # and how deep each sits. Scenery in FRONT of an object means the save-under
          # trick cannot hold — what was saved from under an object is no longer what
          # ends up over it — so the whole view is rebuilt each frame instead, the same
          # way a scrolling scene is.
          @picture = IR::Stacking.picture(node)
          @handover = IR::SceneHandover.of(node)
          # Does the game show both a painted screen and one drawn from tiles, at different
          # times? Then the painted one is left alone by what rebuilds the other (see
          # #request_repaint).
          @changes_screen_kind = IR::Modes.resolve(node).crosses_display_systems?
          # Which part of the display each fade in this program uses. Settled here rather
          # than asked per fade, because the answer is about the whole program (see
          # IR::Fading) and a fade walked over frames runs on every one of them.
          @fading = IR::Fading.resolve(node)
          @repaints ||= IR::Stacking.scenery_over_objects?(@picture.depths,
                                                           scenery: @picture.scenery,
                                                           objects: @picture.objects)
          # An effect placed in the stack reaches what is behind it and leaves what is in
          # front alone, so it has to be applied while the picture is built rather than
          # over the finished one. That is the rebuild path too.
          @repaints ||= node.walk.any? { |child| child.kind == :fade && child.under }
          # ...and so is a picture shown in blocks: each part of it is put into blocks by
          # itself, before the parts go over one another.
          @repaints ||= node.walk.any? { |child| child.kind == :pixelate }
          place_blocks(node)
          @repaints ||= see_through_picture_changes?(node)
          # A see-through sprite is mixed with the scenery under it and never with another
          # sprite, so a screen that has one keeps its scenery apart (see
          # Framebuffer#keep_scenery).
          @screen.keep_scenery if see_through_sprites?
          # A program that waits for frames shows nothing until the first one has been set up:
          # everything said before the game loop reaches the screen by work done between
          # frames, so the picture is held off until then — the console does the same (see
          # Backends::GBA::Drawing#initial_forced_blank_bit). A program that never waits has
          # no first frame to wait for, and shows what it draws as it draws it.
          @screen.held = node.walk.any? { |child| child.kind == :wait_vblank }
          catch(:halt) { exec(node) }
          self
        ensure
          @save.restore_power # a cut is for one run, so the next run turns the console on again
        end

        # The screen is the one the program was built for (Program#described_console): a game laid
        # out on a smaller console's screen is drawn on that screen here too. A tree made by hand
        # with no program at its root is played the way an unbound program is.
        def size_screen_for(node)
          return unless node.kind == :program

          @console = node.described_console
          width, height = @console.screen_size
          return if [@screen.width, @screen.height] == [width, height]

          @screen = Framebuffer.new(width: width, height: height)
        end

        # A picture the size of the screen, for painting part of the scene onto by itself.
        def framebuffer_like_screen(fill:) = Framebuffer.new(width: @screen.width, height: @screen.height, fill: fill)
        private :size_screen_for, :framebuffer_like_screen

        # The picture, painted up to date first if a repaint is owed (see #request_repaint).
        def screen
          paint_owed_repaint
          @screen
        end

        # Read a variable's current value (0 if it was never written).
        def [](name)
          @vars[name]
        end

        # #list, #pool and #game_state: a game's own state read back by the names it gave it.
        include ReadingBack

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

        # Drive input that changes over time. The block is called for each frame the
        # screen shows, with its number (1, 2, 3, …), and returns the buttons held for
        # that frame — the headless equivalent of a player working the pad frame
        # by frame. Needed to observe edges (see `pressed`). A pass said to take several
        # frames (#frames_each_pass) calls it once for each of them, so a tap can start
        # and end inside one slow pass. Returns self.
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

        # SAY THAT A PASS RAN LATE. The block is called at each pass with the pass number
        # (1, 2, 3, …) and gives back how many frames that pass took — one on a program
        # that keeps up, more on one that does not. Every one of them moves the music, the mix
        # and the buttons on, as the console's interrupt does; what the game reads of it (the
        # catching up `once_a_frame` and a beat do) is held at the same cap the console holds it
        # at, so a block that says a hundred has a body caught up ten times.
        #
        # This is here because being late is the one thing this interpreter cannot find out
        # for itself: it has no clock, a frame is over when the program says so, and a pass
        # can never overrun one. That is the right answer for an oracle — but it leaves
        # everything a program does ABOUT being late untestable here, and what a program
        # does about being late is exactly the interesting part. So a test says it instead,
        # the way it says which buttons are held.
        #
        # WHAT IT MOVES, and it is only this: how many frames the pass just ended answers
        # for. A `once_a_frame` body runs that many times, a beat in frames counts that
        # many, a one-shot's counter jumps that far, a song moves on that many frames, a
        # recording the game plays is that many frames further through, and the buttons are
        # read that many times (the input script is called once for each).
        # It does NOT make the interpreter slow — a timer still accrues a pass's worth, and
        # `frames:` still counts passes.
        # Nothing here pretends to be a clock; it pins what a program MEANS when the console
        # tells it the truth. Returns self.
        def frames_each_pass(&block)
          @frames_script = block
          self
        end

        # SAY THAT SETTING UP TOOK +count+ FRAMES WITH THE SCREEN OFF, before the first frame it
        # shows. A console whose screen draws nothing while it is off — the Color's — reads its
        # buttons and plays its music from the screen's interrupt, which those frames never raise,
        # so they move nothing on but `frames_since_power_on`, which counts them at the first
        # frame. (A screen that is on while the game sets up is #frames_each_pass's first pass.)
        # Returns self.
        def frames_setting_up(count)
          @frames_setting_up = count
          self
        end

        # GIVE THE CARTRIDGE A CLOCK, reading +time+ at power-on, the way #hold gives it buttons.
        # It moves on one of the console's frames for every frame the screen shows — a little more
        # than a sixtieth of a second (Console::Description#frame_seconds), so a run of sixty frames sees a
        # second go by — however many passes of the game loop those took. With
        # +set: false+ the clock is there and was never set, which a game can ask (`clock.set?`).
        #
        # A run never told reads no clock at all (`clock.present?` is false), which is what a
        # cartridge without the chip reads — so nothing a test checks ever depends on the time it
        # happens to be when the test runs.
        #
        # The chip is the one the program's console carries: on a console whose chip keeps no date
        # (Console::Description#clock_keeps_date) it counts days from the day +time+ names, the game
        # reads no date until it sets one, and +set: false+ is a chip that stopped, which setting
        # the clock starts again. +keeps_date+ says which kind of chip it is instead,
        # for a run checked against a cartridge for another console than the one the program was
        # built for. Returns self.
        def clock_at(time, set: true, keeps_date: nil)
          @clock_started = time
          @clock_set = set
          @clock_keeps_date = keeps_date
          self
        end

        private

        # CAN WHAT IS SEEN THROUGH A LAYER CHANGE WHILE NOTHING MOVES? Then the picture is one
        # that is built again from the scenery, like a scrolled one, and the sprites have to
        # be kept for that build rather than painted once onto a picture that stays.
        #
        # Two things do it. A see-through amount the game works out, which is told again
        # before each frame (the only program with a :see_through statement). And a fade the
        # display itself does, in a program with a see-through layer: the display blends two
        # layers or fades the picture, never both, so the layer is solid while the fade is on
        # and see-through again when it lifts (see #exec_fade).
        #
        # A PICTURE THAT STAYS CANNOT HOLD EITHER. Its sprites are painted onto it once and
        # are not kept to paint again, and the copy of the scenery it keeps to put back where
        # a sprite was (see #scene_framebuffer) is painted into a buffer of its own, which
        # knows of no fade and holds the layer as it was seen through when the copy was made.
        def see_through_picture_changes?(program)
          return false unless @see_through

          program.walk.any? do |child|
            child.kind == :see_through || (child.kind == :fade && !@fading.palette_walk?(child))
          end
        end

        # Is anything in the see-through layer a sprite?
        def see_through_sprites?
          !@see_through.nil? && @objects.each_value.any? { |obj| @see_through.key?(obj.layer) }
        end

        # REFUSE A PROGRAM THE CONSOLE COULD NOT SHOW, before drawing a frame of it.
        #
        # This interpreter is the answer key: a game's own tests run here because it is
        # fast and needs no emulator, and what it says has to be what the console would
        # say. Nothing stops it painting five background layers — it has no layers, only
        # a picture — so without this a game got a green suite here and a failed build
        # from the cartridge later, over a fact about the console that was knowable from
        # the program all along.
        #
        # The rules and their words live with the guardrails Checks::LayerRefusals lists, which the build
        # and the cartridge lowering both ask as well, so all three refuse the same
        # programs in the same sentence.
        def refuse_too_many_layers!(node)
          refusal = Guardrails::Checks::LayerRefusals.message(node)
          raise ProgramError, refusal if refusal
        end

        # The same answer about sprites: this picture has room for any number of them, and a
        # game for a console can keep only so many places. See Guardrails::Checks::TooManySprites.
        def refuse_too_many_sprites!(node)
          refusal = Guardrails::Checks::TooManySprites.new.refusal_message(node)
          raise ProgramError, refusal if refusal
        end

        # ...and about a sprite's colors: this picture paints each of a sprite's pictures in
        # whatever colors it holds, and the console draws them all from one list. See
        # Guardrails::Checks::PosesWithDifferentColors.
        def refuse_poses_with_different_colors!(node)
          refusal = Guardrails::Checks::PosesWithDifferentColors.new.refusal_message(node)
          raise ProgramError, refusal if refusal
        end

        # ...and about see-through layers: this picture could blend any number at once, and
        # the console blends one a screen. See Guardrails::Checks::SeeThroughPerScreen.
        def refuse_two_see_through_layers!(node)
          refusal = Guardrails::Checks::SeeThroughPerScreen.new.refusal_message(node)
          raise ProgramError, refusal if refusal
        end

        # Register every definition in the tree up front — funcs, named sound
        # effects, songs and timer handlers — so an op can refer to one defined later in
        # the program (a forward reference), the same resolve-names-first move the GBA
        # lowering makes with labels. A handler is armed here rather than where it is
        # written, since it is its timer's from power-on (see Nodes::OnTimer.of).
        def collect_definitions(node)
          @timer_handlers = Nodes::OnTimer.of(node)
          node.walk do |n|
            case n.kind
            when :func
              @funcs[n.name] = n
            when :define_sound
              @defined_sounds[n.name] = n.effect
            when :song
              @player.declare(n)
            when :song_list
              @player.declare_list(n.name, n.songs)
            when :sound_effect_list
              @player.declare_effects(n.name, n.effects)
            when :sample
              @mixer.declare(n.name, Assets::Sample.of(n), n.bytes)
            when :list_new
              # A list is room the cartridge sets aside, so it is there, empty, from power-on —
              # wherever it is declared. A scene that shows tiles painted from a list declared
              # inside it puts them up as it takes over, before its declaration has run once.
              # Empty even for a list full of a value: it is the declaration that fills it, on
              # every backend, and the console's memory holds nothing in particular before then.
              @lists[n.name] ||= ListValue.empty_of(n)
            when :table
              @tables[n.name] = TableValues.new(values: n.values, signed: n.signed)
            when :data
              @data[n.name] = n.bytes
            when :bitmap
              @data[n.name] = n.pixels
              @bitmaps[n.name] = Assets::Image.of(n)
            when :tile_run
              # Tiles the game paints from a list: see-through until the first copy.
              @tile_runs[n.name] = n
              n.tiles.each { |tile| @bitmaps[tile] = blank_run_tile(n) }
              store_run_picture(n, Array.new(n.width * n.height, 0)) if n.picture
              @repaints = true
            when :backing_buffer
              # Reserve the patch. `pixels` stays nil until the first save_region
              # fills it — a restore before any save has nothing to put back.
              @backing[n.name] = { width: n.width, height: n.height, pixels: nil }
            when :color_list
              @color_lists[n.name] = n
            when :picture_groups
              @picture_groups[n.name] = n
              @groups_up[n.name] = Array.new(n.slots, Nodes::PictureGroups::NONE)
            when :object
              # Register the object, so present_objects can find its picture and the
              # variables holding where it is and whether it's shown.
              @objects[n.name] = n
            when :layers
              # The stack of depths, known before anything is drawn: a background can
              # name a layer that puts it behind one declared earlier, and the painting
              # has to know that when it starts rather than halfway through.
              @layer_stack = n.names
              @see_through = n.see_through.to_h { |layer| [layer.name, layer] } unless n.see_through.empty?
            when :background
              # Remember every background so present_objects can redraw them under the
              # objects each frame (that clean redraw is what erases the previous frame),
              # and by name so scroll_background can re-window that one.
              @bg_nodes << n
              @bg_by_name[n.name] = n
            when :scroll_background, :place_bar
              # A program that scrolls even once can put its background at a non-zero
              # offset, so the whole scene has to be repainted every frame — the static
              # save-under trick objects normally ride on no longer holds. Remember that
              # here so present_objects and scroll_background take the repaint path.
              @repaints = true
            when :scroll_rows
              # A bending background is a moving background: each row sits somewhere new
              # every frame, so the scene has to be repainted like a scrolled one.
              # Declared once and standing from then on (last wins if repeated), which is
              # why it is collected here rather than run as a statement.
              @row_bends[n.name] = n
              @repaints = true
            when :shade_outside
              # A light stands from its declaration, like a bend, and is read again before
              # every frame (see #work_out_shade). It darkens the picture as it is SHOWN, so
              # nothing painted has to be painted again for it.
              @shade = n
            when :affine_background
              # A turned or resized background repaints for the same reason a scrolled one
              # does: every pixel of it can land somewhere new. Present anywhere in the
              # tree at all (even a branch never taken) is enough to know the scene needs
              # full repaints, the same over-approximation scroll_background makes.
              @repaints = true
            when :set_tile, :show_map, :background_colors
              # A background whose cells can change is a background that can look
              # different next frame, so the settled-scene shortcut no longer holds and
              # the picture is rebuilt from the map each frame — the same
              # over-approximation, for the same reason. A whole map handed over at once
              # is the same story on a larger scale, and so is the whole of it drawn from
              # another list of colours.
              @repaints = true
            end
          end
        end

        def count_step!
          @steps += 1
          return if @steps <= @max_steps

          # A run counting frames has spent the whole budget inside ONE frame, since the
          # count starts again at every vblank (advance_frame). So this frame is never
          # going to reach one, and there's no settled boundary ahead to stop on. Say so
          # rather than hand back a part-played run: a run that stopped early looks exactly
          # like one that finished, and a test then reads a world frozen mid-frame.
          #
          # A program that has never reached a vblank AT ALL is a different thing and not an
          # error: it has no frames to count, so `frames:` was moot and the budget is its only
          # stop — an unpaced loop (frame_sync: :manual with no wait) is meant to be run that
          # way. That one falls through to the whole-run stop below, which is what it always got.
          raise ProgramError, frame_never_ended_message if @frames_limit && @uses_frames

          @stopped_at_budget = true
          # A frame-based program doesn't stop here — mid-frame would leave a torn,
          # half-drawn screen. Mark it over budget and let it run on to the next frame
          # boundary, where advance_frame stops it with the in-flight frame complete. A
          # program with no frames, or one past the hard cap (its next vblank never came),
          # stops right here.
          @over_budget = true
          throw :halt unless @uses_frames && @steps <= @hard_cap
        end

        # Which frame is in flight: @frame is bumped at the vblank that STARTS a frame, so the
        # work running now belongs to frame @frame. (A program stuck before its first vblank
        # never gets here — see count_step!.)
        def frame_never_ended_message
          "frame #{@frame} of this run never ended. The program ran #{@max_steps} steps in " \
            "that one frame and did not wait for the screen. A frame ends at that wait, so this " \
            "frame cannot end. Look for a loop in the frame that never stops. If the frame is " \
            "only a heavy one, pass a larger `max_steps:`. With `frames:`, that budget is for " \
            "one frame."
        end

        # WHAT EACH KIND OF STATEMENT DOES, one method per kind, looked up by the kind's name —
        # the same shape as the console's table (Backends::GBA::Lowering), and read by the
        # coverage test that holds both backends to every kind. A declaration is gathered before
        # the program runs, so its row is #exec_declaration, which does nothing — every kind that
        # says it is one gets that row, rather than a list of them kept here.
        STATEMENTS = {
          program: :exec_program,
          set: :exec_set,
          add: :exec_add,
          sub: :exec_sub,
          copy: :exec_copy,
          negate: :exec_negate,
          abs: :exec_abs,
          negate_abs: :exec_negate_abs,
          clamp: :exec_clamp,
          save_init: :exec_save_init,
          save_store: :exec_save_store,
          save_write: :exec_save_write,
          save_erase: :exec_save_erase,
          if: :exec_if,
          loop: :exec_loop,
          inside: :exec_inside,
          repeat: :exec_repeat,
          every: :exec_every,
          after: :exec_after,
          list_new: :exec_list_new,
          list_push: :exec_list_push,
          list_drop: :exec_list_drop,
          list_set: :exec_list_set,
          list_fill: :exec_list_fill,
          list_copy: :exec_list_copy,
          blit: :exec_blit,
          blit_pose: :exec_blit_pose,
          save_region: :exec_save_region,
          restore_region: :exec_restore_region,
          call: :exec_call,
          call_one_of: :exec_call_one_of,
          case: :exec_case,
          halt: :exec_halt,
          wait_vblank: :exec_wait_vblank,
          hide_sprites: :exec_hide_sprites,
          rumble: :exec_rumble,
          screen: :exec_screen,
          clear_screen: :exec_clear_screen,
          pixel: :exec_pixel,
          fill_rect: :exec_fill_rect,
          dma_fill_rect: :exec_dma_fill_rect,
          draw_rect_at: :exec_draw_rect_at,
          draw_column_at: :exec_draw_column_at,
          draw_text: :exec_draw_text,
          draw_digit: :exec_draw_digit,
          background: :exec_background,
          scroll_background: :exec_scroll_background,
          place_bar: :exec_place_bar,
          affine_background: :exec_affine_background,
          background_colors: :exec_background_colors,
          color_list_holds: :exec_color_list_holds,
          show_picture_group: :exec_show_picture_group,
          scroll_rows: :exec_scroll_rows,
          shade_outside: :exec_shade_outside,
          show_light_now: :exec_show_light_now,
          camera: :exec_camera,
          fade: :exec_fade,
          tint: :exec_tint,
          pixelate: :exec_pixelate,
          see_through: :exec_see_through,
          present_objects: :exec_present_objects,
          set_tile: :exec_set_tile,
          show_map: :exec_show_map,
          copy_tiles: :exec_copy_tiles, copy_owed_tiles: :exec_copy_owed_tiles,
          enable_sound: :exec_enable_sound,
          beep: :exec_beep,
          noise: :exec_noise,
          wave: :exec_wave,
          stop_wave: :exec_stop_wave,
          play_song: :exec_play_song,
          play_from_list: :exec_play_from_list,
          play_sound_effect: :exec_play_sound_effect,
          stop_music: :exec_stop_music,
          play_sample: :exec_play_sample,
          stop_sample: :exec_stop_sample,
          timer_start: :exec_timer_start,
          timer_stop: :exec_timer_stop,
          on_timer: :exec_on_timer,
          set_clock: :exec_set_clock,
        }.merge(Nodes.of_role(:declaration).to_h { |kind| [kind, :exec_declaration] }).freeze

        def exec(node)
          count_step!
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
          paint_owed_repaint if @picture_owed && !defers_repaint?(node)

          handler = STATEMENTS.fetch(node.kind) do
            raise ProgramError,
                  "the reference backend cannot execute #{node.kind.inspect} " \
                  "(#{node.category}) yet"
          end
          send(handler, node)
        end

        def exec_program(node)
          node.children.each { |child| exec(child) }
        end

        # A declaration: gathered before the program runs (see #collect_definitions), so nothing
        # happens where it is written, just as a func body runs only when something calls it.
        def exec_declaration(_node) = nil

        def exec_set(node)
          @vars[node.var] = eval_value(node.value)
        end

        def exec_add(node)
          @vars[node.var] = Int32.add(@vars[node.var], eval_value(node.operand))
        end

        def exec_sub(node)
          @vars[node.var] = Int32.sub(@vars[node.var], eval_value(node.operand))
        end

        def exec_copy(node)
          @vars[node.dest] = @vars[node.src]
        end

        def exec_negate(node)
          @vars[node.var] = Int32.neg(@vars[node.var])
        end

        def exec_abs(node)
          # |v|: flip it only when it's negative.
          v = @vars[node.var]
          @vars[node.var] = v.negative? ? Int32.neg(v) : v
        end

        def exec_negate_abs(node)
          # -|v|: flip it only when it's positive.
          v = @vars[node.var]
          @vars[node.var] = v.positive? ? Int32.neg(v) : v
        end

        def exec_clamp(node)
          @vars[node.var] = clamp_value(@vars[node.var], eval_value(node.min),
                                          eval_value(node.max))
        end

        def exec_if(node)
          if eval_value(node.cond).zero?
            node.else&.children&.each { |child| exec(child) }
          else
            node.children.each { |child| exec(child) }
          end
        end

        # In the order the console runs a game loop's frame boundary (IR::Frames.loop_in_console_order).
        # A boundary write placed at the end of a pass leaves a background that pass put up at its
        # corner (#exec_scroll_background, #exec_place_bar).
        def exec_loop(node)
          order = IR::Frames.loop_in_console_order(node.children, @console)
          order.before.each { |child| exec(child) }
          @loops_running << order
          loop { order.each_time.each { |child| exec_in_loop(child, order) } }
        ensure
          @loops_running.pop
        end

        def exec_in_loop(child, order)
          @placing_at_pass_end = order.placed?(child)
          exec(child)
        ensure
          @placing_at_pass_end = false
        end

        # A pass that halts ends as every pass does, with its sprites and scroll placed, where its
        # console places them at the end of a pass (IR::Frames::ConsoleLoop#pass_end).
        def place_pass_end_before_halt
          order = @loops_running.last
          order&.pass_end&.each { |child| exec_in_loop(child, order) }
        end

        def exec_inside(node)
          # Hold every cell the children paint inside these edges. The screen answers that
          # question once, for everything, which is why the interpreter needs no per-shape
          # arithmetic here and the other backend does.
          # ...and give back whatever area was in force before, not "anywhere": a routine
          # with an area of its own may be called from inside another's, and the caller's
          # edges still hold for what it draws after the call — as they do on the console,
          # where they are baked into every shape there.
          outer = @screen.area
          @screen.draw_inside(node.x, node.y, node.w, node.h)
          begin
            node.children.each { |child| exec(child) }
          ensure
            @screen.restore_area(outer)
          end
        end

        def exec_repeat(node)
          # A counted loop: the index counts 0..count-1. Evaluate count once,
          # like a for-loop bound. count_step! guards the step budget even when the
          # body is empty.
          count = eval_value(node.count)
          i = 0
          while i < count
            count_step!
            @vars[node.index] = i
            # Checked BEFORE the body, so a loop that is already finished on its first pass
            # runs the body no times at all — the same reading on both backends.
            break if node.stop_when && !eval_value(node.stop_when).zero?

            node.children.each { |child| exec(child) }
            i += 1
          end
        end

        def exec_every(node)
          # A repeating timer, counted in FRAMES rather than in times this code ran: a pass of
          # the game loop is one frame on a program that keeps up and more on one that does
          # not, and a beat given in seconds has to be that many seconds either way. Taking
          # the period off rather than clearing to nought keeps the remainder, so a beat that
          # overshoots does not drift further every time.
          @vars[node.counter] = Int32.add(@vars[node.counter], last_pass_frames)
          if @vars[node.counter] >= node.period
            @vars[node.counter] = Int32.sub(@vars[node.counter], node.period)
            node.children.each { |child| exec(child) }
          end
        end

        def exec_after(node)
          # A one-shot timer, likewise — and the test is REACHED rather than LANDED ON,
          # because a pass worth two frames can step over the frame it was waiting for.
          if @vars[node.counter] < node.frames
            @vars[node.counter] = Int32.add(@vars[node.counter], last_pass_frames)
            node.children.each { |child| exec(child) } if @vars[node.counter] >= node.frames
          end
        end

        def exec_list_new(node)
          # Create (or reset) the named list, empty, at its capacity and element width.
          @lists[node.name] = ListValue.of(node)
        end

        def exec_call(node)
          call_func(node.target)
        end

        def exec_halt(node)
          place_pass_end_before_halt
          stop_motor
          @log << [:halt]
          throw :halt
        end

        def exec_wait_vblank(node)
          advance_frame
        end

        # +backdrop+ is the colour the screen shows wherever nothing is drawn: a scene's arrival
        # says its own (IR::SceneHandover::Arrival#backdrop), and the game's own `screen` its own.
        def exec_screen(node, backdrop: @handover.backdrop_of(node))
          # Remember the chosen mode; the fake screen already models the bitmap the
          # draw ops assume. Double buffering (node.buffered) asks it for a second
          # page: the display shows one picture while the program draws into the other,
          # and they trade places at the frame boundary. A frame's drawing therefore
          # lands on one of the two, so a program that adds to what is already there
          # puts half its additions on each page. See Framebuffer#paged=.
          #
          # Handing over to another KIND of screen replaces the whole display (see
          # IR::SceneHandover), so the old picture is wiped and nothing is up any more: a
          # scene's scenery is put up again when it comes back rather than taken as still
          # there. A switch between single- and double-buffered bitmap keeps the same
          # surface, so it wipes nothing.
          crossing = IR::SceneHandover.crossing?(@screen_mode, node.mode)
          if crossing
            @backdrop = backdrop
            @screen.clear(@backdrop)
            reset_scenery_state
          else
            show_backdrop(backdrop)
          end
          @screen_mode = node.mode
          # A tear-free screen is two pages only where the console keeps two; one that only ever
          # shows a picture whole keeps one, and a single paint is on every frame there.
          @buffered = (node.buffered || false) && @console.painted_pages == 2
          @screen.paged = @buffered
          @screen.tint_by_display = tint_by_display? # a tint in force is mixed this screen's way
          @screen.show_in_blocks(painted_screen? ? @block : 1) # the size of a block outlasts the screen it was said on
          put_up_always_up if crossing && IR::SceneHandover.tiles?(node.mode)
        end

        # THE COLOUR WHEREVER NOTHING IS DRAWN BECOMES +color+: the picture is painted again over it
        # where anything is up, so every empty place shows it at once, as the console shows its
        # backdrop colour the moment it is given another.
        def show_backdrop(color)
          return if color == @backdrop

          @backdrop = color
          @scene_fb = nil
          @bg_shown.empty? ? @screen.clear(@backdrop) : request_repaint
        end

        # Arrive on the screen a scene draws on, for a scene that names none: one reached from
        # a screen of another kind crosses back to its own, the same as if it had said so. Its
        # backdrop is the game's, or black on a painted screen (Arrival#backdrop).
        def cross_to_scene_screen(arrival)
          screen = IR::Modes::SCREEN_OF_MODE.fetch(arrival.mode)
          return show_backdrop(arrival.backdrop) unless IR::SceneHandover.crossing?(@screen_mode, screen)

          exec_screen(Build.screen(screen, buffered: arrival.mode == IR::Modes::BUFFERED), backdrop: arrival.backdrop)
        end

        # PUT UP AGAIN WHAT EVERY SCREEN DRAWN FROM TILES SHOWS, once a screen of another kind
        # has replaced the display (see IR::SceneHandover#always_up): nothing else would, since
        # its statements ran once, at power-on. As declared — every changed cell and the map
        # chosen were left behind with the display.
        def put_up_always_up
          always = @handover.always_up
          always.scenery.each do |bg|
            @bg_maps.delete(bg.name)
            put_up_background(bg)
          end
          always.map_choices.each { |var| @vars[var] = 0 }
          (always.painted_tiles + always.painted_pictures).each { |run| copy_run_tiles(run) }
        end

        def exec_clear_screen(node)
          @screen.clear(resolve_color(node.color))
        end

        def exec_pixel(node)
          @screen.set_pixel(eval_value(node.x), eval_value(node.y), resolve_color(node.color))
        end

        def exec_fill_rect(node)
          @screen.fill_rect(eval_value(node.x), eval_value(node.y),
                            eval_value(node.w), eval_value(node.h),
                            resolve_color(node.color))
        end

        def exec_dma_fill_rect(node)
          # Same picture as fill_rect — the "DMA" is only how a console fills it
          # fast; the pixels that land are identical.
          @screen.fill_rect(eval_value(node.x), eval_value(node.y),
                            eval_value(node.w), eval_value(node.h),
                            resolve_color(node.color))
        end

        def exec_draw_rect_at(node)
          # A rectangle whose position and size are all computed at run time. A width
          # or height of zero or less covers no pixels, so nothing is drawn.
          @screen.fill_rect(eval_value(node.x), eval_value(node.y),
                            eval_value(node.w), eval_value(node.h), resolve_color(node.color))
        end

        def exec_scroll_rows(node)
          # A standing declaration, gathered up front (collect_definitions) — the rows are
          # worked out in the gap between frames, not where it is written (#work_out_bends).
          # Reaching it inline repaints, so a program that never waits for the screen, whose
          # rows are worked out as they are painted (#bend_offset_at), still shows the bend.
          request_repaint
        end

        # A standing declaration, gathered up front (collect_definitions) and worked out at
        # every frame boundary — reaching the line itself does nothing.
        def exec_shade_outside(_node); end

        # The light worked out again here: the picture being drawn is read with it, as the
        # console's display reads rows handed to it while it draws.
        def exec_show_light_now(_node) = work_out_shade

        # WHERE THE LIGHT IS ON EACH ROW, worked out in the gap before a frame, the moment the
        # console works its table out: every row's span from the program's own expressions,
        # and how far the rest of the row is darkened, in the display's sixteenths.
        def work_out_shade
          return unless @shade

          spans = Array.new(@screen.height) do |row|
            @vars[@shade.row] = row
            @shade.children.each { |child| exec(child) } # what the light works out once a row, before its edges
            [eval_value(@shade.left), eval_value(@shade.right)]
          end
          @screen.shade_outside(spans, FadeSteps.sixteenths(eval_value(@shade.amount)))
        end

        def exec_camera(node)
          @screen.camera_to(eval_value(node.x), eval_value(node.y))
        end

        def exec_enable_sound(node)
          @audio << [:enabled]
        end

        # SHAKE THE PLAYER'S HANDS (Nodes::Rumble): the motor runs on the frames the screen shows
        # from the next on (#step_motor), as the console's interrupt runs it as each frame starts.
        # Nothing on a console whose cartridge has no motor.
        def exec_rumble(node)
          return unless @console.rumbles

          @rumble_left = IR::Rumble.frames(eval_value(node.frames))
          @rumble_bits = eval_value(node.pattern) & 0xFF
        end

        # One frame of the motor, read from the pattern as IR::Rumble reads it, while the rumble
        # lasts; off once it has run out.
        def step_motor
          return @motor_on = false unless @rumble_left.positive?

          @motor_on, @rumble_bits = IR::Rumble.step(@rumble_bits)
          @rumble_left -= 1
        end

        # A game that halts or goes wrong shakes nothing from then on.
        def stop_motor
          @rumble_left = 0
          @motor_on = false
        end

        def exec_beep(node)
          @audio << [:beep, resolve_effect(node)]
          @player.game_sound_on(Player::BEEP_CHANNEL)
        end

        def exec_noise(node)
          @audio << [:noise, resolve_noise(node)]
        end

        def exec_wave(node)
          @audio << [:wave, { shape: node.shape, frequency: node.frequency, volume: node.volume }]
          @player.game_sound_on(Player::WAVE_CHANNEL)
        end

        def exec_stop_wave(node)
          @audio << [:stop_wave]
          @player.game_sound_on(Player::WAVE_CHANNEL)
        end

        def exec_play_song(node)
          # Names the tune; the player takes it up at the next frame (see Player#advance), or
          # here when the game said `this_frame: true`.
          @player.request_song(node.name)
          start_song_here if node.this_frame
        end

        def exec_play_from_list(node)
          # The number is worked out HERE and handed over: which song a game picks can be an
          # expression, and evaluating one is the interpreter's business, not the player's.
          named = @player.request_song_at(node.name, eval_value(node.which))
          start_song_here if named && node.this_frame
        end

        def start_song_here = @player.start_song_here(level: @vars.fetch(IR::Tunes::LEVEL, nil))

        def exec_play_sound_effect(node)
          @player.request_effect(node.name, eval_value(node.which), this_frame: node.this_frame)
        end

        def exec_stop_music(node)
          @player.stop
        end

        def exec_play_sample(node)
          @mixer.start(node)
        end

        def exec_stop_sample(node)
          @mixer.stop(node.name)
        end

        def exec_timer_start(node)
          # Start (or restart) a timer: it now runs at hz overflows/sec, from no part of an
          # overflow at all (advance_frame moves it on each frame; see #accrue_timer).
          @timers[node.name] = { hz: node.hz, running: true, parts: 0 }
        end

        def exec_timer_stop(node)
          @timers[node.name]&.[]=(:running, false)
        end

        # Reaching the line does nothing: the handler was armed before the run began (see
        # #collect_definitions), and advance_frame runs its body on each overflow.
        def exec_on_timer(_node); end

        # THE MIX RUNS AT THE CARTRIDGE'S CLOCK: the nearest the console's sample clock can keep
        # to the rate the program's recordings ask for (Console::SampleClock). How many samples
        # a frame holds is a fact about the hardware the sound plays on, not about the program,
        # and this mix exists to make the very bytes that hardware is handed. A program that
        # mixes nothing has no clock.
        def start_mixer_clock(program)
          return unless IR::Mixing.mixes?(program)

          @mixer.start_clock(clock: @console.sample_clock(IR::Mixing.requested_rate(program)),
                             shapes: IR::Mixing.shapes_any_note?(program), voices: @console.recordings_at_once)
        end

        # One vblank: snapshot the current buttons as "previous" (so an edge can
        # be spotted), advance the frame counter, and pull the next frame's input
        # if a script is driving it.
        def advance_frame
          # A LIGHT THAT TAKES TURNS GOES OFF WITH THE PASS that switched it off: the scene it is
          # off in takes the display's mixing for its own as it starts. It comes back on only
          # from the light worked out at this gap, a frame later (see IR::LightScenes and
          # GBA::Raster#emit_light_leaving). A game whose light never takes turns has no switch.
          @screen.light_off = @vars.fetch(IR::LightScenes::ON, 1).zero?

          # The pass that put a background up ends here, and its picture shows the background
          # from the corner (see #put_up_background). A repaint it still owes is painted as
          # repaints are, when the picture is next wanted, so its corners go when that is done
          # or when the next pass changes the picture again (#forget_expired_corners).
          @bg_corners_expired = true unless @bg_from_corner.empty?

          # A frame boundary is the one safe moment to swap the pages of a tear-free
          # screen, so it happens FIRST — before either stop below. The frame whose
          # drawing just finished is the one being published, and a run that stops here
          # has to stop with that frame on screen rather than with the one before it.
          if @buffered
            paint_owed_repaint # the page being published has to be the finished one
            @screen.flip_pages
          end

          # This is a frame boundary: if we're past the budget, stop HERE — the frame just
          # drawn is complete, and the next one's clear/draws haven't started, so the screen
          # is settled. Reaching a vblank also marks the program as frame-based (see count_step!).
          throw :halt if @over_budget

          # Same settled-boundary stop once we've played the requested number of frames:
          # @frame counts frames already completed, so at == the limit the next frame's
          # draws haven't begun. Not a budget cutoff — it ran exactly as asked, so
          # #stopped_at_budget? stays false.
          throw :halt if @frames_limit && @frame >= @frames_limit

          # A new frame starts here, so the step budget starts again with it: when a run is
          # counting frames, the budget guards ONE frame rather than the whole run. Counting
          # the run instead makes the budget the real stop condition on any program whose
          # frames cost more than a few thousand steps — it cuts the run short wherever it
          # has got to, and `frames:` silently means nothing.
          @steps = 0 if @frames_limit

          @uses_frames = true
          @screen.held = false # the first frame is set up, so the picture goes on
          @frame += 1
          took = scripted_pass_frames
          # A running timer overflows hz times a second, so it gains hz FRAME_RATE-ths of an
          # overflow this frame (see #accrue_timer) — the whole ones are what timer_ticks reads
          # back, and each whole overflow crossed this frame runs its on_tick handler once.
          @timers.each { |name, t| accrue_timer(name, t) if t[:running] }
          # The mix, the tune and every sounding note's shape all move on once for every frame
          # that really passed, not once for the pass: the console does all of it from the
          # screen's own interrupts, which keep real time. So a recording a game plays ends after
          # as many frames as it lasts, however long the game takes a pass.
          #
          # IN THE CONSOLE'S ORDER, which is not the order of a frame's own parts. The tune and
          # the shapes are moved on as the screen finishes a picture, just before the game's pass
          # starts; the mix is made as the next picture starts, after the pass. So what the game
          # plays or stops in its pass is in the very next slice, and a note the tune starts has
          # climbed before it is heard (see GBA::Mixer#emit_envelope_step) — and a sound the game
          # starts with a shape is mixed once at nothing before its shape first moves it.
          took.times do
            @mixer.mix
            # A program that never said `music_volume` has no level, rather than a level of 0.
            @player.advance(level: @vars.fetch(IR::Tunes::LEVEL, nil))
            @mixer.step_envelopes
            step_motor
          end
          read_buttons(took)
          @log << [:vblank, @frame]
          @on_vblank&.call(@frame)
          store_frame_counters(took)
          work_out_bends
          work_out_shade
        end

        # THE BUTTONS ARE READ ON EVERY FRAME THE SCREEN SHOWED, not once a pass — the console
        # reads them from the screen's own interrupt, which keeps real time whatever the game
        # is doing. A pass that took +took+ frames reads them that many times, asking the
        # input script for each frame by its number on the screen, and every button that went
        # down on any of them is a press for the pass about to start. So a tap shorter than a
        # slow pass is still one press, and a press held across the whole pass is still one.
        # A program that keeps up reads once a pass, which is what it always did.
        def read_buttons(took)
          @pressed = Set.new
          took.times do
            @screen_frame += 1
            @held = to_button_set(Array(@input_script.call(@screen_frame))) if @input_script
            @pressed |= @held - @seen
            @seen = @held
          end
        end

        # HOW MANY FRAMES THIS PASS TOOK, kept where the other backend keeps it so that a
        # program can read the same two names on either.
        #
        # ONE UNLESS A TEST SAYS OTHERWISE, and it is worth saying why rather than leaving it to
        # be discovered. This interpreter has no clock. A frame is over when the program says it
        # is, so a pass can never overrun one and there is nothing for it to find out. That is
        # the right answer for what it is — an oracle for what a program MEANS, not for how long
        # a console takes over it — so being late is SAID to it, by #frames_each_pass, rather
        # than measured. How long a pass really takes is still the console's question alone.
        # How many frames the pass that just ended took, for whatever reads it. A program with no
        # frames at all has never set it, and then a beat is worth one pass, which is what it was
        # worth before any of this existed.
        def last_pass_frames
          step = @vars[IR::Frames::STEP]
          step.nil? || step.zero? ? 1 : step
        end

        # What the test said this pass was worth: at least one, the frame it ran in. Every frame of
        # it is a frame the screen showed, so the music, the mix and the buttons move on by all of
        # them, as the console's interrupt moves them whatever the game is doing.
        def scripted_pass_frames
          return 1 unless @frames_script

          [@frames_script.call(@frame).to_i, 1].max
        end

        # ...and what the game reads of it is held at the cap the console holds it at
        # (IR::Frames::MOST) — so a body asked to catch up can never be asked to catch up further
        # here than it would there — while the count of frames shown takes every one.
        def store_frame_counters(took)
          @vars[IR::Frames::COUNT] += took + @setting_up_uncounted
          @setting_up_uncounted = 0 # counted once, at the first frame
          @vars[IR::Frames::SEEN] = @vars[IR::Frames::COUNT]
          @vars[IR::Frames::STEP] = took.clamp(1, IR::Frames::MOST)
        end

        # EVERY ROW OF EVERY BEND, WORKED OUT ONCE A PASS, in the gap between frames the game
        # waits at, where the console works them out into the table its display is fed from
        # (GBA::Raster). A pass the console took several frames over is still one gap, so it is
        # one here too however many frames #frames_each_pass says the pass answered for. The
        # block is asked 160 times here and nowhere else: painting the picture reads what was
        # worked out, however many times the picture is built. That matters because a block may
        # change the game — count, roll a random number — and one asked more often here than on
        # the console would play a different game.
        #
        # In the console's order: every bend's top row first, then the rest of each bend in
        # turn, which leaves each bend's row at one past the bottom of the screen.
        #
        # The picture changes every frame even when the program draws nothing, since the bend
        # is worked out from whatever its block reads, so it is asked for again here.
        #
        # It comes last in the frame boundary, after anybody watching the run has been shown the
        # frame — the same moment a run that stops here would have stopped at, so a picture read
        # after a run is the one a watcher saw.
        #
        # A bend written for a background the game does not have is never asked: there are no
        # rows of it to work out.
        def work_out_bends
          bends = @row_bends.select { |name, _| @bg_by_name.key?(name) }
          return if bends.empty?

          bends.each { |name, bend| @bend_rows[name] = [run_bend_for_row(bend, 0)] }
          bends.each do |name, bend|
            (1...@screen.height).each { |py| @bend_rows[name] << run_bend_for_row(bend, py) }
            @vars[bend.row] = @screen.height
          end
          request_repaint
        end

        # Where row +py+ of a bending background sits, as the gap between frames last worked it
        # out. Before the first gap there is nothing kept, and then it is the console's two
        # answers: a program that waits for the screen has its table at nought until that gap
        # (GBA::Raster#emit_boot_row_bends), so every row sits flat; one that never waits has no
        # gap at all, and the console works each row out as it draws it, so this does too.
        def bend_offset_at(name, py)
          rows = @bend_rows[name]
          return rows[py] if rows
          return 0 if @uses_frames

          bend = @row_bends[name]
          bend ? run_bend_for_row(bend, py) : 0
        end

        def call_func(name)
          func = @funcs[name] || raise(ProgramError, "call to undefined func #{name.inspect}")
          func.children.each { |child| exec(child) }
        end

        # Advance one timer by a frame's worth of overflows, and run its on_tick handler
        # once for each whole overflow it crosses this frame.
        #
        # COUNTED IN WHOLE NUMBERS, as FRAME_RATE-ths of an overflow: a frame adds +hz+ of them,
        # and the overflows are how many whole FRAME_RATEs that comes to. Adding hz / FRAME_RATE
        # as a fraction instead lands a hair under a whole overflow on exactly the frames one
        # falls due — a tenth added ten times is not quite one — so the count read one short
        # there, at most rates. Whole numbers are also all a console's processor can keep.
        def accrue_timer(name, timer)
          before = whole_overflows(timer)
          timer[:parts] += timer[:hz]
          handler = @timer_handlers[name] or return
          (whole_overflows(timer) - before).times do
            handler.children.each { |child| exec(child) }
          end
        end

        # How many whole times +timer+ has overflowed since it was started.
        def whole_overflows(timer) = timer[:parts] / FRAME_RATE

        # Render a string with the built-in bitmap font: each set pixel of each
        # glyph becomes one painted cell, offset from the text's top-left origin.
        # Off-screen cells clip away in set_pixel, just as they do on hardware.
        def exec_draw_text(node)
          x = eval_value(node.x)
          y = eval_value(node.y)
          color = resolve_color(node.picked && eval_value(node.showing) != 0 ? node.picked : node.color)
          node.fonts.get(node.font).each_pixel(node.text) do |dx, dy|
            @screen.set_pixel(x + dx, y + dy, color)
          end
        end

        # Draw the run-time digit: work out which of 0..9 the value is and render
        # that one glyph. A value outside 0..9 draws nothing (a digit column always
        # holds a single digit, so this only guards against misuse).
        def exec_draw_digit(node)
          digit = eval_value(node.value)
          return unless (0..9).cover?(digit)

          color = resolve_color(node.color)
          node.fonts.get(node.font).each_pixel(digit.to_s) do |dx, dy|
            @screen.set_pixel(node.x + dx, node.y + dy, color)
          end
        end

        # Resolve a beep's tone + overrides into the concrete musical values that
        # played — the shared rule, so the interpreter and the ROM agree on what a
        # given beep means.
        def resolve_effect(node)
          Audio::Sound.resolve_effect(node.tone, duty: node.duty, decay: node.decay,
                                            volume: node.volume, defined: @defined_sounds)
        end

        # Resolve a noise hit's preset + overrides into the concrete musical values
        # that played — the shared rule, so the interpreter and the ROM agree on
        # what a given hit means.
        def resolve_noise(node)
          Audio::Sound.resolve_noise(node.preset, pitch: node.pitch, decay: node.decay,
                                             volume: node.volume, metallic: node.metallic)
        end

        # Multi-way dispatch: call the scene/func for the clause whose value equals
        # the variable. Values are distinct, so this runs at most one scene.
        #
        # THE READ IS OUTSIDE THE LOOP AND HAS TO BE. A scene's usual last act is to set
        # the variable to the next scene, and re-reading it per clause would then run that
        # one too, in the same pass. Every clause answers the state as it was when the
        # dispatch was reached.
        def exec_case(node)
          value = @vars[node.var]
          node.clauses.each do |clause_value, target|
            next unless value == clause_value

            # A scene that loads first, handed over to, has the pass it takes over on to itself
            # for its pictures; the scene up at power-on was handed over to by nobody (see
            # IR::SceneHandover::Arrival#loads_first?).
            handed_over = !@scene.nil?
            next if take_over(target) && handed_over && @handover.arrival(target).loads_first?

            call_func(target)
          end
        end

        # A SCENE TAKES THE SCREEN AS IT STARTS, by carrying out its plan (see
        # IR::SceneHandover): its screen first, since changing the kind of screen wipes what
        # was up; then the last scene's scenery down, whether or not this one has scenery of
        # its own (waiting for its first background to say so left a file screen's backdrop up
        # over the game it handed to); then its own scenery up as declared, and what it paints
        # from lists copied in as the lists are now. Only on the frame the scene changes;
        # staying in it changes nothing. True when it took over.
        def take_over(scene)
          return false if scene == @scene

          @scene = scene
          arrival = @handover.arrival(scene)
          # Its scenery goes up as declared, so the cells the game changed of a background by
          # one of those names are forgotten now, before anything is painted: a background of
          # the same name in the scene leaving can hold tiles this scene's declaration has not.
          arrival.scenery.each { |bg| @bg_maps.delete(bg.name) }
          arrival.screen ? exec_screen(arrival.screen, backdrop: arrival.backdrop) : cross_to_scene_screen(arrival)
          took_down = false
          if @bg_shown.any?(&:scene) || arrival.scenery.any?
            paint_owed_repaint
            took_down = take_down_scenery
          end
          # Its picture groups are left as the scene left them, since they say what its sprites
          # can show and its sprites are left as they were too: a scene given the screen back
          # draws them again before it can say anything, and a scene that loads first not until
          # the pass after. The console copies those groups in again before the sprites are
          # drawn (see GBA::PictureGroupCopying#emit_forget_sets_of).
          arrival.map_choices.each { |var| @vars[var] = 0 }
          (arrival.painted_tiles + arrival.painted_pictures).each { |run| copy_run_tiles(run) }
          arrival.scenery.each { |bg| put_up_background(bg) }
          redraw_sprites_over_arrived_scenery(arrival, took_down: took_down)
          true
        end

        # THE SPRITES OF THIS FRAME STAY IN FRONT OF SCENERY THAT ARRIVED AFTER THEM. They were
        # drawn as the frame began, from the pass before — the leaving scene's among them, which
        # is still on screen for this one frame on the console too, since its row of the table is
        # written in the gap after the frame. Stamping the new scene's scenery covered them here,
        # where the console draws sprites over whatever scenery is up whenever it arrived. So the
        # picture is built again from the scenery and those sprites, as they were kept when they
        # were drawn. A painted screen keeps its own sprites in its picture and is left alone.
        #
        # The same for a scene that brings no scenery but +took_down+ the last one's: wiping the
        # picture back to what every screen shows wiped those sprites too, where the console goes
        # on drawing them over the backdrop.
        def redraw_sprites_over_arrived_scenery(arrival, took_down:)
          return if (arrival.scenery.empty? && !took_down) || painted_screen? || @obj_layer.empty?

          request_repaint
        end

        # The routine at position +which+ of the list. A number below 0 or past the end names
        # none, and nothing is called.
        def exec_call_one_of(node)
          which = eval_value(node.which)
          call_func(node.targets[which]) if which.between?(0, node.targets.length - 1)
        end

        # Copy a defined bitmap onto the fake screen at (x, y).
        def exec_blit(node)
          blit_image(node.name, eval_value(node.x), eval_value(node.y))
        end

        # Draw a tiled background by stamping each cell's tile onto the fake screen.
        # The map holds an index into the tile list per cell (nil = leave it blank).
        # A tile pixel that's the backdrop color (0) is transparent — left unpainted so
        # a background layer already on screen shows through it. That's how the console
        # composites stacked layers: the backmost paints first, and each layer in front
        # only covers where it has solid pixels, letting the layers behind fill its gaps.
        def exec_background(node)
          # A scene's own scenery goes up as the scene takes over, and as declared (see
          # #take_over). Its statement is reached every frame the scene runs and changes
          # nothing, so an owed repaint can go on being owed (see #defers_repaint?).
          return if @handover.on_arrival?(node)

          paint_owed_repaint
          # ...and a scene's background on a painted screen is drawing like any other, put into
          # the one picture each time its statement runs.
          return stamp_background(node) if node.scene

          put_up_background(node)
        end

        # Stamp +node+ onto the picture, in its place in the stack.
        def put_up_background(node)
          @bg_maps.delete(node.name) if @handover.on_arrival?(node)
          # A layer can put this background BEHIND one that is already on screen, and a
          # stamp only covers where it has solid pixels — so painting it now would leave
          # it in front. Painting the ones it belongs behind back over it settles the
          # stack again. Nothing is repainted in a program whose backgrounds sit in the
          # order they were declared, which is every program that names no layers.
          over = @bg_shown.select { |bg| behind?(node, bg) }
          @bg_shown << node
          # PUT UP, IT SHOWS FROM ITS TOP-LEFT CORNER until the pass ends, wherever the game has
          # scrolled it. The place on the map the console's display starts reading a layer
          # from is set to the map's corner as the layer is switched on, and the game's own
          # place for the view is written there only at the frame boundary. So everything
          # painted of it before then — a repaint a sprite asks for — paints it unscrolled,
          # while the game's own place (@bg_scroll) stays as the game set it.
          mark_from_corner(node)
          # The scenery sprites are repainted over has changed, so the copy of it kept for
          # that is out of date — left, a sprite over a scene's own backdrop would carry the
          # scenery from before the backdrop went up around it.
          @scene_fb = nil
          # A background that has ever been turned or resized is painted through its
          # matrix instead (see #paint_background_window) — a plain stamp here would put
          # the picture back as originally drawn and throw the turn away. It still counts
          # as up: being on screen is what says whose scene is showing, and a scene whose
          # only scenery turns had nothing else to say it.
          # ...and so is a status bar, which is painted from its own top rather than the screen's,
          # and anything put up while one shows, which a stamp would paint over the bar's rows.
          return request_repaint if @bg_affine.key?(node.name) || node.bar? || bar_showing

          stamp_background(node)
          in_stack_order(over).each { |bg| stamp_background(bg) }
        end

        # A SCENE'S SCENERY REPLACES THE SCENE BEFORE'S, rather than being drawn over it (see
        # IR::SceneHandover). A painted screen has no layers to switch off, so the picture
        # goes back to the backdrop and the scenery every screen shows, and the next scene's
        # own is stamped from there.
        # True when it took any down.
        def take_down_scenery
          kept = @bg_shown.reject { |bg| @handover.on_arrival?(bg) }
          return false if kept.length == @bg_shown.length

          @bg_shown = kept
          @scene_fb = nil
          @screen.clear(@backdrop)
          in_stack_order(kept).each { |bg| stamp_background(bg) }
          true
        end

        # NOTHING IS UP ANY MORE. Said when the display is wiped under everything — the one
        # crossing between the two kinds of screen — so whatever comes back is put up again
        # rather than taken as still standing.
        def reset_scenery_state
          @bg_shown = []
          @scene_fb = nil
          # ...and where each sprite was drawn on the old screen: what was under it went with that
          # screen, so nothing is put back over the new one.
          @obj_prev.clear
        end

        # The scenery on screen right now: what every screen shows, plus the active scene's
        # own. The three places that paint the picture all read this rather than the whole
        # program's, so none of them can draw a scene that is not running.
        def showing_scenery
          @handover.showing(@scene)
        end

        # PUT A DIFFERENT TILE IN ONE CELL. The map a background was declared with is the
        # program and never changes; what changes is this run's own copy of it, made the
        # first time a cell of that background is written and read by everything that
        # paints from then on. A coordinate outside the map is left alone rather than
        # growing the map or writing over a neighbour.
        def exec_set_tile(node)
          # A tile only another scene's declaration of the name has, from a line written for that
          # scene, changes nothing here.
          return if node.tile && node.tile >= background_up(node.name).tiles.length

          map = mutable_map(node.name)
          col = eval_value(node.col)
          row = eval_value(node.row)
          return unless row >= 0 && row < map.length && col >= 0 && col < map[row].length
          return if map[row][col] == node.tile

          map[row][col] = node.tile
          # The picture this backend shows is painted, not composed by a display reading
          # the map as it goes — so a changed cell has to be painted again for anything
          # to see it. Repainting the lot is the same over-approximation a scroll makes,
          # and this is an oracle: being obviously right matters more than being quick.
          request_repaint
        end

        # HAND A BACKGROUND A WHOLE DIFFERENT MAP. Its cells become that map exactly as it
        # was declared — so a cell this run had changed with set_tile is back to how it was
        # drawn, which is what the console does too (the whole map is copied in over
        # whatever was there). A number naming no map leaves the cells alone, the same
        # policy set_tile takes for a cell off the edge.
        def exec_show_map(node)
          maps = background_up(node.name).maps
          which = eval_value(node.which)
          return unless maps && which >= 0 && which < maps.length

          @bg_maps[node.name] = maps[which].map(&:dup)
          request_repaint
        end

        # A RUN OF TILES TAKES WHAT ITS LIST HOLDS NOW (see Nodes::TileRun): tile k is the 32
        # bytes from k × 32, each byte two pixels with the left one in the low four bits, each
        # four bits a place in the run's colours, and place 0 see-through. A slot the game
        # never filled reads as 0, which is what the console's memory under it would be
        # copied as for a list it filled from the start.
        def exec_copy_tiles(node)
          copy_run_tiles(@tile_runs.fetch(node.name))
          request_repaint
        end

        # Every run whose bit is set, in the order they were declared (see Nodes::CopyOwedTiles).
        def exec_copy_owed_tiles(node)
          per = Nodes::CopyOwedTiles::RUNS_PER_MASK
          node.runs.each_with_index do |name, i|
            copy_run_tiles(@tile_runs.fetch(name)) if @vars[node.masks.fetch(i / per)].to_i[i % per] == 1
          end
          request_repaint
        end

        def copy_run_tiles(run)
          bytes = @lists.fetch(run.list).to_a
          return copy_run_picture(run, bytes) if run.picture

          run.tiles.each_with_index do |tile, k|
            @bitmaps[tile] = run_tile_from_places(run, run_tile_places(bytes, k))
          end
          forget_colors_worked_out_from(run.tiles)
        end

        # A tile's colours, and a swap of colours, are worked out once from a picture's pixels
        # and places and kept, so a picture painted again has them worked out again from what it
        # holds now — or it shows the colours its old pixels would have taken.
        def forget_colors_worked_out_from(names)
          @tile_colors.delete_if { |(name, _), _| names.include?(name) }
          @recolor_maps.delete_if { |(name, _), _| names.include?(name) }
        end

        # The 64 places of tile +k+ of a run's bytes, row by row.
        def run_tile_places(bytes, k)
          (0...RUN_TILE_BYTES).flat_map do |at|
            byte = (bytes[(k * RUN_TILE_BYTES) + at] || 0) & 0xFF
            [byte & 0x0F, byte >> 4]
          end
        end

        # A sprite's picture from its list: its tiles in the order a sprite's are kept, left to
        # right and then top to bottom, laid back out into one picture.
        def copy_run_picture(run, bytes)
          across = run.width / 8
          places = Array.new(run.width * run.height, 0)
          (across * (run.height / 8)).times do |k|
            left = (k % across) * 8
            top = (k / across) * 8
            run_tile_places(bytes, k).each_with_index do |place, i|
              places[((top + (i / 8)) * run.width) + left + (i % 8)] = place
            end
          end
          store_run_picture(run, places)
        end

        # The picture as everything that draws one reads it: its shape, and its pixels.
        def store_run_picture(run, places)
          picture = run_picture_from_places(run, places, width: run.width, height: run.height)
          @bitmaps[run.picture] = picture
          @data[run.picture] = picture.pixels
          forget_colors_worked_out_from([run.picture])
        end

        RUN_TILE_BYTES = 32

        def blank_run_tile(run) = run_tile_from_places(run, Array.new(64, 0))

        def run_tile_from_places(run, places) = run_picture_from_places(run, places, width: 8, height: 8)

        # A painted picture keeps the run's colour list as its own, because a background told
        # `draw_with` finds the colours to swap in by the list each tile was drawn from (see
        # #tile_colors). Without it the swap finds nothing and the tiles keep their colours.
        def run_picture_from_places(run, places, width:, height:)
          pixels = places.map { |place| place.zero? ? Graphics::Image::TRANSPARENT : run.colors.fetch(place, 0) }
          Assets::Image.new(width: width, height: height, transparent: Graphics::Image::TRANSPARENT,
                            pixels: pixels.pack("v*"), colors: run.colors, places: places.pack("C*"),
                            colors_name: run.colors_name)
        end

        def mutable_map(name)
          @bg_maps[name] ||= background_up(name).map.map(&:dup)
        end

        # The declaration of the background +name+ a line that changes it by name means: the one
        # on the screen up now, for a name declared in several scenes, each with maps of its own.
        def background_up(name) = showing_scenery.find { |bg| bg.name == name } || @bg_by_name.fetch(name)

        # What a background's cells hold NOW: this run's own copy where any of them have
        # been changed, and the declared map where they have not.
        def map_of(node) = @bg_maps[node.name] || node.map

        # Paint one background's whole map onto the screen, cell by cell.
        def stamp_background(node)
          # A status bar is painted from its own top, with nothing under it, as the whole view is
          # built (#repaint_view), never stamped from the screen's corner.
          return request_repaint if node.bar?

          tiles = node.tiles
          tile_w = node.tile_w
          tile_h = node.tile_h
          swapped = background_swap(node)
          set_see_through_for(node.name)
          map_of(node).each_with_index do |row, r|
            row.each_with_index do |index, c|
              next if index.nil?

              stamp_tile(tiles, index, c * tile_w, r * tile_h, tile_w, tile_h, swapped)
            end
          end
          @screen.set_paint_see_through(nil)
        end

        # +nodes+ in the order the declared stack asks for (see IR::Stacking).
        def in_stack_order(nodes)
          IR::Stacking.order_by_stack(nodes, @layer_stack, &:layer)
        end

        # Does +a+ sit further back in the stack than +b+? Only when both named a layer:
        # something that named none keeps the place it had, and has no answer here.
        def behind?(a, b)
          depth_a = @layer_stack.index(a.layer)
          depth_b = @layer_stack.index(b.layer)
          depth_a && depth_b && depth_a < depth_b
        end

        # Paint one tile at (x0, y0), skipping its see-through pixels so whatever's already
        # there shows through — the per-pixel form of a tile blit that layering needs.
        def stamp_tile(tiles, index, x0, y0, tile_w, tile_h, swapped = nil)
          tile_h.times do |ty|
            tile_w.times do |tx|
              color = background_pixel(tiles, index, tx, ty, swapped)
              @screen.set_pixel(x0 + tx, y0 + ty, color) unless color.nil?
            end
          end
        end

        # Scroll a background: record where its window now sits (its run-time offset)
        # and recomposite the frame. On the console this is one register write and the
        # tile hardware redraws the layer from that offset — sprites still float on top
        # for free; here we reproduce that by repainting the scrolled scene and drawing
        # the sprites back over it (see #request_repaint).
        def exec_scroll_background(node)
          @bg_by_name.fetch(node.name) { raise ProgramError, "scroll of undeclared background #{node.name.inspect}" }
          @bg_scroll[node.name] = [eval_value(node.x), eval_value(node.y)]
          # ...and a scroll written after it was put up is the place the display reads from, but
          # one placed at the end of the pass that put it up, which shows it from its corner.
          @bg_from_corner.delete(node.name) unless @placing_at_pass_end
          request_repaint
        end

        # PUT A STATUS BAR'S TOP AT A ROW: kept between 0 and the bottom of the screen, where it is
        # out of view, since a bar always reaches the bottom and a row past it shows no more of it.
        def exec_place_bar(node)
          bar = @bg_by_name.fetch(node.name) { raise ProgramError, "place of undeclared status bar #{node.name.inspect}" }
          return unless bar.bar? # a background that is not a status bar has no top to place

          @bar_top[node.name] = eval_value(node.top).clamp(0, @screen.height)
          # ...and placed after it was put up, this is where the display reads it from, but not
          # placed at the end of the pass that put it up (#exec_scroll_background).
          @bg_from_corner.delete(node.name) unless @placing_at_pass_end
          request_repaint
        end

        # Where the status bar +bar+'s top is on the display now: where the game last placed it,
        # but at the row it was declared with for the rest of a pass that put it up, as a
        # background shows from its corner then (see #put_up_background).
        def bar_top_shown(bar)
          declared = bar.bar_top.clamp(0, @screen.height)
          @bg_from_corner.include?(bar.name) ? declared : @bar_top.fetch(bar.name, declared)
        end

        # The status bar on screen now, or nil. The build lets one show at a time.
        def bar_showing = showing_scenery.find(&:bar?)

        # How many rows from the top the backgrounds under a status bar are seen in: down to the
        # bar's top, or the whole screen while no bar shows.
        def scenery_rows
          bar = bar_showing
          bar ? bar_top_shown(bar) : @screen.height
        end

        # A STATUS BAR, painted from its top row to the bottom of the screen. Its map starts at its
        # top-left corner and never scrolls; its see-through pixels, and the rows past the end of
        # its map, leave the backdrop, since the backgrounds under it are not painted there (see
        # #scenery_rows).
        def paint_status_bar(bar)
          map = map_of(bar)
          swapped = background_swap(bar)
          top = bar_top_shown(bar)
          (top...@screen.height).each do |py|
            my = py - top
            row = map[my / bar.tile_h]
            next unless row

            ty = my % bar.tile_h
            row.each_with_index do |index, col|
              px = col * bar.tile_w
              next if index.nil? || px >= @screen.width

              span = [bar.tile_w, @screen.width - px].min
              @screen.paint_row(px, py, tile_colors(bar.tiles[index], swapped), from: ty * bar.tile_w, count: span)
            end
          end
        end

        # HOW A BACKGROUND IS BEING TURNED RIGHT NOW: the angle in degrees, the size in
        # SCALE_ONE-ths, and the point on screen it turns around — which stays still while
        # the rest of the picture swings or grows about it, and is the middle of the screen
        # unless the program named one (see Background#turns_around).
        Turn = Data.define(:angle, :size, :pivot_x, :pivot_y)

        # Turn/resize a background: record this frame's angle and size and recomposite —
        # the affine sibling of #exec_scroll_background. +angle+ wraps to 0..359 the same
        # way a hardware sprite's does, so a program that never wraps it itself (a fixed
        # rotate of, say, 370) still reads the picture the console would show.
        def exec_affine_background(node)
          @bg_by_name.fetch(node.name) { raise ProgramError, "affine transform of undeclared background #{node.name.inspect}" }
          @bg_affine[node.name] = Turn.new(angle: eval_value(node.angle) % 360, size: eval_value(node.scale),
                                           pivot_x: node.around_x, pivot_y: node.around_y)
          request_repaint
        end

        # Where +bg+'s window sits on the display now: where the game scrolled it, but at the
        # corner for the rest of a pass that put it up (see #put_up_background).
        def scroll_shown(bg) = @bg_from_corner.include?(bg.name) ? [0, 0] : (@bg_scroll[bg.name] || [0, 0])

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
        #
        # +tall+ is how many rows a block of the picture is, for a background being put
        # into blocks: every row then shows the picture row at the top of its block, and
        # is still placed by its own bend (see #paint_scenery_in_blocks). One row, which
        # is the picture as drawn, unless said.
        def paint_background_window(bg, tall = 1)
          turn = @bg_affine[bg.name]
          return paint_affine_background_window(bg, turn, tall) if turn
          return paint_streamed_background_window(bg, tall) if bg.streams?

          tiles = bg.tiles
          map = map_of(bg)
          tile_w = bg.tile_w
          tile_h = bg.tile_h
          swapped = background_swap(bg)
          # Wrap over the console's whole cell grid, not over the rows the author wrote
          # (see the note by IR::TileMap). Sampling a cell past those rows finds no tile
          # there, and an absent tile reads as the backdrop.
          cols, rows_of_cells = IR::TileMap.grid(map)
          map_w = cols * tile_w
          map_h = rows_of_cells * tile_h
          base_x, off_y = scroll_shown(bg)
          off_y %= map_h
          width = @screen.width

          scenery_rows.times do |py|
            # A bending background sits somewhere different on every row: this row's own
            # sideways offset, on top of wherever the background is scrolled to.
            off_x = (base_x + bend_offset_at(bg.name, py)) % map_w # Ruby % wraps negatives into 0..map_w-1
            my = (off_y + py - (py % tall)) % map_h
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
              if index
                @screen.paint_row(px, py, tile_colors(tiles[index], swapped), from: (ty * tile_w) + tx,
                                                                              count: span)
              end
              px += span
            end
          end
        end

        # The window of a background whose map is brought into view a strip at a time
        # (see IR::TileMap.streams?): the same walk as #paint_background_window, except
        # that nothing comes round again. A place outside the map has no cell, so the
        # backdrop and the layers behind show there — on the left and above as much as on
        # the right and below, which is why this tests both ends rather than leaning on
        # an index that Ruby would count from the far end of a row when it is negative.
        def paint_streamed_background_window(bg, tall = 1)
          tiles = bg.tiles
          map = map_of(bg)
          tile_w = bg.tile_w
          tile_h = bg.tile_h
          swapped = background_swap(bg)
          map_w = (map.map(&:length).max || 0) * tile_w
          map_h = map.length * tile_h
          base_x, off_y = scroll_shown(bg)
          width = @screen.width

          scenery_rows.times do |py|
            my = off_y + py - (py % tall)
            next if my.negative? || my >= map_h

            row = map[my / tile_h]
            ty = my % tile_h
            off_x = base_x + bend_offset_at(bg.name, py)
            px = 0
            while px < width
              mx = off_x + px
              tx = mx % tile_w # Ruby % keeps this 0...tile_w for a negative place too
              span = [tile_w - tx, width - px].min
              index = mx.negative? || mx >= map_w ? nil : row[mx / tile_w]
              if index
                @screen.paint_row(px, py, tile_colors(tiles[index], swapped), from: (ty * tile_w) + tx,
                                                                              count: span)
              end
              px += span
            end
          end
        end

        # Repaint an affine background's window under +turn+ (see Turn: an angle, a size and
        # the point it all happens around) — the affine sibling of #paint_background_window,
        # which can only slide the window straight.
        #
        # A plain scroll walks the screen a TILE at a time because every pixel in a run
        # comes from the same tile; a turn breaks that — two screen pixels side by side
        # can land on opposite sides of the map — so this asks the question PIXEL by
        # pixel instead, working backwards through the same matrix a turned sprite reads
        # (see IR::Affine): for a screen pixel this far from the center, which map pixel
        # shows there. Dividing by ONE_TH (256, a power of two) with Ruby's `/` rounds
        # down for a negative numerator exactly the way the console's shift-right would,
        # so the two backends land on the same map pixel without either one specially
        # asking for it.
        def paint_affine_background_window(bg, turn, tall = 1)
          tiles = bg.tiles
          map = map_of(bg)
          tile_w = bg.tile_w
          tile_h = bg.tile_h
          cols, rows_of_cells = IR::TileMap.grid(map)
          map_w = cols * tile_w
          map_h = rows_of_cells * tile_h
          # A turned layer is placed by its turn, which putting it up leaves as it is.
          base_x, base_y = @bg_scroll[bg.name] || [0, 0]
          swapped = background_swap(bg)
          pivot_x = turn.pivot_x
          pivot_y = turn.pivot_y
          pa, pb, pc, pd = Affine.matrix(turn.angle, turn.size)

          scenery_rows.times do |py|
            dy = py - (py % tall) - pivot_y
            @screen.width.times do |px|
              dx = px - pivot_x
              tex_dx = ((pa * dx) + (pb * dy)) / Affine::ONE_TH
              tex_dy = ((pc * dx) + (pd * dy)) / Affine::ONE_TH
              mx = (base_x + pivot_x + tex_dx) % map_w
              my = (base_y + pivot_y + tex_dy) % map_h
              row = map[my / tile_h]
              next unless row

              color = background_pixel(tiles, row[mx / tile_w], mx % tile_w, my % tile_h, swapped)
              @screen.set_pixel(px, py, color) unless color.nil?
            end
          end
        end

        # How far across screen row +py+ sits, for a background given a per-row bend: the row
        # number goes into the bend's row variable, then its body runs and its offset is worked
        # out from there — the same expression the console works out for the row, asked the
        # same number of times (see #work_out_bends).
        def run_bend_for_row(bend, py)
          @vars[bend.row] = py
          bend.children.each { |child| exec(child) }
          eval_value(bend.offset)
        end

        # A tile's pixels as colors, ready to paint, row after row in one flat list —
        # so the pixel at (tx, ty) is at (ty * width) + tx. A see-through pixel is nil,
        # which is how paint_row knows to leave that cell as it is.
        #
        # Tiles are fixed at build time and a scrolling background repaints the same
        # handful of them for every row of every frame, so each one is decoded once and
        # kept. That turns the packed bytes into colors a few dozen times instead of a
        # few million. Tiles the game paints are the exception, and a copy of their list
        # throws their kept colors away (see #copy_run_tiles).
        # +swapped+ is another list of colours the tile is being drawn with this frame (see
        # #background_swap), and nil for the colours it was drawn in. A swap goes by PLACE,
        # so a see-through pixel stays see-through however the list is written: place 0
        # means see-through in every list there is.
        #
        # +swaps+ is the list each of the layer's own lists is drawn with this frame, by own list
        # (see #background_swap); the tile takes the one for the list it was drawn from.
        def tile_colors(name, swaps = nil)
          swapped = swaps && swaps[@bitmaps.fetch(name).list_drawn_from]
          @tile_colors[[name, swapped]] ||= begin
            bmp = @bitmaps.fetch(name)
            recolor = swapped && tile_recolor(name, bmp, swapped)
            Array.new(bmp.width * bmp.height) do |i|
              # Read off the pixel as drawn, never after a swap of colours: a swap moves what
              # a place shows and leaves the place, and so what shows through, alone.
              next if bmp.tile_see_through_at?(i)

              color = bmp.color_at(i)
              recolor.nil? ? color : recolor.color_for(i, color)
            end
          end
        end

        # The same map from a picture's own colours to another list's that an object uses
        # (see #object_recolor), kept in the same place: a tile IS a picture, and the two
        # ways of reading one — by the place each pixel was drawn at, or by its colour where
        # the art recorded no places — are the picture's business rather than the layer's.
        def tile_recolor(name, bmp, swapped)
          @recolor_maps[[name, swapped]] ||= Assets::Recolor.of(bmp, swapped)
        end

        # THE COLOURS A BACKGROUND'S TILES ARE DRAWN FROM THIS FRAME: the step the game last
        # named, as each of the layer's own lists to the list it is drawn with instead — or nil
        # for the ones they were drawn in, which is also what a number naming no step means, so
        # a counter that has run off the end looks right.
        def background_swap(bg)
          lists = bg.recolors
          return nil if lists.empty?

          which = @bg_colors[bg.name] || Build::NO_RECOLOR
          return nil unless which >= 0 && which < lists.length

          # Kept by declaration, not by name: two scenes can each declare a background by one
          # name with lists of their own, and the number the game tells the name picks out of
          # whichever is painted.
          @bg_swaps[[bg.name, bg.scene, which]] ||= bg.list_swaps(which)
        end

        # Draw this background's tiles from the list of colours numbered +which+ from now on
        # — the whole layer at once. Nothing about the map or the pictures changes; the next
        # repaint reads them through the swap.
        def exec_background_colors(node)
          @bg_by_name.fetch(node.name) do
            raise ProgramError, "colors of undeclared background #{node.name.inspect}"
          end
          @bg_colors[node.name] = eval_value(node.which)
          request_repaint
        end

        # Rebuild the whole visible screen the way tile-and-sprite hardware does: paint
        # the backdrop, then the background layers from back to front (each scrolled to
        # its own offset, so nearer layers can slide faster than far ones — parallax),
        # then the sprites over the top in draw order. A fresh repaint means last frame's
        # sprites vanish with it — no save-under needed. Both scroll_background and
        # present_objects call this, so whichever runs last in a frame leaves the
        # settled, correct image regardless of their order.
        # A REPAINT IS OWED RATHER THAN DONE, where it can be. Repainting the whole view is most
        # of what a frame costs here, it is asked for several times a frame (every scroll, and
        # again as the frame is presented), and a test that only reads variables never looks at
        # any of it. So asking marks it owed, and it is painted when something needs it: the
        # picture is read (#screen), something is drawn onto it or changes what it is built from
        # (#exec), or the pages of a tear-free screen trade places (#advance_frame).
        #
        # The picture that comes out is the one painting at once would have made, because
        # nothing it is built from can change while it is owed: a statement that does settles
        # it first, and a statement that repaints anyway simply takes its place. The one input
        # a statement cannot be seen changing is a VARIABLE. A see-through amount the game works
        # out reads them, so the amounts are read when the repaint is owed and the later paint
        # uses those — the numbers painting then would have used. A bending background's rows
        # are worked out once a pass and kept (#work_out_bends), so painting one reads no
        # variable at all.
        #
        # A PAINTED SCREEN IS NEVER BUILT AGAIN, in a game that also has screens drawn from
        # tiles. Its picture is whatever the program painted there, a title painted once
        # among them, and building the view from scenery would wipe that — the display such a
        # screen is shown on reads the painted picture and nothing else. What asks while one
        # is up is the machinery of the game's other screens, which runs every frame whichever
        # is showing. The scenery of the screen that follows is put up as that screen arrives.
        def request_repaint
          return if @screen_mode == :bitmap && @changes_screen_kind

          forget_expired_corners
          @picture_owed = true
          @owed_weights = capture_see_through_weights
        end

        def paint_owed_repaint
          return forget_expired_corners unless @picture_owed

          @picture_owed = false
          repaint_view
          @owed_weights = nil
          forget_expired_corners
        end

        def mark_from_corner(node)
          forget_expired_corners
          @bg_from_corner << node.name
        end

        # The corners of the backgrounds put up in a pass that has ended (#advance_frame): gone
        # once that pass's picture is painted, or once a later pass changes what the picture is
        # made of — the game's own place for the view shows from the frame after.
        def forget_expired_corners
          return unless @bg_corners_expired

          @bg_corners_expired = false
          @bg_from_corner.clear
        end

        # The amounts of each see-through layer the game works out and that has something in it
        # on screen, as they stand now. A layer whose amounts are numbers written in the program
        # never changes, and one with nothing on screen is never painted, so neither is worked
        # out here — working one out can fail (a divide by a number that is still 0), and only
        # the amounts painting would read may do that.
        def capture_see_through_weights
          return nil unless @see_through

          @see_through.each_value.with_object({}) do |layer, weights|
            weights[layer.name] = live_see_through_weights(layer) unless fixed_see_through?(layer) || !layer_has_anything?(layer)
          end
        end

        # Whether anything that could be on screen now is in see-through +layer+: a background
        # showing now, or a sprite anywhere, since whether a sprite is shown is a variable too.
        def layer_has_anything?(layer)
          showing_scenery.any? { |bg| bg.layer == layer.name } ||
            @objects.each_value.any? { |object| object.layer == layer.name }
        end

        # Statements that cannot change the picture or anything it is built from, so a repaint
        # owed across them is still the right one: values, variables, lists, sound, a
        # declaration reached while running (gathered before the run, so it does nothing), and
        # the control flow whose own children are asked one at a time.
        LEAVE_THE_PICTURE_OWED = %i[var list sound value data].freeze
        STEERING = %i[if else case repeat loop call call_one_of every after on_timer timer_start timer_stop
                      func wait_vblank object].freeze
        # ...and the ones that change what the picture is built from and then always repaint, so
        # an owed repaint is replaced rather than painted — plus `background`, which settles one
        # itself when it has anything to put up (see #exec_background).
        REPAINTING = %i[scroll_background place_bar show_map set_tile copy_tiles copy_owed_tiles background_colors see_through present_objects
                        background affine_background].freeze
        # ...and the ones that are mostly laid over the picture as the screen is read, and that
        # owe the picture again themselves on the occasions they change what is painted (see
        # #exec_fade).
        READ_OVER_THE_PICTURE = %i[fade tint pixelate].freeze

        def defers_repaint?(node) = self.class.defers_repaint?(node)

        # The same rule asked of the class, for a backend that has to keep it too: the native
        # one paints an owed rebuild before exactly the statements this one does.
        def self.defers_repaint?(node)
          STEERING.include?(node.kind) || REPAINTING.include?(node.kind) ||
            READ_OVER_THE_PICTURE.include?(node.kind) || LEAVE_THE_PICTURE_OWED.include?(node.category)
        end

        def repaint_view
          kept = @fade_placed ? names_above_placed_fade : nil
          set_blend_for(nil, kept)      # the backdrop is behind everything, so it blends
          @screen.clear(@backdrop)        # the backdrop the layers' transparent pixels reveal
          # A status bar first: no background is painted under it (#scenery_rows), so it is in
          # front of all of them, and every sprite is painted over it.
          bar = bar_showing
          if bar
            set_blend_for(bar.name, kept)
            paint_status_bar(bar)
          end
          levels = @picture.depths
          (0...levels.count).each do |level|
            # Scenery first, then the objects that share this level — an object is drawn
            # over the scenery it sits with, which is what lets a picture put scenery in
            # front of one object and behind another.
            showing_scenery.each do |bg|
              next if bg.bar? || levels.of_scenery(bg) != level

              set_blend_for(bg.name, kept)
              paint_scenery(bg)
            end
            @obj_layer.each do |obj|
              next unless obj[:level] == level

              set_blend_for(obj[:name], kept)
              paint_snapshot_object(obj)
            end
          end
          @screen.set_paint_fade(nil, nil)
          @screen.set_paint_see_through(nil)
        end

        # A fade, over the whole screen or placed in the stack.
        #
        # Over the whole screen it is a blend applied as the screen is READ, so nothing
        # that was drawn changes and the picture comes back untouched when the fade lifts.
        #
        # Placed under a layer it cannot be that, because the things in front of the line
        # have to come through unblended. So the blend is applied to each thing as the
        # picture is BUILT, and the picture is owed again right here — a fade is usually
        # written after the frame has already been composited, and the frame that asked
        # for it is the frame that has to show it. The same goes for the fade that takes a
        # placed one's place, which has to take it back out of the picture.
        #
        # Any other fade leaves an owed repaint owed (see #request_repaint), since
        # nothing the paint reads has changed.
        def exec_fade(node)
          amount = eval_value(node.amount)
          was_fading = fading?
          was_placed = @fade_placed
          walked = @fading.palette_walk?(node)
          steps = FadeSteps.steps(amount, fraction_bits: node.fraction_bits, walked: walked)
          @fade_placed = node.under && [node.under, node.toward, steps]
          if walked
            fade_by_tint(node, steps)
          else
            @screen.fade_steps_to(node.toward, @fade_placed ? 0 : steps, reaches: node.reaches, area: node.area)
          end
          # A fade that takes the see-through layer's blend hands it back when it lifts
          # (see #fading?), so the picture has to be built again at each of those two
          # moments — the layer is drawn solid on one side of them and see-through on the
          # other.
          request_repaint if was_placed || @fade_placed || (@see_through && fading? != was_fading)
        end

        # A fade that moves the COLORS instead of asking the display to blend (see
        # IR::Fading for which fades those are and why).
        #
        # Moving every color toward black by a fraction and moving the finished picture
        # there come to the same picture, so this is a tint toward black or white, counted
        # in thirty-seconds.
        #
        # ROUNDED THE WAY THE CONSOLE'S DOCUMENTED FADE IS, not the way a mix is. A mix keeps
        # a share of each channel and rounds that down; the documented fade takes a share
        # AWAY and rounds the share down, which leaves the channel rounded up. On a dark
        # picture that is a whole frame at the end of a fade in, flat black on one and the
        # picture on the other, so the console's walk adds the rounding back
        # (PaletteTint::DARKEN) and this walks the colors by the same rule, in five bits.
        # Toward white the two rules agree anyway. The display's own fade on the emulator
        # is worked out at eight bits instead (Framebuffer#darkened_by_display), and there a
        # dark colour reaches black a level early, so on a dark picture the two are black on
        # frames a step apart at each end.
        #
        # What it buys is everything the tint already has: the
        # display's blend unit is never told anything, so the see-through layer goes on
        # blending and the mix darkens along with both sides of it.
        #
        # THE PLAIN BITMAP SCREEN HAS NO COLORS TO WALK — it holds a whole color in every
        # pixel — so while one is up the display fades it, in its own sixteenths, the way a
        # tint is mixed there. The fade is the same one either way, and a screen that takes
        # over while it is in force does it that screen's way (see #exec_screen).
        def fade_by_tint(node, steps)
          @screen.tint_steps_to(node.toward, steps, by_display: tint_by_display?)
        end

        # SHOW THE PICTURE IN FLAT BLOCKS of this many pixels each way, from now on. Nothing
        # painted so far changes: the size is read as the picture is next built, so the
        # picture is owed again on the occasions the size is a different one.
        #
        # What is left as drawn all the same is not this statement's to say: a program
        # has one place for its blocks, known before it runs (see #place_blocks).
        def exec_pixelate(node)
          size = Blocks.size(eval_value(node.size))
          return if size == @block

          @block = size
          return @screen.show_in_blocks(size) if painted_screen?

          request_repaint
        end

        # WHERE THIS PROGRAM'S BLOCKS STOP: the names of everything in the layer its
        # `pixelate` statements are placed under, and in front of it, which stay as drawn
        # whatever the size. Nothing, for a program that pixelates the whole picture.
        #
        # One place for the whole program, and two is refused. This picture could move the
        # line as it runs, and a display that keeps "in blocks" as a switch on each thing
        # could not, so neither does (see Blocks).
        def place_blocks(program)
          places = Blocks.places(program)
          raise ProgramError, Blocks.several_places_message(places) if places.size > 1

          @block_kept = places.first ? names_at_or_above(places.first) : []
        end

        # Is the thing called +name+ shown in blocks right now?
        def in_blocks?(name) = @block > 1 && !@block_kept.include?(name)

        # Is the screen that is up one the program paints? To the display that is a single
        # background, whatever was painted on it, so it goes into blocks whole, as it is
        # read. A screen drawn from tiles is built a thing at a time.
        def painted_screen? = @screen_mode.nil? || !IR::SceneHandover.tiles?(@screen_mode)

        # Paint one background where it sits in the view: as drawn, or in blocks while the
        # picture is shown in them.
        def paint_scenery(bg)
          return paint_background_window(bg) unless in_blocks?(bg.name)

          paint_scenery_in_blocks(bg)
        end

        # ONE BACKGROUND IN BLOCKS, and the rule is the display's own.
        #
        # THE BLOCKS ARE FIXED TO THE SCREEN. A block starts at every column and every row
        # that is a multiple of its size, and shows the colour the background has at the
        # block's top left corner — so a background that scrolls slides under a grid that
        # stays where it is. A corner that is see-through leaves the whole block
        # see-through, and what is behind shows there.
        #
        # DOWN AND ACROSS ARE DONE APART, because a display draws a row at a time. Down:
        # every row of a block is drawn from the picture row its top row shows (the
        # painters take how tall a block is) — but placed where the row ITSELF sits, so a
        # background whose rows are each bent a different way keeps each row's own bend,
        # and a block of it is a sheared one. Across: each pixel of a row then takes the
        # one at the start of its block in that same row.
        #
        # So the background is painted onto a sheet of its own, rows first, and laid onto
        # the picture through the blocks. Whatever blend is in force for it applies as it
        # is laid, the same as when it is painted straight on.
        def paint_scenery_in_blocks(bg)
          sheet = framebuffer_like_screen(fill: nil)
          drawing_into(sheet) { paint_background_window(bg, @block) }
          width = @screen.width
          wide = block_width_across(bg)
          scenery_rows.times do |py|
            row = Array.new(width) { |px| sheet.stored_pixel(px - (px % wide), py) }
            @screen.paint_row(0, py, row, from: 0, count: width)
          end
        end

        # How wide a block of +bg+ is. The size, with one exception that is the emulator's
        # and is kept because the console's picture is checked against it: a background
        # that can turn is left a single pixel wide at a size of two, so its rows double
        # and its columns do not. From three up it is in blocks both ways like any other.
        def block_width_across(bg)
          bg.affine && @block == 2 ? 1 : @block
        end

        # A tint — the same idea as a whole-screen fade, toward a color a fade cannot
        # reach. Applied as the screen is read, so nothing drawn changes and the picture
        # is all still there when the amount returns to 0.
        #
        # Counted in thirty-seconds whichever way it reaches the screen. Where the display
        # blends it, it is counted in sixteenths, and a sixteenth is two thirty-seconds.
        #
        # The display blends it only on the plain bitmap screen, which holds a whole color
        # in every pixel. Every other screen draws through a color table, and there the game
        # writes the tinted colors into the table itself, so they round the way the game's
        # own arithmetic does rather than the display's. Which one a tint is follows the
        # screen up NOW, and a tint left on while the game changes kind of screen is mixed
        # the new screen's way from then on (see #exec_screen), as the console puts it back.
        #
        # A TINT TAKES THE PLACE OF WHATEVER FADE WAS IN FORCE, a fade placed in the stack
        # included: a picture has one such effect at a time, and the last one said is it.
        # A fade that goes may have been holding a see-through layer solid, or have been
        # painted into the picture, so the picture is owed again when one does.
        def exec_tint(node)
          was_fading = fading?
          was_placed = @fade_placed
          @fade_placed = nil
          steps = FadeSteps.steps(eval_value(node.amount), fraction_bits: node.fraction_bits, walked: true)
          @screen.tint_steps_to(Graphics::Color.resolve(node.color), steps, by_display: tint_by_display?)
          request_repaint if was_placed || (@see_through && fading? != was_fading)
        end

        # Does the display mix a tint in as it draws, which only the plain bitmap screen does?
        def tint_by_display? = painted_screen? && !@buffered && @console.blends

        # Turn the blend on or off for the thing about to be painted: on for anything the
        # placed fade reaches, off for anything it leaves alone. A +name+ of nil is the
        # backdrop, which is behind everything and so is always reached.
        def set_blend_for(name, kept)
          set_see_through_for(name)
          return @screen.set_paint_fade(nil, nil) if kept.nil?
          return @screen.set_paint_fade(nil, nil) if name && kept.include?(name)

          @screen.set_paint_fade(@fade_placed[1], @fade_placed[2])
        end

        # Turn the see-through blend on for a thing in the see-through layer, and off for
        # everything else. The picture is painted back to front, so "blend with what is
        # already in the buffer" is the display's own "blend with the layer directly
        # beneath" — the stack does not have to be consulted a second time. The one thing
        # already in the buffer that the display would not blend with is another sprite,
        # so the screen is told when the thing is a sprite, and mixes it with the scenery it
        # keeps apart instead (see Framebuffer#keep_scenery).
        def set_see_through_for(name)
          layer = see_through_layer_of(name)
          @screen.set_paint_see_through(layer && !fading? ? see_through_weights(layer) : nil,
                                        sprite: @objects.key?(name))
        end

        # How much of a see-through layer and of what is behind it the display takes, in steps,
        # for the picture being painted: the amounts as they were when a repaint painted now
        # was owed (see #request_repaint), or as they are, so a picture whose amounts
        # the program works out — fog that thickens — is painted at the amounts it had then.
        def see_through_weights(layer)
          @owed_weights&.[](layer.name) || live_see_through_weights(layer)
        end

        def live_see_through_weights(layer)
          SeeThrough.weights(layer, eval_value(layer.shows), eval_value(layer.behind))
        end

        # The amounts have been worked out again for the frame about to be drawn. Nothing
        # to store: the paint above reads them. What this owes is the picture, since a
        # scene that neither moves nor scrolls would otherwise keep the one it was painted
        # with.
        def exec_see_through(node)
          weights = live_see_through_weights(@see_through.fetch(node.layer))
          @see_through_shown ||= {}
          return if weights == @see_through_shown[node.layer]

          @see_through_shown[node.layer] = weights
          request_repaint
        end

        # A layer whose amounts are both numbers the author wrote, which never change.
        def fixed_see_through?(layer)
          layer.shows.kind == :int && layer.behind.kind == :int
        end

        # The see-through layer the thing called +name+ is in, or nil.
        def see_through_layer_of(name)
          return nil unless @see_through && name

          node = @bg_by_name[name] || @objects[name]
          node && @see_through[node.layer]
        end

        # Is a fade in force that takes the blend? A see-through layer asks, because a
        # display blends two layers together or moves the whole picture toward a color —
        # it is one unit and it does one of them. While such a fade runs the layer is
        # solid and darkens with everything else, and it comes back untouched when the
        # fade lifts.
        #
        # A fade that WALKS THE COLORS never gets here: it leaves the blend unit alone,
        # so it sets no fade amount and there is nothing for this to find (see
        # #fade_by_tint). What is left is a fade placed in the stack, which cannot take
        # that route and does take the layer's blend.
        def fading?
          return @fade_placed[2].positive? if @fade_placed

          @screen.fade_steps.positive?
        end

        # The names the fade in force leaves alone — its layer and everything in front.
        def names_above_placed_fade = names_at_or_above(@fade_placed[0])

        # The names of everything in +layer+ and in front of it. Worked out once per layer,
        # because it depends only on the picture — so the same layer always answers with
        # the same list.
        def names_at_or_above(layer)
          @names_at_or_above[layer] ||= IR::Stacking.at_or_above(@picture, layer).map(&:name)
        end

        # Draw one snapshotted object from the layer captured this frame.
        def paint_snapshot_object(obj)
          return paint_object_in_blocks(obj) if in_blocks?(obj[:name])

          if obj[:transform]
            return blit_image_transformed(obj[:image], obj[:x], obj[:y], *obj[:transform],
                                          scales: object_scales?(@objects.fetch(obj[:name])), recolor: obj[:recolor])
          end

          blit_image(obj[:image], obj[:x], obj[:y], recolor: obj[:recolor])
        end

        # ONE SPRITE IN BLOCKS, while the picture is shown in them (see SpriteBlocks, which
        # holds the rule).
        def paint_object_in_blocks(obj)
          blocks = SpriteBlocks.new(@screen, @block)
          name = obj[:image]
          bmp = @bitmaps.fetch(name)
          color_at = picture_reader(name, obj[:recolor])
          unless obj[:transform]
            declared = @objects.fetch(obj[:name])
            boxes = object_boxes(declared).fetch(declared.poses.index(name))
            return blocks.paint_upright(obj[:x], obj[:y], boxes, &color_at)
          end

          w = bmp.width
          h = bmp.height
          pa, pb, pc, pd = Affine.matrix(obj[:transform][0] % 360, obj[:transform][1])
          # The same walk back to the picture #blit_image_transformed makes, from a place in
          # the double-size box.
          top = obj[:y] - (h / 2)
          rows = turned_rows_shown(top, w, h, object_scales?(@objects.fetch(obj[:name]))).map(&:last)
          blocks.paint_turned(obj[:x] - (w / 2), top, w * 2, h * 2, rows) do |ix, iy|
            ddx = ix - w
            ddy = iy - h
            color_at.call((((pa * ddx) + (pb * ddy)) >> 8) + (w / 2), (((pc * ddx) + (pd * ddy)) >> 8) + (h / 2))
          end
        end

        # What the picture +name+ shows at a column and row of itself: a colour, or nil
        # where it is see-through and anywhere outside it. +recolor+ is as for #blit_image.
        def picture_reader(name, recolor)
          bmp = @bitmaps.fetch(name) { raise ProgramError, "blit of undefined image #{name.inspect}" }
          pixels = @data.fetch(name)
          transparent = bmp.transparent
          lambda do |col, row|
            next nil unless col >= 0 && col < bmp.width && row >= 0 && row < bmp.height

            at = (row * bmp.width) + col
            color = pixels.getbyte(at * 2) | (pixels.getbyte((at * 2) + 1) << 8)
            next nil if transparent && color == transparent

            recolor ? recolor.color_for(at, color) : color
          end
        end

        # THE BOXES EACH POSE OF A SPRITE IS DRAWN AS, for the one thing here that has to
        # know: a sprite in blocks is put into them a box at a time (see SpriteBlocks).
        #
        # Nothing else about this picture depends on them. A sprite is its canvas at a
        # place, however a display cuts that up — trimmed to what a pose draws, or in
        # pieces when it is bigger than any one object. Blocks are the exception, because
        # each object holds the place it reads inside its own edges.
        #
        # So the cut is asked of SpriteCut, which every backend reads, and not worked out
        # a second time here: two copies of that rule would be two answers the day one of
        # them changed.
        def object_boxes(obj)
          @object_boxes ||= {}
          @object_boxes[obj.name] ||= begin
            width, height = SpriteCut.canvas_of(@bitmaps, obj.poses)
            whole = object_transformed?(obj) || obj.poses.any? { |pose| painted_picture?(pose) }
            SpriteCut.new(@bitmaps).cut(obj.poses, width: width, height: height, whole: whole)[:boxes]
          end
        end

        # Is this picture one the game paints from a list while it runs?
        def painted_picture?(name) = @tile_runs.each_value.any? { |run| run.picture == name }

        # The color of a background cell's pixel, or nil where the layer behind shows
        # through: an empty cell (a map hole, which the hardware shows as background-palette
        # entry 0) and a see-through pixel of a tile (see #see_through_tile_pixel?) alike.
        def background_pixel(tiles, index, x, y, swapped = nil)
          return nil if index.nil?

          tile_colors(tiles[index], swapped)[(y * @bitmaps.fetch(tiles[index]).width) + x]
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
        # objects on top). See #request_repaint.
        def exec_present_objects(node)
          @drawn = @sprites_hidden ? [] : objects_on_screen(names_in_draw_order(node))
          @sprites_hidden = false
          refuse_pictures_not_up!(@drawn)
          # Kept whichever way the picture is made, with each sprite's depth and colours as they
          # are now: a scene taking over later in this pass builds the picture again from it
          # (see #redraw_sprites_over_arrived_scenery).
          snapshot_object_layer

          if @repaints
            request_repaint
            return
          end

          scene = scene_framebuffer
          node.names.each do |name|
            prev = @obj_prev[name]
            restore_scene_rect(scene, name, prev) if prev
            @obj_prev[name] = nil
          end
          @drawn.each do |on|
            draw_object(on[:object], on[:picture], on[:x], on[:y])
            @obj_prev[on[:object].name] = [on[:x], on[:y]]
          end
        end

        # NO SPRITE ON THE NEXT FRAME. The sprites are drawn as the next pass begins, from the
        # pass that just ran, and that drawing draws none and forgets this was asked: every
        # sprite is where it was, so the drawing after puts each one back where it would have
        # been. On the console the sprite layer is switched off for that frame, which hides the
        # same things — and so a sprite showing a grouped picture whose group is not up is no
        # mistake on that frame, since nothing draws it.
        def exec_hide_sprites(_node)
          @sprites_hidden = true
        end

        # The frame's objects in the order they are drawn: as listed, except that each run the
        # program puts in order is drawn in the order its list holds (see Build#present_objects).
        def names_in_draw_order(node)
          (node.orders || []).reduce(node.names) do |names, run|
            first = names.index(run.objects.first)
            ordered = @lists.fetch(run.order).to_a.map { |at| run.objects.fetch(at) }
            names[0...first] + ordered + names[(first + run.objects.length)..]
          end
        end

        # WHAT IS ON SCREEN THIS FRAME: one entry per object being drawn, saying which of its
        # pictures the pose selector picked and where it went. An object the game has switched
        # off, or one whose selector points outside its set of pictures, is simply not here —
        # which is what "not being drawn" means, and is the answer both the drawing below and a
        # test asking where something is want back.
        #
        # Worked out once a frame and kept, because two callers want it: the drawing, and
        # {#sprites}. Reading it back is how a test asks the oracle which of the things it drew
        # is the one the game named, without knowing a position or a colour in advance.
        def objects_on_screen(names)
          names.filter_map do |name|
            obj = @objects.fetch(name) { raise ProgramError, "present of undeclared object #{name.inspect}" }
            next unless eval_value(obj.active) == 1

            picture = object_pose_image(obj)
            next if picture.nil?

            { object: obj, name: obj.declared, picture: picture,
              x: eval_value(obj.x), y: eval_value(obj.y) }
          end
        end

        # Draw one object's picture at (x, y): straight when it never turns or resizes,
        # through the transform when it does. Shared by the still-scene present path and
        # the scrolling-scene recomposite.
        def draw_object(obj, image, x, y)
          set_see_through_for(obj.name)
          recolor = object_recolor(obj, image)
          if object_transformed?(obj)
            blit_image_transformed(image, x, y, *object_transform(obj), scales: object_scales?(obj), recolor: recolor)
          else
            blit_image(image, x, y, recolor: recolor)
          end
          @screen.set_paint_see_through(nil)
        end

        # THE COLOURS AN OBJECT IS DRAWN IN THIS FRAME, when it is told to draw with another
        # list: each place of the picture's own list shows the colour at the same place of
        # that list. nil draws the picture as it is stored.
        def object_recolor(obj, image)
          lists = obj.recolors
          return nil if lists.empty?

          which = eval_value(obj.recolor)
          return nil unless which >= 0 && which < lists.length

          swapped = lists[which]
          swapped = colors_held_by(swapped) if swapped.is_a?(Symbol)
          @recolor_maps[[image, swapped]] ||= Assets::Recolor.of(@bitmaps.fetch(image), swapped)
        end

        # THE COLOURS A NAMED LIST HOLDS NOW: the set the program last said, or the ones it was
        # declared with — which is also what a number naming no set means.
        def colors_held_by(name)
          list = @color_lists.fetch(name) { raise ProgramError, "drawn with undeclared list of colors #{name.inspect}" }
          which = @held_colors.fetch(name, Build::NO_RECOLOR)
          which >= 0 && which < list.recolors.length ? list.recolors[which] : list.colors
        end

        # A list of colours holds the set numbered +which+ from now on. Nothing is painted
        # here: everything drawn with the list reads it as it is next drawn.
        def exec_color_list_holds(node)
          @held_colors[node.name] = eval_value(node.which)
        end

        # One slot of a set of picture groups holds the group numbered +which+ from now on.
        # Nothing is drawn here: the groups up are only asked about as the sprites are drawn.
        def exec_show_picture_group(node)
          @groups_up.fetch(node.name)[node.slot] = eval_value(node.which)
        end

        # GROUPED PICTURES ARE UP ONLY WHILE ONE OF THEIR GROUPS IS. This backend has every
        # picture in reach whatever is up, so it would draw a sprite showing a picture whose
        # group is not up exactly as the game meant — and the console, which keeps only the
        # groups up in its sprite memory, would draw it from tiles holding some other room's
        # pictures. Stopped here, in plain words, it is a failed test on every build rather than
        # garbage on one of them. So is two groups up at once that up_together never said can be,
        # since the console may have put their pictures in the same place.
        #
        # A sprite answers to the groups of its own scene and to the groups every screen has, and
        # only once its scene has taken over: until then its scene's pictures are not the ones up
        # on the console either, groups or none.
        def refuse_pictures_not_up!(drawn)
          return if @picture_groups.empty?

          @picture_groups.each_value { |groups| refuse_groups_not_together!(groups) if up_in_this_scene?(groups.scene) }
          drawn.each do |on|
            scene = on[:object].scene
            next unless up_in_this_scene?(scene)

            @picture_groups.each_value do |groups|
              next unless groups.scene.nil? || groups.scene == scene

              holding = groups.groups_holding(on[:picture])
              next if holding.empty? || holding.intersect?(up_numbers(groups))

              raise ProgramError, picture_not_up_message(on, groups, holding)
            end
          end
        end

        # Is what belongs to +scene+ (nil: every screen) up now?
        def up_in_this_scene?(scene) = scene.nil? || scene == @scene

        # The numbers of the groups of +groups+ up now: the slots' that name a group.
        def up_numbers(groups) = @groups_up.fetch(groups.name).select { |number| groups.names_group?(number) }.uniq

        def refuse_groups_not_together!(groups)
          up = up_numbers(groups)
          raise ProgramError, groups_not_together_message(groups, up) unless groups.together?(up)
        end

        def groups_not_together_message(groups, up) = Faults.groups_not_together(groups: groups.name, up: up)

        def picture_not_up_message(on, groups, holding)
          Faults.picture_not_up(sprite: on[:object].declared || on[:object].name, picture: on[:picture],
                                groups: groups.name, holding: holding, up: up_numbers(groups))
        end

        # Does this object turn or resize? It does unless BOTH its angle and its size are
        # still the constants they default to — an object that never calls
        # turn/face_angle/scale keeps them and draws straight, so we take the cheaper
        # blit path for it.
        def object_transformed?(obj)
          !(constant?(obj.angle, 0) && constant?(obj.scale, Build::SCALE_ONE))
        end

        def constant?(node, value)
          node.kind == :int && node.value == value
        end

        # This frame's angle and size for a transformed object.
        def object_transform(obj)
          [eval_value(obj.angle), eval_value(obj.scale)]
        end

        # The objects on screen this frame dressed for compositing — each with the depth it
        # sits at and the colours it is being drawn in — as the sprite layer
        # #request_repaint paints over the scrolled scene, in draw order.
        def snapshot_object_layer
          @obj_layer = @drawn.map do |on|
            obj = on[:object]
            image = on[:picture]
            snap = { name: obj.name, image: image, x: on[:x], y: on[:y],
                     level: object_level(obj), recolor: object_recolor(obj, image) }
            snap[:transform] = object_transform(obj) if object_transformed?(obj)
            snap
          end
        end

        # How deep an object sits this frame: the layer it was put in, or the one it was
        # declared in for a number that names none of the others.
        def object_level(obj)
          return @picture.depths[obj.name] if obj.layers.nil? || obj.layers.empty?

          pick = self[obj.layer_pick]
          return @picture.depths[obj.name] unless pick.between?(0, obj.layers.length - 1)

          @picture.depths[IR::Stacking.choice_name(obj, obj.layers[pick])]
        end

        # Which of an object's poses to draw right now — its pose selector picks one
        # of its same-size pictures (facing a direction, or an animation frame). An
        # index outside the set selects nothing.
        def object_pose_image(obj)
          poses = obj.poses
          index = eval_value(obj.pose)
          poses[index] if index >= 0 && index < poses.length
        end

        # The settled scene the objects sit on — the backdrop plus every background —
        # rendered once into its own framebuffer. Backgrounds don't change once drawn,
        # so this is the clean picture we restore under a moving object each frame.
        def scene_framebuffer
          @scene_fb ||= begin
            fb = framebuffer_like_screen(fill: @backdrop) # the backdrop the empty parts of the scene show
            drawing_into(fb) { showing_scenery.each { |bg| stamp_background(bg) } }
            fb
          end
        end

        # Put the clean scene back where an object was last drawn, erasing it before it's
        # redrawn at its new spot. All of an object's poses are the same size, so the
        # first pose gives the patch to restore — its own size for an upright object, or
        # the bigger square a turning object can cover at any angle.
        def restore_scene_rect(scene, name, (x, y))
          obj = @objects.fetch(name)
          width, height = SpriteCut.canvas_of(@bitmaps, obj.poses)
          if object_transformed?(obj)
            rx, ry, w, h = transformed_footprint(obj, x, y, width, height)
            restore_patch(scene, rx, ry, w, h)
            # ...and where a tall patch came round onto the other end of the screen (see
            # TurnedBox), which is the same patch a whole count of lines up or down.
            [-TurnedBox::LINES, TurnedBox::LINES].each do |round|
              restore_patch(scene, rx, ry + round, w, h) if ry + round < @screen.height && ry + round + h > 0
            end
          else
            restore_patch(scene, x, y, width, height)
          end
        end

        # Copy a width×height patch of the settled scene back onto the screen (skipping
        # any cell that falls off it), erasing whatever an object had drawn there.
        def restore_patch(scene, x, y, width, height)
          height.times do |row|
            width.times { |col| @screen.put_back_cell(scene, x + col, y + row) }
          end
        end

        # Draw an image turned +degrees+ clockwise and +scale+ times its size, about its
        # own center, its untransformed top-left at (x, y) — the reference interpreter's
        # stand-in for the console's sprite rotate/scale. See {IR::Affine} for the matrix
        # both backends share.
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
        #     That box is also the ceiling on size: at twice its size a picture fills the
        #     box exactly, and past that its edges are cut off — here and on the console.
        #   * The turn uses whole numbers in 256ths, from the same table of sines the
        #     ROM carries — not exact trigonometry.
        #   * A screen pixel is taken at its whole coordinate, NOT at its center, and
        #     the answer is rounded down. Sampling at pixel centers instead moves the
        #     whole shape half a pixel, which shows up as a one-pixel-thick disagreement
        #     all along one side.
        # One column of a picture, stretched to a height the program worked out.
        #
        # The stepping rule here IS the specification, because both backends have to land every
        # pixel in the same place: walk DOWN THE SCREEN and ask which row of the picture belongs
        # at each screen row. Walking the picture instead and asking where each of its rows
        # lands would leave gaps when stretching and would draw some rows twice when squashing.
        #
        # The step is held in 16ths of a picture row so the console can do it by adding rather
        # than dividing, and truncating at each step is what the console's shift does.
        FIXED = 16

        def exec_draw_column_at(node)
          height = eval_value(node.height)
          return if height <= 0

          bmp = @bitmaps.fetch(node.name) do
            raise ProgramError, "draw_column_at of undefined image #{node.name.inspect}"
          end
          pixels = @data.fetch(node.name)
          slice = eval_value(node.slice).clamp(0, bmp.width - 1)
          x = eval_value(node.x)
          top = eval_value(node.top)
          step = (bmp.height << FIXED) / height

          # Every pixel across the strip shows the same picture column at the same height, so
          # the walk is done once and its answer written across.
          width = node.width || 1

          # Only the rows that show. A wall you are nose-to-nose with is many times taller
          # than the screen, and walking its rows to throw them away is work that grows with
          # how close you stand — so the walk starts on the first row that shows and stops
          # after the last, which is what lets a height be what perspective says it is.
          rows = [[-top, 0].max, [height, @screen.height - top].min].then { |a, z| a...z }

          rows.each do |row|
            source = ((row * step) >> FIXED).clamp(0, bmp.height - 1)
            at = (((source * bmp.width) + slice) * 2)
            color = pixels.getbyte(at) | (pixels.getbyte(at + 1) << 8)
            next if bmp.transparent && color == bmp.transparent

            width.times { |dx| @screen.set_pixel(x + dx, top + row, color) } # the screen clips
          end
        end

        def blit_image_transformed(name, x, y, degrees, scale, scales:, recolor: nil)
          bmp = @bitmaps.fetch(name) { raise ProgramError, "blit of undefined image #{name.inspect}" }
          pixels = @data.fetch(name)
          transparent = bmp.transparent
          w = bmp.width
          h = bmp.height
          pa, pb, pc, pd = Affine.matrix(degrees % 360, scale)
          left = x - (w / 2) # the double-size patch: half a picture out on every side
          top = y - (h / 2)

          # Which row of the screen each row of the patch lands on is not always the row it
          # stands at (see TurnedBox).
          turned_rows_shown(top, w, h, scales).each do |iy, row|
            ddy = iy - h # offset from the patch's center, in whole pixels
            (w * 2).times do |ix|
              ddx = ix - w
              # Work back to the picture. The matrix is in 256ths, so shifting down by
              # 8 both scales it back and rounds down, exactly as the console does.
              sx = (((pa * ddx) + (pb * ddy)) >> 8) + (w / 2)
              sy = (((pc * ddx) + (pd * ddy)) >> 8) + (h / 2)
              next unless sx >= 0 && sx < w && sy >= 0 && sy < h

              at = (sy * w) + sx
              i = at * 2
              color = pixels.getbyte(i) | (pixels.getbyte(i + 1) << 8)
              next if transparent && color == transparent

              @screen.set_pixel(left + ix, row, recolor ? recolor.color_for(at, color) : color)
            end
          end
        end

        # The rows of a turned sprite's double-size patch that show, each as [the row of the
        # patch, the row of the screen]. +top+ is where the patch's first row stands, +w+ and
        # +h+ the picture's size, and +scales+ whether the sprite's size ever changes.
        def turned_rows_shown(top, w, h, scales)
          TurnedBox.rows_shown(top, h * 2, Affine.rows_reached(w, h, scales: scales), @screen.height)
        end

        # Does this object's size ever change? One that only turns reaches less of its patch.
        def object_scales?(obj) = !constant?(obj.scale, Build::SCALE_ONE)

        # The patch of screen a transformed object can cover, as [x, y, width, height].
        # This is what's put back under it before it's redrawn, so it has to hold the
        # picture at every angle and size it might have been drawn at last frame — the
        # erase can't depend on knowing which.
        #
        # An object that only turns can't reach further than half its own diagonal from
        # its center, whatever the angle, so a square that wide is enough and is cheaper
        # to walk. One that resizes has no such bound short of the whole double-size box
        # the display gives it, so that's what we clear.
        def transformed_footprint(obj, x, y, w, h)
          cx = x + (w / 2)
          cy = y + (h / 2)
          return [cx - w, cy - h, w * 2, h * 2] if object_scales?(obj)

          side = Affine.turning_reach(w, h)
          [cx - (side / 2), cy - (side / 2), side, side]
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
          index = eval_value(node.index)
          poses = node.poses
          return unless index >= 0 && index < poses.length

          blit_image(poses[index], eval_value(node.x), eval_value(node.y))
        end

        # Copy a defined bitmap onto the fake screen with its top-left at (x, y). Each
        # pixel is a little-endian 15-bit halfword in the stored bytes; set_pixel
        # clips any that fall off-screen, matching how the hardware framebuffer
        # behaves, and a transparent pixel is skipped so the background shows through.
        # +recolor+ maps a colour to the one it is drawn in instead (see #object_recolor).
        def blit_image(name, x, y, recolor: nil)
          bmp = @bitmaps.fetch(name) { raise ProgramError, "blit of undefined image #{name.inspect}" }
          pixels = @data.fetch(name)
          transparent = bmp.transparent

          bmp.height.times do |row|
            bmp.width.times do |col|
              at = (row * bmp.width) + col
              i = at * 2
              color = pixels.getbyte(i) | (pixels.getbyte(i + 1) << 8)
              next if transparent && color == transparent
              @screen.set_pixel(x + col, y + row, recolor ? recolor.color_for(at, color) : color)
            end
          end
        end

        # --- per-pixel collision (do two sprites' solid pixels actually touch?) ---

        # True when a non-transparent pixel of one posed sprite lands on a
        # non-transparent pixel of the other. Each side names its current picture (from
        # its poses and run-time pose), and where it sits; we walk only the rectangle
        # where their boxes overlap and stop at the first pixel solid in both.
        def pixels_overlap?(node)
          a = collision_sprite(node.a_poses, node.a_pose, node.a_x, node.a_y)
          b = collision_sprite(node.b_poses, node.b_pose, node.b_x, node.b_y)
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
          { pixels: @data.fetch(name), w: bmp.width, h: bmp.height,
            transparent: bmp.transparent, x: eval_value(x_node), y: eval_value(y_node) }
        end

        # Whether pixel (col, row) of a sprite's picture is drawn (not its see-through
        # colour) — the same "skip the transparent pixel" test the blit uses.
        def solid_pixel?(sprite, col, row)
          i = ((row * sprite[:w]) + col) * 2
          color = sprite[:pixels].getbyte(i) | (sprite[:pixels].getbyte(i + 1) << 8)
          transparent = sprite[:transparent]
          transparent.nil? || color != transparent
        end

        # --- save memory (see IR::SaveImage, laid out as IR::SaveLayout says) ---

        SAVE_WIDTHS = { byte: 1, half: 2, word: 4 }.freeze

        # Boot-load the persisted variables from save memory. When it already carries this
        # program's marker, each variable takes its saved value; otherwise (a fresh
        # cartridge) each takes its default. Either way each is written back and the marker
        # after them, which is what the console's branchless boot does — so the two write the
        # same bytes in the same order, and a power cut lands on the same one.
        def exec_save_init(node)
          saved = @save.word(SaveLayout::SAVE_VAR_MARKER_AT) == Int32.wrap(node.magic)
          node.vars.each do |v|
            at = SaveLayout.save_var_at(v.slot)
            value = saved ? @save.word(at) : Int32.wrap(v.default)
            @vars[v.name] = value
            write_save(at, value, SAVE_WIDTHS[:word])
          end
          write_save(SaveLayout::SAVE_VAR_MARKER_AT, node.magic, SAVE_WIDTHS[:word])
        end

        # Mirror one persisted variable's current value into its save slot.
        def exec_save_store(node)
          write_save(SaveLayout.save_var_at(node.slot), @vars[node.var], 4)
        end

        def exec_save_write(node)
          write_save(eval_value(node.at), eval_value(node.value), SAVE_WIDTHS.fetch(node.width))
        end

        def exec_save_erase(node)
          at = eval_value(node.at)
          on_save_memory { @save.wipe_block(at, wait: node.wait != false) }
        end

        def value_of_save_read(node)
          at = eval_value(node.at)
          width = SAVE_WIDTHS.fetch(node.width)
          on_save_memory { width == 4 ? @save.word(at) : @save.read(at, width) }
        end

        def value_of_save_sum(node)
          at = eval_value(node.at)
          length = eval_value(node.length)
          on_save_memory { @save.checksum(at, length) }
        end

        def write_save(at, value, width) = on_save_memory { @save.write(at, value, width) }

        # Reach save memory. The power going off stops the program where it stands, and
        # something the chip cannot do stops it with the reason.
        def on_save_memory
          yield
        rescue SaveImage::PowerOff
          throw(:halt)
        rescue SaveImage::Refused => e
          raise ProgramError, e.message
        end

        # --- backing store (save the pixels under a moving object, then put them back) ---

        # Copy the buffer-sized screen patch at (x, y) into the named backing buffer.
        # An off-screen cell reads as nil (there's nothing out there to remember);
        # restore skips those, so a patch hanging off an edge round-trips cleanly.
        def exec_save_region(node)
          buf = backing_for(node.buffer)
          x = eval_value(node.x)
          y = eval_value(node.y)
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
          buf = backing_for(node.buffer)
          cells = buf[:pixels]
          return if cells.nil?

          x = eval_value(node.x)
          y = eval_value(node.y)
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

        # --- what ReadingBack reads #list, #pool and #game_state from ---

        def list_items(name) = @lists[name]&.to_a
        def list_names = @lists.keys
        def variables_now = @vars

        def exec_list_push(node)
          list = list_for(node.name)
          raise ProgramError, Faults.list_full(node.name, list.capacity) if list.full?

          list.push(eval_value(node.value))
        end

        def exec_list_drop(node)
          list = list_for(node.name)
          from = node.from # :front (a shift) or :back (a pop)
          raise ProgramError, Faults.list_empty(node.name, from) if list.empty?

          from == :front ? list.shift : list.pop
        end

        def exec_list_set(node)
          list = list_for(node.name)
          index = eval_value(node.index)
          check_list_index!(list, node.name, index)
          list.set(index, eval_value(node.value))
        end

        # The same as a list_set at each index in turn, so an index outside the list is the same
        # error — said once, before anything is written.
        def exec_list_fill(node)
          count = eval_value(node.count)
          return unless count.positive?

          list = list_for(node.name)
          from = eval_value(node.from)
          [from, from + count - 1].each { |index| check_list_index!(list, node.name, index) }
          value = eval_value(node.value)
          count.times { |i| list.set(from + i, value) }
        end

        # The list made to hold the run of the table from +at+, held so the whole run is inside
        # the table — the same start the console copies from. Each entry is kept the way the
        # list keeps an item, so a byte the table reads as 200 reads back as -56, as the bytes
        # copied on the console do.
        def exec_list_copy(node)
          values = @tables.fetch(node.table).values
          start = eval_value(node.at).clamp(0, values.length - node.count)
          list_for(node.name).replace(values[start, node.count])
        end

        def value_of_list_get(node)
          list = list_for(node.name)
          index = eval_value(node.index)
          check_list_index!(list, node.name, index)
          list.get(index)
        end

        # Read table[index] from a ROM table. An out-of-range index is made safe the
        # same way the GBA lowering does it, so the two backends agree: a power-of-two
        # table wraps the index, any other size clamps it to the ends — the read always
        # lands on a real element. The value comes back exactly as authored (the table's
        # signedness only decides how the console stores/sign-extends it).
        def value_of_table_get(node)
          table = @tables.fetch(node.name) do
            raise ProgramError, "reference to undefined table #{node.name.inspect}"
          end
          values = table.values
          Int32.wrap(values[safe_table_index(eval_value(node.index), values.length)])
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

          raise ProgramError, Faults.index_out_of_range(name, index, list.length)
        end

        # Evaluate an operand to a signed 32-bit integer. Operands are normally
        # value nodes; a bare Integer or Symbol is accepted too for convenience.
        # WHAT EACH KIND OF VALUE COMES TO, one method per kind — the value half of STATEMENTS.
        VALUES = {
          int: :value_of_int,
          var_ref: :value_of_var_ref,
          neg: :value_of_neg,
          bit_not: :value_of_bit_not,
          absolute: :value_of_absolute,
          clamped: :value_of_clamped,
          binop: :value_of_binop,
          mul_fix: :value_of_mul_fix,
          div_fix: :value_of_div_fix,
          shift_right: :value_of_shift_right,
          held: :value_of_held,
          pressed: :value_of_pressed,
          chance: :value_of_chance,
          pixels_overlap: :value_of_pixels_overlap,
          data_byte: :value_of_data_byte,
          table_get: :value_of_table_get,
          list_get: :value_of_list_get,
          list_len: :value_of_list_len,
          save_read: :value_of_save_read,
          save_sum: :value_of_save_sum,
          timer_ticks: :value_of_timer_ticks,
          clock: :value_of_clock,
        }.freeze

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

          handler = VALUES.fetch(node.kind) do
            raise ProgramError, "not a value node: #{node.kind.inspect}"
          end
          send(handler, node)
        end

        def value_of_int(node)
          Int32.wrap(node.value)
        end

        def value_of_var_ref(node)
          @vars[node.name]
        end

        def value_of_neg(node)
          Int32.neg(eval_value(node.operand))
        end

        def value_of_bit_not(node)
          Int32.bit_not(eval_value(node.operand))
        end

        def value_of_absolute(node)
          v = eval_value(node.operand)
          v.negative? ? Int32.neg(v) : v
        end

        def value_of_clamped(node)
          v = eval_value(node.operand)
          clamp_value(v, eval_value(node.min), eval_value(node.max))
        end

        def value_of_binop(node)
          eval_binop(node.op, eval_value(node.lhs), eval_value(node.rhs))
        end

        def value_of_mul_fix(node)
          Int32.mul_fix(eval_value(node.lhs), eval_value(node.rhs), node.fraction_bits)
        end

        def value_of_div_fix(node)
          Int32.div_fix(eval_value(node.lhs), eval_value(node.rhs), node.fraction_bits)
        end

        def value_of_shift_right(node)
          Int32.shift_right(eval_value(node.operand), node.bits)
        end

        def value_of_held(node)
          flag_int(button_held?(node.button))
        end

        def value_of_pressed(node)
          flag_int(button_pressed?(node.button))
        end

        # A chance holds when the random draw lands below the threshold.
        def value_of_chance(node)
          flag_int(eval_value(node.draw) < node.percent)
        end

        def value_of_pixels_overlap(node)
          flag_int(pixels_overlap?(node))
        end

        def value_of_data_byte(node)
          data_byte(node.name, node.index)
        end

        def value_of_list_len(node)
          list_for(node.name).length
        end

        def value_of_timer_ticks(node)
          timer_ticks(node.name)
        end

        # The clock as it reads now: where #clock_at started it, on by every frame the screen has
        # shown. That count moves only between passes, so every reading in one pass is of the same
        # moment, and a minute cannot turn over between reading the minute and the second.
        #
        # A FRAME IS THE CONSOLE'S, a little more than a sixtieth of a second, since a clock keeps
        # real seconds and the console's frames are what this counts in; an emulator's clock pinned
        # to a moment moves on the same way, so the two read each second turn over on one frame.
        #
        # A time the game set is kept as how far it is from this clock (see IR::Clock::OFFSET_DAYS),
        # and added on here.
        #
        # A chip that keeps no date, the Color's, reads as set only once the game has set a time
        # on it (IR::Clock.undated_set?).
        def value_of_clock(node)
          days = @vars.fetch(IR::Clock::OFFSET_DAYS, 0)
          seconds = @vars.fetch(IR::Clock::OFFSET_SECONDS, 0)
          now = clock_now
          now &&= now + (days * IR::Clock::SECONDS_A_DAY) + seconds
          set = clock_keeps_date? ? @clock_set : IR::Clock.undated_set?(@clock_set, days, seconds)
          IR::Clock.reading(node.reading, now, set: set)
        end

        # The clock's own time now, before anything the game set is added on; nil for no clock.
        def clock_now
          return unless @clock_started

          moved = IR::Clock.moved_on(@clock_started, @screen_frame * @console.frame_seconds)
          clock_keeps_date? ? moved : IR::Clock.undated(moved, @clock_started)
        end

        # Whether the clock chip is one that keeps the date: the console's own, unless #clock_at
        # was told otherwise.
        def clock_keeps_date?
          return @clock_keeps_date unless @clock_keeps_date.nil?

          @console.clock_keeps_date
        end

        # SETTING THE CLOCK keeps how far the time set is from the clock's own, to the whole
        # second, in days and the seconds left over — so the readings are the time set straight
        # away, and the part of a second the clock was into carries on as it was, as it does on
        # the console. Worked out with the calendar rather than with the formula the other
        # backends use, so that the two are checked against each other.
        def exec_set_clock(node)
          now = clock_now
          return unless now

          wanted = IR::Clock::SET_PARTS.to_h { |part| [part, eval_value(node.public_send(part))] }
          midnight = Time.utc(wanted[:year], wanted[:month], wanted[:day]) - Time.utc(now.year, now.month, now.day)
          days = (midnight / IR::Clock::SECONDS_A_DAY).round
          seconds = (wanted[:hour] * 3600) + (wanted[:minute] * 60) + wanted[:second] -
                    ((now.hour * 3600) + (now.min * 60) + now.sec)
          days, seconds = days + seconds.div(IR::Clock::SECONDS_A_DAY), seconds % IR::Clock::SECONDS_A_DAY
          @vars[IR::Clock::OFFSET_DAYS] = days
          @vars[IR::Clock::OFFSET_SECONDS] = seconds
          @clock_set = true
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
          Int32.wrap(timer ? whole_overflows(timer) % 65_536 : 0)
        end

        # A button is "held" while it's down. It's "pressed" only on the edge —
        # the first frame it goes down, i.e. down now but up at the last vblank.
        # That edge is what a game uses to fire once per tap instead of every
        # frame the button is held.
        #
        # A press is any button that went down on a frame the screen showed since the last
        # pass took its presses (see #read_buttons), the way the console collects them,
        # and nothing was down before the first frame. So a button held while the power comes
        # on is one press on the first frame, and before any frame has been reached — the
        # setting up above a game loop — nothing is pressed yet.
        def button_held?(button)
          return !@held.empty? if button == IR::Buttons::ANY

          @held.include?(check_button!(button))
        end

        def button_pressed?(button)
          return !@pressed.empty? if button == IR::Buttons::ANY

          @pressed.include?(check_button!(button))
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
          Graphics::Color.resolve(color)
        end

        # Arithmetic routes through Int32 (signed 32-bit wraparound); comparisons
        # use signed ordering and yield 1/0, so a condition is simply "non-zero".
        def eval_binop(op, lhs, rhs)
          case op
          when :+ then Int32.add(lhs, rhs)
          when :- then Int32.sub(lhs, rhs)
          when :* then Int32.mul(lhs, rhs)
          when :/ then Int32.div(lhs, rhs)
          when :% then Int32.mod(lhs, rhs)
          # Bit by bit, on the 32 bits behind the number (see Int32's own note on
          # what a shift count outside 0...32 does).
          when :& then Int32.bit_and(lhs, rhs)
          when :| then Int32.bit_or(lhs, rhs)
          when :^ then Int32.bit_xor(lhs, rhs)
          when :<< then Int32.shift_left(lhs, rhs)
          when :>> then Int32.shift_right(lhs, rhs)
          when :> then flag_int(Int32.cmp(lhs, rhs) > 0)
          when :< then flag_int(Int32.cmp(lhs, rhs) < 0)
          when :>= then flag_int(Int32.cmp(lhs, rhs) >= 0)
          when :<= then flag_int(Int32.cmp(lhs, rhs) <= 0)
          when :== then flag_int(Int32.cmp(lhs, rhs).zero?)
          when :!= then flag_int(!Int32.cmp(lhs, rhs).zero?)
          # Condition composition: operands are already 0/1, so combine them.
          when :and then flag_int(!lhs.zero? && !rhs.zero?)
          when :or then flag_int(!lhs.zero? || !rhs.zero?)
          else raise ProgramError, "unknown binary operator #{op.inspect}"
          end
        end

        # Held at the floor, then at the ceiling — in that order, so a floor the game has
        # worked out to above its ceiling gives the ceiling, as the console's two
        # compare-and-replace steps do (see GBA::Expressions#eval_clamped).
        def clamp_value(value, min, max)
          [[value, min].max, max].min
        end

        def flag_int(flag)
          flag ? 1 : 0
        end
      end
    end
  end
end
