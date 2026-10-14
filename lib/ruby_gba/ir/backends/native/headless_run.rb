# frozen_string_literal: true

require "open3"
require "tmpdir"
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
          # How long the program may take to reach its next frame before it is taken to be stuck:
          # a game that loops without ever waiting for the screen never ends on its own.
          #
          # It is each frame that is timed, and not the whole run. Every frame's answer waits its
          # turn among Ruby's threads, which run one at a time, so a run of many frames beside
          # busy threads takes far longer than the game does, and is not stuck. Nor is it how
          # long the program stays silent: one stuck in a loop can go on printing, a line for
          # every sound it makes on the way round.
          LONGEST_FRAME_SECONDS = 60

          # The picture at one moment of a run, read the way the interpreter's screen is: #pixel
          # gives the colour at (x, y) as the player would see it, nil off the screen, #shown
          # every pixel that way row by row, and #to_a every pixel as it is STORED — no window
          # moved over the picture and no fade mixed in.
          Picture = Data.define(:shown, :stored) do
            def pixel(x, y)
              return nil unless x.between?(0, Screen::WIDTH - 1) && y.between?(0, Screen::HEIGHT - 1)

              shown[(y * Screen::WIDTH) + x]
            end

            def to_a = stored.dup
          end

          # Where the game had got to at one frame boundary, or (+frame+ :end) when the run
          # stopped: every variable, the picture as a check number (see .picture_check), how
          # long the sound log was, and the sprites it last drew (see #sprites).
          Moment = Data.define(:frame, :variables, :picture, :sounds, :sprites)

          # Raised for something a test asks of the interpreter that the native lowering cannot
          # answer yet — which says the test's file was opted into native runs too early, or
          # the one test wants `skip_on_native`.
          class CannotAnswer < StandardError; end

          # The variables printed among +rows+ ("var name value"), by name.
          def self.variables_in(rows)
            rows.grep(/\Avar /).to_h { |row| _, name, value = row.split(" "); [name.to_sym, Integer(value)] }
          end

          # The whole picture printed among +rows+ ("picture" and four hex digits a pixel), which
          # a program prints when it is not writing its pictures to a file.
          def self.picture_in(rows)
            rows.find { |row| row.start_with?("picture ") }.delete_prefix("picture ").scan(/\h{4}/).map { |hex| hex.to_i(16) }
          end

          # A picture as the one number the program prints for it each frame: the CRC-32 of its
          # pixels, two bytes each with the low byte first.
          def self.picture_check(shown) = Zlib.crc32(shown.pack("v*"))

          # +held+ buttons as the program reads them: a bit each, in the order IR::Buttons lists.
          def self.button_mask(held) = Array(held).sum { |button| 1 << IR::Buttons::NAMES.index(button) }

          # How many numbers a second the sound the program makes comes as (RG_SOUND_RATE).
          SOUND_RATE = 48_000

          # Every variable as the run ended, each moment of the run, and the sound log in the
          # interpreter's words (see SoundLog) — which, read from an input script or a watching
          # block, are as they stood at the frame it is asked about. +sound+ is the sound
          # itself, one speaker's worth as whole numbers, for a run asked to record it.
          attr_reader :vars, :moments, :audio, :sound

          # Whether the screen the run ended on is tear-free, as the interpreter answers it.
          attr_reader :buffered

          # The interpreter's options, so a test makes either the same way. +save+ — the save
          # memory a game starts with — is refused until the native lowering can hold one.
          def initialize(save: nil)
            @longest_frame = LONGEST_FRAME_SECONDS
            @held = []
            @vars = {}
            @audio = []
            @sprites = []
            return if save.nil?

            raise CannotAnswer, "the native lowering cannot start a game from save memory yet"
          end

          # Buttons held down for the whole run, replacing any held before. An input script
          # (#input_each_frame) decides instead when there is one. Gives back self.
          def hold(*buttons)
            @held = buttons
            self
          end

          # Give the program +seconds+ to reach each frame before it is stopped, in place of
          # LONGEST_FRAME_SECONDS. This player's own, for a test of the limit itself. Gives back
          # self.
          def allowing_each_frame(seconds)
            @longest_frame = seconds
            self
          end

          # Keep the sound the run makes, for #sound to give back — every voice, or +only+ square
          # voice 1 or 2, which is how one voice is heard at a time. Gives back self.
          def recording_sound(only: nil)
            @records_sound = true
            @heard_voice = only
            self
          end

          # Drive input that changes over time: the block is called for each frame with its
          # number (1, 2, 3, …) and gives back the buttons held during it. It may read the game
          # (#[], #screen, #sprites) as it stands at the end of the frame before. Gives back self.
          def input_each_frame(&block)
            @input_script = block
            self
          end

          # Watch a run frame by frame, as the interpreter's each_vblank does: the block is called
          # at each frame boundary with the frame's number, once that frame's buttons are
          # decided, and the game reads then (#[], #vars, #screen, #sprites, #audio) as it stood
          # at that boundary. It only watches: the game is waiting for its buttons while the block runs,
          # and nothing it does depends on what the block read. Gives back self.
          def each_vblank(&block)
            @on_vblank = block
            self
          end

          # The picture the run ended on — or, from inside an input script or a watching block,
          # the picture at the frame boundary it is asked about. The program writes each moment's
          # picture to a file, and it is read from there only when somebody asks, so a run nobody
          # watches reads the one it ends on and no other.
          def screen
            @screen ||= @pictures && picture_now
          end

          # The sprites the game last drew, back to front, as the interpreter's #sprites gives
          # them: each row saying whose it is, where, and which of its pictures it shows. Name a
          # sprite and only its rows come back; a name the game has no sprite for is refused in
          # the interpreter's words.
          def sprites(name = nil)
            name ? @drawn_sprites.rows_named(@sprites, name) : @sprites
          end

          # Plays +program+ for +frames+ frames — as many as the interpreter plays when it is not
          # told — or until it halts. Gives back self, as the interpreter's run does. A step
          # budget (+max_steps+) is the interpreter's own and is refused: the C keeps no count of
          # its steps.
          def run(program, max_steps: nil, frames: nil)
            raise CannotAnswer, "the native lowering keeps no step budget, so it cannot run with max_steps" if max_steps

            @vars = {}
            @audio = []
            @screen = nil
            @sprites = []
            @sound_log = SoundLog.new(program)
            @drawn_sprites = DrawnSprites.new(program)
            play(Native.new.build_headless(program), frames || Reference::DEFAULT_FRAMES)
            self
          end

          # A variable's value now — at the end of the run, or, from inside an input script or a
          # watching block, at the frame boundary it is asked at — and 0 for one the program
          # never names.
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

          # What the program prints is read a line at a time, so the two big things it makes go
          # to files of their own, in a folder that lasts as long as the run: every moment's
          # picture, written over the one before and read when it is asked for (#screen), and
          # the sound, for a run asked to record it, read back when the program has finished.
          def play(exe, frames)
            Dir.mktmpdir("ruby-gba-run") do |dir|
              File.open(File.join(dir, "picture"), "w+b") do |pictures|
                @pictures = pictures
                play_frames(exe, frames, ["--picture-out", pictures.path, *sound_options(dir)])
              end
              @sound = File.binread(File.join(dir, "sound")).unpack("s<*") if @records_sound
            end
          ensure
            @pictures = nil
          end

          def sound_options(dir)
            return [] unless @records_sound

            ["--sound-out", File.join(dir, "sound"), *(["--sound-voice", @heard_voice.to_s] if @heard_voice)]
          end

          # The picture in the program's file now, which is the picture of the moment it last
          # printed: every pixel as shown and then every pixel as stored, two bytes each with the
          # low byte first.
          def picture_now
            each = Screen::WIDTH * Screen::HEIGHT
            pixels = @pictures.pread(each * 4, 0).unpack("v*")
            unless pixels.length == each * 2
              raise Zig::Error, "the program's picture file holds #{pixels.length} pixels, where two pictures are #{each * 2}"
            end

            Picture.new(shown: pixels.first(each), stored: pixels.last(each))
          end

          def play_frames(exe, frames, options)
            @moments = []
            Open3.popen3(exe, frames.to_s, *options) do |stdin, stdout, stderr, waiter|
              complaint = Thread.new { stderr.read }
              # A program that is stopped has its streams closed under this reader, which is
              # reported where the program is (#next_line) and not a second time from here.
              complaint.report_on_exception = false
              frame = 0
              rows = []
              expect_next_frame
              while (line = next_line(stdout, waiter, exe, frame))
                case line
                when /\Aframe (\d+)\z/ then frame = Integer(Regexp.last_match(1))
                                            rows = []
                when "end" then rows = []
                when /\Asound / then @audio << @sound_log.entry_from(line)
                when "buttons?" then record_frame_and_send_buttons(stdin, frame, rows)
                else rows << line
                end
              end
              refuse_failed_run!(exe, waiter.value, complaint.value)
              record_end(rows)
            end
          end

          # A frame boundary: the game as it stands is recorded, that frame's buttons are decided,
          # whoever is watching the run is shown the frame, and then the buttons are sent. That
          # is the interpreter's order, and the program is waiting for its buttons throughout, so
          # the picture in its file is this frame's for as long as anybody here can ask for it.
          def record_frame_and_send_buttons(stdin, frame, rows)
            @vars = self.class.variables_in(rows)
            @sprites = @drawn_sprites.rows_in(rows)
            @screen = nil
            check = rows.find { |row| row.start_with?("picture-crc ") }.delete_prefix("picture-crc ").to_i(16)
            @moments << Moment.new(frame: frame, variables: @vars, picture: check, sounds: @audio.size, sprites: @sprites)
            buttons = @input_script ? @input_script.call(frame) : @held
            @on_vblank&.call(frame)
            stdin.puts(self.class.button_mask(buttons))
            stdin.flush
            expect_next_frame
          end

          # The program has just been started, or handed a frame's buttons: from now it has
          # LONGEST_FRAME_SECONDS to reach the next frame. However long a test's input script
          # took to decide, or its watching block to look, is its own time, and is not counted.
          def expect_next_frame
            @frame_due = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @longest_frame
          end

          def record_end(rows)
            @vars = self.class.variables_in(rows)
            @sprites = @drawn_sprites.rows_in(rows)
            @screen = picture_now
            @buffered = rows.include?("pages 2")
            @moments << Moment.new(frame: :end, variables: @vars, picture: self.class.picture_check(@screen.shown),
                                   sounds: @audio.size, sprites: @sprites)
          end

          # The next line the program printed, or nil once it has finished; a program that has
          # had as long as a frame may take since +frame+, and has not reached the next, is
          # stopped.
          def next_line(stdout, waiter, exe, frame)
            remaining = @frame_due - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            unless remaining.positive? && stdout.wait_readable(remaining)
              Process.kill(:KILL, waiter.pid)
              raise Zig::Error, "#{File.basename(exe)} had not reached the frame after frame #{frame} " \
                                "in #{@longest_frame} seconds, and was stopped"
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
