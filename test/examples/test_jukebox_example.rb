# frozen_string_literal: true

require "test_helper"

require "stringio"
require_relative "../../examples/jukebox"

# The Jukebox example (examples/jukebox.rb): the sound showcase. Three classical
# melodies written with the note/tempo DSL; the cursor picks one and it plays and
# loops on the music channel. This asserts what the player hears — the highlighted
# tune's notes actually fire — on the interpreter oracle AND that a real ROM drives
# the music channel on hardware.
class TestJukeboxExample < Minitest::Test

  # The opening (downbeat) note of each tune, in Hz — distinct so each is a
  # diagnostic value. If the frame-0 fix regressed, these would never sound.
  ODE_FIRST    = 330 # E4
  ELISE_FIRST  = 659 # E5
  MINUET_FIRST = 587 # D5

  # A per-frame input that taps DOWN +n+ times, one edge per tap, then holds
  # nothing — leaving the cursor parked on row n. The interpreter samples the
  # script from frame 1, so the presses land on odd frames (1, 3, ...) with a
  # released frame between them, and each is a fresh rising edge the cursor moves on.
  def tap_down(times)
    down_frames = Array.new(times) { |k| 1 + k * 2 }
    ->(f) { down_frames.include?(f) ? [:down] : [] }
  end

  def notes(interpreter)
    interpreter.audio.select { |e| e[0] == :note }
  end

  def test_the_example_builds_clean
    rom = Jukebox.build_rom(out: StringIO.new, err: StringIO.new)
    assert_operator rom.size, :>, 0, "the built ROM should be non-empty"
  end

  # Row 0 is selected at the start, so the first tune plays with no input and
  # sounds its opening note. Ode to Joy is a two-part arrangement, so both the
  # melody's downbeat and the bass note under it sound together on frame 0.
  ODE_BASS_FIRST = 131 # C3, the bass note under the opening measure

  def test_the_first_song_plays_by_default_on_the_interpreter
    i = Reference.new.run(Jukebox.program, max_steps: 4000)
    assert_includes notes(i), [:note, :ode_to_joy, ODE_FIRST],
                    "the highlighted tune should sound its melody downbeat"
    assert_includes notes(i), [:note, :ode_to_joy, ODE_BASS_FIRST],
                    "the two-part arrangement should sound its bass under the melody"
  end

  # Move the cursor down one row and the second tune takes over the channel.
  def test_selecting_the_second_song_plays_it_on_the_interpreter
    i = Reference.new.input_each_frame(&tap_down(1)).run(Jukebox.program, max_steps: 4000)
    assert_includes notes(i), [:note, :fur_elise, ELISE_FIRST],
                    "selecting row 1 should play Fur Elise"
  end

  # SWITCHING SONGS IS A FADE, not a cut: the tune playing goes quiet first, the new one starts
  # while nothing can be heard, and then comes up. Read off the log in order — the last volume
  # any voice was set to before the new tune's first note is nothing, and after it the music is
  # loud again.
  def test_moving_the_cursor_fades_the_old_tune_out_before_the_new_one_comes_in
    log = Reference.new.input_each_frame(&tap_down(1)).run(Jukebox.program, frames: 80).audio
    start = log.index([:note, :fur_elise, ELISE_FIRST])

    refute_nil start, "the second tune starts"
    before = log[0...start].select { |entry| entry[0] == :loudness }
    after = log[start..].select { |entry| entry[0] == :loudness }

    assert_equal 0, before.last&.last, "the old tune is silent when the new one starts (#{before.inspect})"
    assert_operator before.map(&:last).max, :>, 0, "...having been heard before that"
    assert_operator after.map(&:last).max, :>, 0, "and the new tune comes up (#{after.inspect})"
  end

  # Two rows down lands on the third tune.
  def test_selecting_the_third_song_plays_it_on_the_interpreter
    i = Reference.new.input_each_frame(&tap_down(2)).run(Jukebox.program, max_steps: 4000)
    assert_includes notes(i), [:note, :minuet, MINUET_FIRST],
                    "selecting row 2 should play the Minuet"
  end

  # The three headings say they are centred, so the proof is that they LOOK centred:
  # the gap to the left of the lit pixels matches the gap to the right. Read off the
  # picture rather than recomputed from the font, so it would still catch a font that
  # measured itself wrong. The example used to multiply the character count by four
  # and every one of these lines sat left of centre — each by a different amount.
  HEADING_ROWS = { 14 => "JUKEBOX", 34 => "PRESS UP OR DOWN", 108 => "NOW PLAYING" }.freeze

  # The leftmost and rightmost columns anything is drawn in, over the rows one line of
  # text occupies.
  def lit_span(screen, y, height: 7)
    xs = (0...240).select { |x| (0...height).any? { |dy| screen.pixel(x, y + dy) != 0 } }
    refute_empty xs, "nothing is drawn at y=#{y}"
    [xs.first, xs.last]
  end

  def test_the_headings_are_genuinely_centred
    screen = Reference.new.run(Jukebox.program, max_steps: 4000).screen

    HEADING_ROWS.each do |y, text|
      left, right = lit_span(screen, y)
      assert_in_delta left, 239 - right, 1,
                      "#{text.inspect} sits #{left} from the left and #{239 - right} from the right"
    end
  end

  # The cursor is drawn beside the picked row, and moves with it. Worth pinning here
  # because the example drew ">" for a long time and nothing appeared: the built-in
  # font had no such glyph, so every frame drew an invisible cursor and the only thing
  # marking the picked row was its colour.
  ROW_TOPS = [50, 64, 78, 92].freeze

  def test_the_cursor_hangs_off_the_left_of_the_picked_row
    at_rest = Reference.new.run(Jukebox.program, max_steps: 4000).screen
    left_edges = ROW_TOPS.map { |y| lit_span(at_rest, y).first }

    assert_operator left_edges[0], :<, left_edges[1],
                    "the picked row starts further left, because the cursor is beside it"
    assert_equal left_edges[1], left_edges[2], "the other two rows line up with each other"

    moved = Reference.new.input_each_frame(&tap_down(1)).run(Jukebox.program, max_steps: 4000)
    after = ROW_TOPS.map { |y| lit_span(moved.screen, y).first }

    assert_operator after[1], :<, after[0], "the cursor followed the pick down a row"
  end

  # ...and the console dips too: loud, a stretch of quiet as the cursor moves, then loud again.
  def test_the_console_dips_between_tunes
    rom = Jukebox.build_rom(out: StringIO.new, err: StringIO.new)
    down = ->(frame) { (40..41).cover?(frame) ? RubyGBA::Constants::KEY_DOWN : 0 }
    energy = assert_emulator_loads_rom(rom, frames: 110, keys: down).audio_energy_by_frame
    loud = energy.max / 4

    assert_operator energy[20..38].max, :>, loud, "the first tune plays (#{energy.inspect})"
    assert_operator energy[42..70].min, :<, loud / 8, "it goes quiet as the cursor moves (#{energy.inspect})"
    assert_operator energy[85..].max, :>, loud, "and the next tune comes up (#{energy.inspect})"
  end

  # --- the piano tune and its sound effects ---

  # SOMEBODY AT THE JUKEBOX: moves the cursor down to the piano tune, waits for the chord it names
  # (:big, every voice the tune's; :small, four of them), and a few frames into it presses each of
  # +presses+ — a button, and how many frames after the first press it goes down. Each press is
  # held for three frames, so the game sees one press whether a pass of its loop takes one frame
  # or two. Handed whose each voice is on every frame, it answers the buttons held on that frame.
  #
  # IT WAITS FOR THE CHORD rather than for a frame number, because the two backends do not start
  # counting at the same moment — the console sets the game up before its first pass — so the
  # same frame number is a different moment of the tune on each. The chord is the same moment.
  class Listener
    TAP = 3

    attr_reader :pressed_at

    def initialize(chord:, presses:)
      @chord = chord
      @presses = presses
      @frame = 0
      @frames_in_chord = 0
    end

    def keys(owners)
      @frame += 1
      return taps_down if @frame <= 6 * TAP

      count_the_chord(owners) unless @pressed_at
      return [] unless @pressed_at || @frames_in_chord > 8

      @pressed_at ||= @frame
      @presses.filter_map { |button, after| button if (@frame - @pressed_at - after).between?(0, TAP - 1) }
    end

    private

    # Three taps of DOWN: row 0 to the piano tune on row 3.
    def taps_down = ((@frame - 1) / TAP).even? ? [:down] : []

    # How many frames running every voice has been the tune's chord.
    def count_the_chord(owners)
      voices = @chord == :big ? 16 : 4
      in_chord = owners.size == voices && owners.all? { |owner| owner.first == :song }
      @frames_in_chord = in_chord ? @frames_in_chord + 1 : 0
    end
  end

  # ONE FRAME OF THE JUKEBOX, as a test reads it: whose each voice was as the frame began, the
  # voices themselves and how loud the sound was over the frame (the console's only — the
  # interpreter mixes nothing).
  Moment = Data.define(:owners, :voices, :loudness)

  # A run of the jukebox on the interpreter with +listener+ at the buttons: every frame's Moment,
  # from the listener's first press on (from the start, when it never presses), and what the
  # run logged.
  def interpreted_jukebox(listener, frames:)
    i = Reference.new
    moments = []
    i.input_each_frame do |_frame|
      moments << Moment.new(owners: i.sound_owners, voices: nil, loudness: nil)
      listener.keys(moments.last.owners)
    end
    i.run(Jukebox.program, frames: frames)
    [from_the_press(moments, listener), i.audio]
  end

  # ...and on the console.
  def console_jukebox(listener, frames:)
    rom = Jukebox.build_rom(out: StringIO.new, err: StringIO.new)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "jukebox.gba")
      rom.write(path)
      probe = RubyGBA::Emulator.probe(path)
      moments = Array.new(frames) do
        voices = rom.built.voices.read { |address| probe.read32(address) }
        owners = voices.map(&:owner)
        probe.step(1, keys: listener.keys(owners))
        Moment.new(owners: owners, voices: voices, loudness: probe.audio_energy)
      end
      probe.close
      from_the_press(moments, listener)
    end
  end

  def from_the_press(moments, listener) = moments.drop((listener.pressed_at || 1) - 1)

  # The same listener's run on both backends: [interpreter, console], each from the first press.
  def on_both(frames:, **listening)
    [interpreted_jukebox(Listener.new(**listening), frames: frames).first,
     console_jukebox(Listener.new(**listening), frames: frames)]
  end

  HOORAY = [:"sfx.hooray", 0].freeze
  BLIP = [:"sfx.blip", 0].freeze
  BIG_CHORD = Array.new(16) { |part| [:song, part] }.freeze
  SMALL_CHORD = BIG_CHORD.first(4).freeze

  # HOORAY ON THE BIG CHORD takes a voice from the tune, which has every one; the part that lost
  # it has it back at the next big chord, two measures on.
  def test_hooray_takes_a_voice_from_the_tunes_big_chord_on_both_backends
    on_both(frames: 560, chord: :big, presses: [[:a, 0]]).each do |moments|
      assert_equal BIG_CHORD, moments.first.owners, "every voice is the tune's as A goes down"
      assert(moments.first(40).any? { |now| now.owners.include?(HOORAY) && now.owners.size == 16 },
             "HOORAY takes one of them")
      assert_equal BIG_CHORD, moments[250].owners, "and the tune has it back at its next big chord"
    end
  end

  # BLIP ranks below the tune: on the big chord there is no voice for it, and every voice is as it
  # would have been with nobody pressing B — on the small chord, it is heard.
  def test_blip_is_not_played_on_the_big_chord_and_is_on_the_small_one
    _, log = interpreted_jukebox(Listener.new(chord: :big, presses: [[:b, 0]]), frames: 300)
    pressed = on_both(frames: 300, chord: :big, presses: [[:b, 0]])
    nobody = on_both(frames: 300, chord: :big, presses: [])

    assert_includes log, [:sound_effect, :"sfx.blip"]
    pressed.zip(nobody).each do |with_b, without|
      assert_equal without.first(30).map(&:owners), with_b.first(30).map(&:owners), "the big chord, untouched"
    end
    on_both(frames: 200, chord: :small, presses: [[:b, 0]]).each do |moments|
      assert(moments.first(30).any? { |now| now.owners == SMALL_CHORD + [BLIP] }, "BLIP over the small chord")
    end
  end

  # A SECOND PRESS STARTS HOORAY AGAIN from its first note: the interpreter plays that note twice,
  # and on the console, a few frames after the second press, HOORAY's voice is reading the first
  # note's pitch again where its second note would otherwise be sounding.
  def test_hooray_pressed_again_starts_from_its_first_note
    _, log = interpreted_jukebox(Listener.new(chord: :small, presses: [[:a, 0], [:a, 7]]), frames: 200)

    assert_equal 2, log.count([:sound_effect, :"sfx.hooray"])
    assert_equal 2, log.count([:note, :"sfx.hooray", RubyGBA::Music::NOTE_FREQUENCIES[:C5]])
    moments = console_jukebox(Listener.new(chord: :small, presses: [[:a, 0], [:a, 7]]), frames: 200)
    steps = moments.first(30).map { |now| now.voices.find { |voice| voice.owner == HOORAY }&.step }
    first_note = steps.compact.first

    assert_equal first_note, steps[14], "the first note again, where the second was due (#{steps.inspect})"
  end

  # HOORAY KEEPS SOUNDING, AT ITS OWN VOLUME, while the music fades: A, then DOWN moves the cursor
  # off the tune. Both backends keep its voice through the fade; the console says how loud.
  def test_hooray_does_not_fade_with_the_music
    both = on_both(frames: 200, chord: :small, presses: [[:a, 0], [:down, 2]])
    both.each do |moments|
      assert_operator moments.first(25).count { |now| now.owners.include?(HOORAY) }, :>, 15, "HOORAY sounds through the fade"
    end

    moments = both.last
    hooray = moments.first(25).filter_map { |now| now.voices.find { |voice| voice.owner == HOORAY }&.volume }
    tune = moments.first(25).map { |now| now.voices.select { |voice| voice.owner.first == :song }.sum(&:volume) }
    assert_equal [hooray.first], hooray.uniq, "at one volume"
    assert_operator tune.last, :<, tune.first, "while the tune goes quiet"
  end

  # HOORAY OVER THE SMALL CHORD, heard on the console: louder than the same frames with nobody
  # pressing A, and once it has ended, frame for frame as loud as those — the tune was not
  # touched and did not slip.
  def test_hooray_adds_to_the_sound_and_leaves_the_tune_as_it_was
    pressed = console_jukebox(Listener.new(chord: :small, presses: [[:a, 0]]), frames: 200)
    quiet = console_jukebox(Listener.new(chord: :small, presses: []), frames: 200) # waits for the same frame

    assert_operator pressed.first(40).sum(&:loudness), :>, quiet.first(40).sum(&:loudness), "HOORAY is heard"
    assert_equal quiet[60, 60].map(&:loudness), pressed[60, 60].map(&:loudness), "and after it, the tune as it was"
  end

  # On real hardware: the ROM boots and the music channel is actually driven.
  def test_the_music_channel_is_driven_on_the_console
    rom = Jukebox.build_rom(out: StringIO.new, err: StringIO.new)
    v = assert_emulator_loads_rom(rom, frames: 12)
    assert v.sound?, "the highlighted tune should drive the music channel"
  end
end
