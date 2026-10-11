# frozen_string_literal: true

require "native_comparison"

# IS THE SOUND THE DESKTOP BUILD MAKES THE SOUND THE CARTRIDGE MAKES? For any game:
#
#   include SoundComparison
#   assert_native_sounds_like_the_console(program, frames: 300, buttons: { 2 => [:a], 3 => [:a] })
#
# The console's own voices never pass through memory — its sound chip makes each wave itself — so
# there are no bytes to compare. The answer key is what comes out of the emulator, and it is
# judged the way an ear would: frame by frame, is each voice as LOUD, at the same PITCH, with the
# same thin or full TONE. One voice at a time, because two voices added together have no one
# pitch to measure; the emulator can leave voices out of its mix, and so can the desktop build.
#
# It is deterministic: the emulator and the desktop build each play the same run the same way
# every time, so a comparison that passes once passes always.
#
# THE TOLERANCES, and why each is there. The emulator does not hand over what the chip does but
# what a speaker would get: resampled, and filtered a little.
#
#   - LOUDNESS, two of a voice's fifteen steps. The filter adds a thump as a note starts from
#     silence, worth nearly two steps on a note at full volume, and nothing after it.
#   - A FRAME EITHER WAY. A fading note steps down on a clock of the chip's own that is not in
#     step with the frames, so a step can fall a frame early or late; and a frame where the note
#     changes is half one note and half the next. So a frame is right if it matches the console's
#     frame before, the same frame, or the one after.
#   - PITCH, three parts in two hundred, and TONE, a twentieth of the wave. Resampling moves each
#     edge of the wave by up to a sample, in a wave of about a hundred.
#
# Pitch and tone are compared only where a voice is holding a note steadily — loud enough to
# measure, and not on a frame where its note changes.
module SoundComparison
  Native = RubyGBA::IR::Backends::Native
  Hardware = RubyGBA::Console::Hardware

  FRAMES_A_SECOND = 16_777_216 / 280_896.0
  CONSOLE_RATE = 44_100 # what the emulator hands its sound over at

  # The emulator's name for each voice the desktop build makes, and the build's number for it.
  VOICES = { square1: 1, square2: 2 }.freeze

  FULL_VOLUME = 15
  LOUDNESS_SLACK = 2.0  # steps of FULL_VOLUME
  PITCH_SLACK = 0.015   # as a share of the pitch
  TONE_SLACK = 0.05     # as a share of the wave
  STEADY_LOUDNESS = 3.0 # a voice quieter than this is too quiet to measure the pitch of
  JUMP_SAMPLES = 6      # as many samples as one edge of the wave is spread over, and one to spare
  # How many frames apart the two may start, either way. The console has a cartridge to start up
  # before the game's first frame, and where a button press sets the sound off, the two can pick
  # the press up a frame or two apart. The whole run is then compared from where each starts.
  MOST_FRAMES_APART = 3

  # One voice over a run: its samples, how many a second, and how far the wave jumps on a note at
  # full volume — which is what turns a jump into one of the voice's fifteen steps.
  Heard = Data.define(:samples, :rate, :full_jump) do
    # Which sample frame +index+ starts at. A frame is 280,896 ticks of a clock of 2^24 a second,
    # which is not a whole number of samples; this is where the desktop build itself cuts them
    # (rg_sound_render_frame), in whole numbers so it never drifts.
    def frame_start(index) = (index * rate * 280_896) >> 24

    # How many whole frames there are.
    def frame_count = (samples.length << 24) / (rate * 280_896)

    def frame(index)
      return [] if index.negative? || index >= frame_count

      samples[frame_start(index)...frame_start(index + 1)]
    end

    # How far the wave jumps in a frame: the biggest change over a few samples, which is one
    # edge of the wave from low to high or back.
    #
    # Not the highest sample less the lowest, which is what it looks like it should be. As a note
    # starts the emulator's filter pushes the whole wave to one side and lets it drift back over
    # the next frame or so; the highest and lowest samples of that frame are then further apart
    # than the wave is tall, by as much as a quarter on a low note. An edge is over in a few
    # samples, in which the drift has gone nowhere.
    def jump(index) = frame(index).each_cons(JUMP_SAMPLES).map { |few| (few.last - few.first).abs }.max || 0

    # How loud the voice is in a frame, in its own steps: 0 is silent, 15 its loudest.
    def loudness(index) = jump(index) * FULL_VOLUME.to_f / full_jump

    def sounding?(index) = loudness(index) >= 1.0

    # The first frame the voice is heard in, or nil for a voice that is never heard.
    def first_heard = (0...frame_count).find { |index| sounding?(index) }

    # The pitch in a frame: how many times a second the wave rises through its middle.
    def pitch(index)
      part = frame(index)
      middle = (part.max + part.min) / 2.0
      part.each_cons(2).count { |before, after| before < middle && after >= middle } * rate.to_f / part.length
    end

    # How much of the wave is spent high in a frame, 0 to 1.
    def high_share(index)
      part = frame(index)
      middle = (part.max + part.min) / 2.0
      part.count { |sample| sample >= middle }.to_f / part.length
    end

    # Is the voice holding one note through this frame — loud enough to measure, and at the pitch
    # of the frames either side?
    def steady?(index)
      [index - 1, index, index + 1].all? { |near| loudness(near) >= STEADY_LOUDNESS } &&
        [index - 1, index + 1].all? { |near| (pitch(near) - pitch(index)).abs <= pitch(index) * PITCH_SLACK }
    end
  end

  # The desktop build's sound matches the console's, voice by voice and frame by frame, over
  # +frames+ frames of +program+. +buttons+ maps a frame (from 1) to the buttons held in it; the
  # console starts a frame or two later than the desktop build, so hold a button for a few frames
  # rather than one.
  def assert_native_sounds_like_the_console(program, frames:, buttons: {}, voices: VOICES.keys)
    console = voices.to_h { |voice| [voice, console_voice(program, voice, frames: frames + MOST_FRAMES_APART, buttons: buttons)] }
    native = voices.to_h { |voice| [voice, native_voice(program, voice, frames: frames, buttons: buttons)] }
    later = frames_later(console, native)
    differences = voices.flat_map do |voice|
      voice_differences(console.fetch(voice), native.fetch(voice), later, frames).map { |difference| "#{voice}, #{difference}" }
    end

    assert_empty differences.first(8), "the desktop build does not sound like the console (#{differences.length} frames differ)"
  end

  # One voice of the cartridge's sound in the emulator: its left speaker, with the other voices
  # left out of the mix. Asked of the emulator directly, because here it is the answer key and
  # not the thing under test (`require_emulator!` skips on a native run, for a test that is about
  # the cartridge).
  def console_voice(program, voice, frames:, buttons: {})
    RubyGBA::Diagnostics::Emulator.load!
    keys = ->(frame) { buttons.fetch(frame + 1, []).sum { |button| Hardware.const_get("KEY_#{button.upcase}") } }
    verifier = RubyGBA::Diagnostics::Verifier.new(assemble_rom(program), frames: 0, keys: keys)
    verifier.hearing(only: voice)
    verifier.step(frames)
    Heard.new(samples: verifier.audio_samples.each_slice(2).map(&:first), rate: CONSOLE_RATE, full_jump: full_jump(:console))
  end

  # The same voice of the desktop build's sound.
  def native_voice(program, voice, frames:, buttons: {})
    run = Native::HeadlessRun.new.recording_sound(only: VOICES.fetch(voice))
    run.input_each_frame { |frame| buttons.fetch(frame, []) }.run(program, frames: frames)
    Heard.new(samples: run.sound, rate: Native::HeadlessRun::SOUND_RATE, full_jump: full_jump(:native))
  end

  private

  # How far the wave jumps on a note at full volume, on the console or the desktop build: found
  # by playing one, once, and kept. Each has its own, since how loud "full" comes out is a
  # setting of whatever plays it and not something the two have to agree on.
  def full_jump(side)
    Ractor.store_if_absent(:"sound_comparison_full_jump_#{side}") do
      program = RubyGBA::Builder.new.tap do |builder|
        builder.instance_eval do
          enable_sound
          song(:full) { volume FULL_VOLUME; note :A4, :whole }
          play_song :full
          game_loop {}
        end
        builder.finalize_program
      end.program
      voice = side == :console ? calibration_console(program) : calibration_native(program)
      jumps = (0...voice.frame_count).map { |index| voice.jump(index) }.select(&:positive?)
      jumps.sort[jumps.length / 2] # the middle one of the frames it sounds in
    end
  end

  def calibration_console(program)
    RubyGBA::Diagnostics::Emulator.load!
    verifier = RubyGBA::Diagnostics::Verifier.new(assemble_rom(program), frames: 30)
    Heard.new(samples: verifier.audio_samples.each_slice(2).map(&:first), rate: CONSOLE_RATE, full_jump: 1)
  end

  def calibration_native(program)
    run = Native::HeadlessRun.new.recording_sound.run(program, frames: 30)
    Heard.new(samples: run.sound, rate: Native::HeadlessRun::SOUND_RATE, full_jump: 1)
  end

  # How many frames later the console's sound starts than the desktop build's, from the first
  # voice either is heard on. The console has to be heard, or there is nothing to compare.
  def frames_later(console, native)
    heard = console.values.filter_map(&:first_heard).min
    flunk "the console played nothing on #{console.keys.join(' or ')}, so there is nothing to compare" if heard.nil?

    played = native.values.filter_map(&:first_heard).min
    flunk "the desktop build played nothing, and the console is first heard in frame #{heard}" if played.nil?

    later = heard - played
    assert_operator later.abs, :<=, MOST_FRAMES_APART, "the console's sound starts #{later} frames after the desktop build's"
    later
  end

  # Every frame the desktop build's voice differs from the console's on, in words.
  def voice_differences(console, native, later, frames)
    both_have = [frames, native.frame_count, console.frame_count - later].min
    (0...both_have).filter_map do |index|
      near = [index - 1, index, index + 1].map { |frame| frame + later }
      loud = native.loudness(index)
      if near.none? { |frame| (console.loudness(frame) - loud).abs <= LOUDNESS_SLACK }
        next format("frame %d: as loud as %.1f of 15, and the console is %.1f", index, loud, console.loudness(index + later))
      end
      next unless native.steady?(index) && console.steady?(index + later)

      steady_difference(console, native, index, index + later)
    end
  end

  def steady_difference(console, native, index, console_index)
    pitch = native.pitch(index)
    wanted = console.pitch(console_index)
    return format("frame %d: at %.0f Hz, and the console is at %.0f", index, pitch, wanted) if (pitch - wanted).abs > wanted * PITCH_SLACK

    high = native.high_share(index)
    wanted = console.high_share(console_index)
    format("frame %d: high for %.2f of its wave, and the console for %.2f", index, high, wanted) if (high - wanted).abs > TONE_SLACK
  end
end
