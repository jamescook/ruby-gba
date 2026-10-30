# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        # A Super Nintendo cartridge played in the emulator (HeadlessRun), and then the same buttons,
        # pass for pass, played on the interpreter — stopping at the first pass the two disagree on,
        # about any variable, any list or pool, or any pixel. Every checked run makes the same
        # comparison and says it in the same words (RunComparison).
        #
        # It takes the interpreter's calls, so a test written against Reference.new can be handed one
        # of these instead and play its game on a Super Nintendo with nothing else changed:
        #
        #   run = VBlank::IR::Backends::SNES::CheckedRun.new
        #   run.input_each_frame { |frame| frame < 30 ? [:right] : [] }.run(game.program, frames: 60)
        #   run[:x]
        #
        # The interpreter plays the program on the screen of the console it was built for, and the
        # two pictures are compared over the Super Nintendo's screen, the top-left 256×224 of it.
        class CheckedRun
          extend RunComparison

          Moment = HeadlessRun::Moment

          # The cartridge and the interpreter disagreed. The message says the pass and everything
          # that differs there.
          Disagreement = RunComparison::Disagreement

          def initialize(save: SaveImage.new)
            @save = save
            @cartridge = HeadlessRun.new(save: save)
            @played = {}
            @held = []
            @cartridge.input_each_frame { |frame| @played[frame] = buttons_for(frame) }
          end

          def hold(*buttons)
            @held = buttons
            @cartridge.hold(*buttons)
            self
          end

          def input_each_frame(&script)
            @script = script
            self
          end

          def each_vblank(&block)
            @cartridge.each_vblank(&block)
            self
          end

          def run(program, max_steps: nil, frames: nil)
            frames ||= max_steps ? frames_within(program, max_steps) : Reference::DEFAULT_FRAMES
            refuse_endless_game_without_frames!(program)
            before = @save.dup # the interpreter starts from the save memory the cartridge started from
            @near = HeadlessRun.near_pictures?(program)
            @cartridge.run(program, frames: frames)
            width, height = @cartridge.screen.then { |picture| [picture.width, picture.height] }
            moments = play_on_interpreter(program, frames, width, height, before)
            difference = self.class.first_difference(moments, @cartridge.moments)
            difference ||= self.class.sounds_difference(@interpreter_sounds, @cartridge.audio_played)
            difference ||= dsp_difference
            difference ||= self.class.save_difference(before, @save) if SaveLayout.named_by?(program)
            raise Disagreement, "the Super Nintendo lowering and the interpreter disagree at #{difference}" if difference

            self
          end

          def [](name) = @cartridge[name]
          def screen = @cartridge.screen

          def method_missing(name, ...) = @cartridge.public_send(name, ...)
          def respond_to_missing?(name, include_private = false) = @cartridge.respond_to?(name, include_private)

          def self.lowered_side = "cartridge"

          private

          def buttons_for(frame) = @script ? Array(@script.call(frame)) : @held

          # A game that never waits for the screen has no frames to count, so it is played on the
          # interpreter first, with the buttons held from power-on, to find whether it comes to an
          # end by itself: the cartridge keeps no count of its steps.
          def refuse_endless_game_without_frames!(program)
            return if program.walk.any? { |node| node.kind == :wait_vblank }
            return unless Reference.new(save: @save.dup).hold(*@held).run(program).stopped_at_budget?

            raise RunComparison::AsksTheInterpreter, "its step budget to stop a game that never waits for the screen"
          end

          # A step budget is played as the frames it covers, as GBC::CheckedRun#frames_within plays it.
          def frames_within(program, max_steps)
            lead = Reference.new(save: @save.dup).hold(*@held).input_each_frame { |frame| buttons_for(frame) }
                            .run(program, max_steps: max_steps)
            return lead.frame unless lead.frame.zero? && lead.stopped_at_budget?

            raise RunComparison::AsksTheInterpreter, "its step budget to stop a game before it first waits for the screen"
          end

          # The interpreter is told how many frames each pass took on the cartridge, so whatever keeps
          # real time moves on by the same frames on both. It plays on +save+, which it leaves as the
          # save memory it ended with.
          def play_on_interpreter(program, frames, width, height, save)
            interpreter = Reference.new(save: save).hold(*@held)
            moments = []
            interpreter.frames_each_pass { |pass| @cartridge.frames_took(pass) }
            interpreter.input_each_frame { |frame| @played.fetch(frame, []) }
                       .each_vblank { |frame| moments << moment_of(interpreter, frame, width, height) }
                       .run(program, frames: frames)
            @interpreter_sounds = interpreter.audio.dup
            moments << moment_of(interpreter, :end, width, height)
          end

          def moment_of(interpreter, frame, width, height)
            Moment.new(frame: frame, variables: interpreter.vars.dup, picture: picture_check(interpreter.screen, width, height),
                       sounds: interpreter.audio.size, sprites: interpreter.sprites,
                       collections: interpreter.game_state.except(:vars), sounding: interpreter.active_samples.dup)
          end

          # THE SOUND UNIT ITSELF, held to the sound log: the first time the game was found waiting with
          # a register of the S-DSP holding something other than what the interpreter's log says it
          # must, as far as the entries the cartridge had logged then (each register those entries
          # write, DSPWrites.after), the pass and the registers that differ. The log agreeing is not
          # enough: a write dropped on the way, sent to the wrong register or never answered would
          # leave the log right and the sound wrong. The logs themselves are held to each other
          # first, so the cartridge's entries as far as that count are the interpreter's — read as
          # the cartridge logged them, where a stop names the tune it stopped (HeadlessRun#audio_as_logged),
          # which the interpreter's [:stop_music] does not.
          #
          # A RECORDING THE GAME PLAYS takes a voice of the four past the Advance's, chosen by where the
          # interpreter's mix puts it (Runtime::Recordings), which the log does not say: those voices'
          # registers are not held to it, nor their bits of the key-on and key-off registers, which
          # they share. Which recordings sound is held instead, at every moment (HeadlessRun#active_samples).
          def dsp_difference
            voicing = @cartridge.rom.built.sound_voicing
            recordings = !@cartridge.rom.built.recording_names.empty?
            # Only as far as the interpreter's log goes: past it, nothing held the cartridge's entries.
            logged_entries = @cartridge.audio_as_logged.take(@interpreter_sounds.size)
            stop = DSPWrites.misnamed_stop(logged_entries, voicing)
            return "entry #{stop + 1} of the sound log: the cartridge stopped #{logged_entries[stop][1].inspect}, not the tune playing" if stop

            @cartridge.dsp_reads.each_with_index do |(logged, held), i|
              expected = DSPWrites.after(logged_entries.take(logged), voicing)
              expected = DSPWrites.console_voices_only(expected) if recordings
              wrong = expected.filter_map do |register, value|
                got = held.getbyte(register)
                got &= DSPWrites::CONSOLE_VOICE_BITS if recordings && register == DSPWrites::KEY_OFF
                format("$%<register>02X holds $%<got>02X, the log says $%<value>02X", register: register, got: got,
                                                                                       value: value) if got != value
              end
              next if wrong.empty?

              return "the wait at the end of pass #{i + 1}: the sound unit's DSP registers: #{wrong.join(', ')}"
            end
            nil
          end

          # The interpreter's picture over the cartridge's screen, as the cartridge's Moments hold it
          # (HeadlessRun.moment_picture).
          def picture_check(screen, width, height)
            shown = (0...height).flat_map { |y| (0...width).map { |x| screen.pixel(x, y) || 0 } }
            HeadlessRun.moment_picture(shown, @near)
          end
        end
      end
    end
  end
end
