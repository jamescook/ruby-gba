# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class Native
        # What tells a game played as C from the same game played on the interpreter, said in
        # words a person can act on: the first entry of the sound log, the first byte of save
        # memory, the first sprite, every variable the two disagree on. CheckedRun says its
        # disagreements with these.
        #
        # It also plays a program both ways a frame at a time and keeps every pixel of every
        # frame (#native_snapshots, #reference_snapshots), which is dear, and is what a check
        # that found two pictures differ uses to say where.
        module Differences
          # One moment of a run: its heading ("frame 3", "end"), the variables, the picture shown,
          # the sound log up to then, and the sprites last drawn, each saying whose it is.
          Snapshot = Data.define(:heading, :variables, :picture, :sounds, :sprites)

          # The snapshots the windowless program printed. +held+ is down from power-on, before
          # the game's first statement, and +buttons+ say what is held on each frame from the
          # first on.
          def native_snapshots(program, frames:, buttons:, mode:, held: [])
            exe = Native.new.build_headless(program, mode: mode)
            input = (1..frames).map { |frame| "#{HeadlessRun.button_mask(buttons.fetch(frame, []))}\n" }.join
            from_power_on = held.empty? ? [] : ["--held-from-power-on", HeadlessRun.button_mask(held)]
            parse_snapshots(Zig.run_program(exe, args: [frames, "--every-picture", *from_power_on], input: input), program)
          end

          def reference_snapshots(program, frames:, buttons:, held: [])
            interpreter = Reference.new.hold(*held)
            snapshots = []
            interpreter.input_each_frame { |frame| buttons.fetch(frame, []) }
                       .each_vblank { |frame| snapshots << reference_moment(interpreter, "frame #{frame}") }
                       .run(program, frames: frames)
            snapshots << reference_moment(interpreter, "end")
          end

          # The first entry of the sound log the two disagree on, or nil when every entry is the
          # same.
          def sounds_difference(want, got)
            at = (0...[want.size, got.size].max).find { |index| want[index] != got[index] }
            at && "entry #{at} of the sound log: #{lowered_side} has #{got[at].inspect}, Reference #{want[at].inspect}"
          end

          # The first frame's slice of mixed sound the two disagree on — the frame and the first
          # sample in it — or nil when they made the same bytes throughout.
          def mix_difference(want, got)
            return "how many frames were mixed: the #{lowered_side} mixed #{got.size}, Reference #{want.size}" if want.size != got.size

            frame = want.each_index.find { |index| want[index] != got[index] } or return nil
            sample = (0...[want[frame].size, got[frame].size].max).find { |index| want[frame][index] != got[frame][index] }
            "frame #{frame + 1} of the mix, sample #{sample}: #{lowered_side} has #{got[frame][sample].inspect}, " \
              "Reference #{want[frame][sample].inspect}"
          end

          # How many sounds each lost to a full mixer, and the most voices the music held at one
          # of those moments, when the two disagree.
          def drops_difference(want, got)
            return nil if [want.dropped, want.music_held] == [got.dropped, got.music_held]

            "the sounds lost to a full mixer: the #{lowered_side} lost #{got.dropped} with the music holding at most " \
              "#{got.music_held}, Reference #{want.dropped} with #{want.music_held}"
          end

          # The first byte of save memory the two ended a run disagreeing on, or nil when the two
          # chips hold the same bytes throughout.
          def save_difference(want, got)
            wanted = want.to_sav
            held = got.to_sav
            return nil if wanted == held

            at = (0...[wanted.bytesize, held.bytesize].max).find { |index| wanted.getbyte(index) != held.getbyte(index) }
            format("save memory at 0x%<at>X: #{lowered_side} has 0x%<got>02X, Reference 0x%<want>02X", at: at, got: held.getbyte(at) || 0,
                                                                                      want: wanted.getbyte(at) || 0)
          end

          # The first of the sprites drawn that the two disagree on, counted from the back, or nil
          # when they drew the same ones in the same places showing the same pictures.
          def sprites_difference(want, got)
            at = (0...[want.size, got.size].max).find { |index| want[index] != got[index] }
            at && "sprite #{at} of those drawn: #{lowered_side} has #{sprite_in_words(got[at])}, Reference #{sprite_in_words(want[at])}"
          end

          # What these call the side being checked against the interpreter: the game as C. The
          # JavaScript lowering, which is checked by the same words, calls it JS.
          def lowered_side = "C"

          private

          def sprite_in_words(row) = row ? "#{row.name.inspect} at (#{row.x}, #{row.y}) showing #{row.picture.inspect}" : "none"

          def reference_moment(interpreter, heading)
            Snapshot.new(heading: heading, variables: interpreter.vars.dup, picture: interpreter.screen.shown,
                         sounds: interpreter.audio.dup, sprites: interpreter.sprites)
          end

          # Every variable the two disagree on, said as "name: C has 2, Reference 1". Both ways: a
          # variable the interpreter wrote and the C never printed is a variable the lowering lost
          # track of, which comparing only what the C printed would never notice.
          def variable_differences(want, got)
            unprinted = (want.keys - got.keys).map { |name| "#{name}: the #{lowered_side} does not keep it" }
            wrong = got.filter_map do |name, value|
              expected = want.fetch(name, 0)
              "#{name}: #{lowered_side} has #{value}, Reference #{expected}" if expected != value
            end
            unprinted + wrong
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
