# frozen_string_literal: true

module RubyGBA
  class Builder
    # The randomness verbs: a deterministic pseudo-random number stream.
    #
    # There's no dice in the console — "random" is really a hidden number the game
    # keeps churning, so we own it completely: the same seed always replays the
    # same sequence, on every boot and on every backend (the churn is plain
    # multiply-and-add, which the interpreter and the console agree on to the bit).
    # That determinism is a feature — a game can seed a constant and play out
    # identically every time (handy for tests and attract-mode demos), and only opt
    # in to unpredictability by seeding from something the player can't predict.
    #
    # A concern of {Builder}: mixed in, so seed/roll/rand/chance are flat DSL verbs.
    # It leans on the builder core (record, ensure_var, at_boot) for everything else.
    module Randomness
      # The hidden variable holding the stream's state. Every draw churns it; the
      # game never sees it (underscore-prefixed, like the other machinery vars).
      RNG_STATE = :__rng

      # How the stream churns: state = state * MULT + INC, which overflows past a
      # 32-bit number and wraps around — and that wraparound *is* the trick that
      # makes the next number look unrelated to the last (see IR::Int32, where the
      # wrap is pinned so every backend churns the number identically). These
      # particular constants (from Numerical Recipes) make it cycle through every
      # possible 32-bit value before repeating, so the stream never gets stuck.
      RNG_MULT = 1_664_525
      RNG_INC  = 1_013_904_223

      # A draw reads the *top* of the state, not the bottom: churned this way, the
      # low bits fall into a short, obvious rhythm (a coin flip off the last bit
      # would just go 0,1,0,1…), while the high bits look random. Dividing by 2**16
      # brings the top 16 bits down to where we can use them.
      RNG_HIGH_DIV = 65_536

      # The most values a single draw can span. Because a draw comes from the top 16
      # bits, it only distinguishes about this many outcomes — ask for a wider spread
      # and the top of the range would never come up. It comfortably covers the whole
      # screen (240x160) and every 15-bit color, so real game ranges never hit it.
      MAX_ROLL_SPAN = RNG_HIGH_DIV / 2

      # Where the stream starts when a game never calls +seed+. Any fixed value keeps
      # an unseeded game reproducible; it has to be written explicitly at boot because
      # console memory isn't reliably zero when the machine powers on (the same reason
      # the input snapshots are cleared up front).
      DEFAULT_SEED = 0x2545_F491

      # Seed the random stream. The same seed replays the exact same sequence every
      # time — so `seed 42` makes a game deterministic (great for a test or a demo
      # that must play out identically). +n+ may be a number, a variable, or an
      # expression Value; seeding from a value the player influences (say, how long
      # they waited before pressing START) is how you make each playthrough differ.
      #
      # @param n [Integer, Symbol, Value] the stream's new starting point
      def seed(n)
        use_rng!
        record(Build.set(RNG_STATE, Value.node_for(n)))
        ensure_var(n)
      end

      # Stir the stream by one step — the way to make a game unpredictable. The
      # console has no true randomness, so the entropy has to come from the one thing
      # nobody can predict: *when* the player acts. Call this every frame while you
      # wait for them, and the stream keeps moving; whatever spot it lands on when
      # they finally press the button is decided by their reaction time, so each
      # playthrough differs. A game that never calls it stays perfectly reproducible.
      #
      #   scene :title do
      #     draw_text "PRESS START", 76, 100, :gray
      #     randomize                              # keep stirring while we wait
      #     if_pressed(:start) { call :new_game }  # start from wherever it landed
      #   end
      def randomize
        use_rng!
        churn_rng
      end

      # Draw a random whole number in +range+ into the variable +name+, churning the
      # stream. +range+ is an ordinary Ruby range:
      #
      #   roll :enemy_x, 0..239      # somewhere across the screen
      #   roll :dir, 0..1            # a coin flip
      #   roll :dx, -2..2            # a nudge left or right
      #
      # @param name [Symbol] the variable to store the draw in
      # @param range [Range] the inclusive/exclusive range to draw from
      # @return [Value] a handle to the variable, so calls can chain
      def roll(name, range)
        lo, width = range_bounds(range)
        use_rng!
        ensure_var(name)
        churn_rng
        # Take the random high bits of the state, fold them non-negative, then fit
        # them into the range: value = (high mod width) + lo.
        record(Build.set(name, Build.binop(:/, Build.var_ref(RNG_STATE), Build.int(RNG_HIGH_DIV))))
        record(Build.abs(name))
        record(Build.set(name, range_reduce(name, lo, width)))
        Value.new(self, Build.var_ref(name), name: name)
      end

      # Draw a random number in +range+ and hand back a {Value} — for assigning it
      # (`set :dx, rand(1..2)`) or building an expression from it (`rand(0..9) * 10`).
      # Churns the stream. Each call draws into its own hidden variable, so two draws
      # in one expression are independent.
      #
      # @param range [Range] the range to draw from
      # @return [Value] the drawn value
      def rand(range)
        roll(next_rng_var, range)
      end

      # A {Condition} that is true +percent+% of the time (0–100) — branch on it with
      # `.then`, compose it with `&` / `|`, exactly like a comparison. Churns the
      # stream.
      #
      #   chance(30).then { beep :powerup }   # a 30% drop
      #
      # @param percent [Integer] how often it holds, 0 (never) to 100 (always)
      # @return [Condition] the yes/no test
      def chance(percent)
        unless percent.is_a?(Integer) && (0..100).cover?(percent)
          raise ArgumentError, "chance takes a whole percent from 0 to 100, got #{percent.inspect}"
        end

        draw = next_rng_var
        roll(draw, 0...100) # 0..99
        # Holds percent% of the time — the cost estimator weighs a gated body by that.
        Condition.new(self, Build.binop(:<, Build.var_ref(draw), Build.int(percent)),
                      cost_tag: { kind: :chance, percent: percent })
      end

      private

      # Note that the program draws random numbers, and make sure the stream's state
      # variable exists. The one-time seed at boot is added by #initialize_rng_stream.
      def use_rng!
        @prng_used = true
        ensure_var(RNG_STATE)
      end

      # Churn the stream to its next state: state = state * MULT + INC (wrapping past
      # 32 bits — that overflow is what scrambles it).
      def churn_rng
        step = Build.binop(:+, Build.binop(:*, Build.var_ref(RNG_STATE), Build.int(RNG_MULT)), Build.int(RNG_INC))
        record(Build.set(RNG_STATE, step))
      end

      # Fit a non-negative draw into [lo, lo+width): value = (draw mod width) + lo.
      # There's no modulo op, so spell it out as draw - (draw / width) * width; with
      # a non-negative draw, division-toward-zero makes that a true remainder.
      def range_reduce(name, lo, width)
        quotient = Build.binop(:/, Build.var_ref(name), Build.int(width))
        modulo = Build.binop(:-, Build.var_ref(name), Build.binop(:*, quotient, Build.int(width)))
        lo.zero? ? modulo : Build.binop(:+, modulo, Build.int(lo))
      end

      # A fresh hidden variable to hold one anonymous draw (for #rand / #chance).
      # Named per call at build time, so a draw inside a loop reuses the one variable
      # every frame rather than allocating forever.
      def next_rng_var
        @rng_seq += 1
        :"__rand_#{@rng_seq}"
      end

      # The range's inclusive low bound and its width (how many values it spans),
      # accepting both 0..9 and 0...10. Every way a range can be wrong gets its own
      # plain-language error rather than a wrong distribution or a crash downstream:
      # a non-range or non-whole-number bounds (including an endless `0..`, whose end
      # is nil); bounds too big for the console's 32-bit numbers; an empty range; or
      # one wider than a single draw can actually cover.
      def range_bounds(range)
        unless range.is_a?(Range) && range.begin.is_a?(Integer) && range.end.is_a?(Integer)
          raise ArgumentError,
                "give roll/rand a range of whole numbers like 0..9 or 0...10, got #{range.inspect}"
        end

        lo = range.begin
        hi = range.exclude_end? ? range.end - 1 : range.end
        unless in_int32?(lo) && in_int32?(hi)
          raise ArgumentError,
                "roll/rand's range #{range.inspect} is out of bounds — its ends must fit in a " \
                "32-bit number (#{IR::Int32::MIN}..#{IR::Int32::MAX})"
        end

        width = hi - lo + 1
        unless width.positive?
          raise ArgumentError, "the range #{range.inspect} is empty — its start must be at or below its end"
        end
        if width > MAX_ROLL_SPAN
          raise ArgumentError,
                "roll/rand can spread across at most #{MAX_ROLL_SPAN} values at once, but " \
                "#{range.inspect} spans #{width} — for a wider spread, scale up a smaller draw, " \
                "e.g. rand(0..999) * 1000 + rand(0..999)"
        end

        [lo, width]
      end

      # Whether a number fits in the console's signed 32-bit world — the range every
      # value lives in (see IR::Int32). A bound outside it would wrap silently.
      def in_int32?(number)
        number.between?(IR::Int32::MIN, IR::Int32::MAX)
      end

      # If the program draws random numbers, plant a fixed seed at boot, so an
      # unseeded game is reproducible and every backend (and the real console, whose
      # RAM isn't zero at boot) starts the stream from the same place. An explicit
      # `seed` later just overwrites it.
      def initialize_rng_stream
        at_boot(Build.set(RNG_STATE, Build.int(DEFAULT_SEED))) if @prng_used
      end
    end
  end
end
