# frozen_string_literal: true

require "test_helper"
require "mixed_sound"

require "stringio"
require VBlank.root.join("examples/jukebox").to_s

# Somebody at the jukebox, and what the run's player and the Advance's cartridge are each held
# to with them there, kept once for the cartridge's tests
# (test/lowering/gba/examples/test_jukebox_example_cartridge.rb).
module JukeboxListening
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
  # voices themselves, how loud the sound was over the frame, and every sample the console's
  # recorded-sound channel played in it, as its value and the cycle it fell due (the last three the
  # console's only — the interpreter mixes nothing).
  Moment = Data.define(:owners, :voices, :loudness, :played)

  HOORAY = Ractor.make_shareable([:"sfx.hooray", 0])
  BLIP = Ractor.make_shareable([:"sfx.blip", 0])
  BIG_CHORD = Ractor.make_shareable(Array.new(16) { |part| [:song, part] })
  SMALL_CHORD = Ractor.make_shareable(BIG_CHORD.first(4))

  # A, then DOWN two frames later: HOORAY, and the cursor moving off the tune so the music fades.
  HOORAY_THEN_DOWN = Ractor.make_shareable({ chord: :small, presses: [[:a, 0], [:down, 2]] })

  # A run of the jukebox on the interpreter with +listener+ at the buttons: every frame's Moment,
  # from the listener's first press on (from the start, when it never presses), and what the
  # run logged.
  private def interpreted_jukebox(listener, frames:)
    i = game_player
    moments = []
    i.input_each_frame do |_frame|
      moments << Moment.new(owners: i.sound_owners, voices: nil, loudness: nil, played: nil)
      listener.keys(moments.last.owners)
    end
    i.run(Jukebox.program, frames: frames)
    [from_the_press(moments, listener), i.audio]
  end

  private def from_the_press(moments, listener) = moments.drop((listener.pressed_at || 1) - 1)

  # HOORAY ON THE BIG CHORD, in +moments+ from A going down: every voice is the tune's, HOORAY
  # takes one of them, and the tune has it back at its next big chord.
  private def assert_hooray_takes_a_voice_from_the_big_chord(moments)
    assert_equal BIG_CHORD, moments.first.owners, "every voice is the tune's as A goes down"
    assert(moments.first(40).any? { |now| now.owners.include?(HOORAY) && now.owners.size == 16 },
           "HOORAY takes one of them")
    assert_equal BIG_CHORD, moments[250].owners, "and the tune has it back at its next big chord"
  end

  # BLIP, from three runs: B on the big chord, nobody on the big chord, and B on the small chord.
  private def assert_blip_waits_for_a_voice(pressed, nobody, small)
    assert_equal nobody.first(30).map(&:owners), pressed.first(30).map(&:owners), "the big chord, untouched"
    assert(small.first(30).any? { |now| now.owners == SMALL_CHORD + [BLIP] }, "BLIP over the small chord")
  end

  # HOORAY_THEN_DOWN's +moments+: HOORAY's voice is kept through the fade.
  private def assert_hooray_sounds_through_the_fade(moments)
    assert_operator moments.first(25).count { |now| now.owners.include?(HOORAY) }, :>, 15, "HOORAY sounds through the fade"
  end
end

# The Jukebox example (examples/jukebox.rb): the sound showcase. Three classical
# melodies written with the note/tempo DSL; the cursor picks one and it plays and
# loops on the music channel. This asserts what the player hears — the highlighted
# tune's notes actually fire — on the run's own player. The cartridge read back in the
# emulator is in test/lowering/gba/examples/test_jukebox_example_cartridge.rb.
class TestJukeboxExample < Minitest::Test
  include MixedSound
  include JukeboxListening

  # The opening (downbeat) note of each tune, in Hz — distinct so each is a
  # diagnostic value. If the frame-0 fix regressed, these would never sound.
  ODE_FIRST    = 330 # E4
  ELISE_FIRST  = 659 # E5
  MINUET_FIRST = 587 # D5

  # A per-frame input that taps DOWN +n+ times, one edge per tap, then holds
  # nothing — leaving the cursor parked on row n. The interpreter samples the
  # script from frame 1, so the presses land on odd frames (1, 3, ...) with a
  # released frame between them, and each is a fresh rising edge the cursor moves on.
  private def tap_down(times)
    down_frames = Array.new(times) { |k| 1 + k * 2 }
    ->(f) { down_frames.include?(f) ? [:down] : [] }
  end

  private def notes(interpreter)
    interpreter.audio.select { |e| e[0] == :note }
  end

  # Row 0 is selected at the start, so the first tune plays with no input and
  # sounds its opening note. Ode to Joy is a two-part arrangement, so both the
  # melody's downbeat and the bass note under it sound together on frame 0.
  ODE_BASS_FIRST = 131 # C3, the bass note under the opening measure

  def test_the_first_song_plays_by_default_on_the_interpreter
    i = game_player.run(Jukebox.program, max_steps: 4000)
    assert_includes notes(i), [:note, :ode_to_joy, ODE_FIRST],
                    "the highlighted tune should sound its melody downbeat"
    assert_includes notes(i), [:note, :ode_to_joy, ODE_BASS_FIRST],
                    "the two-part arrangement should sound its bass under the melody"
  end

  # Move the cursor down one row and the second tune takes over the channel.
  def test_selecting_the_second_song_plays_it_on_the_interpreter
    i = game_player.input_each_frame(&tap_down(1)).run(Jukebox.program, max_steps: 4000)
    assert_includes notes(i), [:note, :fur_elise, ELISE_FIRST],
                    "selecting row 1 should play Fur Elise"
  end

  # SWITCHING SONGS IS A FADE, not a cut: the tune playing goes quiet first, the new one starts
  # while nothing can be heard, and then comes up. Read off the log in order — the last volume
  # any voice was set to before the new tune's first note is nothing, and after it the music is
  # loud again.
  def test_moving_the_cursor_fades_the_old_tune_out_before_the_new_one_comes_in
    log = game_player.input_each_frame(&tap_down(1)).run(Jukebox.program, frames: 80).audio
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
    i = game_player.input_each_frame(&tap_down(2)).run(Jukebox.program, max_steps: 4000)
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
  private def lit_span(screen, y, height: 7)
    xs = (0...240).select { |x| (0...height).any? { |dy| screen.pixel(x, y + dy) != 0 } }
    refute_empty xs, "nothing is drawn at y=#{y}"
    [xs.first, xs.last]
  end

  def test_the_headings_are_genuinely_centred
    screen = game_player.run(Jukebox.program, max_steps: 4000).screen

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
    at_rest = game_player.run(Jukebox.program, max_steps: 4000).screen
    left_edges = ROW_TOPS.map { |y| lit_span(at_rest, y).first }

    assert_operator left_edges[0], :<, left_edges[1],
                    "the picked row starts further left, because the cursor is beside it"
    assert_equal left_edges[1], left_edges[2], "the other two rows line up with each other"

    moved = game_player.input_each_frame(&tap_down(1)).run(Jukebox.program, max_steps: 4000)
    after = ROW_TOPS.map { |y| lit_span(moved.screen, y).first }

    assert_operator after[1], :<, after[0], "the cursor followed the pick down a row"
  end

  # The console dipping between tunes, and the music channel driven on it, read in the emulator,
  # are in test/lowering/gba/examples/test_jukebox_example_cartridge.rb.

  # --- the piano tune and its sound effects ---

  # HOORAY ON THE BIG CHORD takes a voice from the tune, which has every one; the part that lost
  # it has it back at the next big chord, two measures on.
  def test_hooray_takes_a_voice_from_the_tunes_big_chord
    assert_hooray_takes_a_voice_from_the_big_chord(interpreted_jukebox(Listener.new(chord: :big, presses: [[:a, 0]]),
                                                                       frames: 560).first)
  end

  # BLIP ranks below the tune: on the big chord there is no voice for it, and every voice is as it
  # would have been with nobody pressing B — on the small chord, it is heard.
  def test_blip_is_not_played_on_the_big_chord_and_is_on_the_small_one
    pressed, log = interpreted_jukebox(Listener.new(chord: :big, presses: [[:b, 0]]), frames: 300)

    assert_includes log, [:sound_effect, :"sfx.blip"]
    assert_blip_waits_for_a_voice(pressed,
                                  interpreted_jukebox(Listener.new(chord: :big, presses: []), frames: 300).first,
                                  interpreted_jukebox(Listener.new(chord: :small, presses: [[:b, 0]]), frames: 200).first)
  end

  # A SECOND PRESS STARTS HOORAY AGAIN from its first note: the interpreter plays that note twice.
  # (On the console HOORAY's voice reads the first note's pitch again where its second note would
  # otherwise be sounding: that is in the cartridge's tests.)
  def test_hooray_pressed_again_starts_from_its_first_note
    _, log = interpreted_jukebox(Listener.new(chord: :small, presses: [[:a, 0], [:a, 7]]), frames: 200)

    assert_equal 2, log.count([:sound_effect, :"sfx.hooray"])
    assert_equal 2, log.count([:note, :"sfx.hooray", VBlank::Audio::Music::NOTE_FREQUENCIES[:C5]])
  end

  # HOORAY KEEPS SOUNDING while the music fades: A, then DOWN moves the cursor off the tune. Its
  # voice is kept through the fade. (How loud it is, the console says: in the cartridge's tests.)
  def test_hooray_does_not_fade_with_the_music
    assert_hooray_sounds_through_the_fade(interpreted_jukebox(Listener.new(**HOORAY_THEN_DOWN), frames: 200).first)
  end

  # A WHOLE PIECE OF REAL MUSIC, BYTE FOR BYTE: moved up to the piano chords (which fades the
  # tune out, switches, and fades the chords in, a dozen recorded voices at once), with HOORAY
  # asked for over them — every byte of sound the cartridge's mixer writes, worked out by the
  # interpreter too (see MixedSound).
  def test_the_interpreter_makes_the_same_bytes_of_sound_as_the_cartridge
    assert_mixes_agree(Jukebox.program, frames: 150, presses: { 5 => [:up], 6 => [:up], 60 => [:a], 61 => [:a] },
                                        at_least: 60)
  end
end
