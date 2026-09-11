# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # WHICH COLLECTIONS GO IN THE OTHER MEMORY, and why the answer is not "the big ones".
        #
        # The console has two work memories, and they are not two sizes of the same thing:
        #
        #   the quick one    32K, on the processor's own die, a whole word wide, no waiting
        #   the roomy one   256K, a separate chip, half as wide, and it makes the processor
        #                    wait — so a whole number read from it costs about six times
        #                    what the same read costs from the quick one
        #
        # Everything a program declares used to come out of the quick one, and a program
        # that asked for more than fits did not build. Meanwhile a quarter of a megabyte
        # sat idle, touched by nothing but the audio mixer's two output buffers.
        #
        # AND THE QUICK ONE IS ALSO WHERE THE HOT CODE GOES. Data is handed out first, so a
        # big cold collection quietly pushes a routine the frame spends its time in back
        # into the cartridge, where it runs about two and a third times slower. That is
        # invisible from the program and it is the expensive half of this.
        #
        # SO THE RULE IS: everything stays in the quick memory until it will not fit, and
        # then the COLDEST things move — not the biggest, and not the last declared.
        #
        #   what the author asked for      `fast: false` says "I know this is cold"; those
        #                                  move first, whatever their size.
        #   what a frame never touches     a collection nothing in the per-frame path
        #                                  reads is one nobody waits on. Biggest first,
        #                                  since each move buys the most room.
        #   everything else                only if it still does not fit, and then this
        #                                  really is a game asking for more than the
        #                                  console has near to hand.
        #
        # `fast: true` keeps one where it is and takes it out of the reckoning entirely, so
        # an author who knows better than the rule can say so.
        #
        # WHAT A FRAME TOUCHES is read off the program rather than guessed: the game loop's
        # body, and every routine reachable from it. That is a structural fact — this
        # collection is named in the per-frame path, or it is not — with nothing predicted
        # and nothing to drift.
        class Roomy
          # A collection considered for the move: its name, how much room it wants, whether
          # a frame ever touches it, and what the author said about it (nil for nothing).
          Candidate = Data.define(:name, :bytes, :hot, :asked) do
            # Smallest number moves first. Within a group the biggest goes first, since
            # each move has to buy as much room as it can.
            def rank = [asked == false ? 0 : (hot ? 2 : 1), -bytes]
          end

          def initialize(program)
            @hot = Roomy.touched_every_frame(program)
          end

          # Which of +candidates+ to move so that +over+ bytes come out of the quick
          # memory. Returns their names, in the order they were moved.
          def choose(candidates, over)
            moved = []
            freed = 0
            candidates.reject { |c| c.asked == true }
                      .sort_by(&:rank)
                      .each do |c|
              break if freed >= over

              moved << c.name
              freed += c.bytes
            end
            moved
          end

          def hot?(name) = @hot.include?(name)

          # THE COLLECTIONS A FRAME TOUCHES: everything named inside the game loop's body,
          # plus everything named inside any routine it can reach from there. A program
          # with no game loop has no per-frame path, so nothing is hot and the rule falls
          # back to size alone.
          #
          # A TIMER'S HANDLER COUNTS TOO, although a frame does not reach it: it is run by
          # the console many times a second, which is the same thing said another way.
          def self.touched_every_frame(program)
            bodies = program.walk.select { |n| n.kind == :func }.to_h { |n| [n.name, n] }
            roots = program.walk.select { |n| [:loop, :on_timer].include?(n.kind) }
            seen = Set.new
            found = Set.new
            roots.each { |node| gather(node, bodies, seen, found) }
            found
          end

          # Walk one body, following every way it can reach another routine, collecting the
          # names of every collection it touches. +seen+ stops a routine that calls itself
          # from going round forever.
          #
          # EVERY WAY OF REACHING ONE MATTERS, and missing one reads a whole game as cold. A
          # `call` names its routine outright. A game's SCENES are reached by a multi-way
          # dispatch instead — one clause per state, each naming the routine that draws it —
          # and a game of any size puts all its per-frame work there. Following only calls, a
          # raycaster with twenty-six collections came back with none of them touched by a
          # frame. So this follows whatever a node says it can call (IR::Node#callees).
          def self.gather(node, bodies, seen, found)
            node.walk do |n|
              found << n.name if %i[list_get list_set list_push list_drop list_len list_new].include?(n.kind)
              n.callees.each { |target| reach(target, bodies, seen, found) }
            end
          end

          def self.reach(target, bodies, seen, found)
            return if seen.include?(target)

            seen << target
            body = bodies[target]
            gather(body, bodies, seen, found) if body
          end
        end
      end
    end
  end
end
