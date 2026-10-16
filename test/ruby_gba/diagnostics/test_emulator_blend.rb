# frozen_string_literal: true

require "test_helper"
require "emulator_blend"

# The interpreter's display effects against the emulator's own arithmetic, over the whole
# domain rather than sampled: every 5-bit channel value against every amount.
#
# Both are exact. The interpreter works the display's fade and tint out the way the
# emulator does — at eight bits a channel, and for the fade with green and blue rounding
# the other way from red, so one gray faded a quarter of the way to black is 24, 23, 23 —
# and this holds it to that at every value, amount and channel.
class TestEmulatorBlend < Minitest::Test
  runs_on :reference

  Framebuffer = RubyGBA::IR::Backends::Reference::Framebuffer

  CHANNELS = (0..31).to_a.freeze
  AMOUNTS = (0..100).to_a.freeze

  # What the console shows for a one-cell screen of +color+ under a fade — the real
  # implementation, not a copy of it.
  private def console_shows(color, toward, amount)
    screen = Framebuffer.new(width: 1, height: 1, fill: color)
    screen.fade_to(toward, amount)
    screen.pixel(0, 0)
  end

  private def channel_of(color, field)
    (color >> (field * 5)) & 0x1F
  end

  # What the console shows under a tint, again through the real implementation.
  private def console_tints(color, toward, amount)
    screen = Framebuffer.new(width: 1, height: 1, fill: color)
    screen.tint_to(toward, amount)
    screen.pixel(0, 0)
  end

  # Every value, every amount, both fade directions, all three channels.
  private def each_fade_deviation
    return enum_for(:each_fade_deviation) unless block_given?

    %i[black white].each do |toward|
      CHANNELS.each do |value|
        AMOUNTS.each do |amount|
          y = EmulatorBlend.steps_of(amount)
          3.times do |field|
            console = channel_of(console_shows(value << (field * 5), toward, amount), field)
            emulator = if toward == :black
                         EmulatorBlend.darkened(value, y, field)
                       else
                         EmulatorBlend.brightened(value, y, field)
                       end
            yield [emulator - console,
                   { effect: "fade #{toward}", value: value, amount: amount, field: field }]
          end
        end
      end
    end
  end

  # A tint mixes two colors, so the sweep is every picture value against every tint
  # value. The amounts walk one percentage per distinct sixteenth rather than all
  # hundred, which is the same domain without a hundred repeats of each step.
  private def each_tint_deviation
    return enum_for(:each_tint_deviation) unless block_given?

    EmulatorBlend.percents_for_every_step.each do |amount|
      steps = EmulatorBlend.steps_of(amount)
      CHANNELS.each do |have|
        CHANNELS.each do |want|
          3.times do |field|
            shift = field * 5
            console = channel_of(console_tints(have << shift, want << shift, amount), field)
            emulator = EmulatorBlend.mixed(have, EmulatorBlend::STEPS - steps, want, steps, field)
            yield [emulator - console,
                   { effect: "tint", have: have, want: want, amount: amount, field: field }]
          end
        end
      end
    end
  end

  def test_the_interpreter_fades_exactly_as_the_emulator_does
    off = each_fade_deviation.reject { |delta, _| delta.zero? }

    assert_empty off.first(5), "#{off.size} channels differ from the emulator's fade"
  end

  def test_the_interpreter_tints_exactly_as_the_emulator_does
    off = each_tint_deviation.reject { |delta, _| delta.zero? }

    assert_empty off.first(5), "#{off.size} channels differ from the emulator's tint"
  end

  # The case that shows the widening, pinned as a number rather than against the
  # transcription: a channel at 16 mixed half way toward 31 is 24 at eight bits, where five
  # bits say 23.
  def test_a_channel_half_way_from_sixteen_to_the_top_is_twenty_four
    assert_equal 24, channel_of(console_tints(16, 31, 50), 0)
  end

  # The quirk the fade has to copy, pinned so it cannot change unnoticed: the emulator
  # divides the red channel on its raw byte and the other two on their shifted fields, so
  # a uniform gray comes back with unequal channels. 24 is a channel that LOST a truncated
  # share; 23 is one that KEPT one.
  def test_the_emulator_treats_the_red_channel_differently
    y = EmulatorBlend.steps_of(25)
    per_channel = 3.times.map { |field| EmulatorBlend.darkened(31, y, field) }

    assert_equal [24, 23, 23], per_channel, "red truncates coarser than green and blue"
  end
end
