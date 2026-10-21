# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBC
        # A Game Boy Color cartridge played in the emulator with nobody watching, driven and read back
        # through the calls a test makes on Backends::Reference — so a test written against the
        # interpreter can be handed this instead and never know. Native::HeadlessRun does the same
        # for the game as C; this is its twin for a cartridge, and makes the same Moments, which is
        # what lets the checked run compare the two with the interpreter's words.
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
          CannotAnswer = Native::HeadlessRun::CannotAnswer
          Moment = Native::HeadlessRun::Moment

          # How many frames a pass may take before the game is taken to be stuck.
          LONGEST_PASS_FRAMES = 600

          # The picture at one moment of a run, read the way the interpreter's screen is: #pixel gives
          # the colour at (x, y), nil off the screen, #shown every pixel row by row. The Color has no
          # window over a larger picture, so what is stored is what is shown.
          Picture = Data.define(:shown, :width, :height) do
            def pixel(x, y) = on_screen?(x, y) ? shown[(y * width) + x] : nil
            def stored_pixel(x, y) = pixel(x, y)
            def to_a = shown.dup
            def camera_x = 0
            def camera_y = 0

            private

            def on_screen?(x, y) = x.between?(0, width - 1) && y.between?(0, height - 1)
          end

          attr_reader :vars, :moments, :rom, :save

          def initialize(save: SaveImage.new)
            unless save.is_a?(SaveImage)
              raise ArgumentError, "save: must be a RubyGBA::IR::SaveImage. To make an empty save memory, " \
                                   "write RubyGBA::IR::SaveImage.new."
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

          # The picture the run ended on, or the one at the frame boundary an input script or a
          # watching block is asked at.
          def screen = @screen

          # Plays +program+ for +frames+ frames — as many as the interpreter plays when it is not told
          # — or until it halts. Gives back self.
          def run(program, max_steps: nil, frames: nil)
            raise CannotAnswer, "a Game Boy Color cartridge keeps no step budget, so it cannot run with max_steps" if max_steps

            @rom = GBC.new.build(program, title: "CHECKED")
            @places = @rom.built
            @drawn_sprites = Native::DrawnSprites.new(program)
            @declared_lists = program.walk.select { |node| node.kind == :list_new }.map(&:name).uniq
            @moments = []
            @vars = {}
            @lists = {}
            play(frames || Reference::DEFAULT_FRAMES)
            self
          end

          def [](name) = @vars.fetch(name, 0)

          def stopped_at_budget? = false

          # The rest of what the interpreter answers, each refused by name.
          # What it drew at the moment the run ended, as the interpreter says it (Reference#sprites):
          # every sprite, back to front, or the ones the game declared as +name+.
          def sprites(name = nil)
            rows = @sprites || []
            name ? @drawn_sprites.rows_named(rows, name) : rows
          end

          %i[audio mixed_sound active_samples peak_voices sound_drops sound_owners frame log screen_mode
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
            saves = Native::Saving.named_by?(@rom.built.source_program)
            refuse_power_cut! if saves
            Diagnostics::Emulator.with_cartridge(@rom, file_name: "game.gbc", save: (@save if saves)) do |core|
              @core = core
              @core.set_keys(Native::HeadlessRun.button_mask(@held))
              play_passes(frames)
            ensure
              @core = nil
            end
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
            pending = nil # [pass, variables, lists] whose picture is not on the screen yet
            waited = 0
            loop do
              @core.run_frame
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
              mark_last_pass_taken if passes == frames
              hold_after_this_pass if passes > frames
              waited = 0
              decide_buttons(passes) if passes <= frames
            end
          end

          # The buttons for the pass after +pass+, decided now — before the emulator plays the blank
          # the game reads them in.
          def decide_buttons(pass)
            buttons = @input_script ? @input_script.call(pass) : @held
            @core.set_keys(Native::HeadlessRun.button_mask(buttons))
          end

          # The moment of +frame+ — a pass's number, or :end for the moment the run ended on, which
          # is no frame boundary and so is not shown to a block watching each one.
          def record_moment(frame, variables, lists, picture)
            @vars = variables
            @lists = lists
            @screen = picture
            @moments << Moment.new(frame: frame, variables: variables, picture: picture_check(picture), sounds: 0,
                                   sprites: @sprites, collections: game_state.except(:vars), sounding: [])
            @on_vblank&.call(frame) unless frame == :end
          end

          # The game halted: its picture copied to the console once more, then shown; the moment is
          # the end of the run.
          def finish_after_halt
            frames = 0
            until shown_pass == Runtime::Frame::END_SHOWN || frames > 3
              @core.run_frame
              frames += 1
            end
            @core.run_frame
            @sprites = read_sprites
            record_moment(:end, read_variables, read_lists, picture_now)
          end

          def picture_check(picture) = Native::HeadlessRun.picture_check(picture.shown)

          # The emulator's picture, each pixel turned back into the 15-bit colour the console holds.
          def picture_now
            buffer = @core.video_buffer
            width = @core.width
            height = @core.height
            shown = Array.new(width * height) do |i|
              at = i * 4
              (buffer.getbyte(at) >> 3) | ((buffer.getbyte(at + 1) >> 3) << 5) | ((buffer.getbyte(at + 2) >> 3) << 10)
            end
            Picture.new(shown: shown, width: width, height: height)
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
            else "the game went wrong (#{code})"
            end
          end
        end
      end
    end
  end
end
