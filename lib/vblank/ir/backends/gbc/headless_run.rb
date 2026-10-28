# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBC
        # A Game Boy Color cartridge played in the emulator with nobody watching, driven and read back
        # through the calls a test makes on Backends::Reference — so a test written against the
        # interpreter can be handed this instead and never know. It makes the Moments every checked
        # run compares (RunComparison), which is what lets the checked run compare the two with the
        # interpreter's words.
        #
        # HOW A PASS IS READ. The emulator plays a frame at a time and stops as the console begins its
        # vertical blank. The runtime keeps, where this can read it, how many passes of the game loop
        # have ended, whether the game is waiting at the end of one, and which pass the console's
        # picture shows (Runtime::Frame) — the picture of a pass is copied to the console in the blank
        # after it, so it is on the screen one frame after the pass's numbers are final. So each pass's
        # numbers are read when the game is found waiting at its end, and its picture from the first
        # frame drawn showing it, and the two make the pass's moment. The buttons for the next pass are
        # set before the emulator plays on, and the game reads them in the blank.
        class HeadlessRun
          CannotAnswer = RunComparison::CannotAnswer
          Moment = RunComparison::Moment

          # How many frames a pass may take before the game is taken to be stuck.
          LONGEST_PASS_FRAMES = 600

          # The picture at one moment of a run, read the way the interpreter's screen is: #pixel gives
          # the colour at (x, y), nil off the screen, #shown every pixel row by row. #camera_x and
          # #camera_y are where the view sits over a painted picture (nought on a tiled screen, as the
          # interpreter's are).
          Picture = Data.define(:shown, :width, :height, :camera_x, :camera_y) do
            def pixel(x, y) = on_screen?(x, y) ? shown[(y * width) + x] : nil
            def stored_pixel(x, y) = pixel(x, y)
            def to_a = shown.dup

            private

            def on_screen?(x, y) = x.between?(0, width - 1) && y.between?(0, height - 1)
          end

          attr_reader :vars, :moments, :rom, :save

          def initialize(save: SaveImage.new)
            unless save.is_a?(SaveImage)
              raise ArgumentError, "save: must be a VBlank::IR::SaveImage. To make an empty save memory, " \
                                   "write VBlank::IR::SaveImage.new."
            end

            @save = save
            @held = []
            @vars = {}
            @lists = {}
            @declared_lists = []
          end

          include Reference::ReadingBack

          def hold(*buttons)
            @held = buttons
            self
          end

          def input_each_frame(&block)
            @input_script = block
            self
          end

          def each_vblank(&block)
            @on_vblank = block
            self
          end

          # Give the cartridge's clock chip, which counts days and keeps no date, the time of day
          # +time+ says and a count of nought days when the game first reads it, moved on a frame of
          # the console's each frame, as the interpreter's #clock_at does on a console whose chip is
          # of that kind; +set: false+ is a chip that stopped when its battery ran out. +days+ is a
          # chip that has counted that many already, and +counters+ one whose five registers hold
          # those bytes — what a real chip can hold once its battery has run out — neither of which
          # the interpreter has a word for. A run never told plays a cartridge with no chip at all.
          # Gives back self.
          def clock_at(time, set: true, days: 0, counters: nil)
            @clock_started = time
            @clock_set = set
            @clock_days = days
            @clock_counters = counters
            self
          end

          # The picture the run ended on, or the one at the frame boundary an input script or a
          # watching block is asked at.
          def screen = @screen

          # Plays +program+ for +frames+ frames — as many as the interpreter plays when it is not told
          # — or until it halts. Gives back self.
          def run(program, max_steps: nil, frames: nil)
            raise CannotAnswer, "a Game Boy Color cartridge keeps no step budget, so it cannot run with max_steps" if max_steps

            @rom = GBC.new.build(program, title: "CHECKED")
            @places = @rom.built
            @drawn_sprites = SpriteNames.new(program)
            @declared_lists = program.walk.select { |node| node.kind == :list_new }.map(&:name).uniq
            @sound_log = SoundLog.new(@places)
            @sounds = 0
            @audio = []
            @audio_handed = 0
            @frames_took = {}
            @dark_frames = nil
            @motor = false
            @deciding = false
            @decided = nil
            @moments = []
            @vars = {}
            @lists = {}
            play(frames || Reference::DEFAULT_FRAMES)
            self
          end

          def [](name) = @vars.fetch(name, 0)

          def stopped_at_budget? = false

          # How many frames each pass answered for, by the pass's number, as the interpreter is told
          # it (Reference#frames_each_pass): one, for a game that keeps up.
          def frames_took(pass) = @frames_took.fetch(pass, 1)

          # How many frames the screen was off for before the first, as the runtime counted them
          # (Runtime::Frame::DARK_FRAMES), as the interpreter is told it (Reference#frames_setting_up):
          # none, for a game that does not count them.
          def dark_frames_counted = @dark_frames || 0

          # Whether the cartridge's motor runs on the frame the run's picture is (Reference#motor_on?).
          def motor_on? = @motor

          # The rest of what the interpreter answers, each refused by name.
          # What it drew at the moment the run ended, as the interpreter says it (Reference#sprites):
          # every sprite, back to front, or the ones the game declared as +name+.
          def sprites(name = nil)
            rows = @sprites || []
            name ? @drawn_sprites.rows_named(rows, name) : rows
          end

          # The sound log up to the moment the run ended, or the one at the frame boundary an input
          # script or a watching block is asked at, in the interpreter's words (GBC::SoundLog). It is
          # the test's to clear as it watches, as the interpreter's is: what comes after is added to
          # what the test left. The run is compared by every entry whatever the test did to it.
          def audio
            @audio.concat(@sound_log.entries[@audio_handed...@sounds]) if @sounds > @audio_handed
            @audio_handed = [@audio_handed, @sounds].max
            @audio
          end

          # The sound log up to the moment the run ended, every entry, whatever a test did to #audio.
          def audio_played = @sound_log.entries.take(@sounds)

          # Every entry the cartridge played, past where the run ended too: the frames it is played
          # on after the last pass compared play the music on.
          def whole_audio = @sound_log.entries.dup

          %i[mixed_sound active_samples peak_voices sound_drops sound_owners frame log screen_mode
             buffered].each do |name|
            define_method(name) { |*| refuse_unanswered!(name) }
          end
          def volume_of(*) = refuse_unanswered!(:volume_of)
          def level_of(*) = refuse_unanswered!(:level_of)
          def frames_each_pass(&) = refuse_unanswered!(:frames_each_pass)
          def write_save_copy(*) = refuse_unanswered!(:write_save_copy)
          def write_save_vars(*) = refuse_unanswered!(:write_save_vars)

          private

          def refuse_unanswered!(name)
            raise CannotAnswer, "the Game Boy Color lowering cannot answer `#{name}` yet, which this test asks the " \
                                "interpreter. Say `skip_on_gbc` in this one test."
          end

          # THE SAVE MEMORY goes in as the file the emulator keeps a cartridge's battery-backed
          # memory in, and what the run left there comes back into the same image when the console
          # is off again — so one image handed to two runs is a power cycle, as it is for the
          # interpreter.
          def play(frames)
            saves = SaveLayout.named_by?(@rom.built.source_program)
            refuse_power_cut! if saves
            Diagnostics::Emulator.with_cartridge(@rom, file_name: "game.gbc", save: (@save if saves)) do |core|
              @core = core
              start_clock if @rom.clock?
              @core.set_keys(IR::Buttons.mask(@held))
              @core.record_arrivals(@sound_log.addresses) if @sound_log.any?
              play_passes(frames)
            ensure
              @core = nil
            end
          end

          # The emulator gives every cartridge whose header says it has a clock chip one that reads
          # the computer's clock, so a run never told a time has the chip taken away, and one told
          # has its chip's counters set: the seconds, minutes and hours +time+ says, its days, and
          # the halt bit for a chip that stopped (Lowering::Clock). The moment is the date and the
          # hour the Time says, as the interpreter takes it.
          def start_clock
            return @core.remove_clock unless @clock_started

            h = Console::GBCHardware
            said = IR::Clock.moved_on(@clock_started, 0)
            high = (@clock_days >> 8) & h::CLOCK_DAY_NINTH_BIT
            counters = @clock_counters ||
                       [said.sec, said.min, said.hour, @clock_days & 0xFF, @clock_set ? high : high | h::CLOCK_HALT]
            @core.use_counting_clock((said.to_r * 1000).to_i, counters.pack("C*"), !@clock_counters.nil?)
          end

          def refuse_power_cut!
            return unless @save.power_left

            raise CannotAnswer, "a Game Boy Color cartridge keeps no count of its steps, so it cannot have its power " \
                                "cut after #{@save.power_left} of them"
          end

          # Pass by pass until +frames+ have ended or the game stops: each pass's numbers when the game
          # is found waiting at its end, its picture once the screen shows it. The interpreter, told
          # to play +frames+ frames, plays one pass more and stops as that one ends, without a frame
          # boundary for it: the end of the run is that pass.
          def play_passes(frames)
            pending = nil # [pass, variables, lists, sprites, sounds] whose picture is not on the screen yet
            waited = 0
            loop do
              play_frame
              waited += 1
              refuse_stuck_game! if waited > LONGEST_PASS_FRAMES
              if pending && shown_pass == pending.first
                pass, variables, lists, @sprites, sounds = pending
                pending = nil
                return record_moment(:end, variables, lists, picture_now, sounds) if pass > frames

                record_moment(pass, variables, lists, picture_now, sounds_after_pass(pass))
              end
              case state
              when Runtime::Frame::HALTED then return finish_after_halt
              when Runtime::Frame::WENT_WRONG then raise_fault
              end
              next unless pending.nil? && waiting? && passes > @moments.size

              pending = [passes, read_variables, read_lists, read_sprites, @sound_log.entries.size]
              note_dark_frames if passes == 1
              note_frames_took(passes - 1) if passes > 1
              mark_last_pass_taken if passes == frames
              hold_after_this_pass if passes > frames
              waited = 0
              @deciding = passes <= frames
            end
          end

          # THE BUTTONS ARE DECIDED A SCREEN FRAME AT A TIME, numbered as the runtime counts the
          # frames it draws, since the runtime reads them in the screen's interrupt on every one
          # (Runtime::Frame) — so a pass that spans several frames reads each of them, as the
          # interpreter's does. They are decided from the first pass's end, before the blank the
          # game first reads them in: until then they are the ones held from power-on.
          def decide_buttons
            return unless @deciding

            frame = word(runtime_place(Runtime::Frame::FRAMES)) + 1
            return if frame == @decided

            @decided = frame
            buttons = @input_script ? @input_script.call(frame) : @held
            @core.set_keys(IR::Buttons.mask(buttons))
          end

          # How many frames pass +pass+ took, as the runtime counted them where its wait ended
          # (Runtime::Frame::STEPS) — read once the game waits at the end of the pass after it. The
          # real number, and not the one the game reads, which is held at IR::Frames::MOST: the
          # music and the buttons take every frame.
          def note_frames_took(pass)
            kept = Runtime::Frame::STEPS_KEPT
            @frames_took[pass] = @core.bus_read8(runtime_place(Runtime::Frame::STEPS) + (pass % kept))
          end

          # Read once the first pass has ended, by when the screen is on and the count is done.
          def note_dark_frames
            dark = @places.runtime[Runtime::Frame::DARK_FRAMES]
            @dark_frames = dark ? half(dark) : 0
          end

          # The moment of +frame+ — a pass's number, or :end for the moment the run ended on, which
          # is no frame boundary and so is not shown to a block watching each one.
          def record_moment(frame, variables, lists, picture, sounds)
            @vars = variables
            @lists = lists
            @screen = picture
            @sounds = sounds
            @motor = @core.motor_on? # as the frame the picture is was shown
            @moments << Moment.new(frame: frame, variables: variables, picture: picture_check(picture), sounds: sounds,
                                   sprites: @sprites, collections: game_state.except(:vars), sounding: [],
                                   motor: @motor)
            @on_vblank&.call(frame) unless frame == :end
          end

          # The game halted: its picture copied to the console once more, then shown; the moment is
          # the end of the run.
          def finish_after_halt
            sounds = @sound_log.entries.size
            # No pass comes after the last wait to read its frames at: read them here.
            (1..passes).last(Runtime::Frame::STEPS_KEPT).each { |pass| note_frames_took(pass) unless @frames_took.key?(pass) }
            frames = 0
            until shown_pass == Runtime::Frame::END_SHOWN || frames > 3
              play_frame
              frames += 1
            end
            play_frame
            @sprites = read_sprites
            record_moment(:end, read_variables, read_lists, picture_now, sounds)
          end

          # How many entries of the sound log are pass +pass+'s, the frame boundary after it included
          # (GBC::SoundLog). The end of the run has no boundary after it, so its moment counts the log
          # as the game was found waiting.
          def sounds_after_pass(pass) = @sound_log.any? ? @sound_log.size_after_pass(pass) : 0

          # One frame of the emulator, with its buttons decided, and what the cartridge played in it
          # into the sound log.
          def play_frame
            decide_buttons
            @core.run_frame
            @sound_log.read(@core.take_arrivals) if @sound_log.any?
          end

          def picture_check(picture) = RunComparison.picture_check(picture.shown)

          # The emulator's picture, each pixel turned back into the 15-bit colour the console holds.
          def picture_now
            buffer = @core.video_buffer
            width = @core.width
            height = @core.height
            shown = Array.new(width * height) do |i|
              at = i * 4
              (buffer.getbyte(at) >> 3) | ((buffer.getbyte(at + 1) >> 3) << 5) | ((buffer.getbyte(at + 2) >> 3) << 10)
            end
            camera_x, camera_y = view_over_painting
            Picture.new(shown: shown, width: width, height: height, camera_x: camera_x, camera_y: camera_y)
          end

          # Where the view sits over a painted picture: the scroll the game last asked for
          # (Runtime::Picture::SCROLL), each a byte read as a whole number from -128, or nought on a
          # screen drawn from tiles.
          def view_over_painting
            return [0, 0] unless @core.bus_read8(runtime_place(Runtime::Paint::SCREEN_KIND)) == Runtime::Paint::PAINTED

            at = runtime_place(Runtime::Picture::SCROLL)
            [0, 1].map do |i|
              byte = @core.bus_read8(at + i)
              byte >= 0x80 ? byte - 0x100 : byte
            end
          end

          def read_variables = @places.variables.transform_values { |address| word(address) }

          # The sprites the game placed in its last pass, back to front (GBC::Places#drawn_sprite_rows).
          def read_sprites = @places.drawn_sprite_rows(@drawn_sprites, @core.method(:bus_read8))

          # The +width+ bytes at +address+ as one number, lowest byte first, as the Color keeps them.
          def little(address, width) = (0...width).sum { |i| @core.bus_read8(address + i) << (8 * i) }

          def read_lists
            @places.lists.to_h do |name, (address, _capacity, width, _label)|
              capacity = half(address + Runtime::Lists::CAPACITY)
              front = half(address + Runtime::Lists::FRONT)
              length = half(address + Runtime::Lists::LENGTH)
              items = Array.new(length) do |i|
                slot = (front + i) % capacity
                read_slot(address + Runtime::Lists::HEADER + (slot * width), width)
              end
              [name, items]
            end
          end

          def read_slot(address, width)
            raw = little(address, width)
            top = 1 << ((8 * width) - 1)
            raw >= top ? raw - (top << 1) : raw
          end

          def word(address) = IR::Int32.wrap(@core.bus_read32(address))
          def half(address) = little(address, 2)

          def runtime_place(name) = @places.runtime.fetch(name)

          # The last pass the run reads: the game is told to show it and go no further.
          def hold_after_this_pass = @core.bus_write32(runtime_place(Runtime::Frame::HOLD), 1)
          # The interpreter stops a run at the boundary after the last pass compared, before it
          # moves its timers on (Runtime::Frame::LAST_PASS_TAKEN).
          def mark_last_pass_taken = @core.bus_write32(runtime_place(Runtime::Frame::LAST_PASS_TAKEN), 1)
          def state = @core.bus_read8(runtime_place(Runtime::Frame::STATE))
          def waiting? = @core.bus_read8(runtime_place(Runtime::Frame::WAITING)) == 1
          def passes = word(runtime_place(Runtime::Frame::PASSES))
          def shown_pass = @core.bus_read32(runtime_place(Runtime::Frame::SHOWN))

          # --- what ReadingBack reads #list, #pool and #game_state from ---

          def list_items(name) = @lists.fetch(name) { @declared_lists.include?(name) ? [] : nil }&.dup
          def list_names = @declared_lists | @lists.keys
          def variables_now = @vars

          def refuse_stuck_game!
            raise CannotAnswer, "the Game Boy Color cartridge had not reached the end of a pass in " \
                                "#{LONGEST_PASS_FRAMES} frames, and was stopped"
          end

          # The game went wrong: the interpreter's words for what went wrong, from what the runtime
          # kept of it.
          def raise_fault
            at = runtime_place(Runtime::Frame::FAULT)
            code = @core.bus_read8(at)
            list = @places.lists.find { |_, (address, *)| address == half(at + 1) }&.first
            first = word(at + 3)
            second = word(at + 7)
            raise ProgramError, fault_message(code, list, first, second)
          end

          # The sentence for the fault the runtime kept as +code+, with the two numbers it kept
          # beside it and the list it named, if any.
          def fault_message(code, list, first, second)
            case code
            when Runtime::Frame::INDEX_OUT_OF_RANGE then Faults.index_out_of_range(list, first, second)
            when Runtime::Frame::LIST_FULL then Faults.list_full(list, first)
            when Runtime::Frame::LIST_EMPTY then Faults.list_empty(list, first.zero? ? :back : :front)
            when Runtime::Frame::COPY_TOO_LONG then Faults.copy_too_long(list, first, second)
            when Runtime::Frame::COPY_PAST_TABLE then Faults.copy_past_table(first, second)
            when Runtime::Frame::PICTURE_NOT_THERE then Faults.picture_missing(first, second)
            when Runtime::Frame::SAVE_READ_OUTSIDE then Faults.save_outside("read", first, second)
            when Runtime::Frame::SAVE_WRITE_OUTSIDE then Faults.save_outside("wrote to", first, second)
            when Runtime::Frame::PICTURE_NOT_UP then picture_not_up_message(@places.picture_checks.fetch(first), second)
            when Runtime::Frame::GROUPS_NOT_TOGETHER then groups_not_together_message(@places.together_checks.fetch(first))
            else "the game went wrong (#{code})"
            end
          end

          # Reference#picture_not_up_message, from what the check that stopped the game asked, the
          # pose the sprite showed, and the numbers the game said in the set's slots as it stopped.
          def picture_not_up_message(check, pose)
            Faults.picture_not_up(sprite: check.sprite, picture: check.poses.fetch(pose), groups: check.groups,
                                  holding: check.holdings.fetch(pose), up: groups_said_up(check))
          end

          # Reference#groups_not_together_message, from the set the check asked of and the numbers
          # the game said in its slots as it stopped.
          def groups_not_together_message(check) = Faults.groups_not_together(groups: check.groups, up: groups_said_up(check))

          # Reference#up_numbers: the groups the game said are up in a set's slots, in slot order,
          # each once, and only the numbers that name a group.
          def groups_said_up(check)
            check.said_at.map { |at| word(at) }.select { |number| check.group_numbers.include?(number) }.uniq
          end
        end
      end
    end
  end
end
