# frozen_string_literal: true

require_relative "test_helper"

# Tests for Probe#sound_feed — where each sample the recorded-sound channel played came from.
#
# The game plays one recording on a loop and does nothing else, so the mixer writes a buffer each
# frame and the channel plays it the next. While the screen draws its picture the channel plays the
# buffer the mixer finished the frame before, which nothing writes until the next frame begins: so
# every sample played on those lines can be checked against the byte at its address once the frame
# is over, which is the check that the feed says the truth.
class TestRubyGBAEmulatorSoundFeed < Minitest::Test
  include RubyGBAEmulatorTestSupport

  # A ramp from quiet to loud and back, so neighbouring samples differ and a sample put down to the
  # wrong address reads as the wrong number.
  RAMP = ((-100..100).step(4).to_a + (-100..100).step(4).to_a.reverse).freeze

  # The lines the screen draws its picture on, when the channel plays the buffer mixed the frame
  # before and nothing writes to it.
  PICTURE_LINES = (1..159)

  # The console's roomy work memory, where the mixer keeps its buffers.
  ROOMY_MEMORY = (0x0200_0000...0x0204_0000)

  # The console's sound switches, written as words: the master switch; the half that sends channel
  # A to both speakers at full volume, clocked by timer 0 (the upper half of the word at 0x80); and
  # timer 0, running and counting from 0xFC00, so it runs out every 1024 cycles.
  SOUND_MASTER = 0x0400_0084
  SOUND_ON = 0x80
  SOUND_MIXING = 0x0400_0080
  CHANNEL_A_BOTH_SIDES_ON_TIMER_0 = 0x0304 << 16
  TIMER_0 = 0x0400_0100
  TIMER_RUNNING_EVERY_1024_CYCLES = (0x0080 << 16) | 0xFC00

  def test_every_sample_played_while_the_picture_is_drawn_is_the_byte_at_its_address
    with_probe(looping_recording_rom) do |probe|
      probe.step(10)
      checked = probe.sound_feed(frames: 1).played.select { |sample| PICTURE_LINES.cover?(sample.line) }

      refute_empty checked, "a recording on a loop plays samples while the picture is drawn"
      checked.each do |sample|
        assert_includes ROOMY_MEMORY, sample.from, "the mixer's buffers are in the roomy memory"
        assert_equal signed_byte(probe.read8(sample.from)), sample.value,
                     format("the sample played on line %d came from 0x%08x", sample.line, sample.from)
      end
    end
  end

  def test_a_buffer_is_played_one_byte_after_another
    with_probe(looping_recording_rom) do |probe|
      probe.step(10)
      checked = probe.sound_feed(frames: 1).played.select { |sample| PICTURE_LINES.cover?(sample.line) }
      steps = checked.each_cons(2).map { |a, b| b.from - a.from }

      assert_equal [1], steps.uniq, "the channel plays its buffer in order, one byte at a time"
    end
  end

  # Each word the copy engine put in the queue is played, four samples to the word, from the same
  # place: what the queue was fed and what it played are one story.
  def test_what_is_played_comes_from_the_words_that_were_fetched
    with_probe(looping_recording_rom) do |probe|
      probe.step(10)
      assert_played_from_fetched_words(probe.sound_feed(frames: 2))
    end
  end

  # FRAMES NOBODY RECORDED, between two feeds, put words in the queue that the first feed never saw
  # arrive. The second must not say they came from where the first feed's words did: it says it
  # does not know, which is address 0, and everything else it played it saw fetched.
  def test_a_feed_after_unrecorded_frames_does_not_guess_where_the_queue_came_from
    with_probe(looping_recording_rom) do |probe|
      probe.step(10)
      probe.sound_feed(frames: 1)
      probe.step(3)
      assert_played_from_fetched_words(probe.sound_feed(frames: 2))
    end
  end

  # ...and asked a frame at a time with nothing between, it is one feed: only the very first samples
  # say they do not know.
  def test_feeds_one_after_another_are_one_feed
    with_probe(looping_recording_rom) do |probe|
      probe.step(10)
      probe.sound_feed(frames: 1)
      unknown = probe.sound_feed(frames: 1).played.count { |sample| sample.from&.zero? }

      assert_equal 0, unknown, "the second frame knows where every sample came from"
    end
  end

  # WHEN A SAMPLE WAS DUE is the timer's, and the timer runs out at an even pace: so the times the
  # samples fell due are one period apart, however late the emulator got to each behind whatever
  # instruction was running. The times it got to them are not, which is what +late+ is for.
  def test_samples_fall_due_one_timer_period_apart
    with_probe(looping_recording_rom) do |probe|
      probe.step(10)
      played = probe.sound_feed(frames: 2).played.reject { |sample| sample.from&.zero? }
      gaps = played.each_cons(2).map { |a, b| b.due - a.due }

      assert_equal 1, gaps.uniq.size, "every sample falls due one period after the last (#{gaps.tally})"
      assert_operator gaps.first, :>, 0
    end
  end

  # A QUEUE THAT RUNS DRY plays silence, and the feed says so rather than leaving a hole. A game
  # whose mixer keeps up never lets it...
  def test_a_mixer_that_keeps_up_never_runs_dry
    with_probe(looping_recording_rom) do |probe|
      probe.step(10)
      assert_equal 0, probe.sound_feed(frames: 2).played.count(&:silence?)
    end
  end

  # ...so the channel is switched on and clocked by hand in a game that plays nothing: its timer
  # asks for a sample over and over, and nothing ever puts one in the queue.
  def test_a_queue_nothing_feeds_plays_silence_and_says_so
    with_probe(silent_rom) do |probe|
      probe.step(5)
      probe.write32(SOUND_MASTER, SOUND_ON)
      probe.write32(SOUND_MIXING, CHANNEL_A_BOTH_SIDES_ON_TIMER_0)
      probe.write32(TIMER_0, TIMER_RUNNING_EVERY_1024_CYCLES)
      played = probe.sound_feed(frames: 1).played

      assert_operator played.size, :>, 200, "the timer runs out about 274 times a frame"
      assert(played.all? { |sample| sample.silence? && sample.value.zero? }, "and every time there is nothing to play")
    end
  end

  def test_frames_must_be_positive
    with_probe(looping_recording_rom) do |probe|
      assert_raises(ArgumentError) { probe.sound_feed(frames: 0) }
    end
  end

  private

  def looping_recording_rom
    ramp = RAMP
    build_rom("FEED", code: "FEED") do
      screen :bitmap
      clear_screen :black
      tone = sample :ramp, pcm: ramp, rate: 8192
      tone.play(loop: true)
      game_loop {}
    end
  end

  def silent_rom
    build_rom("HUSH", code: "HUSH") do
      screen :bitmap
      clear_screen :black
      game_loop {}
    end
  end

  # The console's memory reads a byte back unsigned; a sample is signed.
  def signed_byte(byte) = byte >= 128 ? byte - 256 : byte

  # Every sample whose address the feed knows came from a word it saw fetched, and is that word's
  # byte at that place.
  def assert_played_from_fetched_words(feed)
    fetched = feed.fetched.to_h { |word| [word.from, word.word] }
    known = feed.played.reject { |sample| sample.silence? || sample.from.zero? }

    assert_operator known.size, :>, 100, "most of the samples come from words fetched in the feed"
    known.each do |sample|
      word = fetched.fetch(sample.from & ~3) { flunk format("0x%08x was never fetched in this feed", sample.from) }
      assert_equal signed_byte((word >> (8 * (sample.from & 3))) & 0xFF), sample.value
    end
  end
end
