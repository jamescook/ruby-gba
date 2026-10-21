# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBC
        # A GAME'S TIMERS, said for a Game Boy Color. Mixed into StatementLowering, over Native's timers.
        #
        # A timer (`timer :beat, per_second: 10`) ticks so many times a second whatever the game is
        # doing, and runs what the game said to do on each tick. There is no clock in it: a frame is
        # the interpreter's sixtieth of a second, so at every frame boundary a running timer gains
        # its rate in sixtieths of a tick, and each whole tick that comes to is a tick
        # (Reference#accrue_timer). The Color's own hardware timer counts its own clock, which is
        # not the frame — a pass that runs late would tick it more than the interpreter ticks — so
        # this counts frames instead, as the interpreter does.
        #
        # IT IS WRITTEN AS THE GAME'S OWN STATEMENTS rather than as runtime code. Native's runtime
        # keeps its timers in C (rg_timer_start and the rest); here each timer is a handful of the
        # game's numbers, the words that start, stop and read one are statements about them, and
        # routines of the game's — run by the runtime at each frame boundary (Runtime's
        # rt_frame_begins) — move every running timer on and run its ticks. The compiler that makes
        # everything else of the game's makes these too, so there is no SM83 of their own to get
        # wrong.
        #
        # Each timer keeps: when it was first started, as a count (nought for never), since timers
        # move on in the order they were first started, as the interpreter walks them; whether it
        # is running; its rate, as the whole ticks and the sixtieths of a tick a frame adds (kept
        # apart so that adding them never goes round, at any rate a game can ask for); the
        # sixtieths of a tick it is through (always under sixty); and its whole ticks, coming
        # round at 65536 as the interpreter's count does.
        module Timers
          C = Native::C

          # The name the statements give the routine the runtime runs at each frame boundary, or
          # nil for a game with no timers.
          def timer_frame_routine = @timers.empty? ? nil : timers_frame_name.text

          private

          # The numbers each timer keeps (see the comment at the top).
          TIMER_PLACES = %i[order running whole_rate part_rate parts ticks].freeze

          # Every number the timers keep, from power-on.
          def timer_globals
            return [] if @timers.empty?

            places = @timers.values.flat_map { |number| TIMER_PLACES.map { |what| timer_place(number, what) } }
            [*places, timers_started, timer_crossed].map { |name| C::Global.new(name: name) }
          end

          def timer_place(number, what) = @names.own("timer_#{number}_#{what}")
          def timers_started = @names.own("timers_started")
          def timer_crossed = @names.own("timer_crossed")
          def timers_frame_name = @names.own("timers_frame")
          def timer_frame_name(number) = @names.own("timer_#{number}_frame")

          # Reference#exec_timer_start: running at its rate, its count from nought — and, the first
          # time, given its place in the order the timers move on in.
          def lower_timer_start(node)
            number = @timers.fetch(node.name)
            order = timer_place(number, :order)
            first_time = [C::Assign.new(timers_started, call("rg_add", timers_started, C::Int.new(1))),
                          C::Assign.new(order, timers_started)]
            whole, part = node.hz.divmod(Reference::FRAME_RATE)
            [C::If.new(condition: call("rg_eq", order, C::Int.new(0)), body: first_time),
             C::Assign.new(timer_place(number, :running), C::Int.new(1)),
             C::Assign.new(timer_place(number, :whole_rate), C::Int.new(whole)),
             C::Assign.new(timer_place(number, :part_rate), C::Int.new(part)),
             C::Assign.new(timer_place(number, :parts), C::Int.new(0)),
             C::Assign.new(timer_place(number, :ticks), C::Int.new(0))]
          end

          # Reference#exec_timer_stop: its count is kept. A timer never started has nothing to stop,
          # and stays one that moves on in no order.
          def lower_timer_stop(node) = [C::Assign.new(timer_place(@timers.fetch(node.name), :running), C::Int.new(0))]

          # Reference#timer_ticks: nought for a timer never started, which is what its count starts at.
          def value_of_timer_ticks(node) = timer_place(@timers.fetch(node.name), :ticks)

          # THE ROUTINES THE RUNTIME RUNS AT EACH FRAME BOUNDARY: one that moves every running timer
          # on, in the order the timers were first started — the k-th started is looked for k-th —
          # and one for each timer that moves it on and runs its handler, so each handler is written
          # once however many timers there are. Empty for a game with no timers.
          def timer_frame_functions
            return [] if @timers.empty?

            in_order = (1..@timers.size).flat_map do |place_in_order|
              @timers.values.map do |number|
                C::If.new(condition: call("rg_eq", timer_place(number, :order), C::Int.new(place_in_order)),
                          body: [C::If.new(condition: timer_place(number, :running),
                                           body: [eval_call(timer_frame_name(number).text)])])
              end
            end
            [*@timers.map { |name, number| timer_frame_function(name, number) },
             C::Function.new(name: timers_frame_name, body: in_order)]
          end

          # One timer, a frame on: its sixtieths, the whole ticks they come to, and its handler run
          # once for each. How many that is is settled before the first of them runs, so a handler
          # that stops or restarts its own timer still finishes the ticks this frame crossed, as the
          # interpreter's does.
          def timer_frame_function(name, number)
            parts = timer_place(number, :parts)
            ticks = timer_place(number, :ticks)
            sixtieths = call("rg_add", parts, timer_place(number, :part_rate))
            frame_rate = C::Int.new(Reference::FRAME_RATE)
            moved = [C::Assign.new(timer_crossed, call("rg_add", timer_place(number, :whole_rate),
                                                       call("rg_div", sixtieths, frame_rate))),
                     C::Assign.new(parts, call("rg_mod", sixtieths, frame_rate)),
                     C::Assign.new(ticks, call("rg_and", call("rg_add", ticks, timer_crossed), C::Int.new(0xFFFF)))]
            handler = @tick_handlers[name]
            if handler
              each_tick = [*body_of(handler), C::Assign.new(timer_crossed, call("rg_sub", timer_crossed, C::Int.new(1)))]
              moved << C::While.new(condition: call("rg_gt", timer_crossed, C::Int.new(0)), body: each_tick)
            end
            C::Function.new(name: timer_frame_name(number), body: moved)
          end
        end
      end
    end
  end
end
