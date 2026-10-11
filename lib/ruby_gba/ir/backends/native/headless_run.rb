# frozen_string_literal: true

require "open3"
require "zlib"

module RubyGBA
  module IR
    module Backends
      class Native
        # A game run as C with no window (runtime/rg_headless.c), driven and read back through
        # the calls a test makes on Backends::Reference — so a test written against the
        # interpreter can be handed this instead and never know.
        #
        # The program is talked to a frame at a time rather than handed every frame's buttons
        # up front: it prints where the game has got to and asks for the next frame's buttons,
        # and this answers. That is what lets an input script look at the game before it
        # decides, the way the interpreter's does.
        #
        # The class methods read what the program prints, a line at a time, and are the one
        # place that knows how it prints it.
        class HeadlessRun
          # How long one run may take before it is taken to be stuck: a game that loops without
          # ever waiting for the screen never ends on its own.
          LONGEST_RUN_SECONDS = 60

          # The picture the run ended on, as the player would see it, read the way the
          # interpreter's screen is: #pixel gives the colour at (x, y), nil off the screen, and
          # #shown every pixel row by row.
          Picture = Data.define(:shown) do
            def pixel(x, y)
              return nil unless x.between?(0, Screen::WIDTH - 1) && y.between?(0, Screen::HEIGHT - 1)

              shown[(y * Screen::WIDTH) + x]
            end
          end

          # Where the game had got to at one frame boundary, or (+frame+ :end) when the run
          # stopped: every variable, and the picture as a check number (see .picture_check).
          Moment = Data.define(:frame, :variables, :picture)

          # Raised for something a test asks of the interpreter that the native lowering cannot
          # answer yet — which says the test's file was opted into native runs too early, or
          # the one test wants `skip_on_native`.
          class CannotAnswer < StandardError; end

          # The variables printed among +rows+ ("var name value"), by name.
          def self.variables_in(rows)
            rows.grep(/\Avar /).to_h { |row| _, name, value = row.split(" "); [name.to_sym, Integer(value)] }
          end

          # The whole picture printed among +rows+ ("picture" and four hex digits a pixel).
          def self.picture_in(rows)
            rows.find { |row| row.start_with?("picture ") }.delete_prefix("picture ").scan(/\h{4}/).map { |hex| hex.to_i(16) }
          end

          # A picture as the one number the program prints for it each frame: the CRC-32 of its
          # pixels, two bytes each with the low byte first.
          def self.picture_check(shown) = Zlib.crc32(shown.pack("v*"))

          # +held+ buttons as the program reads them: a bit each, in the order IR::Buttons lists.
          def self.button_mask(held) = Array(held).sum { |button| 1 << IR::Buttons::NAMES.index(button) }

          # The picture the run ended on, every variable then, and each moment of the run.
          attr_reader :screen, :vars, :moments

          # The interpreter's options, so a test makes either the same way. +save+ — the save
          # memory a game starts with — is refused until the native lowering can hold one.
          def initialize(save: nil)
            @held = []
            @vars = {}
            return if save.nil?

            raise CannotAnswer, "the native lowering cannot start a game from save memory yet"
          end

          # Buttons held down for the whole run, replacing any held before. An input script
          # (#input_each_frame) decides instead when there is one. Gives back self.
          def hold(*buttons)
            @held = buttons
            self
          end

          # Drive input that changes over time: the block is called for each frame with its
          # number (1, 2, 3, …) and gives back the buttons held during it. It may read the game
          # (#[]) as it stands at the end of the frame before. Gives back self.
          def input_each_frame(&block)
            @input_script = block
            self
          end

          # Plays +program+ for +frames+ frames — as many as the interpreter plays when it is not
          # told — or until it halts. Gives back self, as the interpreter's run does. A step
          # budget (+max_steps+) is the interpreter's own and is refused: the C keeps no count of
          # its steps.
          def run(program, max_steps: nil, frames: nil)
            raise CannotAnswer, "the native lowering keeps no step budget, so it cannot run with max_steps" if max_steps

            @vars = {}
            play(Native.new.build_headless(program), frames || Reference::DEFAULT_FRAMES)
            self
          end

          # A variable's value now — at the end of the run, or, from inside an input script, at
          # the end of the frame before — and 0 for one the program never names.
          def [](name)
            @vars.fetch(name, 0)
          end

          # The rest of what the interpreter answers, said by name. Anything else is an ordinary
          # NoMethodError, since the interpreter would not answer it either.
          def method_missing(name, *, **, &)
            return super unless Reference.public_method_defined?(name)

            raise CannotAnswer, "the native lowering cannot answer `#{name}` yet, which this test asks the " \
                                "interpreter. Leave its file interpreter-only, or say `skip_on_native` in this one test."
          end

          def respond_to_missing?(_name, _include_private = false) = false

          private

          def play(exe, frames)
            @moments = []
            Open3.popen3(exe, frames.to_s) do |stdin, stdout, stderr, waiter|
              complaint = Thread.new { stderr.read }
              deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + LONGEST_RUN_SECONDS
              frame = 0
              rows = []
              while (line = next_line(stdout, deadline, waiter, exe))
                case line
                when /\Aframe (\d+)\z/ then frame = Integer(Regexp.last_match(1))
                                            rows = []
                when "end" then rows = []
                when "buttons?" then record_frame_and_send_buttons(stdin, frame, rows)
                else rows << line
                end
              end
              refuse_failed_run!(exe, waiter.value, complaint.value)
              record_end(rows)
            end
          end

          # A frame boundary: the game as it stands is recorded, and then that frame's buttons
          # are sent.
          def record_frame_and_send_buttons(stdin, frame, rows)
            @vars = self.class.variables_in(rows)
            check = rows.find { |row| row.start_with?("picture-crc ") }.delete_prefix("picture-crc ").to_i(16)
            @moments << Moment.new(frame: frame, variables: @vars, picture: check)
            stdin.puts(self.class.button_mask(@input_script ? @input_script.call(frame) : @held))
            stdin.flush
          end

          def record_end(rows)
            @vars = self.class.variables_in(rows)
            @screen = Picture.new(shown: self.class.picture_in(rows))
            @moments << Moment.new(frame: :end, variables: @vars, picture: self.class.picture_check(@screen.shown))
          end

          # The next line the program printed, or nil once it has finished; a program still
          # running at +deadline+ is stopped.
          def next_line(stdout, deadline, waiter, exe)
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            unless remaining.positive? && stdout.wait_readable(remaining)
              Process.kill(:KILL, waiter.pid)
              raise Zig::Error, "#{File.basename(exe)} was still running after #{LONGEST_RUN_SECONDS} seconds, and was stopped"
            end
            stdout.gets&.chomp
          end

          def refuse_failed_run!(exe, status, complaint)
            raise Zig::Error, "#{File.basename(exe)} stopped (#{status}):\n#{complaint}" unless status.success?
          end
        end
      end
    end
  end
end
