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
            @drawn_sprites = SpriteNames.new(program)
            @declared_lists = program.walk.select { |node| node.kind == :list_new }.map(&:name).uniq
            @frames_took = {}
            @deciding = false
            @decided = nil
            @moments = []
            @vars = {}
            @lists = {}
            @sprites = []
            @sound_entries = []
            @sounds = 0
            @audio = []
            @audio_handed = 0
            @dsp_reads = []
            @apu_ram = nil
            @active_samples = nil
            play(frames || Reference::DEFAULT_FRAMES)
            self
          end

          def [](name) = @vars.fetch(name, 0)

          def stopped_at_budget? = false

          # How many frames each pass answered for, by the pass's number, as the interpreter is told
          # it (Reference#frames_each_pass): one, for a game that keeps up.
          def frames_took(pass) = @frames_took.fetch(pass, 1)

          # What it drew at the moment the run ended, as the interpreter says it (Reference#sprites).
          def sprites(name = nil) = name ? @drawn_sprites.rows_named(@sprites, name) : @sprites

          # The sound log up to the moment the run ended, or the one at the frame boundary a watching
          # block is asked at, in the interpreter's words (the build's sound_entries, by the number the
          # cartridge's own log keeps: Runtime::Sound). It is the test's to clear as it watches, as
          # the interpreter's is: what comes after is added to what the test left.
          def audio
            @audio.concat(@sound_entries[@audio_handed...@sounds]) if @sounds > @audio_handed
            @audio_handed = [@audio_handed, @sounds].max
            @audio
          end

          # The sound log up to the moment the run ended, every entry, whatever a test did to #audio.
          def audio_played = @sound_entries.take(@sounds)

          # Every entry the cartridge logged, past where the run ended too.
          def whole_audio = @sound_entries.dup

          # The S-DSP's 128 registers as the emulator held them each time the game was found waiting
          # at a pass's end, each with how many entries the sound log held then: [entries, registers],
          # oldest first — what the sound unit was really told, for a checked run to hold to the
          # interpreter's sound log as far as those entries (DSPWrites.after). Empty for a game that
          # makes no sound.
          attr_reader :dsp_reads

          # The registers as the run ended.
          def dsp_registers = @dsp_reads.last&.last

          # The recordings sounding as the run ended, in the order of their places, as the
          # interpreter says them (Reference#active_samples): the cartridge's own count
          # (Runtime::Recordings), heard or not.
          def active_samples = @active_samples || []

          # The sound unit's 64K of memory as the run ended — its program, the sample table and the
          # recordings — for a test to read a recording the DSP plays. Nil for a game with no sound.
          attr_reader :apu_ram

          # The rest of what the interpreter answers, each refused by name.
          %i[peak_voices sound_drops sound_owners frame log screen_mode buffered].each do |name|
            define_method(name) { |*| refuse_unanswered!(name) }
          end

          # The Advance's mix, a stream of sound its processor makes from every recording: a Super
          # Nintendo plays each recording on a voice of its sound chip, and makes no such stream.
          def mixed_sound
            raise CannotAnswer, "a Super Nintendo plays each recording on a voice of its own sound chip, so it has no " \
                                "mixed sound to read. Say `skip_on_snes` in this one test."
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

          # THE SAVE MEMORY goes in as the .srm file bsnes keeps a cartridge's battery-backed RAM in,
          # and what the run left there comes back into the same image when the console is off
          # again — so one image handed to two runs is a power cycle, as it is for the interpreter.
          def play(frames)
            saves = SaveLayout.named_by?(@rom.built.source_program)
            refuse_power_cut! if saves
            Diagnostics::Emulator.with_cartridge(@rom, file_name: "game.sfc", save: (@save if saves)) do |core|
              @core = core
              set_buttons(@held)
              play_passes(frames)
            ensure
              @core = nil
            end
          end

          def refuse_power_cut!
            return unless @save.power_left

            raise CannotAnswer, "a Super Nintendo cartridge keeps no count of its steps, so it cannot have its power " \
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
              if pending && shown_pass == pending.first && (pending.first > frames || sounds_counted?(pending.first))
                pass, variables, lists, @sprites, sounds = pending
                pending = nil
                return record_moment(:end, variables, lists, picture_now, sounds) if pass > frames

                record_moment(pass, variables, lists, picture_now, sounds)
              end
              case state
              when Runtime::Frame::HALTED then return finish_after_halt
              when Runtime::Frame::WENT_WRONG then raise_cartridge_fault!
              end
              next unless pending.nil? && waiting? && passes > @moments.size

              pending = [passes, read_variables, read_lists, read_sprites, read_sounds]
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

          # The moment of +frame+ — a pass's number, or :end for the moment the run ended on. +sounds+
          # is how many entries the sound log held as the game was found waiting (#read_sounds).
          #
          # A PASS'S SOUNDS INCLUDE ITS FRAME BOUNDARY'S MUSIC, which the interpreter plays after the
          # pass, before anything reads the frame (Reference#advance_frame). The cartridge plays it
          # where the wait ends (Runtime::Music), after the game was found waiting, so a pass's moment
          # takes the count the cartridge kept as that wait ended (Runtime::Sound::LOGGED_BY_PASS),
          # which #play_passes waits for (#sounds_counted?). The moment the run ended on has no
          # boundary after it.
          def record_moment(frame, variables, lists, picture, sounds)
            @vars = variables
            @lists = lists
            @screen = picture
            @sounds = frame == :end || !sound? ? sounds : logged_by_pass(frame)
            read_sound_entries(@sounds) if sound?
            @apu_ram = @core.apu_ram if frame == :end && sound?
            @active_samples = recordings_at(frame)
            @moments << Moment.new(frame: frame, variables: variables, picture: RunComparison.picture_check(picture.shown),
                                   sounds: @sounds, sprites: @sprites, collections: game_state.except(:vars), sounding: @active_samples)
            @on_vblank&.call(frame) unless frame == :end
          end

          # How many entries the cartridge's sound log holds now, those read into the log in the
          # interpreter's words, and the S-DSP's registers kept beside the count (#dsp_reads); 0 for
          # a game that makes no sound.
          def read_sounds
            return 0 unless sound?

            logged = half(runtime_place(Runtime::Sound::LOGGED))
            read_sound_entries(logged)
            @dsp_reads << [logged, @core.dsp_registers]
            logged
          end

          def sound? = @places.runtime.key?(Runtime::Sound::LOGGED)

          # The recordings the cartridge's places held at the moment of +frame+, by name, in the order
          # of their places: as the pass's wait ended (Runtime::Recordings::KEPT_BY_PASS), the
          # interpreter's mix at that frame boundary, or as they are now for the moment the run ended.
          # None for a game that plays none.
          def recordings_at(frame)
            recordings = Runtime::Recordings
            return [] unless @places.runtime.key?(recordings::PLACES_STATE)

            held = if frame == :end
                     state = runtime_place(recordings::PLACES_STATE)
                     Array.new(recordings::PLACES) { |place| half(state + (place * recordings::PLACE_BYTES)) }
                   else
                     kept = wram_offset(runtime_place(recordings::KEPT_BY_PASS)) +
                            ((frame % Runtime::Frame::STEPS_KEPT) * recordings::PLACES)
                     Array.new(recordings::PLACES) { |place| @core.wram_read8(kept + place) }
                   end
            held.reject(&:zero?).map { |number| @places.recording_names.fetch(number - 1) }
          end

          # How many entries the sound log held as pass +pass+'s wait ended.
          def logged_by_pass(pass) = half(logged_slot(pass) + 2)

          # Whether the cartridge has kept that count for +pass+ yet: its slot carries the pass's
          # number. True for a game that makes no sound.
          def sounds_counted?(pass) = !sound? || half(logged_slot(pass)) == (pass & 0xFFFF)

          def logged_slot(pass)
            runtime_place(Runtime::Sound::LOGGED_BY_PASS) +
              ((pass % Runtime::Frame::STEPS_KEPT) * Runtime::Sound::LOGGED_SLOT_BYTES)
          end

          # The cartridge's sound log read into the interpreter's words as far as +logged+ entries.
          def read_sound_entries(logged)
            if logged - @sound_entries.size > Runtime::Sound::LOG_LENGTH
              raise CannotAnswer, "the Super Nintendo cartridge logged more than #{Runtime::Sound::LOG_LENGTH} sounds in " \
                                  "one pass, more than its sound log holds"
            end

            ring = wram_offset(runtime_place(Runtime::Sound::LOG))
            (@sound_entries.size...logged).each do |count|
              @sound_entries << @places.sound_entries.fetch(@core.wram_read8(ring + (count % Runtime::Sound::LOG_LENGTH)))
            end
          end

          # The game halted: its picture shown once more (copied over several blanks on a Super FX
          # cartridge, ChipPaint); the moment is the end of the run.
          def finish_after_halt
            (1..passes).last(Runtime::Frame::STEPS_KEPT).each { |pass| note_frames_took(pass) unless @frames_took.key?(pass) }
            frames = 0
            until shown_pass == Runtime::Frame::END_SHOWN || frames > LONGEST_PASS_FRAMES
              play_frame
              frames += 1
            end
            play_frame
            @sprites = read_sprites
            record_moment(:end, read_variables, read_lists, picture_now, read_sounds)
          end

          def play_frame
            decide_buttons
            @core.run_frame
          end

          # The emulator's picture, each pixel the 15-bit colour the console holds.
          def picture_now = Picture.new(shown: @core.colors, width: @core.width, height: @core.height, camera_x: 0, camera_y: 0)

          def read_variables = @places.variables.transform_values { |address| word(address) }

          # The sprites the game placed in its last pass, back to front, as the interpreter says them
          # (Reference#sprites): the runtime keeps a row for each (Runtime::Picture::DRAWN) — whose,
          # which picture, where — and SpriteNames turns the numbers back into names.
          def read_sprites
            at = wram_offset(runtime_place(Runtime::Picture::DRAWN))
            signed = ->(value) { value >= 0x8000 ? value - 0x10000 : value }
            Array.new(@core.wram_read16(at)) do |i|
              whose, picture, x, y = @core.wram_bytes(at + 2 + (i * Runtime::Picture::DRAWN_BYTES), 8).unpack("v4")
              @drawn_sprites.row(signed.call(whose), picture, signed.call(x), signed.call(y))
            end
          end

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
          def raise_cartridge_fault!
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
            when Runtime::Frame::PICTURE_NOT_THERE then Faults.picture_missing(first, second)
            when Runtime::Frame::SAVE_READ_OUTSIDE then Faults.save_outside("read", first, second)
            when Runtime::Frame::SAVE_WRITE_OUTSIDE then Faults.save_outside("wrote to", first, second)
            when Runtime::Frame::CELLS_FULL
              raise CannotAnswer, "the Super Nintendo cartridge stopped: the game changed more than " \
                                  "#{Runtime::Picture::MOST_CELLS} cells of its backgrounds in one pass, more than its " \
                                  "queue for the blank holds"
            else "the game went wrong (#{code})"
            end
          end
        end
      end
    end
  end
end
