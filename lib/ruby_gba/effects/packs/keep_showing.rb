# frozen_string_literal: true

module RubyGBA
  module Effects
    module Packs
      # A picture that is drawn when it changes and then left there — a score, a
      # health bar, a GAME OVER banner, the words over a finished game.
      #
      # WHAT IT IS FOR. A picture repainted every frame needs none of this. A picture
      # left alone between changes is much cheaper, and on the tear-free screen
      # (`screen :bitmap, tear_free: true`) leaving it alone needs care: that screen
      # keeps TWO pictures and shows them in turn, so the program draws into the one
      # nobody is looking at and they trade places at the frame boundary. A change
      # painted a single time therefore reaches one of the two, and the screen flickers
      # between the new figure and the old one, half the frames each.
      #
      # So a change is painted once per picture the screen keeps. The game says WHEN
      # the picture changed; how many paints that takes is read off the screen the game
      # declared, and no game writes the number down.
      #
      #   bar = keep_showing(:status_bar) { paint_the_bar }
      #
      #   # ...somewhere a change happens:
      #   (health != last).then { bar.changed }
      #
      #   # ...and in the frame, where the picture belongs in the drawing order:
      #   bar.draw
      #
      # ON A PLAIN SCREEN THE SAME GAME CODE IS RIGHT and costs one paint, because a
      # screen that keeps one picture needs one. Nothing in the game says which screen
      # it is on, which is the point — a game moved from `screen :bitmap` to
      # `screen :bitmap, tear_free: true` keeps working, and the flicker that would
      # have appeared never does.
      #
      # A pack, by {Effects}'s own test: every line is written in `var`, `func`,
      # `call` and `.then`, and no backend knows this file exists.
      module KeepShowing
        # Draw something once and leave it there, and let the framework work out how
        # many times "once" really is on this screen.
        #
        # The block is the drawing, and it is built into a routine of its own rather
        # than emitted at each place that needs it — so a picture painted from three
        # places costs its code once. Declare it where the picture belongs — the top
        # level, or inside a `scene` that owns it — the same as a `sprite`.
        #
        # @param name [Symbol] what to call the picture, for the routine and its counter
        # @return [Shown] the handle: #changed when it changes, #draw in drawing order
        def keep_showing(name, &drawing)
          unless name.is_a?(Symbol)
            raise ArgumentError,
                  "keep_showing needs a name for the picture, as a symbol: " \
                  "keep_showing(:status_bar) { ... }. You gave #{name.inspect}."
          end
          unless drawing
            raise ArgumentError,
                  "keep_showing needs a block saying what to draw: " \
                  "keep_showing(:#{name}) { draw_text \"GAME OVER\", :center, 80, :white }."
          end
          if keep_showing_pictures.key?(name)
            raise ArgumentError,
                  "keep_showing(:#{name}) was declared twice. Each picture needs its own " \
                  "name. Declare it once and keep the handle it gives back."
          end

          keep_showing_pictures[name] = Shown.new(self, name, &drawing)
        end

        # The pictures declared so far, by name — so a double declaration is caught
        # and the guardrail can see what was asked for.
        def keep_showing_pictures = @keep_showing_pictures ||= {}

        # One such picture: a routine that draws it, and a count of how many pages
        # still want it.
        #
        # The count is the whole mechanism. #changed sets it to however many pictures
        # this screen keeps; #draw paints while it is positive and takes one off. So a
        # change is painted on that many frames running, which is one of each page,
        # and nothing in a game ever names a page.
        class Shown
          def initialize(builder, name, &drawing)
            @b = builder
            @name = name
            @pages = builder.screen_pages
            @todo = builder.var(:"__shown_#{name}_todo", 0)
            builder.func(routine, &drawing)
          end

          # THE PICTURE CHANGED. Call it at the moment the thing it shows moves — when
          # the score goes up, when the game ends. It paints nothing itself; it says
          # that every page now wants a fresh copy.
          #
          # Calling it again before the last change has reached both pages simply asks
          # again, so a burst of changes cannot leave a page holding a stale figure.
          def changed
            @todo.set @pages
            self
          end

          # PAINT IT IF ANY PAGE STILL WANTS IT. Call this every frame, at the point in
          # the drawing order where the picture belongs — over the scene it sits on top
          # of, under anything that covers it. A frame with no change outstanding costs
          # one comparison and draws nothing.
          def draw
            (@todo > 0).then(estimate: { usually: 1, in: REPAINTS_IN }) do
              @todo.sub 1
              @b.call(routine)
            end
            self
          end

          # NOBODY WANTS IT ANY MORE. Call it where the thing the picture showed is put
          # back — a new game starting over a finished one. Any paints still owed from
          # the last change are dropped, so a banner cannot follow the game that ended
          # into the one that replaced it. It erases nothing itself; whatever draws next
          # covers it.
          def cancel
            @todo.set 0
            self
          end

          # How often a picture like this is repainted: a figure that moves when you are
          # hit or when you fire changes on a handful of frames in every sixty. Said
          # here because an unsaid body is counted on every frame.
          REPAINTS_IN = 10

          # How many times a change is painted on this screen: one per picture the
          # screen keeps.
          attr_reader :pages

          def routine = :"__draw_shown_#{@name}"
        end

        # The guardrails this pack brings with it.
        def self.checks
          @checks ||= [NeverDrawn.new]
        end

        # A picture that is declared and told when it changes, but never drawn.
        #
        # The two halves sit in different places on purpose — a change is noticed
        # wherever it happens, and the painting belongs in the drawing order — so it
        # is an easy one to half-write. Left like that the picture never appears at
        # all: the counter goes up on every change and nothing ever reads it. No
        # crash, no blank where something should be, just a game missing its score.
        #
        # Read structurally, the same way the shake's own check is: the routine is
        # declared as soon as a picture is, and #draw is the only thing that ever
        # places a call to it. A declared routine with no call is exactly this bug.
        class NeverDrawn
          NAME = :keep_showing_never_drawn
          PLAIN_NAME = "a picture that is never drawn"

          def detect(program)
            declared(program).filter_map do |routine|
              next if called?(program, routine)

              IR::Guardrails::Finding.new(check: NAME, severity: :warning,
                                          message: message_for(routine), node: :program)
            end
          end

          private

          PREFIX = "__draw_shown_"

          def declared(program)
            program.each.filter_map do |node|
              node.name if node.kind == :func && node.name.to_s.start_with?(PREFIX)
            end
          end

          def called?(program, routine)
            program.each.any? { |node| node.kind == :call && node.target == routine }
          end

          def message_for(routine)
            picture = routine.to_s.delete_prefix(PREFIX)
            "This game declares `keep_showing(:#{picture})`, but it never draws that " \
              "picture. The block says what to draw. A call to `draw` on the handle is " \
              "what puts it on screen. With no such call the picture never appears. To " \
              "fix this, call `#{picture}.draw` in the frame, where the picture belongs " \
              "in the drawing order."
          end
        end
      end
    end
  end
end
