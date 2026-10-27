# frozen_string_literal: true

require "open3"
require "tmpdir"
require "zlib"

module VBlank
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
          # every pixel that way row by row, and #stored_pixel and #to_a as it is STORED — no
          # window moved over the picture and no fade mixed in. #camera_x and #camera_y are where
          # that window sits.
          Picture = Data.define(:shown, :stored, :camera_x, :camera_y) do
            def pixel(x, y) = on_screen?(x, y) ? shown[(y * Screen::WIDTH) + x] : nil

            def stored_pixel(x, y) = on_screen?(x, y) ? stored[(y * Screen::WIDTH) + x] : nil

            def to_a = stored.dup

            private

            def on_screen?(x, y) = x.between?(0, Screen::WIDTH - 1) && y.between?(0, Screen::HEIGHT - 1)
          end

          # Where the game had got to at one frame boundary (RunComparison::Moment).
          Moment = RunComparison::Moment

          # Raised for something a test asks of the interpreter that the native lowering cannot
          # answer yet — which says the test's file was opted into native runs too early, or
          # the one test wants `skip_on_native`.
          CannotAnswer = RunComparison::CannotAnswer

          # Whose a sounding mixer voice is, as the C prints it (rg_mix_voice_reading's owner).
          GAME_OWNS = 0
          SONG_OWNS = 1
          EFFECT_OWNS = 2

          # The variables printed among +rows+ ("var name value"), by name.
          def self.variables_in(rows)
            rows.grep(/\Avar /).to_h { |row| _, name, value = row.split(" "); [name.to_sym, Integer(value)] }
          end

          # The lists printed among +rows+ ("list", the name, a tab, and the items oldest first), by
          # name. The tab ends the name, which may hold spaces.
          def self.lists_in(rows)
            rows.grep(/\Alist /).to_h do |row|
              name, items = row.delete_prefix("list ").split("\t", 2)
              [name.to_sym, items.to_s.split(" ").map { |item| Integer(item) }]
            end
          end

          # The whole picture printed among +rows+ ("picture" and four hex digits a pixel), which
          # a program prints when it is not writing its pictures to a file.
          def self.picture_in(rows)
            rows.find { |row| row.start_with?("picture ") }.delete_prefix("picture ").scan(/\h{4}/).map { |hex| hex.to_i(16) }
          end

          # Where the window sat over the picture, printed among +rows+ ("camera X Y").
          def self.camera_in(rows)
            rows.find { |row| row.start_with?("camera ") }.split(" ").drop(1).map { |number| Integer(number) }
          end

          # A picture as the one number the program prints for it each frame
          # (RunComparison.picture_check).
          def self.picture_check(shown) = RunComparison.picture_check(shown)

          # +held+ buttons as the program reads them (IR::Buttons.mask).
          def self.button_mask(held) = IR::Buttons.mask(held)

          # How many numbers a second the sound the program makes comes as (RG_SOUND_RATE).
          SOUND_RATE = 48_000

          # Every variable as the run ended, each moment of the run, and the sound log in the
          # interpreter's words (see SoundLog) — which, read from an input script or a watching
          # block, are as they stood at the frame it is asked about. +sound+ is the sound
          # itself, one speaker's worth as whole numbers, for a run asked to record it.
          attr_reader :vars, :moments, :audio, :sound

          # The sound log as the run made it, every entry, whatever a test did to #audio: a test may
          # clear that one as it watches, the way it may clear the interpreter's, and this is what
          # the run is compared by. Each moment counts its entries from here.
          attr_reader :audio_played

          # Whether the screen the run ended on is tear-free, as the interpreter answers it.
          attr_reader :buffered

          # The save memory the run was handed, holding what the last run left in it.
          attr_reader :save

          # The interpreter's options, so a test makes either the same way. +save+ is the save
          # memory the game starts with (an IR::SaveImage), a new cartridge's unless one is
          # handed over. What a run leaves in its save memory is put back into it, so handing
          # the SAME one to two runs is the console turned off and on again, as it is for the
          # interpreter.
          def initialize(save: SaveImage.new)
            unless save.is_a?(SaveImage)
              raise ArgumentError, "save: must be a VBlank::IR::SaveImage. To make an empty save memory, " \
                                   "write VBlank::IR::SaveImage.new."
            end

            @save = save
            @longest_frame = LONGEST_FRAME_SECONDS
            @held = []
            @vars = {}
            @lists = {}
            @declared_lists = []
            @mix_slices = []
            @mixing = []
            @mix_peak = 0
            @mix_drops = [0, 0]
            @audio = []
            @audio_played = []
            @sprites = []
          end

          # #list, #pool and #game_state, answered from what the program printed as the
          # interpreter answers them from what it holds.
          include Reference::ReadingBack

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

          # Keep the sound the run makes, for #sound to give back — every voice, or +only+ one of
          # them by the console's count (1 and 2 the square voices, 3 the wave voice, 4 the noise
          # voice), which is how one voice is heard at a time. Gives back self.
          def recording_sound(only: nil)
            @records_sound = true
            @heard_voice = only
            self
          end

          # Give the cartridge a clock reading +time+ at power-on, as the interpreter's #clock_at
          # does, moved on a frame of the console's each frame; +set: false+ is a clock that is
          # there and was never set. A run never told has no clock. Gives back self.
          def clock_at(time, set: true)
            @clock_started = time
            @clock_set = set
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

            @save.use_memory!(SaveLayout.memory_of(program))
            @keeps_save = Saving.named_by?(program)
            @vars = {}
            @lists = {}
            @declared_lists = program.walk.select { |node| node.kind == :list_new }.map(&:name).uniq
            @mix_slices = []
            @mixing = []
            @mix_peak = 0
            @mix_drops = [0, 0]
            @audio = []
            @audio_played = []
            @screen = nil
            @sprites = []
            @sound_log = SoundLog.new(program)
            @drawn_sprites = DrawnSprites.new(program)
            play(headless_program(program), frames || Reference::DEFAULT_FRAMES)
            self
          ensure
            @save.restore_power # a cut is for one run, as it is for the interpreter
          end

          # A variable's value now — at the end of the run, or, from inside an input script or a
          # watching block, at the frame boundary it is asked at — and 0 for one the program
          # never names.
          def [](name)
            @vars.fetch(name, 0)
          end

          # WHAT THE MIXER MADE AND IS PLAYING, as the interpreter answers it — at the end of the
          # run, or at the frame boundary a watching block or an input script asks at. Every
          # frame's slice of sound, oldest first; the recordings sounding, a voice each, in the
          # order of the voices; the most that sounded at once; how many plays were dropped; the
          # level a sounding recording of the game's plays at; and how far through its shape the
          # first voice sounding a recording is.
          def mixed_sound = @mix_slices.dup
          def active_samples = @mixing.map { |recording, *| recording_name(recording) }
          def peak_voices = @mix_peak

          def level_of(name)
            _, _, level, = @mixing.find { |recording, *| recording_name(recording) == name }
            level
          end

          def sound_drops
            dropped, held = @mix_drops
            Diagnostics::SoundDrops::Reading.new(dropped: dropped, music_held: held, voices: VBlank::Audio::Sound::MIXER_VOICES)
          end

          def volume_of(name)
            _, loudness, = @mixing.find { |recording, _, _, owner| owner == GAME_OWNS && recording_name(recording) == name }
            loudness && VBlank::Audio::Sound::MIX_LEVELS.key(loudness)
          end

          # Whose each sounding voice is, in the same order: :game, [:song, lane], or the sound
          # effect's name and its lane.
          def sound_owners
            @mixing.map do |_, _, _, owner, effect, lane|
              case owner
              when GAME_OWNS then :game
              when SONG_OWNS then [:song, lane]
              when EFFECT_OWNS then [@sound_log.sound_effects.fetch(effect), lane]
              end
            end
          end

          def recording_name(number) = @sound_log.recordings.fetch(number).name

          # The C keeps no count of its steps, so nothing stops a run of it at one: it ends at
          # the frames asked for, or where the game halts. A game only a step budget would stop
          # never reaches the C at all (CheckedRun#refuse_endless_game_without_frames!).
          def stopped_at_budget? = false

          # The rest of what the interpreter answers, each said by name, so a test asking one meets
          # a sentence saying so rather than a NoMethodError that reads like a typo in the test.
          # test_native_headless_run.rb holds this list to every public method the interpreter
          # has, so one added there and not here fails that test.
          def frame = refuse_unanswered!(:frame)
          def frames_each_pass(&) = refuse_unanswered!(:frames_each_pass)
          def log = refuse_unanswered!(:log)
          def screen_mode = refuse_unanswered!(:screen_mode)
          def write_save_copy(*) = refuse_unanswered!(:write_save_copy)
          def write_save_vars(*) = refuse_unanswered!(:write_save_vars)

          private

          def refuse_unanswered!(name)
            raise CannotAnswer, "#{lowering_name} cannot answer `#{name}` yet, which this test asks the " \
                                "interpreter. Leave its file interpreter-only, or say `#{skip_helper_name}` in this one test."
          end

          # What a refusal calls this lowering, and the helper a test says to skip it there.
          # JS::HeadlessRun says its own.
          def lowering_name = "the native lowering"
          def skip_helper_name = "skip_on_native"

          # The program a run plays: the game built as C with no window. JS::HeadlessRun plays the
          # game as JavaScript instead, which prints the same lines, and builds that here.
          def headless_program(program) = Native.new.build_headless(program)

          # How the program at +exe+ is started: the settings it gets besides this process's own,
          # and the command. A program built as C is started as itself; Ruby::HeadlessRun's is a
          # script, started by a Ruby.
          def program_command(exe) = [{}, exe]

          # What the program prints is read a line at a time, so the two big things it makes go
          # to files of their own, in a folder that lasts as long as the run: every moment's
          # picture, written over the one before and read when it is asked for (#screen), and
          # the sound, for a run asked to record it, read back when the program has finished.
          def play(exe, frames)
            Dir.mktmpdir("vblank-run") do |dir|
              File.open(File.join(dir, "picture"), "w+b") do |pictures|
                @pictures = pictures
                play_frames(exe, frames, ["--picture-out", pictures.path, *sound_options(dir), *save_options(dir),
                                          *held_options, *clock_options])
              end
              @sound = File.binread(File.join(dir, "sound")).unpack("s<*") if @records_sound
              @save.replace_with_sav(File.binread(save_file(dir)), from: "The save memory the program wrote") if @keeps_save
            end
          ensure
            @pictures = nil
          end

          def save_file(dir) = File.join(dir, "save")

          # A game that names save memory is handed this run's, as the .sav file the program
          # starts from and writes back when it ends (see #play) — and a cut waiting on it, as
          # the step the program's power goes off at.
          def save_options(dir)
            return [] unless @keeps_save

            File.binwrite(save_file(dir), @save.to_sav)
            ["--save", save_file(dir), *(["--save-cut-after", @save.power_left.to_s] if @save.power_left)]
          end

          # Buttons held for the whole run are down from power-on, before the game's first
          # statement, as the interpreter's are — and an input script decides only from the first
          # frame on, as the interpreter's does.
          def held_options
            @held.empty? ? [] : ["--held-from-power-on", self.class.button_mask(@held).to_s]
          end

          # The clock's moment as the program takes it: the date and the hour the Time says, as
          # seconds from the start of 1970 with no time zone (see IR::Clock.reading), and its part
          # of a second as the console's ticks: the Advance's, which the runtime counts in
          # (RG_CONSOLE_TICKS_A_SECOND).
          def clock_options
            return [] unless @clock_started

            said = IR::Clock.moved_on(@clock_started, 0)
            ticks = (said.subsec * Console::ADVANCE.cycles_a_second).floor
            ["--clock-at", said.to_i.to_s, ticks.to_s, @clock_set ? "1" : "0"]
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

            Picture.new(shown: pixels.first(each), stored: pixels.last(each), camera_x: @camera[0], camera_y: @camera[1])
          end

          def play_frames(exe, frames, options)
            @moments = []
            Open3.popen3(*program_command(exe), frames.to_s, *options) do |stdin, stdout, stderr, waiter|
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
                when /\Asound / then @audio_played << @sound_log.entry_from(line)
                                     @audio << @audio_played.last
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
            read_state_from(rows)
            @screen = nil
            check = rows.find { |row| row.start_with?("picture-crc ") }.delete_prefix("picture-crc ").to_i(16)
            @moments << Moment.new(frame: frame, variables: @vars, picture: check, sounds: @audio_played.size, sprites: @sprites,
                                   collections: game_state.except(:vars), sounding: active_samples)
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
            read_state_from(rows)
            @screen = picture_now
            @buffered = rows.include?("pages 2")
            @moments << Moment.new(frame: :end, variables: @vars, picture: self.class.picture_check(@screen.shown),
                                   sounds: @audio_played.size, sprites: @sprites, collections: game_state.except(:vars),
                                   sounding: active_samples)
          end

          # Where the game stands, as the program printed it at one moment.
          def read_state_from(rows)
            @vars = self.class.variables_in(rows)
            @lists = self.class.lists_in(rows)
            @sprites = @drawn_sprites.rows_in(rows)
            @camera = self.class.camera_in(rows)
            read_mix_from(rows)
          end

          # What the mixer made and is playing, for a game that mixes recordings (see print_mix in
          # runtime/rg_headless.c): a new slice when one was made since the last moment, and the
          # voices and counts as they stand.
          def read_mix_from(rows)
            slice = rows.find { |row| row.start_with?("mix ") || row == "mix" }
            @mix_slices << slice.split(" ").drop(1).map { |sample| Integer(sample) } if slice
            mixing = rows.find { |row| row.start_with?("mixing") } or return

            @mixing = mixing.split(" ").drop(1).map { |number| Integer(number) }.each_slice(6).to_a
            @mix_peak = Integer(rows.find { |row| row.start_with?("mix_peak ") }.split(" ").last)
            @mix_drops = rows.find { |row| row.start_with?("mix_drops ") }.split(" ").drop(1).map { |number| Integer(number) }
          end

          # --- what ReadingBack reads #list, #pool and #game_state from ---

          # A list the program never reaches has no storage in the C and is not printed, and the
          # interpreter holds it, empty, from power-on: so a list the game declares and the
          # program did not print is empty.
          def list_items(name) = @lists.fetch(name) { @declared_lists.include?(name) ? [] : nil }&.dup
          def list_names = @declared_lists | @lists.keys

          # Every variable the program names. The interpreter holds only the ones a run has
          # written, so a variable the game names and never writes is here, at 0, and not there.
          def variables_now = @vars

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

          def refuse_failed_run!(exe, status, complaint) = Zig.refuse_stopped_program!(exe, status, complaint)
        end
      end
    end
  end
end
