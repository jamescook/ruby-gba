# frozen_string_literal: true

require "tmpdir"

module RubyGBA
  # Measures a built ROM's real per-frame cost on the emulator — the "analyze" half of
  # the cost tooling, opposite the static estimate in {IR::CostModel}. It runs the ROM
  # and reads how many of a frame's ~228 scanlines the CPU actually burns, which is the
  # measured number the static estimate can only guess at.
  module Analyzer
    module_function

    # A full frame is 228 scanlines; work past that can't finish before the next frame,
    # so the frame rate drops. The emulator's busy measurement caps and wobbles as it
    # nears this ceiling, so a reading that high means "saturated", not an exact count.
    FRAME_SCANLINES = 228
    SATURATED = 200       # at or above this, the CPU is effectively maxed for the frame
    SETTLE = 8            # frames to run before reading, so the game reaches steady state

    Result = Data.define(:scanlines) do
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
    # busy scanlines a frame burns, taking the smallest of a few reads (the quietest,
    # least-noisy sample). Returns a {Result}.
    def measure(rom_path)
      probe = Emulator.probe(rom_path)
      scanlines = 3.times.map { probe.busy_scanlines(settle: SETTLE) }.min
      Result.new(scanlines: scanlines)
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

    # Lower a program to a ROM, write it to a temp file, and measure it.
    def measure_program(program)
      rom = ROM.assemble(IR::Backends::GBA.new.lower(program), title: "PROFILE", code: "BPRF", maker: "01")
      Dir.mktmpdir do |dir|
        path = File.join(dir, "profile.gba")
        rom.write(path)
        return measure(path)
      end
    end
  end
end
