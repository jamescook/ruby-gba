# frozen_string_literal: true

require "tmpdir"

module RubyGBA
  # Measures a built ROM's real per-frame cost on the emulator — the "analyze" half of
  # the cost tooling, opposite the static estimate in {IR::CostModel}. It runs the ROM
  # and reads how many of a frame's ~228 scanlines a frame actually burns, which is the
  # measured number the static estimate can only guess at. The reading is the frame's
  # wall-clock work — the CPU executing PLUS the stall while a DMA engine copies — so a
  # DMA-heavy frame reads its true cost, not just the CPU part.
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
    FPS_WINDOW = 90       # emulated frames to count game frames over, for a saturated scene's real rate

    # +scanlines+ is the measured per-frame wall-clock cost (CPU plus DMA-stall); +fps+ is
    # the counted game frame rate, measured only when the scanline reading saturates,
    # because that is the only time it is needed. It settles what the reading cannot: 60
    # means every pass met its frame.
    Result = Data.define(:scanlines, :fps) do
      def saturated?
        scanlines >= SATURATED
      end

      def percent
        (scanlines * 100.0 / FRAME_SCANLINES).round
      end
    end

    # How many scenes to profile by default when the dev names none — enough to cover a
    # normal game, few enough to keep a run quick.
    SCENE_CAP = 10

    # Measure +rom_path+ on the emulator. Runs the ROM to a settled frame and reads the
    # wall-clock scanlines a frame burns — the CPU work plus the DMA-stall — taking the
    # largest of a few reads. A frame that fits reads the same each time, so the largest
    # is its steady cost; a frame that overruns the budget wobbles as work bleeds into
    # the next frame, and the peak is the honest "this is over budget" signal (the min
    # can dip below the saturation line and read as fitting when it is not). Returns a
    # {Result} with no fps (that needs the counter run).
    def measure(rom_path)
      probe = Emulator.probe(rom_path)
      scanlines = 3.times.map { probe.frame_cost(settle: SETTLE).active_scanlines }.max
      Result.new(scanlines: scanlines, fps: nil)
    ensure
      probe&.close
    end

    # Profile a game's scenes. A scene the player only reaches after input is measured
    # by booting straight into it (below), so no button-scripting is needed. Returns a
    # Hash of scene name => {Result}. +only+ narrows to named scenes; nil profiles all,
    # up to SCENE_CAP. A game with no scenes profiles as a whole under the +nil+ key.
    def profile(game, only: nil)
      dispatch = scenes(game.program)
      return { nil => measure_program(game.program) } unless dispatch

      names = pick_scenes(dispatch[:scenes], only)
      names.to_h do |name|
        variant = boot_into(game.program, dispatch[:selector], dispatch[:scenes].fetch(name))
        [name, measure_program(variant)]
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

    # Measure a program's per-frame cost. A reading well clear of the ceiling is exact and
    # that is the end of it; one near the ceiling is not, so the program is run again with
    # a hidden per-frame counter and its frames are counted directly. That count is what
    # decides whether it fits — it can just as well come back at the full rate.
    def measure_program(program)
      busy = in_temp_rom(assemble(program)) { |path| measure(path) }
      return busy unless busy.saturated?

      Result.new(scanlines: busy.scanlines, fps: measure_fps(program))
    end

    # The counted frame rate. A hidden counter ticks once per game-loop iteration; run a
    # window of emulated frames and the counter's rise is how many game frames elapsed, so
    # fps = game frames * 60 / window. A loop waits for the screen, so the answer lands on
    # 60, 30, 20... and 60 means every pass met its frame. nil when there is no game loop
    # to count.
    def measure_fps(program)
      counter = :__profile_frames
      return nil unless instrument_frame_counter(program, counter)

      backend = IR::Backends::GBA.new
      rom = ROM.assemble(backend.lower(program), title: "PROFILE", code: "BPRF", maker: "01")
      address = backend.instance_variable_get(:@vars)[counter]
      in_temp_rom(rom) do |path|
        probe = Emulator.probe(path)
        probe.step(SETTLE)
        before = probe.read32(address)
        probe.step(FPS_WINDOW)
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

    def assemble(program)
      ROM.assemble(IR::Backends::GBA.new.lower(program), title: "PROFILE", code: "BPRF", maker: "01")
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
