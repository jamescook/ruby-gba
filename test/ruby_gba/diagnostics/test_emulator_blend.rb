# frozen_string_literal: true

require "test_helper"
require "emulator_blend"
require "differential"

# The slack the whole-screen comparison allows a blended pixel, PROVED over its whole
# domain rather than sampled.
#
# The comparison lets the emulator be up to Differential::EMULATOR_BLEND_SLACK steps out
# on a blended channel, either way. Both directions are real and neither can be dropped:
# the emulator evaluates one expression per channel, on the channel's own value for red
# and on a shifted field for green and blue, which moves where the rounding falls — so
# for one gray faded a quarter of the way to black it hands back 24, 23, 23. Whatever the
# display really does, one of those reads low and the other reads high.
#
# So this walks every 5-bit channel value against every amount, comparing what the
# console does with what the emulator's own arithmetic does, and asserts the bound holds
# everywhere and is TIGHT ON EACH SIDE — if a change makes it looser, this fails and says
# so instead of the slack quietly covering more than it was measured to.
#
# WHAT THE SLACK IS NOT FOR. It cannot tell one rounding rule from another, because a
# rule change is exactly one step. The rule is pinned elsewhere and exactly:
# test_fade.rb walks all seventeen levels on the console's red channel, which is the one
# the emulator computes as written.
class TestEmulatorBlend < Minitest::Test
  include Differential

  Framebuffer = RubyGBA::IR::Backends::Reference::Framebuffer

  CHANNELS = (0..31).to_a.freeze
  AMOUNTS = (0..100).to_a.freeze

  # What the console shows for a one-cell screen of +color+ under a fade — the real
  # implementation, not a copy of it.
  def console_shows(color, toward, amount)
    screen = Framebuffer.new(width: 1, height: 1, fill: color)
    screen.fade_to(toward, amount)
    screen.pixel(0, 0)
  end

  def channel_of(color, field)
    (color >> (field * 5)) & 0x1F
  end

  # What the console shows under a tint, again through the real implementation.
  def console_tints(color, toward, amount)
    screen = Framebuffer.new(width: 1, height: 1, fill: color)
    screen.tint_to(toward, amount)
    screen.pixel(0, 0)
  end

  # Every value, every amount, both fade directions and the tint, all three channels.
  def each_deviation
    return enum_for(:each_deviation) unless block_given?

    each_fade_deviation { |d| yield d }
    each_tint_deviation { |d| yield d }
  end

  def each_fade_deviation
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
  def each_tint_deviation
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

  def test_the_emulator_never_reads_further_below_than_the_slack_allows
    worst = each_deviation.min_by { |delta, _| delta }

    assert_operator worst.first, :>=, -EMULATOR_BLEND_SLACK,
                    "the emulator read #{worst.first} steps low at #{worst.last.inspect}, " \
                    "past the slack of #{EMULATOR_BLEND_SLACK}"
  end

  def test_the_emulator_never_reads_further_above_than_the_slack_allows
    worst = each_deviation.max_by { |delta, _| delta }

    assert_operator worst.first, :<=, EMULATOR_BLEND_SLACK,
                    "the emulator read #{worst.first} steps high at #{worst.last.inspect}, " \
                    "past the slack of #{EMULATOR_BLEND_SLACK}"
  end

  # The slack is not larger than it needs to be, on EITHER side. If this fails because a
  # real worst case shrank, tighten EMULATOR_BLEND_SLACK to match — a slack wider than
  # the measurement is coverage given away for nothing. If one side goes to nought, the
  # slack has stopped being symmetric and the comparison can say so instead.
  def test_the_slack_is_tight_in_both_directions
    deltas = each_deviation.map(&:first)

    assert_equal [-EMULATOR_BLEND_SLACK, EMULATOR_BLEND_SLACK], [deltas.min, deltas.max],
                 "the worst readings are #{deltas.min} and #{deltas.max}, so the slack can be exactly that"
  end

  # The quirk that causes all of this, pinned so it cannot change unnoticed: the emulator
  # divides the red channel on its raw byte and the other two on their shifted fields, so
  # a uniform gray comes back with unequal channels.
  #
  # The two answers are the two rules a fade could follow. 24 is a channel that LOST a
  # truncated share, which is what the display does and what the interpreter now does;
  # 23 is one that KEPT a truncated share. So this is not only where the slack comes
  # from, it is why the emulator cannot settle the rule on its own.
  def test_the_emulator_treats_the_red_channel_differently
    y = EmulatorBlend.steps_of(25)
    per_channel = 3.times.map { |field| EmulatorBlend.darkened(31, y, field) }

    assert_equal [24, 23, 23], per_channel,
                 "red truncates coarser than green and blue — this is what the slack is for"
  end
end
