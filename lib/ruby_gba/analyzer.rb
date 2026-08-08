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
    WINDOW = 30           # frames read per attempt; the worst of them is that attempt's cost
    FPS_WINDOW = 90       # emulated frames to count game frames over, for a saturated scene's real rate

    # The op kinds that read a button, so the profiler can ask a program which buttons it
    # cares about instead of holding all ten.
    INPUT_KINDS = %i[held pressed].freeze

    # +scanlines+ is the measured per-frame wall-clock cost (CPU plus DMA-stall) of the
    # worst frame found; +fps+ is the counted game frame rate, measured only when the
    # scanline reading saturates, because that is the only time it is needed. It settles
    # what the reading cannot: 60 means every pass met its frame. +keys+ is what was held
    # to find that frame — empty when the game is at its worst doing nothing.
    Result = Data.define(:scanlines, :fps, :keys) do
      def initialize(scanlines:, fps: nil, keys: [])
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
    def measure(rom_path, keys: [])
      attempt(rom_path, Array(keys), {}, nil)
    end

    # Profile a game's scenes. A scene the player only reaches after input is measured
    # by booting straight into it (below), so no button-scripting is needed. Returns a
    # Hash of scene name => {Result}. +only+ narrows to named scenes; nil profiles all,
    # up to SCENE_CAP. A game with no scenes profiles as a whole under the +nil+ key.
    #
    # +keys+ pins what the player is doing: nil sweeps the buttons the game reads (the
    # default), a list holds exactly those and nothing else.
    def profile(game, only: nil, keys: nil)
      # Build the measuring ROMs exactly as the game builds its own. Measuring a
      # differently-built ROM would report a frame rate the shipped game does not have.
      options = game.respond_to?(:build_options) ? game.build_options : {}
      dispatch = scenes(game.program)
      return { nil => measure_program(game.program, options: options, keys: keys) } unless dispatch

      names = pick_scenes(dispatch[:scenes], only)
      names.to_h do |name|
        value = dispatch[:scenes].fetch(name)
        variant = boot_into(game.program, dispatch[:selector], value)
        [name, measure_program(variant, options: options, keys: keys,
                               stays_in: { var: dispatch[:selector], value: value })]
      end
    end

    # A game's scene dispatch, read from its case node: { selector: <var>, scenes:
    # { name => value } }. nil when the game has no scenes (a single game loop).
    def scenes(program)
      node = program.walk.find { |n| n.kind == :case }
      return nil unless node

      map = node[:clauses].each_with_object({}) do |(value, func), acc|
        acc[func.to_s.delete_prefix("_scene_").to_sym] = value
      end
      { selector: node[:var], scenes: map }
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
    def boot_into(program, selector, value)
      init = program.children.select { |node| node.kind == :set && node[:var] == selector }.last
      unless init
        raise ArgumentError,
              "cannot boot into a scene: this game never sets its scene variable #{selector.inspect} at " \
              "start. Declare it with `var #{selector.inspect}, 0` before the game loop."
      end
      init[:value] = IR::Build.int(value)
      program
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
      worst = in_temp_rom(measuring[:rom]) do |path|
        attempts.filter_map { |held| attempt(path, held, measuring[:vars], pinned ? nil : stays_in) }
                .max_by(&:scanlines)
      end
      return worst unless worst.saturated?

      Result.new(scanlines: worst.scanlines, fps: measure_fps(program, options, keys: worst.keys),
                 keys: worst.keys)
    end

    # One windowed reading with +held+ down throughout, or nil when it does not count:
    # the buttons moved the game out of the scene being measured, so the frames read
    # belong to some other scene. Nothing held is always kept — it is the baseline, and
    # a scene that leaves on its own is no worse measured than it was before.
    def attempt(path, held, vars, stays_in)
      probe = Emulator.probe(path)
      probe.step(SETTLE, keys: held)
      watch = scene_watch(vars, stays_in, held)
      peak = 0.0
      WINDOW.times do
        peak = [peak, frame_scanlines(probe.frame_cost(keys: held))].max
        return nil if watch && probe.read32(watch) != stays_in[:value]
      end
      Result.new(scanlines: peak, fps: nil, keys: held)
    ensure
      probe&.close
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
      program.walk.filter_map { |node| node[:button] if INPUT_KINDS.include?(node.kind) }.uniq
    end

    # The counted frame rate, with +keys+ held throughout — the same buttons the winning
    # reading was taken under, or the count would answer about a different game. A hidden
    # counter ticks once per game-loop iteration; run a window of emulated frames and the
    # counter's rise is how many game frames elapsed, so fps = game frames * 60 / window.
    # A loop waits for the screen, so the answer lands on 60, 30, 20... and 60 means every
    # pass met its frame. nil when there is no game loop to count.
    def measure_fps(program, options = {}, keys: [])
      counter = :__profile_frames
      return nil unless instrument_frame_counter(program, counter)

      measuring = build_for_measuring(program, options)
      address = measuring[:vars][counter]
      in_temp_rom(measuring[:rom]) do |path|
        probe = Emulator.probe(path)
        probe.step(SETTLE, keys: keys)
        before = probe.read32(address)
        probe.step(FPS_WINDOW, keys: keys)
        elapsed = probe.read32(address) - before
        probe.close
        elapsed.positive? ? (elapsed * 60.0 / FPS_WINDOW).round(1) : nil
      end
    end

    # Add a hidden counter that ticks once per game-loop iteration. Returns true if a
    # game loop was there to instrument.
    def instrument_frame_counter(program, counter)
      loop_node = program.walk.find { |node| node.kind == :loop }
      return false unless loop_node

      program.children.unshift(IR::Build.set(counter, IR::Build.int(0)))
      loop_node.children << IR::Build.add(counter, IR::Build.int(1))
      true
    end

    # A measuring ROM and where its variables live. The addresses come from the very
    # backend that built the ROM, so a reading of the scene variable (or the hidden frame
    # counter) is a reading of this ROM's memory and not a guess.
    def build_for_measuring(program, options = {})
      backend = IR::Backends::GBA.new(**options)
      rom = ROM.assemble(backend.lower(program), title: "PROFILE", code: "BPRF", maker: "01")
      { rom: rom, vars: backend.instance_variable_get(:@vars) }
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
