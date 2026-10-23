# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class Native
        # What tells a game played as C from the same game played on the interpreter: the
        # comparison every checked run makes (RunComparison), and besides it, a program played
        # both ways a frame at a time keeping every pixel of every frame (#lowered_snapshots,
        # #reference_snapshots), which is dear, and is what a check that found two pictures differ
        # uses to say where.
        module Differences
          include RunComparison

          # One moment of a run: its heading ("frame 3", "end"), the variables, the picture shown,
          # the sound log up to then, and the sprites last drawn, each saying whose it is.
          Snapshot = Data.define(:heading, :variables, :picture, :sounds, :sprites)

          # The snapshots the windowless program printed. +held+ is down from power-on, before
          # the game's first statement, and +buttons+ say what is held on each frame from the
          # first on.
          def lowered_snapshots(program, frames:, buttons:, mode:, held: [])
            input = (1..frames).map { |frame| "#{HeadlessRun.button_mask(buttons.fetch(frame, []))}\n" }.join
            from_power_on = held.empty? ? [] : ["--held-from-power-on", HeadlessRun.button_mask(held)]
            parse_snapshots(run_headless_program(program, mode, args: [frames, "--every-picture", *from_power_on],
                                                                input: input), program)
          end

          # +program+ built to run with no window and run with +args+ and +input+, giving back what it
          # printed: the game as C, built the way +mode+ says. JS::Differences runs the game as
          # JavaScript instead, which prints the same lines.
          def run_headless_program(program, mode, args:, input:)
            Zig.run_program(Native.new.build_headless(program, mode: mode), args: args, input: input)
          end

          def reference_snapshots(program, frames:, buttons:, held: [])
            interpreter = Reference.new.hold(*held)
            snapshots = []
            interpreter.input_each_frame { |frame| buttons.fetch(frame, []) }
                       .each_vblank { |frame| snapshots << reference_moment(interpreter, "frame #{frame}") }
                       .run(program, frames: frames)
            snapshots << reference_moment(interpreter, "end")
          end

          private

          def reference_moment(interpreter, heading)
            Snapshot.new(heading: heading, variables: interpreter.vars.dup, picture: interpreter.screen.shown,
                         sounds: interpreter.audio.dup, sprites: interpreter.sprites)
          end

          def picture_difference(want, got)
            return nil if want == got

            first = want.each_index.find { |i| want[i] != got[i] }
            differing = want.each_index.count { |i| want[i] != got[i] }
            "the pictures differ in #{differing} pixels, the first at (#{first % Screen::WIDTH}, #{first / Screen::WIDTH}): " \
              "#{lowered_side} shows #{format('%04x', got[first])}, Reference #{format('%04x', want[first])}"
          end

          # The program's printed moments. A sound line belongs to the log as it grows, so each
          # moment holds the log up to its own heading — which is where the interpreter's
          # each_vblank reads it.
          def parse_snapshots(text, program)
            sound_log = SoundLog.new(program)
            drawn = DrawnSprites.new(program)
            sounds = []
            moments = []
            text.each_line(chomp: true) do |line|
              if line.start_with?("sound ")
                sounds << sound_log.entry_from(line)
              elsif line.start_with?("frame ") || line == "end"
                moments << [line, [], sounds.size]
              else
                moments.last[1] << line
              end
            end
            moments.map do |heading, rows, sound_count|
              Snapshot.new(heading: heading, variables: HeadlessRun.variables_in(rows),
                           picture: HeadlessRun.picture_in(rows), sounds: sounds.take(sound_count),
                           sprites: drawn.rows_in(rows))
            end
          end
        end
      end
    end
  end
end
