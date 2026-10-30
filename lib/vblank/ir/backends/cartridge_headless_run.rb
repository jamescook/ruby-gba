# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      # A CONSOLE'S OWN CARTRIDGE PLAYED IN THE EMULATOR WITH NOBODY WATCHING, driven and read back
      # through the calls a test makes on Backends::Reference — so a test written against the
      # interpreter can be handed this instead and never know. It makes the Moments every checked run
      # compares (RunComparison). The Game Boy Color's and the Super Nintendo's (GBC::HeadlessRun,
      # SNES::HeadlessRun) are this, each with what its console keeps its own way.
      #
      # HOW A PASS IS READ. The emulator plays a frame at a time. Each console's runtime keeps, where
      # this can read it, how many passes of the game loop have ended, whether the game is waiting
      # at the end of one, and which pass the screen shows (each runtime's Frame, by the same names).
      # A pass's picture is copied to the console in the blank after it, so it is on the screen a
      # frame after the pass's numbers are final. So each pass's numbers are read when the game is
      # found waiting at its end, and its picture from the first frame that shows it, and the two
      # make the pass's moment. The buttons for each frame are set before the emulator plays it, and
      # the game reads them in its blank.
      #
      # What a console's run says for itself:
      #
      #   kit                     the console's kit (Console::CheckedKit): its lowering builds the
      #                           cartridge, its title is in every refusal
      #   byte, read32, write32   the console's memory as this reads it, by the address the build
      #                           gave a place (half too, where the emulator reads two bytes faster)
      #   state, waiting?         how the runtime stands, read as wide as it keeps them
      #   set_buttons(buttons)    the buttons a game names, on the console's controller
      #   power_on                what is done before the first frame, past the buttons held
      #   read_fault              what the runtime kept of a fault: [code, list's place, first, second]
      #   picture_now(camera)     the emulator's picture, as a Picture
      #   record_moment, finish_after_halt
      #                           the moment of a pass, and the end of a game that halted
      #
      # and whatever else the interpreter answers that its console can (the sound, the clock).
      class CartridgeHeadlessRun
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

        # Defines a method for each of +names+ that refuses by name: a question the interpreter
        # answers and this console's run cannot yet. Each is written out as a plain method, not
        # made from a block, so a test in a Ractor can call it.
        def self.refuses(*names)
          names.each do |name|
            class_eval("def #{name}(*, **, &) = refuse_unanswered!(:#{name})", __FILE__, __LINE__)
          end
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
          @sprites = []
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
          raise RunComparison::AsksTheInterpreter, "a step budget (`max_steps:`)" if max_steps

          @rom = kit.lowering.new.build(program, title: "CHECKED")
          @places = @rom.built
          @drawn_sprites = SpriteNames.new(program)
          @declared_lists = program.walk.select { |node| node.kind == :list_new }.map(&:name).uniq
          @frames_took = {}
          @deciding = false
          @decided = nil
          @moments = []
          @vars = {}
          @lists = {}
          @sprites = []
          start_run(program)
          play(frames || Reference::DEFAULT_FRAMES)
          self
        end

        def [](name) = @vars.fetch(name, 0)

        def stopped_at_budget? = false

        # How many frames each pass answered for, by the pass's number, as the interpreter is told
        # it (Reference#frames_each_pass): one, for a game that keeps up.
        def frames_took(pass) = @frames_took.fetch(pass, 1)

        # What it drew at the moment the run ended, as the interpreter says it (Reference#sprites):
        # every sprite, back to front, or the ones the game declared as +name+.
        def sprites(name = nil) = name ? @drawn_sprites.rows_named(@sprites, name) : @sprites

        # The rest of what the interpreter answers that no console's run can, each refused by name.
        refuses :peak_voices, :sound_drops, :sound_owners, :frame, :log, :screen_mode, :buffered, :volume_of,
                :level_of, :write_save_copy, :write_save_vars

        # Two the interpreter is told rather than asked, and no console's run will ever take.
        def frames_each_pass(&) = raise(RunComparison::AsksTheInterpreter, "for a pass to take several frames (`frames_each_pass`)")
        def frames_setting_up(*) = raise(RunComparison::AsksTheInterpreter, "how many frames setting up takes (`frames_setting_up`)")

        private

        def refuse_unanswered!(name)
          raise CannotAnswer, "the #{kit.title} lowering cannot answer `#{name}` yet, which this test asks the " \
                              "interpreter. Say `skip_on_#{kit.name}` in this one test."
        end

        # What a console's run sets up for itself as a run starts, past what every one does.
        def start_run(_program) = nil

        # Where each of the runtime's names is kept.
        def runtime = kit.lowering::Runtime

        # THE SAVE MEMORY goes in as the file the emulator keeps a cartridge's battery-backed memory
        # in, and what the run left there comes back into the same image when the console is off
        # again — so one image handed to two runs is a power cycle, as it is for the interpreter.
        def play(frames)
          saves = SaveLayout.named_by?(@rom.built.source_program)
          refuse_power_cut! if saves
          Diagnostics::Emulator.with_cartridge(@rom, file_name: "game#{kit.description.extension}",
                                                     save: (@save if saves)) do |core|
            @core = core
            power_on
            play_passes(frames)
          ensure
            @core = nil
          end
        end

        def refuse_power_cut!
          return unless @save.power_left

          raise RunComparison::AsksTheInterpreter, "for the power to be cut after #{@save.power_left} steps"
        end

        # Pass by pass until +frames+ have ended or the game stops: each pass's numbers when the game
        # is found waiting at its end, its picture once the screen shows it. The interpreter, told
        # to play +frames+ frames, plays one pass more and stops as that one ends, without a frame
        # boundary for it: the end of the run is that pass.
        def play_passes(frames)
          pending = nil # [pass, variables, lists, sprites, sounds, camera] whose picture is not on the screen yet
          waited = 0
          loop do
            play_frame
            waited += 1
            refuse_stuck_game! if waited > LONGEST_PASS_FRAMES
            if pending && shown_pass == pending.first && moment_ready?(pending.first, frames)
              pass, variables, lists, @sprites, sounds, camera = pending
              pending = nil
              return record_moment(:end, variables, lists, picture_now(camera), sounds) if pass > frames

              record_moment(pass, variables, lists, picture_now(camera), sounds)
            end
            case state
            when runtime::Frame::HALTED then return finish_after_halt
            when runtime::Frame::WENT_WRONG then raise_cartridge_fault!
            end
            next unless pending.nil? && waiting? && passes > @moments.size

            pending = [passes, read_variables, read_lists, read_sprites, read_sounds, read_camera]
            return end_before_first_picture(*pending.drop(1)) if ends_before_first_picture?(frames)

            note_frames_took(passes - 1) if passes > 1
            mark_last_pass_taken if passes == frames
            hold_after_this_pass if passes > frames
            waited = 0
            @deciding = passes <= frames
            first_pass_ended if passes == 1
          end
        end

        # Whether the moment of +pass+, shown now, can be read yet: a console whose runtime counts
        # a pass's sounds after its wait waits for the count.
        def moment_ready?(_pass, _frames) = true

        # Whether a run of +frames+ ends as the first pass does, before anything is shown.
        def ends_before_first_picture?(_frames) = false

        # What is read once the first pass has ended.
        def first_pass_ended = nil

        # How many entries the sound log held as the game was found waiting, and where the camera
        # put the view: none and nowhere, for a console's run that reads neither then.
        def read_sounds = 0
        def read_camera = nil

        # THE BUTTONS ARE DECIDED A SCREEN FRAME AT A TIME, numbered as the runtime counts the
        # frames it draws, since the runtime reads them in the screen's interrupt on every one —
        # so a pass that spans several frames reads each of them, as the interpreter's does. They
        # are decided from the first pass's end: until then they are the ones held from power-on.
        def decide_buttons
          return unless @deciding

          frame = word(runtime_place(runtime::Frame::FRAMES)) + 1
          return if frame == @decided

          @decided = frame
          set_buttons(@input_script ? Array(@input_script.call(frame)) : @held)
        end

        # How many frames pass +pass+ took, as the runtime counted them where its wait ended
        # (Frame::STEPS) — read once the game waits at the end of the pass after it. The real
        # number, and not the one the game reads, which is held at IR::Frames::MOST: the music
        # and the buttons take every frame.
        def note_frames_took(pass)
          @frames_took[pass] = byte(runtime_place(runtime::Frame::STEPS) + (pass % runtime::Frame::STEPS_KEPT))
        end

        def read_variables = @places.variables.transform_values { |address| word(address) }

        # Every list as the runtime keeps it: a header (each runtime's Lists says where in it the
        # capacity, the front and the length are) and then its slots, a ring from the front.
        def read_lists
          layout = runtime::Lists
          @places.lists.to_h do |name, (address, _capacity, width, _label)|
            capacity = half(address + layout::CAPACITY)
            front = half(address + layout::FRONT)
            length = half(address + layout::LENGTH)
            items = Array.new(length) do |i|
              slot = (front + i) % capacity
              read_slot(address + layout::HEADER + (slot * width), width)
            end
            [name, items]
          end
        end

        # A slot of +width+ bytes, read back sign-extended as the interpreter's is.
        def read_slot(address, width)
          raw = little(address, width)
          top = 1 << ((8 * width) - 1)
          raw >= top ? raw - (top << 1) : raw
        end

        # The +width+ bytes at +address+ as one number, lowest byte first, as both consoles keep them.
        def little(address, width) = (0...width).sum { |i| byte(address + i) << (8 * i) }

        def word(address) = IR::Int32.wrap(read32(address))
        def half(address) = little(address, 2)

        def runtime_place(name) = @places.runtime.fetch(name)

        # The last pass the run reads: the game is told to show it and go no further.
        def hold_after_this_pass = write32(runtime_place(runtime::Frame::HOLD), 1)
        # The interpreter stops a run at the boundary after the last pass compared, before it
        # moves its timers on (Frame::LAST_PASS_TAKEN).
        def mark_last_pass_taken = write32(runtime_place(runtime::Frame::LAST_PASS_TAKEN), 1)
        def passes = word(runtime_place(runtime::Frame::PASSES))
        def shown_pass = read32(runtime_place(runtime::Frame::SHOWN))

        # --- what ReadingBack reads #list, #pool and #game_state from ---

        def list_items(name) = @lists.fetch(name) { @declared_lists.include?(name) ? [] : nil }&.dup
        def list_names = @declared_lists | @lists.keys
        def variables_now = @vars

        def refuse_stuck_game!
          raise CannotAnswer, "the #{kit.title} cartridge had not reached the end of a pass in " \
                              "#{LONGEST_PASS_FRAMES} frames, and was stopped"
        end

        # The game went wrong: the interpreter's words for what went wrong, from what the runtime
        # kept of it.
        def raise_cartridge_fault!
          code, place, first, second = read_fault
          list = @places.lists.find { |_, (address, *)| address == place }&.first
          raise ProgramError, fault_message(code, list, first, second)
        end

        # The sentence for the fault the runtime kept as +code+ (CartridgeFaults), with the two
        # numbers it kept beside it and the list it named, if any.
        def fault_message(code, list, first, second)
          case code
          when CartridgeFaults::INDEX_OUT_OF_RANGE then Faults.index_out_of_range(list, first, second)
          when CartridgeFaults::LIST_FULL then Faults.list_full(list, first)
          when CartridgeFaults::LIST_EMPTY then Faults.list_empty(list, first.zero? ? :back : :front)
          when CartridgeFaults::COPY_TOO_LONG then Faults.copy_too_long(list, first, second)
          when CartridgeFaults::COPY_PAST_TABLE then Faults.copy_past_table(first, second)
          when CartridgeFaults::PICTURE_NOT_THERE then Faults.picture_missing(first, second)
          when CartridgeFaults::SAVE_READ_OUTSIDE then Faults.save_outside("read", first, second)
          when CartridgeFaults::SAVE_WRITE_OUTSIDE then Faults.save_outside("wrote to", first, second)
          else console_fault_message(code, first, second)
          end
        end

        # The sentence for a fault only this console's runtime keeps, from what it kept.
        def console_fault_message(code, _first, _second) = "the game went wrong (#{code})"
      end
    end
  end
end
