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
# and has to hold a note long enough for its pitch to be compared at least once — or, for the
# noise voice, hiss long enough for how bright it is to be; a run where that never happens fails
# and says so, rather than passing because there was nothing to differ.
#
# HOW LOUD EACH KIND OF VOICE IS READ. A square voice and the noise voice are two heights and
# nothing between, so how loud one is is how far it jumps from one to the other (Heard#jump). The
# wave voice climbs its waveform a step at a time and never jumps its whole height at once, so
# how loud it is is how tall the wave stands, top to bottom (Heard#height) — read from the
# emulator's sound with its drift taken back out (#without_drift). All three come out in the same
# steps, 0 to 15: the wave voice at its loudest is as tall as a square voice's jump at volume 15.
#
# THE NOISE VOICE IS JUDGED ITS OWN WAY, because a hiss is a pattern and not a wave. It has no
# pitch to read from the spacing of its rises, so what is compared in its place is how BRIGHT it
# is: how often it changes, counted as how many times it crosses its own middle through three
# frames (Heard#brightness). And a slow hiss, a rumble, stays high or low for frames at a time,
# so a frame with no jump in it is not a silent one: its loudness is asked only where one of the
# two jumps (#hiss_loudness_difference). The pattern itself — which way it stands on each step —
# is a test of its own, for a hiss slow enough that every step shows (Heard#runs).
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
#   - THE NOISE VOICE'S LOUDNESS, two steps and a half. A square wave jumps hundreds of times a
#     frame, so a frame is as loud as the voice was at the frame's start. A low hiss jumps a few
#     times a frame, and each jump is as tall as the volume at the moment it falls — a moment the
#     two can put either side of a step of the fade, on top of the step their fades can already
#     be apart.
#   - A FRAME EITHER WAY, for loudness. A fading note steps down on a clock of the chip's own
#     that is not in step with the frames, so a step can fall a frame early or late. So a frame
#     is as loud as it should be if it matches the console's frame before, the same frame, or
#     the one after.
#   - PITCH, one part in a hundred, and TONE, a fiftieth of the wave. Resampling moves each edge
#     of the wave by a fraction of a sample, in a wave of a hundred or so.
#   - HOW BRIGHT A HISS IS, three parts in twenty and three crossings. A hiss slower than the
#     console hands its voices on is the same pattern on both, step for step, and the two counts
#     are a few crossings apart: one at either end of the three frames can fall inside them on
#     one and outside on the other, which is the three. The fastest hisses step several times
#     between one hand-over and the next, and which of those steps each of the two catches is
#     not the same — so they play different stretches of one pattern, as two rolls of the same
#     dice, and their counts wander apart by a few parts in a hundred, which three in twenty is
#     well clear of. What that catches is a hiss stepping at twice its speed or half, or on the
#     wrong clock. It is too wide to catch one a single rung of the voice's ladder out where the
#     rungs are a seventh apart; which rung a note takes is worked out once for every backend
#     (Audio::Sound.noise_rung) and tested there.
#
# Pitch and tone are compared wherever the console is simply holding a note — every wave the
# same, through the frame itself and two frames either side — which is what makes sure the
# desktop build should be holding it too, whichever of them is a frame ahead. A frame where the
# note is changing is left to the loudness check. How bright a hiss is is compared the same way,
# wherever the console hisses loud enough through the frame and two either side and is one hiss
# throughout: the count through the frame before and the frame after is within a quarter of
# this frame's. A slow hiss wanders that far by itself, being a pattern and not a tone, so some
# of its frames are left out too; where one hit gives way to another, all of them are. And a
# hiss that crosses fewer than a dozen times in three frames is too slow to count at all.
module SoundComparison
  include NativeComparison

  Recording = VBlank::Diagnostics::SoundRecording
  CONSOLE_RATE = Recording::CARTRIDGE_RATE # what the emulator hands its sound over at

  # A frame of the console: this many ticks of a clock of 2^CLOCK_BITS a second.
  FRAME_TICKS = 280_896
  CLOCK_BITS = 24

  # The emulator's name for each voice the desktop build makes, and the build's number for it —
  # which is the console's own count of its voices.
  VOICES = Recording::VOICES

  # A frame is read for broken waves where the voice is at least this share as loud as at its
  # loudest: quieter, the emulator's drift back to nought blurs the wave's edges.
  READABLE_SHARE = 0.25

  # The voices a comparison listens to when it is not told which.
  SQUARE_VOICES = %i[square1 square2].freeze

  FULL_VOLUME = 15
  LOUDNESS_SLACK = 1.5  # steps of FULL_VOLUME
  HISS_LOUDNESS_SLACK = 2.5 # ...and for the noise voice
  HEARD = 0.75          # a voice at least this loud is sounding...
  SILENT = 0.25         # ...and one no louder than this is not
  PITCH_SLACK = 0.01    # as a share of the pitch
  TONE_SLACK = 0.02     # as a share of the wave
  HELD_LOUDNESS = 3.0   # a voice quieter than this is too quiet to measure the pitch of
  WAVE_SLACK = 0.03     # how much one wave may differ in length from the usual one and be the same note
  SAME_NOTE_SHARE = 0.8 # how many of the waves have to be that length for it to be one note
  JUMP_SAMPLES = 6      # as many samples as one edge of the wave is spread over, and one to spare
  # How fast the emulator lets its sound drift back to nought: every sample it hands over has
  # lost one part in this many of where the sound stood (see #without_drift).
  DRIFT_SAMPLES = 512
  BRIGHTNESS_SLACK = 0.15 # as a share of how many times the console's hiss crosses its middle
  BRIGHTNESS_SPARE = 3    # ...and this many crossings besides, in the three frames counted
  BRIGHTNESS_LEAST = 12   # a hiss crossing fewer times than this in three frames is too slow to count
  SAME_HISS_SLACK = 0.25  # how far that count may move from one frame to the next and be one hiss
  # How many frames apart the two may start, either way. The console has a cartridge to start up
  # before the game's first frame, and where a button press sets the sound off, the two can pick
  # the press up a frame or two apart. The whole run is then compared from where each starts.
  MOST_FRAMES_APART = 3

  # A note a voice is holding: its pitch in Hz, and how much of each wave is spent high.
  Note = Data.define(:pitch, :high_share)

  # One voice over a run: which kind of voice it is (:square, :wave or :noise), its samples, how
  # many a second, and how far a square wave jumps on a note at full volume — which is what turns
  # a jump, or a wave's height, into one of the voice's fifteen steps.
  #
  # +kept+ is what has been read off it so far. A comparison asks the same thing of the same
  # frame many times over — each frame's loudness for the frame either side as well, and all of
  # it again for each way of lining the two runs up — and reading it is most of the work.
  Heard = Data.define(:kind, :samples, :rate, :full_jump, :kept) do
    def initialize(kind:, samples:, rate:, full_jump:, kept: {}) = super

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

    # How tall the wave voice's wave stands in a frame: from its lowest sample to its highest.
    #
    # That is the very thing #jump says not to trust, and it can be trusted here only because the
    # emulator's drift has been taken back out of the wave voice's samples first
    # (SoundComparison#without_drift). A frame holds a whole wave of any note from 60 Hz up, which
    # is every note with a name; one lower than that reads shorter than it is.
    def height(index) = frames(index, index).minmax.then { |low, high| low ? high - low : 0 }

    # How loud the voice is in a frame, in its own steps: 0 is silent, 15 its loudest.
    def loudness(index)
      kept[[:loudness, index]] ||= (kind == :wave ? height(index) : jump(index)) * FULL_VOLUME.to_f / full_jump
    end

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
      kept.fetch([:note, index, every_wave]) { |asked| kept[asked] = note_read_at(index, every_wave) }
    end

    def note_read_at(index, every_wave)
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

    # How bright a hiss is through frame +index+ and the one either side: how many times it
    # crosses its own middle in those three frames, or nil when it is too quiet in any of them
    # to count. A fast, thin hiss crosses hundreds of times a frame, and a rumble a handful.
    #
    # Each frame is counted against its own middle, since the emulator's filter lets the whole
    # hiss drift as it fades.
    def brightness(index)
      near = [index - 1, index, index + 1]
      return nil unless near.all? { |frame| loudness(frame) >= HELD_LOUDNESS }

      near.sum { |frame| crossings(frame) }
    end

    # How many times the voice crosses its own middle in one frame.
    def crossings(index)
      kept[[:crossings, index]] ||= begin
        part = frames(index, index)
        middle = (part.max + part.min) / 2.0
        part.each_cons(2).count { |before, after| (before < middle) != (after < middle) }
      end
    end

    # How long the voice stays one way before each of its first +count+ changes, counted from
    # the first: the run of steps it is high for, then low, then high. A step is +step_seconds+
    # long, so this is the pattern of a hiss itself, for one slow enough that every step shows.
    def runs(step_seconds, count)
      edges = []
      at = 0
      while at < samples.length - JUMP_SAMPLES && edges.length <= count
        if (samples[at + JUMP_SAMPLES - 1] - samples[at]).abs > full_jump / 2
          edges << at
          at += JUMP_SAMPLES
        else
          at += 1
        end
      end
      edges.each_cons(2).map { |from, to| ((to - from) / (rate * step_seconds)).round }
    end
  end

  # The desktop build's sound matches the console's, voice by voice and frame by frame, over
  # +frames+ frames of +program+. +buttons+ maps a frame (from 1) to the buttons held in it; the
  # console starts a frame or two apart from the desktop build, so hold a button for a few frames
  # rather than one. +voices+ is the two square voices unless it is said, and every one of them
  # has to be heard: name the voices the run uses, and leave out one it never does.
  #
  # For the same reason a button reaches the two on DIFFERENT PASSES of the game, which matters
  # where the game is racing something of its own; "The console starts its game a frame or two
  # after the desktop build" in .claude/testing/native-sound.md says how to hold one so it does not.
  def assert_native_sounds_like_the_console(program, frames:, buttons: {}, voices: SQUARE_VOICES)
    console = voices.to_h { |voice| [voice, console_voice(program, voice, frames: frames + MOST_FRAMES_APART, buttons: buttons)] }
    native = voices.to_h { |voice| [voice, native_voice(program, voice, frames: frames, buttons: buttons)] }
    later = frames_console_starts_later!(console, native)
    differences = [later, later - 1, later + 1].map { |apart| differences_lined_up(console, native, apart, frames) }.min_by(&:length)

    assert_empty differences.first(8), "the desktop build does not sound like the console (#{differences.length} frames differ)"
    voices.select { |voice| kind_of(voice) == :square }.each do |voice|
      assert_operator waves_broken_while_loud(native[voice]), :<=, waves_broken_while_loud(console[voice]),
                      "the desktop build's #{voice} breaks more waves than the console's: it loses its place in its wave"
    end
  end

  # THE WAVES THEMSELVES, on every frame, a note changing or not: how many waves a square voice
  # breaks, going back to the start of its wave where the chip carries on (Diagnostics::SoundRecording
  # says how one is found). Counted where the voice is loud enough to read (READABLE_SHARE), and as
  # a total for the run, since the two do not break theirs on the same frame. The loudness, pitch
  # and tone above are read only where a note is held still, so this is what hears a fade or a
  # restarted note.
  def waves_broken_while_loud(heard)
    frames = Recording.new(samples: heard.samples, rate: heard.rate, frame_seconds: Rational(FRAME_TICKS, 1 << CLOCK_BITS)).frames
    loudest = frames.map(&:loudness).max || 0
    frames.select { |frame| loudest.positive? && frame.loudness >= loudest * READABLE_SHARE }.sum(&:waves_broken)
  end

  # One voice of the cartridge's sound in the emulator, with the other voices left out of the mix.
  def console_voice(program, voice, frames:, buttons: {})
    samples = console_samples(program, frames: frames, buttons: buttons, only: voice)
    Heard.new(kind: kind_of(voice), samples: voice == :wave ? without_drift(samples) : samples,
              rate: CONSOLE_RATE, full_jump: full_jump(:console))
  end

  # The emulator's samples with its drift taken back out: the sound as the voice made it, before
  # the emulator's filter.
  #
  # The filter is there to do what a real speaker's wiring does. A voice's sound is all on one
  # side of nought, and the filter lets the whole of it sink back towards nought, a five-hundred-
  # and-twelfth of the way each sample. So a note that starts or stops drags the next frame or two
  # with it. A square wave and a hiss are read from their edges, which are over before the drift
  # has gone anywhere, and are left as they come. The wave voice has no edge: its loudness is how
  # tall its wave stands and its tone how much of the wave lies above its middle, and both are
  # moved by a wave that is sinking as it is measured. What the filter took away, sample by
  # sample, is put back: each sample gets back that share of everything handed over before it.
  def without_drift(samples)
    handed_over = 0
    samples.map do |sample|
      restored = sample + (handed_over / DRIFT_SAMPLES.to_f)
      handed_over += sample
      restored
    end
  end

  # The same voice of the desktop build's sound.
  def native_voice(program, voice, frames:, buttons: {})
    Heard.new(kind: kind_of(voice), samples: native_samples(program, frames: frames, buttons: buttons, only: voice),
              rate: Native::HeadlessRun::SOUND_RATE, full_jump: full_jump(:native))
  end

  private

  # Which kind of voice a name is: both square voices are one kind.
  def kind_of(voice) = SQUARE_VOICES.include?(voice) ? :square : voice

  def never_compared(voice)
    if voice == :noise
      "hisses steadily for long enough on the console to compare how bright it is"
    else
      "holds a note long enough on the console to compare its pitch"
    end
  end

  # The cartridge's sound in the emulator: its left speaker, every voice or +only+ one. Asked of
  # the emulator directly, because here it is the answer key and not the thing under test
  # (`require_emulator!` skips on a native run, for a test that is about the cartridge).
  def console_samples(program, frames:, buttons: {}, only: nil)
    Recording.of(program, on: :cartridge, frames: frames, buttons: buttons, only: only).samples
  end

  def native_samples(program, frames:, buttons: {}, only: nil)
    Recording.of(program, on: :native, frames: frames, buttons: buttons, only: only).samples
  end

  # How far the wave jumps on a square note at full volume, on the console or the desktop build:
  # found by playing one, once, and kept. Each has its own, since how loud "full" comes out is a
  # setting of whatever plays it and not something the two have to agree on. Every voice is
  # measured in it: the console mixes its four voices on one scale, and so does the desktop build.
  def full_jump(side)
    Ractor.store_if_absent(:"sound_comparison_full_jump_#{side}") do
      program = program_of do
        enable_sound
        song(:full) { volume FULL_VOLUME; note :A4, :whole }
        play_song :full
        game_loop {}
      end
      samples = side == :console ? console_samples(program, frames: 30) : native_samples(program, frames: 30)
      voice = Heard.new(kind: :square, samples: samples, rate: side == :console ? CONSOLE_RATE : Native::HeadlessRun::SOUND_RATE,
                        full_jump: 1)
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

  # Everything that differs with the console's sound taken to start +later+ frames after the
  # desktop build's, each voice's differences said under its name — and a voice with nothing to
  # compare its pitch by is a difference too.
  #
  # The two are lined up by the frame each first makes a sound in, and that is tried a frame out
  # either way as well, keeping whichever agrees best (the first, when they agree as well). It is
  # the noise voice that needs it: a hiss does not jump until its first step is over, which for a
  # rumble is most of a frame after the hit, and the two can then put that first jump either side
  # of a frame's end. Lined up a frame out, every note of a run differs on its first frame and its
  # last, so which line-up is the right one is never close.
  def differences_lined_up(console, native, later, frames)
    console.keys.flat_map do |voice|
      found, compared = voice_differences(console.fetch(voice), native.fetch(voice), later, frames)
      found.unshift("never #{never_compared(voice)}") unless compared.positive?
      found.map { |difference| "#{voice}, #{difference}" }
    end
  end

  # Every frame the desktop build's voice differs from the console's on, in words, and how many
  # frames' notes — or, for the noise voice, how many frames' hiss — were compared.
  def voice_differences(console, native, later, frames)
    both_have = [frames, native.frame_count, console.frame_count - later].min
    compared = 0
    differences = (0...both_have).filter_map do |index|
      at = index + later
      wrong = console.kind == :noise ? hiss_loudness_difference(console, native, at, index) : loudness_difference(console, native, at, index)
      next wrong if wrong
      next if index + 1 >= native.frame_count # a note is read from a frame and the one either side

      difference = console.kind == :noise ? hiss_difference(console, native, at, index) : held_note_difference(console, native, at, index)
      next if difference.nil? # the console is not simply holding a note, or hissing, here and either side

      compared += 1
      difference.first
    end
    [differences, compared]
  end

  # What differs about how loud a square voice or the wave voice is at one frame, or nil.
  def loudness_difference(console, native, at, index)
    loud = native.loudness(index)
    wanted = [at - 1, at, at + 1].map { |frame| console.loudness(frame) }
    return format("frame %d: silent, and the console is heard", index) if loud <= SILENT && wanted.all? { |level| level >= HEARD }
    return format("frame %d: heard, and the console is silent", index) if loud >= HEARD && wanted.all? { |level| level <= SILENT }
    return nil if wanted.any? { |level| (level - loud).abs <= LOUDNESS_SLACK }

    format("frame %d: as loud as %.1f of 15, and the console is %.1f", index, loud, wanted[1])
  end

  # The same for the noise voice, which is asked a different way round.
  #
  # A square wave jumps in every frame it sounds in, so a frame with no jump is a silent one. A
  # hiss is a pattern, and a slow one stays high or low for frames at a time: a frame with no jump
  # in it says nothing about whether the voice is sounding. So a frame is judged only where one of
  # the two jumps in it, and then the other has to jump as far in that frame or the one either
  # side — asked from the desktop build's frame, and from the console's.
  def hiss_loudness_difference(console, native, at, index)
    here = [index - 1, index, index + 1].map { |frame| native.loudness(frame) }
    there = [at - 1, at, at + 1].map { |frame| console.loudness(frame) }
    if here[1] >= HEARD
      return format("frame %d: heard, and the console is silent", index) if there.all? { |level| level <= SILENT }
      unless there.any? { |level| (level - here[1]).abs <= HISS_LOUDNESS_SLACK }
        return format("frame %d: as loud as %.1f of 15, and the console is %.1f", index, here[1], there[1])
      end
    end
    return nil if there[1] < HEARD
    return format("frame %d: silent, and the console is heard", index) if here.all? { |level| level <= SILENT }
    return nil if here.any? { |level| (level - there[1]).abs <= HISS_LOUDNESS_SLACK }

    format("frame %d: as loud as %.1f of 15, and the console is %.1f", index, here[1], there[1])
  end

  # What differs about the note held at one frame, in a list of its own (empty when nothing
  # does), or nil where the console is not holding one note there and either side.
  def held_note_difference(console, native, at, index)
    held = [at - 1, at, at + 1].map { |frame| console.held_note(frame, every_wave: true) }
    return nil unless held.all?

    [note_difference(held[1], native.held_note(index), index)]
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

  # The same for a hiss: what differs about how bright it is at one frame, or nil where the
  # console is not hissing loud enough there and either side to count.
  def hiss_difference(console, native, at, index)
    wanted = [at - 1, at, at + 1].map { |frame| console.brightness(frame) }
    return nil unless wanted.all?
    return nil unless wanted[1] >= BRIGHTNESS_LEAST
    return nil unless wanted.all? { |count| (count - wanted[1]).abs <= wanted[1] * SAME_HISS_SLACK }

    played = native.brightness(index)
    if played.nil?
      [format("frame %d: no hiss loud enough to count, and the console's crosses its middle %d times", index, wanted[1])]
    elsif (played - wanted[1]).abs > (wanted[1] * BRIGHTNESS_SLACK) + BRIGHTNESS_SPARE
      [format("frame %d: a hiss crossing its middle %d times in three frames, and the console's %d", index, played, wanted[1])]
    else
      [nil]
    end
  end
end
