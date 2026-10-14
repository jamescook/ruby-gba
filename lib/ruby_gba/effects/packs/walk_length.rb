# frozen_string_literal: true

module RubyGBA
  module Effects
    module Packs
      # HOW MANY STEPS AN EFFECT WALKED OVER FRAMES TAKES, from the `frames:` or `duration:`
      # its verb was given — the one reading every walk shares (a pixelate, an iris), so
      # each says the same thing about a length that makes no sense.
      #
      # It counts the first frame and the last, as the screen fade counts its own: a walk of
      # ten frames is nine steps, landing on the tenth.
      module WalkLength
        module_function

        # +named+ is how the effect is called in a sentence, `a pixelate` or `an iris`.
        def steps(frames, duration, default, named)
          raise ArgumentError, "#{named} takes frames: or duration:, not both." if frames && duration

          count = duration ? seconds_in_frames(duration, named) : (frames || default)
          unless DSL::Whole.positive?(count)
            raise ArgumentError, "#{named} needs a positive whole number of frames. You gave #{(frames || duration).inspect}."
          end

          [count - 1, 1].max
        end

        def seconds_in_frames(duration, named)
          unless duration.is_a?(Numeric) && duration.positive?
            raise ArgumentError, "#{named} needs a positive duration in seconds. You gave #{duration.inspect}."
          end

          (duration * Builder::ControlFlow::FRAMES_PER_SECOND).round
        end
      end
    end
  end
end
