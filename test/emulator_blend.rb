# frozen_string_literal: true

# WHAT THE EMULATOR DOES TO A BLENDED PIXEL, transcribed from its own source so the
# slack the whole-screen comparison allows can be PROVED rather than sampled.
#
# The console blends in the five bits a channel actually has. The emulator we test
# against is built for 32-bit color, so it first widens each channel to eight bits and
# blends there — a different arithmetic that lands a step or two away.
#
# The asymmetry that makes this worth writing down: the emulator divides the RED channel
# on its raw byte and the GREEN and BLUE channels on their shifted fields, which are 256
# times finer. So the three channels truncate differently and a uniform gray comes back
# with unequal channels. It is a quirk of that renderer, not of the console.
#
#     a = color & 0xFF;     c |= (a - (a * y) / 16) & 0xFF;      // red
#     a = color & 0xFF00;   c |= (a - (a * y) / 16) & 0xFF00;    // green
#     a = color & 0xFF0000; c |= (a - (a * y) / 16) & 0xFF0000;  // blue
#
# Only the darken/brighten pair is needed here; the alpha mix has the same shape.
module EmulatorBlend
  CHANNEL_MAX = 31
  STEPS = 16

  # A 5-bit channel widened to eight bits the way the emulator widens one: the top three
  # bits repeated into the bottom, so the top of the range reaches 255 exactly.
  def self.widen(value)
    (value << 3) | (value >> 2)
  end

  # ...and back down, the way the frame is read.
  def self.narrow(value)
    value >> 3
  end

  # One channel taken toward black by +y+ sixteenths, in the emulator's arithmetic.
  # +field+ is which channel it is (0 red, 1 green, 2 blue), because that decides how far
  # up the value sits while it is divided — which is the whole of the difference.
  def self.darkened(value, y, field)
    shift = field * 8
    a = widen(value) << shift
    narrow(((a - ((a * y) / STEPS)) & (0xFF << shift)) >> shift)
  end

  # The same toward white.
  def self.brightened(value, y, field)
    shift = field * 8
    a = widen(value) << shift
    top = 0xFF << shift
    narrow(((a + (((top - a) * y) / STEPS)) & top) >> shift)
  end

  # Two channels mixed, weighted, in the emulator's arithmetic — what a tint reaches the
  # screen as. Same per-field asymmetry as the pair above, and it saturates at the top of
  # the byte rather than wrapping.
  #
  #     a = colorA & 0xFF;   b = colorB & 0xFF;   c |= ((a * wA + b * wB) / 16) & 0x1FF;
  #     ...then clamped to 0xFF if it overflowed
  def self.mixed(value_a, weight_a, value_b, weight_b, field)
    shift = field * 8
    a = widen(value_a) << shift
    b = widen(value_b) << shift
    top = 0xFF << shift
    c = ((a * weight_a) + (b * weight_b)) / STEPS
    narrow((c > top ? top : c & top) >> shift)
  end

  # How far a percentage is, in the sixteenths the blend counts in — the same conversion
  # the lowering emits.
  def self.steps_of(percent)
    ((percent * STEPS) / 100).clamp(0, STEPS)
  end

  # A percentage for each distinct number of sixteenths, so a sweep covers the real
  # domain without walking a hundred percentages that collapse onto the same step.
  def self.percents_for_every_step
    (0..STEPS).map { |step| (step * 100.0 / STEPS).ceil }
  end
end
