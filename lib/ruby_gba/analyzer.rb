# frozen_string_literal: true

require "tmpdir"

module RubyGBA
  # Measures a built ROM's real per-frame cost on the emulator — the "analyze" half of
  # the cost tooling, opposite the static estimate in {IR::CostModel}. It runs the ROM
  # and reads how many of a frame's ~228 scanlines a frame actually burns, which is the
  # measured number the static estimate can only guess at. The reading is the frame's
  # wall-clock work — the CPU executing PLUS the stall while a DMA engine copies — so a
  # DMA-heavy frame reads its true cost, not just the CPU part.
  #
  # A GAME COSTS WHAT THE PLAYER MAKES IT COST, and that is what shapes this file. A game
  # standing still can be the cheapest frame it ever draws — examples/raycaster.rb read
  # 225 of 228 doing nothing and 228 the moment the view turned, because turning brings
  # nearer walls and taller columns into view. So the profiler does not read one frame
  # doing nothing. It holds each button the game reads, in turn, reads EVERY frame over a
  # window, and reports the worst frame it found and what was held to find it.
  module Analyzer
    module_function

    # A full frame is 228 scanlines; work past that can't finish before the next frame,
    # so the frame rate drops. The measurement cannot count past a frame's worth, though,
    # so as it nears that ceiling it stops being an exact number.
    FRAME_SCANLINES = 228
    # At or above this the reading is no longer an exact count. That is a fact about the
    # MEASUREMENT and says nothing yet about whether the program fits — a frame can very
    # nearly fill and still meet every one. It means "go and count the frames instead".
    SATURATED = 200
    SETTLE = 8            # frames to run before reading, so the game reaches steady state
    WINDOW = 30           # frames read per attempt; the worst is its cost and the middle its typical
    FPS_WINDOW = 90       # emulated frames to count game frames over, for a saturated scene's real rate

    # The op kinds that read a button, so the profiler can ask a program which buttons it
    # cares about instead of holding all ten.
    INPUT_KINDS = %i[held pressed].freeze

    # +scanlines+ is the measured per-frame wall-clock cost (CPU plus DMA-stall) of the
    # worst frame found; +fps+ is the counted game frame rate, measured only when the
    # scanline reading saturates, because that is the only time it is needed. It settles
    # what the reading cannot: 60 means every pass met its frame. +keys+ is what was held
    # to find that frame — empty when the game is at its worst doing nothing.
    #
    # +per_pass+ is what a whole PASS of the game loop cost, and it is the only reading that
    # keeps meaning something once a game is over budget. A video frame holds 228 scanlines and
    # no more, so a pass that overruns spreads itself across two of them and each reads a full
    # frame: the per-frame number stops at the ceiling and stays there however far past it the
    # game goes. Counting the work over a window and dividing by the PASSES in that window has
    # no ceiling — a game taking two frames a pass reads about 456, one taking four reads about
    # 912. Measured only when the per-frame reading saturates, since below that a pass is a
    # frame and the two numbers are the same. See #measure_saturated.
    # +tearing+ is what the display really showed, on the one screen where that can be
    # asked: how many rows went up before the game had finished them (see {Tearing}). It is
    # the one verdict the report could never check, only estimate.
    #
    # +typical+ is the MIDDLE frame of the same window, and it answers a different question
    # from +scanlines+. A game whose frame is the same every time has one answer and both
    # numbers give it. A game with work that only happens sometimes — a per-pixel collision
    # that walks only when two sprites really touch — has two, and they are far apart:
    # measured on examples/pacman.rb, a typical frame costs 2.48 and the worst of a hundred
    # and fifty costs 4.11, with the dear ones happening twice. The model prices both
    # questions too (what every frame pays, and what the worst one does), so having both
    # measured is what lets each be held against the estimate that means the same thing.
    Result = Data.define(:scanlines, :typical, :fps, :keys, :per_pass, :tearing) do
      def initialize(scanlines:, typical: nil, fps: nil, keys: [], per_pass: nil,
                     tearing: Tearing::Reading.none)
        super
      end

      def saturated?
        scanlines >= SATURATED
      end

      def percent
        (scanlines * 100.0 / FRAME_SCANLINES).round
      end

      def held?
        !keys.empty?
      end

      # The reading as the plain hash the cost report folds in, so the report stays free of
      # this module's types. The tearing reading travels as its three numbers for the same
      # reason, and as nothing at all where the screen could not be asked.
      def for_report
        { scanlines: scanlines, typical: typical, fps: fps, saturated: saturated?,
          per_pass: per_pass, keys: keys,
          torn_rows: tearing.rows, torn_from: tearing.first, torn_to: tearing.last }
      end
    end

    # How many scenes to profile by default when the dev names none — enough to cover a
    # normal game, few enough to keep a run quick.
    SCENE_CAP = 10

    # Measure +rom_path+ on the emulator with +keys+ held throughout. Settles the game
    # into steady state, then reads EVERY frame over a window and keeps the worst.
    #
    # The worst is the honest one twice over. A frame that fits reads the same each time,
    # so the peak is simply its steady cost. A frame that overruns splits across two video
    # frames — one reads a full 228 and the next reads only the leftover — so a reading
    # taken at the wrong moment can look cheap when the game is dropping frames. And a
    # game whose work follows the player, or grows on its own, is only expensive some of
    # the time. Returns a {Result} with no fps (that needs the counter run).
    #
    # The same window's MIDDLE frame comes back beside it, for the other question — what a
    # frame usually costs rather than what the worst one did. See {Result}.
    def measure(rom_path, keys: [])
      attempt(rom_path, Array(keys), {}, nil)
    end

    # Profile a program's scenes. A scene the player only reaches after input is measured
    # by booting straight into it (below), so no button-scripting is needed. Returns a
    # Hash of scene name => {Result}. +only+ narrows to named scenes; nil profiles all,
    # up to SCENE_CAP. A game with no scenes profiles as a whole under the +nil+ key.
    #
    # +options+ are the build options the game was built with ({BuildRecord#build_options}),
    # because the measuring ROMs are built here from the program and have to be built the
    # same way — a differently-built ROM has a frame rate the shipped game does not.
    #
    # +keys+ pins what the player is doing: nil sweeps the buttons the game reads (the
    # default), a list holds exactly those and nothing else.
    def profile(program, options: {}, only: nil, keys: nil)
      dispatch = scenes(program)
      return { nil => measure_program(program, options: options, keys: keys) } unless dispatch

      names = pick_scenes(dispatch[:scenes], only)
      names.to_h do |name|
        value = dispatch[:scenes].fetch(name)
        variant = boot_into(program, dispatch[:selector], value)
        [name, measure_program(variant, options: options, keys: keys,
                               stays_in: { var: dispatch[:selector], value: value })]
      end
    end

    # A game's scene dispatch, read from its case node: { selector: <var>, scenes:
    # { name => value } }. nil when the game has no scenes (a single game loop).
    def scenes(program)
      node = program.walk.find { |n| n.kind == :case }
      return nil unless node

      map = node.clauses.each_with_object({}) do |(value, func), acc|
        acc[func.to_s.delete_prefix("_scene_").to_sym] = value
      end
      { selector: node.var, scenes: map }
    end

    # The scenes to profile: the named ones (raising on an unknown name), or all up to
    # the cap when none are named.
    def pick_scenes(scene_map, only)
      return scene_map.keys.first(SCENE_CAP) unless only

      unknown = only.map(&:to_sym) - scene_map.keys
      unless unknown.empty?
        raise ArgumentError, "no scene named #{unknown.first}. This game's scenes are: #{scene_map.keys.join(', ')}."
      end
      only.map(&:to_sym)
    end

    # A fresh copy of +program+ that boots straight into a scene, by overriding the
    # selector variable's boot value. The scene dispatch reads that variable each frame,
    # so the game starts in the chosen scene. Not the shipped ROM — a throwaway for
    # measuring.
    #
    # The whole game is present and every variable starts at its declared default, but
    # state a scene would normally get from the transition INTO it (a level loaded, a
    # score set, enemies spawned by another scene) is NOT set — the scene runs on its
    # boot defaults. So this measures a scene's baseline cost; a scene whose cost depends
    # on that state needs a setup step (a future feature). Top-level boot setup, done
    # before the game loop rather than inside a scene, does run.
    #
    # Overrides the LAST boot-time set of the selector, so a game that sets it more than
    # once at start still ends up in the chosen scene.
    # Answers a COPY, for the same reason #instrument_frame_counter does: this rewrites where
    # the game starts, and measuring one scene must not leave the caller's program booting
    # into it — least of all when the next scene is about to be measured from the same tree.
    def boot_into(program, selector, value)
      booted = program.copy
      init = booted.children.select { |node| node.kind == :set && node.var == selector }.last
      unless init
        raise ArgumentError,
              "cannot boot into a scene: this game never sets its scene variable #{selector.inspect} at " \
              "start. Declare it with `var #{selector.inspect}, 0` before the game loop."
      end
      init.value = IR::Build.int(value)
      booted
    end

    # Measure a program and report its WORST frame — the reading a player would actually
    # meet. Each attempt (nothing held, then each button the game reads) gets its own
    # windowed reading; the dearest one wins and carries the buttons that produced it.
    #
    # A reading well clear of the ceiling is exact and that is the end of it; one near the
    # ceiling is not, so the winning attempt is run again with a hidden per-frame counter
    # and its frames are counted directly. That count is what decides whether it fits —
    # it can just as well come back at the full rate.
    #
    # +stays_in+ is the scene this reading is about ({ var:, value: }): a held button that
    # moves the game out of that scene measured a different scene, so that attempt is
    # thrown away rather than reported under the wrong name. Buttons the caller pinned are
    # held as asked and never thrown away — that is what pinning them means.
    def measure_program(program, options: {}, keys: nil, stays_in: nil)
      measuring = build_for_measuring(program, options)
      pinned = keys ? Array(keys).map(&:to_sym) : nil
      attempts = pinned ? [pinned] : attempt_keys(program)
      # Only a screen with one framebuffer can be asked whether it tore — see {Tearing}.
      tearing = Tearing.measurable?(program)
      worst = in_temp_rom(measuring[:rom]) do |path|
        readings = attempts.filter_map do |held|
          attempt(path, held, measuring[:vars], pinned ? nil : stays_in, tearing: tearing)
        end
        worst_reading(readings)
      end
      return worst unless worst.saturated?

      counted = measure_saturated(program, options, keys: worst.keys)
      Result.new(scanlines: worst.scanlines, typical: worst.typical, fps: counted[:fps],
                 per_pass: counted[:per_pass], keys: worst.keys, tearing: worst.tearing)
    end

    # How much dearer a held button has to read before the reading is attributed to it.
    #
    # Two runs of the same program are not bit-identical to a fraction of a scanline: holding
    # a button moves nothing about the work, but it does move where the reading lands by a
    # thousandth or two. Without a floor, the dearest attempt wins by that thousandth and the
    # report says "the worst frame found while holding LEFT" about a button that costs
    # nothing — which is worse than saying nothing, because it points a reader at the wrong
    # thing. A quarter of a scanline is far above that wobble and far below anything a player
    # could feel, so it names a button only when the button is doing something.
    WORTH_BLAMING = 0.25

    # The reading to report: nothing held unless a button really made it dearer. The
    # buttons-free attempt comes first, so it is the one to beat.
    def worst_reading(readings)
      at_rest = readings.first
      return readings.max_by(&:scanlines) unless at_rest && at_rest.keys.empty?

      dearest = readings.max_by(&:scanlines)
      dearest.scanlines - at_rest.scanlines > WORTH_BLAMING ? dearest : at_rest
    end

    # One windowed reading with +held+ down throughout, or nil when it does not count:
    # the buttons moved the game out of the scene being measured, so the frames read
    # belong to some other scene. Nothing held is always kept — it is the baseline, and
    # a scene that leaves on its own is no worse measured than it was before.
    def attempt(path, held, vars, stays_in, tearing: false)
      probe = Emulator.probe(path)
      probe.step(SETTLE, keys: held)
      watch = scene_watch(vars, stays_in, held)
      frames = []
      torn = Tearing::Reading.none
      WINDOW.times do
        frames << frame_scanlines(probe.frame_cost(keys: held))
        # Each measured frame leaves the probe at the frame boundary with the game halted,
        # which is where the picture it just showed can be held against the picture it had
        # finished drawing. The worst frame of the window is the one to report, the same
        # call the cost reading makes.
        torn = worst_tear(torn, Tearing.read(probe)) if tearing
        return nil if watch && probe.read32(watch) != stays_in[:value]
      end
      Result.new(scanlines: frames.max, typical: middle(frames), fps: nil, keys: held, tearing: torn)
    ensure
      probe&.close
    end

    # The middle frame of a window. The MEDIAN rather than the mean, because the thing being
    # kept out is a rare dear frame and a mean would carry a share of it — two collisions in a
    # hundred and fifty move a mean by enough to matter and move a median by nothing.
    def middle(frames)
      return nil if frames.empty?

      sorted = frames.sort
      sorted[sorted.length / 2]
    end

    # The worse of two tearing readings: the one that showed more of the picture stale. An
    # unmeasured reading loses to any measured one, so a window that could be read at all
    # reports what it read.
    def worst_tear(a, b)
      return b unless a.measured?
      return a unless b.measured?

      b.rows > a.rows ? b : a
    end

    # What one measured frame cost, from the probe's two clocks — the LARGER of them,
    # because each one is blind to something the other sees and neither can overstate a
    # frame.
    #
    # The wall-clock reading is the frame minus the time the CPU spent asleep, so it counts
    # the stall while a DMA engine copies, which the CPU-executing count cannot see. But it
    # is measured by summing the sleeps, and a program the hardware wakes over and over —
    # one bending a background is woken 228 times a frame — has its waking time counted
    # into a sleep and comes out BELOW the cycles it demonstrably executed. Bending
    # examples/lake.rb reads 29 that way against 38 executed.
    #
    # So take whichever is higher. A DMA-heavy frame reads its stall; an interrupt-heavy one
    # reads its CPU; an ordinary one reads the same either way.
    def frame_scanlines(cost)
      [cost.active_scanlines, cost.busy_scanlines].max
    end

    # Where to watch for the game leaving the scene being measured: the address of the
    # scene variable the dispatch tests each frame. nil when there is nothing to watch —
    # no scene, or no button held that could move it.
    def scene_watch(vars, stays_in, held)
      return nil if held.empty? || stays_in.nil?

      vars[stays_in[:var]]
    end

    # What to hold, one attempt at a time: nothing, then each button the program reads.
    # The game says which buttons matter — a game that reads none is measured at rest,
    # and no attempt holds a button the game would ignore.
    def attempt_keys(program)
      [[]] + buttons_read(program).map { |button| [button] }
    end

    # The buttons this program reads, in the order it first reads them.
    def buttons_read(program)
      program.walk.filter_map { |node| node.button if INPUT_KINDS.include?(node.kind) }.uniq
    end

    # WHAT A GAME COSTS ONCE IT IS TOO BIG FOR ITS FRAME, with +keys+ held throughout — the
    # same buttons the winning reading was taken under, or the count would answer about a
    # different game. Two numbers out of one run, and the second is the one that matters.
    #
    # A hidden counter ticks once per game-loop iteration. Over a window of emulated frames its
    # rise is how many PASSES the game made, so the frame rate is passes * 60 / window.
    #
    # THAT RATE IS COARSE BY CONSTRUCTION, and it is worth being plain about why. A loop waits
    # for the screen, so a pass takes a whole number of frames and the rate can only land on
    # 60, 30, 20, 15. "30" therefore covers everything from one frame of work to two — a game
    # that got a third faster reads exactly the same as one that did not move at all, which is
    # no use to anybody trying to make it faster.
    #
    # SO THE WORK IS ADDED UP TOO. Each video frame holds 228 scanlines and no more, so a frame
    # reading is capped; the sum over a window is not, and dividing it by the passes in that
    # window gives what one pass really cost. A game taking two frames a pass comes out about
    # 456, one taking four about 912, and the number keeps its meaning however far over budget
    # the game is. Below saturation a pass IS a frame and this agrees with the per-frame
    # reading, so it is measured only where it says something new.
    #
    # Empty when there is no game loop to count.
    def measure_saturated(program, options = {}, keys: [])
      counter = :__profile_frames
      counted = instrument_frame_counter(program, counter) or return {}

      measuring = build_for_measuring(counted, options)
      address = measuring[:vars][counter]
      in_temp_rom(measuring[:rom]) do |path|
        probe = Emulator.probe(path)
        probe.step(SETTLE, keys: keys)
        before = probe.read32(address)
        # Step the window a frame at a time rather than in one go, so the SAME run that counts
        # the passes also adds up the work — one emulator run answers both questions, and both
        # answers are then about the same frames rather than about two different runs.
        work = FPS_WINDOW.times.sum { frame_scanlines(probe.frame_cost(keys: keys)) }
        elapsed = probe.read32(address) - before
        probe.close
        next {} unless elapsed.positive?

        { fps: (elapsed * 60.0 / FPS_WINDOW).round(1), per_pass: (work / elapsed).round(1) }
      end
    end

    # The counted frame rate on its own, for a caller that wants only that.
    def measure_fps(program, options = {}, keys: [])
      measure_saturated(program, options, keys: keys)[:fps]
    end

    # A COPY of the program with a hidden counter that ticks once per game-loop iteration,
    # or nil when there is no loop to count. Counting frames means adding something that
    # counts them, and the caller's program is not the place to put it: the tree handed in
    # is often the one a ROM reports on, so instrumenting it in place would leave that
    # report describing a game with statements the shipped ROM does not have — and measuring
    # twice would add the counter twice.
    def instrument_frame_counter(program, counter)
      counted = program.copy
      loop_node = counted.walk.find { |node| node.kind == :loop }
      return nil unless loop_node

      counted.children.unshift(IR::Build.set(counter, IR::Build.int(0)))
      loop_node.children << IR::Build.add(counter, IR::Build.int(1))
      counted
    end

    # A measuring ROM and where its variables live. The addresses come from the very
    # backend that built the ROM, so a reading of the scene variable (or the hidden frame
    # counter) is a reading of this ROM's memory and not a guess.
    def build_for_measuring(program, options = {})
      backend = IR::Backends::GBA.new(**options)
      rom = ROM.assemble(backend.lower(program), title: "PROFILE", code: "BPRF", maker: "01")
      { rom: rom, vars: backend.var_addresses }
    end

    def in_temp_rom(rom)
      Dir.mktmpdir do |dir|
        path = File.join(dir, "profile.gba")
        rom.write(path)
        return yield(path)
      end
    end
  end
end
