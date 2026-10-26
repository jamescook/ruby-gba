# frozen_string_literal: true

module VBlank
  module Diagnostics
    # WHICH SCENES RUN LATE ON THE FRAME THE GAME HANDS OVER TO THEM, measured on the console.
    #
    # A scene's pictures go into video memory as it takes over, on the same pass as its first
    # pass of game, so a scene with a lot of art can run that one pass past the end of its frame
    # while every pass after it fits — and the game is a frame late from there. Nothing in the
    # program says so, and the more art a scene holds the likelier it is, so a game that adds
    # rooms meets it without changing a line of the scene. `scene :x, loads_first: true` gives
    # the copy a pass of its own (see IR::SceneHandover::Arrival#loads_first?), and this is
    # what points an author at it.
    #
    # Each scene is handed over to once, from another scene, by writing the variable the game
    # picks its scenes with — the way the build enters a scene to measure it (see
    # Profiler.survey_scenes) — and the frames after it are read: whether each finished a pass
    # of the game loop. A scene that misses only on its hand-over is late; one that misses on
    # every frame is a slow scene, which the build says already, and is left to that.
    module HandOvers
      # A scene whose hand-over ran past its frame. +loads_first+ says the scene already copies
      # its pictures on a pass of their own, and that pass is the one that did not fit.
      Late = Data.define(:scene, :loads_first)

      # Frames to run before anything is written, so the game is past its own start-up.
      BOOT_FRAMES = 8
      # Frames the scene handed over from is given, so the hand-over is from a scene that is up.
      FROM_FRAMES = 4
      # Frames read from the hand-over on: the copying pass, the first pass of work, and two
      # passes after them to tell a late hand-over from a slow scene.
      READ_FRAMES = 4

      module_function

      # The scenes of +rom+ whose hand-over ran past its frame, in the order the game names them.
      # A game with fewer than two scenes hands over to nothing.
      def late(rom, keys: [])
        dispatch = Analyzer.scenes(rom.built.source_program)
        address = dispatch && rom.built.var_addresses[dispatch[:selector]]
        return [] unless address && dispatch[:scenes].size > 1

        program = rom.built.source_program
        Profiler.in_temp_rom(rom) do |path|
          dispatch[:scenes].filter_map do |scene, value|
            from = dispatch[:scenes].values.find { |other| other != value }
            finished = passes_after_hand_over(path, address, from, value, Array(keys))
            loads_first = loads_first?(program, scene)
            Late.new(scene: scene, loads_first: loads_first) if late_hand_over?(finished, loads_first)
          end
        end
      end

      # Whether each of the READ_FRAMES frames after handing over from the scene +from+ to the
      # scene +to+ finished a pass of the game loop.
      def passes_after_hand_over(path, address, from, to, keys)
        probe = Emulator.probe(path)
        begin
          probe.step(BOOT_FRAMES, keys: keys)
          probe.write32(address, from)
          probe.step(FROM_FRAMES, keys: keys)
          probe.write32(address, to)
          Array.new(READ_FRAMES) { probe.profile(frames: 1, keys: keys).finished.positive? }
        ensure
          probe.close
        end
      end

      # A hand-over is late when one of its own passes missed its frame and the passes after it
      # did not: the copying pass and, for a scene that loads first, the first pass of work after
      # it.
      def late_hand_over?(finished, loads_first)
        own = loads_first ? 2 : 1
        !finished.first(own).all? && finished.drop(own).all?
      end

      def loads_first?(program, scene)
        program.children.any? { |node| node.kind == :func && node.name == :"_scene_#{scene}" && node.loads_first }
      end

      # What a late hand-over means, and what to do about it, in plain words.
      def message(late)
        if late.loads_first
          "The #{late.scene.inspect} scene loads first, but the frame that puts its pictures up " \
            "still runs past its end. The pictures and the rest of the game loop do not fit in one " \
            "frame. To fix this, give the scene fewer pictures, or do less in the game loop outside " \
            "the scene."
        else
          "When the game changes to the #{late.scene.inspect} scene, that frame runs past its end, " \
            "so the game is one frame late from there. The scene puts its pictures up on that frame " \
            "and does its first frame of work too. To fix this, write `scene #{late.scene.inspect}, " \
            "loads_first: true`. Then the pictures go up on a frame of their own, and the work starts " \
            "on the next frame."
        end
      end
    end
  end
end
