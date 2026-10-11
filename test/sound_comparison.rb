# frozen_string_literal: true

require "differential"
require "native_comparison"

# IS THE SOUND THE DESKTOP BUILD MAKES THE SOUND THE CARTRIDGE MAKES? For any game:
#
#   include SoundComparison
#   assert_native_sounds_like_the_console(program, frames: 300, buttons: { 3 => [:a], 4 => [:a] })
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
# IT REFUSES TO PASS ON NOTHING. Every voice it is asked about has to be heard on the console,
# and has to hold a note long enough for its pitch to be compared at least once; a run where
# that never happens fails and says so, rather than passing because there was nothing to differ.
#
# THE TOLERANCES, and why each is there. The emulator does not hand over what the chip does but
# what a speaker would get: resampled, and filtered a little.
#
#   - LOUDNESS, a step and a half of a voice's fifteen. A step, because a note that fades a step
#     a frame is a step quieter by the end of a frame than at its start, and the two do not
#     start a note at the same point in a frame. The half, because the emulator's edges ring a
#     little, so a jump reads a shade taller or shorter than it is. That allowance is never what
#     lets a voice go missing: heard on one and silent on the other is a difference whatever
#     the loudness.
#   - A FRAME EITHER WAY, for loudness. A fading note steps down on a clock of the chip's own
#     that is not in step with the frames, so a step can fall a frame early or late. So a frame
#     is as loud as it should be if it matches the console's frame before, the same frame, or
#     the one after.
#   - PITCH, one part in a hundred, and TONE, a fiftieth of the wave. Resampling moves each edge
#     of the wave by a fraction of a sample, in a wave of a hundred or so.
#
# Pitch and tone are compared wherever the console is simply holding a note — every wave the
# same, through the frame itself and two frames either side — which is what makes sure the
# desktop build should be holding it too, whichever of them is a frame ahead. A frame where the
# note is changing is left to the loudness check.
module SoundComparison
  include NativeComparison

  CONSOLE_RATE = 44_100 # what the emulator hands its sound over at

  # A frame of the console: this many ticks of a clock of 2^CLOCK_BITS a second.
  FRAME_TICKS = 280_896
  CLOCK_BITS = 24

  # The emulator's name for each voice the desktop build makes, and the build's number for it.
  VOICES = { square1: 1, square2: 2 }.freeze

  FULL_VOLUME = 15
  LOUDNESS_SLACK = 1.5  # steps of FULL_VOLUME
  HEARD = 0.75          # a voice at least this loud is sounding...
  SILENT = 0.25         # ...and one no louder than this is not
  PITCH_SLACK = 0.01    # as a share of the pitch
  TONE_SLACK = 0.02     # as a share of the wave
  HELD_LOUDNESS = 3.0   # a voice quieter than this is too quiet to measure the pitch of
  WAVE_SLACK = 0.03     # how much one wave may differ in length from the usual one and be the same note
  SAME_NOTE_SHARE = 0.8 # how many of the waves have to be that length for it to be one note
  JUMP_SAMPLES = 6      # as many samples as one edge of the wave is spread over, and one to spare
  # How many frames apart the two may start, either way. The console has a cartridge to start up
  # before the game's first frame, and where a button press sets the sound off, the two can pick
  # the press up a frame or two apart. The whole run is then compared from where each starts.
  MOST_FRAMES_APART = 3

  # A note a voice is holding: its pitch in Hz, and how much of each wave is spent high.
  Note = Data.define(:pitch, :high_share)

  # One voice over a run: its samples, how many a second, and how far the wave jumps on a note at
  # full volume — which is what turns a jump into one of the voice's fifteen steps.
  Heard = Data.define(:samples, :rate, :full_jump) do
    # Which sample frame +index+ starts at. A frame is not a whole number of samples; this is
    # where the desktop build itself cuts them (rg_sound_render_frame), in whole numbers so it
    # never drifts.
    def frame_start(index) = (index * rate * FRAME_TICKS) >> CLOCK_BITS

    # How many whole frames there are.
    def frame_count = (samples.length << CLOCK_BITS) / (rate * FRAME_TICKS)

    # The samples of frames +first+ to +last+, or none where the run does not reach.
    def frames(first, last)
      return [] if first.negative? || last >= frame_count

      samples[frame_start(first)...frame_start(last + 1)]
    end

    # How far the wave jumps in a frame: the biggest change over a few samples, which is one
    # edge of the wave from low to high or back.
    #
    # Not the highest sample less the lowest, which is what it looks like it should be. As a note
    # starts the emulator's filter pushes the whole wave to one side and lets it drift back over
    # the next frame or so, and the highest and lowest samples of that frame are then further
    # apart than the wave is tall. An edge is over in a few samples, in which the drift has gone
    # nowhere.
    def jump(index) = frames(index, index).each_cons(JUMP_SAMPLES).map { |few| (few.last - few.first).abs }.max || 0

    # How loud the voice is in a frame, in its own steps: 0 is silent, 15 its loudest.
    def loudness(index) = jump(index) * FULL_VOLUME.to_f / full_jump

    # The first frame the voice is heard in, or nil for a voice that is never heard.
    def first_heard = (0...frame_count).find { |index| loudness(index) >= HEARD }

    # The note the voice holds through frame +index+ and the one either side, or nil when it is
    # too quiet there or is not one note throughout.
    #
    # The pitch is read from how far apart the wave's rises are, each placed between the two
    # samples it falls between — not from how many rises there are, which can only be a whole
    # number and so only says the pitch to the nearest sixty Hz or so. It is one note when nearly
    # every wave is the length of the middle one: a voice told to sound its note again (the
    # music turned down) starts the wave over, which leaves one wave short, and that is still the
    # same note.
    #
    # +every_wave+ asks for more: every wave that length, with none starting over, and the frames
    # as loud as each other. That is what says a note is being held and nothing at all is
    # happening to it, which is when another player of the same game has to be holding it too.
    # (The loudness matters to the reading itself: where a loud note gives way to a quiet one,
    # the quiet one never reaches the middle of the loud one's wave, and its rises go unseen.)
    def held_note(index, every_wave: false)
      return nil unless [index - 1, index, index + 1].all? { |near| loudness(near) >= HELD_LOUDNESS }
      return nil if every_wave && [index - 1, index + 1].any? { |near| (loudness(near) - loudness(index)).abs > LOUDNESS_SLACK }

      part = frames(index - 1, index + 1)
      middle = (part.max + part.min) / 2.0
      rises = (0...(part.length - 1)).filter_map do |at|
        at + ((middle - part[at]) / (part[at + 1] - part[at])) if part[at] < middle && part[at + 1] >= middle
      end
      waves = rises.each_cons(2).map { |from, to| to - from }
      return nil if waves.length < 2

      usual = waves.sort[waves.length / 2]
      alike = waves.select { |wave| (wave - usual).abs <= usual * WAVE_SLACK }
      return nil if alike.length < waves.length * (every_wave ? 1 : SAME_NOTE_SHARE)

      whole_waves = part[rises.first.ceil...rises.last.ceil]
      Note.new(pitch: rate * alike.length / alike.sum, high_share: whole_waves.count { |sample| sample >= middle }.to_f / whole_waves.length)
    end
  end

  # The desktop build's sound matches the console's, voice by voice and frame by frame, over
  # +frames+ frames of +program+. +buttons+ maps a frame (from 1) to the buttons held in it; the
  # console starts a frame or two apart from the desktop build, so hold a button for a few frames
  # rather than one. Every one of +voices+ has to be heard: leave out a voice the run never uses.
  #
  # For the same reason a button reaches the two on DIFFERENT PASSES of the game, and that is the
  # whole run's fault to carry where the game is racing something: walk a character for frames
  # 3 to 30 and the ghost chasing it is two passes further on in one than the other, so it is
  # caught a frame apart and the sounds are compared a frame out. Hold such a button from frame 1
  # until what it does has stopped mattering (the character is against a wall, the menu has
  # moved on), and both play the same game.
  def assert_native_sounds_like_the_console(program, frames:, buttons: {}, voices: VOICES.keys)
    console = voices.to_h { |voice| [voice, console_voice(program, voice, frames: frames + MOST_FRAMES_APART, buttons: buttons)] }
    native = voices.to_h { |voice| [voice, native_voice(program, voice, frames: frames, buttons: buttons)] }
    later = frames_console_starts_later!(console, native)
    differences = voices.flat_map do |voice|
      found, notes_compared = voice_differences(console.fetch(voice), native.fetch(voice), later, frames)
      assert_operator notes_compared, :>, 0, "#{voice} never holds a note long enough on the console to compare its pitch"
      found.map { |difference| "#{voice}, #{difference}" }
    end

    assert_empty differences.first(8), "the desktop build does not sound like the console (#{differences.length} frames differ)"
  end

  # One voice of the cartridge's sound in the emulator, with the other voices left out of the mix.
  def console_voice(program, voice, frames:, buttons: {})
    Heard.new(samples: console_samples(program, frames: frames, buttons: buttons, only: voice), rate: CONSOLE_RATE,
              full_jump: full_jump(:console))
  end

  # The same voice of the desktop build's sound.
  def native_voice(program, voice, frames:, buttons: {})
    Heard.new(samples: native_samples(program, frames: frames, buttons: buttons, only: VOICES.fetch(voice)),
              rate: Native::HeadlessRun::SOUND_RATE, full_jump: full_jump(:native))
  end

  private

  # The cartridge's sound in the emulator: its left speaker, every voice or +only+ one. Asked of
  # the emulator directly, because here it is the answer key and not the thing under test
  # (`require_emulator!` skips on a native run, for a test that is about the cartridge).
  def console_samples(program, frames:, buttons: {}, only: nil)
    RubyGBA::Diagnostics::Emulator.load!
    keys = ->(frame) { buttons.fetch(frame + 1, []).sum { |button| Differential::KEY_BITS.fetch(button) } }
    verifier = RubyGBA::Diagnostics::Verifier.new(assemble_rom(program), frames: 0, keys: keys)
    verifier.hearing(only: only) if only
    verifier.step(frames)
    verifier.audio_samples.each_slice(2).map(&:first)
  end

  def native_samples(program, frames:, buttons: {}, only: nil)
    run = Native::HeadlessRun.new.recording_sound(only: only)
    run.input_each_frame { |frame| buttons.fetch(frame, []) }.run(program, frames: frames).sound
  end

  # How far the wave jumps on a note at full volume, on the console or the desktop build: found
  # by playing one, once, and kept. Each has its own, since how loud "full" comes out is a
  # setting of whatever plays it and not something the two have to agree on.
  def full_jump(side)
    Ractor.store_if_absent(:"sound_comparison_full_jump_#{side}") do
      program = program_of do
        enable_sound
        song(:full) { volume FULL_VOLUME; note :A4, :whole }
        play_song :full
        game_loop {}
      end
      samples = side == :console ? console_samples(program, frames: 30) : native_samples(program, frames: 30)
      voice = Heard.new(samples: samples, rate: side == :console ? CONSOLE_RATE : Native::HeadlessRun::SOUND_RATE, full_jump: 1)
      jumps = (0...voice.frame_count).map { |index| voice.jump(index) }.select(&:positive?)
      jumps.sort[jumps.length / 2] # the middle one of the frames it sounds in
    end
  end

  # How many frames later the console's sound starts than the desktop build's, from the first
  # voice either is heard on. Every voice asked about has to be heard on the console, or part of
  # what was asked is being compared with nothing.
  def frames_console_starts_later!(console, native)
    never = console.select { |_, voice| voice.first_heard.nil? }.keys
    flunk "the console never plays #{never.join(' or ')} in this run, so there is nothing to compare it with" unless never.empty?

    played = native.values.filter_map(&:first_heard).min
    flunk "the desktop build played nothing" if played.nil?

    later = console.values.map(&:first_heard).min - played
    assert_operator later.abs, :<=, MOST_FRAMES_APART, "the console's sound starts #{later} frames after the desktop build's"
    later
  end

  # Every frame the desktop build's voice differs from the console's on, in words, and how many
  # frames' notes were compared.
  def voice_differences(console, native, later, frames)
    both_have = [frames, native.frame_count, console.frame_count - later].min
    notes_compared = 0
    differences = (0...both_have).filter_map do |index|
      at = index + later
      loud = native.loudness(index)
      wanted = [at - 1, at, at + 1].map { |frame| console.loudness(frame) }
      next format("frame %d: silent, and the console is heard", index) if loud <= SILENT && wanted.all? { |level| level >= HEARD }
      next format("frame %d: heard, and the console is silent", index) if loud >= HEARD && wanted.all? { |level| level <= SILENT }
      unless wanted.any? { |level| (level - loud).abs <= LOUDNESS_SLACK }
        next format("frame %d: as loud as %.1f of 15, and the console is %.1f", index, loud, wanted[1])
      end

      next if index + 1 >= native.frame_count # a note is read from a frame and the one either side

      held = [at - 1, at, at + 1].map { |frame| console.held_note(frame, every_wave: true) }
      next unless held.all? # the console is not simply holding a note here and either side

      notes_compared += 1
      note_difference(held[1], native.held_note(index), index)
    end
    [differences, notes_compared]
  end

  def note_difference(wanted, played, index)
    if played.nil?
      format("frame %d: no one note is held, and the console holds %.0f Hz", index, wanted.pitch)
    elsif (played.pitch - wanted.pitch).abs > wanted.pitch * PITCH_SLACK
      format("frame %d: at %.1f Hz, and the console is at %.1f", index, played.pitch, wanted.pitch)
    elsif (played.high_share - wanted.high_share).abs > TONE_SLACK
      format("frame %d: high for %.3f of its wave, and the console for %.3f", index, played.high_share, wanted.high_share)
    end
  end
end
