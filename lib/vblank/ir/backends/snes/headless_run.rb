# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        # A Super Nintendo cartridge played in the emulator with nobody watching, driven and read back
        # through the calls a test makes on Backends::Reference — so a test written against the
        # interpreter can be handed this instead and never know. It makes the Moments every checked
        # run compares (RunComparison).
        #
        # HOW A PASS IS READ. The emulator plays a frame at a time: each frame starts with the
        # vertical blank before it, and stops as the next blank begins. The runtime keeps, where this
        # can read it, how many passes of the game loop have ended, whether the game is waiting at
        # the end of one, and which pass the screen shows (Runtime::Frame). A pass's picture is copied
        # to the console in the blank after it, at the start of the next frame, and that frame shows
        # it. So each pass's numbers are read when the game is found waiting at its end, and its
        # picture from the first frame whose blank made it the pass shown. The buttons for each frame
        # are set before the emulator plays it, and the game reads them in its blank.
        class HeadlessRun
          CannotAnswer = RunComparison::CannotAnswer
          Moment = RunComparison::Moment

          # How many frames a pass may take before the game is taken to be stuck.
          LONGEST_PASS_FRAMES = 600

          # The picture at one moment of a run, read the way the interpreter's screen is.
          Picture = Data.define(:shown, :width, :height, :camera_x, :camera_y) do
            def pixel(x, y) = on_screen?(x, y) ? shown[(y * width) + x] : nil
            def stored_pixel(x, y) = pixel(x, y)
            def to_a = shown.dup

            private

            def on_screen?(x, y) = x.between?(0, width - 1) && y.between?(0, height - 1)
          end

          attr_reader :vars, :moments, :rom

          def initialize(save: SaveImage.new)
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

          # The picture the run ended on, or the one at the frame boundary an input script or a
          # watching block is asked at.
          def screen = @screen

          # Plays +program+ for +frames+ frames, or until it halts. Gives back self.
          def run(program, max_steps: nil, frames: nil)
            raise CannotAnswer, "a Super Nintendo cartridge keeps no step budget, so it cannot run with max_steps" if max_steps

            @rom = SNES.new.build(program, title: "CHECKED")
            @places = @rom.built
            @declared_lists = program.walk.select { |node| node.kind == :list_new }.map(&:name).uniq
            @frames_took = {}
            @deciding = false
            @decided = nil
            @moments = []
            @vars = {}
            @lists = {}
            @sprites = []
            play(frames || Reference::DEFAULT_FRAMES)
            self
          end

          def [](name) = @vars.fetch(name, 0)

          def stopped_at_budget? = false

          # How many frames each pass answered for, by the pass's number, as the interpreter is told
          # it (Reference#frames_each_pass): one, for a game that keeps up.
          def frames_took(pass) = @frames_took.fetch(pass, 1)

          # What it drew at the moment the run ended, as the interpreter says it (Reference#sprites).
          def sprites(_name = nil) = @sprites

          # The sound log: a Super Nintendo cartridge plays no sound yet, so it is empty.
          def audio = []
          def audio_played = []
          def whole_audio = []

          # The rest of what the interpreter answers, each refused by name.
          %i[mixed_sound active_samples peak_voices sound_drops sound_owners frame log screen_mode
             buffered].each do |name|
            define_method(name) { |*| refuse_unanswered!(name) }
          end
          def volume_of(*) = refuse_unanswered!(:volume_of)
          def level_of(*) = refuse_unanswered!(:level_of)
          def frames_each_pass(&) = refuse_unanswered!(:frames_each_pass)
          def clock_at(*, **) = refuse_unanswered!(:clock_at)
          def write_save_copy(*) = refuse_unanswered!(:write_save_copy)
          def write_save_vars(*) = refuse_unanswered!(:write_save_vars)

          private

          def refuse_unanswered!(name)
            raise CannotAnswer, "the Super Nintendo lowering cannot answer `#{name}` yet, which this test asks the " \
                                "interpreter. Say `skip_on_snes` in this one test."
          end

          def play(frames)
            Diagnostics::Emulator.with_cartridge(@rom, file_name: "game.sfc") do |core|
              @core = core
              set_buttons(@held)
              play_passes(frames)
            ensure
              @core = nil
            end
          end

          # Pass by pass until +frames+ have ended or the game stops: each pass's numbers when the game
          # is found waiting at its end, its picture once the screen shows it. The interpreter, told
          # to play +frames+ frames, plays one pass more and stops as that one ends, without a frame
          # boundary for it: the end of the run is that pass.
          def play_passes(frames)
            pending = nil # [pass, variables, lists, sprites] whose picture is not on the screen yet
            waited = 0
            loop do
              play_frame
              waited += 1
              refuse_stuck_game! if waited > LONGEST_PASS_FRAMES
              if pending && shown_pass == pending.first
                pass, variables, lists, @sprites = pending
                pending = nil
                return record_moment(:end, variables, lists, picture_now) if pass > frames

                record_moment(pass, variables, lists, picture_now)
              end
              case state
              when Runtime::Frame::HALTED then return finish_after_halt
              when Runtime::Frame::WENT_WRONG then raise_fault
              end
              next unless pending.nil? && waiting? && passes > @moments.size

              pending = [passes, read_variables, read_lists, read_sprites]
              note_frames_took(passes - 1) if passes > 1
              mark_last_pass_taken if passes == frames
              hold_after_this_pass if passes > frames
              waited = 0
              @deciding = passes <= frames
            end
          end

          # THE BUTTONS ARE DECIDED A SCREEN FRAME AT A TIME, numbered as the runtime counts the frames
          # it draws, since the runtime reads them in the screen's interrupt on every one — so a pass
          # that spans several frames reads each of them, as the interpreter's does. They are decided
          # from the first pass's end: until then they are the ones held from power-on.
          def decide_buttons
            return unless @deciding

            frame = word(runtime_place(Runtime::Frame::FRAMES)) + 1
            return if frame == @decided

            @decided = frame
            set_buttons(@input_script ? Array(@input_script.call(frame)) : @held)
          end

          # The buttons a game names, on the controller's: the same names, A, B, the shoulders L and R.
          def set_buttons(buttons) = @core.set_buttons(buttons.map(&:to_sym) - [Buttons::ANY])

          # How many frames pass +pass+ took, as the runtime counted them where its wait ended.
          def note_frames_took(pass)
            kept = Runtime::Frame::STEPS_KEPT
            @frames_took[pass] = @core.wram_read8(runtime_place(Runtime::Frame::STEPS) + (pass % kept))
          end

          # The moment of +frame+ — a pass's number, or :end for the moment the run ended on.
          def record_moment(frame, variables, lists, picture)
            @vars = variables
            @lists = lists
            @screen = picture
            @moments << Moment.new(frame: frame, variables: variables, picture: RunComparison.picture_check(picture.shown),
                                   sounds: 0, sprites: @sprites, collections: game_state.except(:vars), sounding: [])
            @on_vblank&.call(frame) unless frame == :end
          end

          # The game halted: its picture shown once more; the moment is the end of the run.
          def finish_after_halt
            (1..passes).last(Runtime::Frame::STEPS_KEPT).each { |pass| note_frames_took(pass) unless @frames_took.key?(pass) }
            frames = 0
            until shown_pass == Runtime::Frame::END_SHOWN || frames > 3
              play_frame
              frames += 1
            end
            play_frame
            @sprites = read_sprites
            record_moment(:end, read_variables, read_lists, picture_now)
          end

          def play_frame
            decide_buttons
            @core.run_frame
          end

          # The emulator's picture, each pixel the 15-bit colour the console holds.
          def picture_now = Picture.new(shown: @core.colors, width: @core.width, height: @core.height, camera_x: 0, camera_y: 0)

          def read_variables = @places.variables.transform_values { |address| word(address) }

          # The sprites the game placed in its last pass: none yet, since the Super Nintendo build
          # makes no sprites.
          def read_sprites = []

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
            raw = (0...width).sum { |i| @core.wram_read8(wram_offset(address) + i) << (8 * i) }
            top = 1 << ((8 * width) - 1)
            raw >= top ? raw - (top << 1) : raw
          end

          # Where +address+ is in work RAM: an address in the first 8K is its own offset, and one in
          # banks $7E and $7F is counted from $7E:0000.
          def wram_offset(address) = address >= 0x7E0000 ? address - 0x7E0000 : address

          def word(address) = IR::Int32.wrap(@core.wram_read32(wram_offset(address)))
          def half(address) = @core.wram_read16(wram_offset(address))

          def runtime_place(name) = @places.runtime.fetch(name)

          # The last pass the run reads: the game is told to show it and go no further.
          def hold_after_this_pass = @core.wram_write32(runtime_place(Runtime::Frame::HOLD), 1)
          # The interpreter stops a run at the boundary after the last pass compared, before it
          # moves its timers on (Runtime::Frame::LAST_PASS_TAKEN).
          def mark_last_pass_taken = @core.wram_write32(runtime_place(Runtime::Frame::LAST_PASS_TAKEN), 1)
          def state = half(runtime_place(Runtime::Frame::STATE))
          def waiting? = half(runtime_place(Runtime::Frame::WAITING)) == 1
          def passes = word(runtime_place(Runtime::Frame::PASSES))
          def shown_pass = @core.wram_read32(runtime_place(Runtime::Frame::SHOWN))

          # --- what ReadingBack reads #list, #pool and #game_state from ---

          def list_items(name) = @lists.fetch(name) { @declared_lists.include?(name) ? [] : nil }&.dup
          def list_names = @declared_lists | @lists.keys
          def variables_now = @vars

          def refuse_stuck_game!
            raise CannotAnswer, "the Super Nintendo cartridge had not reached the end of a pass in " \
                                "#{LONGEST_PASS_FRAMES} frames, and was stopped"
          end

          # The game went wrong: the interpreter's words for what went wrong, from what the runtime
          # kept of it.
          def raise_fault
            at = runtime_place(Runtime::Frame::FAULT)
            code = half(at)
            place = @core.wram_read32(at + Runtime::Frame::FAULT_LIST) & 0xFFFFFF
            list = @places.lists.find { |_, (address, *)| address == place }&.first
            first = word(at + Runtime::Frame::FAULT_FIRST)
            second = word(at + Runtime::Frame::FAULT_SECOND)
            raise ProgramError, fault_message(code, list, first, second)
          end

          def fault_message(code, list, first, second)
            case code
            when Runtime::Frame::INDEX_OUT_OF_RANGE then Faults.index_out_of_range(list, first, second)
            when Runtime::Frame::LIST_FULL then Faults.list_full(list, first)
            when Runtime::Frame::LIST_EMPTY then Faults.list_empty(list, first.zero? ? :back : :front)
            else "the game went wrong (#{code})"
            end
          end
        end
      end
    end
  end
end
