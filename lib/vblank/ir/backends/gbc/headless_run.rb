# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBC
        # A Game Boy Color cartridge played in the emulator with nobody watching, driven and read back
        # through the calls a test makes on Backends::Reference (CartridgeHeadlessRun says how a pass
        # is read). What is the Color's own: its memory read over the bus, the sound log read off
        # the processor as it plays (GBC::SoundLog), the clock chip, the rumble motor, the frames
        # its screen was off for before the first, and the faults of picture groups not up.
        class HeadlessRun < CartridgeHeadlessRun
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

          # How many frames the screen was off for before the first, as the runtime counted them
          # (Runtime::Frame::DARK_FRAMES), as the interpreter is told it (Reference#frames_setting_up):
          # none, for a game that does not count them.
          def dark_frames_counted = @dark_frames || 0

          # Whether the cartridge's motor runs on the frame the run's picture is (Reference#motor_on?).
          def motor_on? = @motor

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

          # The rest of what the interpreter answers, each refused by name.
          refuses :mixed_sound, :active_samples

          private

          def kit = Console.for(:gbc)

          def start_run(_program)
            @sound_log = SoundLog.new(@places)
            @sounds = 0
            @audio = []
            @audio_handed = 0
            @dark_frames = nil
            @motor = false
          end

          def power_on
            start_clock if @rom.clock?
            set_buttons(@held)
            @core.record_arrivals(@sound_log.addresses) if @sound_log.any?
          end

          def set_buttons(buttons) = @core.set_keys(IR::Buttons.mask(buttons))

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

          # Read once the first pass has ended, by when the screen is on and the count is done.
          def first_pass_ended
            dark = @places.runtime[Runtime::Frame::DARK_FRAMES]
            @dark_frames = dark ? half(dark) : 0
          end

          # How many entries the sound log held as the game was found waiting.
          def read_sounds = @sound_log.entries.size

          # The moment of +frame+ — a pass's number, or :end for the moment the run ended on, which
          # is no frame boundary and so is not shown to a block watching each one. A pass's sounds
          # are the log's entries as far as the frame boundary after it (#sounds_after_pass); the end
          # of the run has no boundary after it, so its moment counts the log as the game was found
          # waiting.
          def record_moment(frame, variables, lists, picture, sounds)
            sounds = sounds_after_pass(frame) unless frame == :end
            @vars = variables
            @lists = lists
            @screen = picture
            @sounds = sounds
            @motor = @core.motor_on? # as the frame the picture is was shown
            @moments << Moment.new(frame: frame, variables: variables, picture: RunComparison.picture_check(picture.shown),
                                   sounds: sounds, sprites: @sprites, collections: game_state.except(:vars),
                                   sounding: [], motor: @motor)
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
            record_moment(:end, read_variables, read_lists, picture_now(nil), sounds)
          end

          # How many entries of the sound log are pass +pass+'s, the frame boundary after it included
          # (GBC::SoundLog).
          def sounds_after_pass(pass) = @sound_log.any? ? @sound_log.size_after_pass(pass) : 0

          # One frame of the emulator, with its buttons decided, and what the cartridge played in it
          # into the sound log.
          def play_frame
            decide_buttons
            @core.run_frame
            @sound_log.read(@core.take_arrivals) if @sound_log.any?
          end

          # The emulator's picture, each pixel turned back into the 15-bit colour the console holds.
          # The view over a painted picture is read as the picture is, from the scroll the pass
          # shown asked for.
          def picture_now(_camera)
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
            return [0, 0] unless byte(runtime_place(Runtime::Paint::SCREEN_KIND)) == Runtime::Paint::PAINTED

            at = runtime_place(Runtime::Picture::SCROLL)
            [0, 1].map do |i|
              value = byte(at + i)
              value >= 0x80 ? value - 0x100 : value
            end
          end

          # The sprites the game placed in its last pass, back to front (GBC::Places#drawn_sprite_rows).
          def read_sprites = @places.drawn_sprite_rows(@drawn_sprites, @core.method(:bus_read8))

          # The Color's memory, read and written over its bus.
          def byte(address) = @core.bus_read8(address)
          def read32(address) = @core.bus_read32(address)
          def write32(address, value) = @core.bus_write32(address, value)

          def state = byte(runtime_place(Runtime::Frame::STATE))
          def waiting? = byte(runtime_place(Runtime::Frame::WAITING)) == 1

          # Fault: what went wrong (a byte), the list's place (two bytes), and two numbers that say
          # how (four bytes each).
          def read_fault
            at = runtime_place(Runtime::Frame::FAULT)
            [byte(at), half(at + 1), word(at + 3), word(at + 7)]
          end

          def console_fault_message(code, first, second)
            case code
            when CartridgeFaults::PICTURE_NOT_UP then picture_not_up_message(@places.picture_checks.fetch(first), second)
            when CartridgeFaults::GROUPS_NOT_TOGETHER then groups_not_together_message(@places.together_checks.fetch(first))
            else super
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
