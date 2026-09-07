# frozen_string_literal: true

module RubyGBA
  # A game's block, run — the one place a DSL block becomes a program.
  #
  # Running a block is four steps in a fixed order: make a {Builder}, evaluate the block
  # on it, finalize (which is also what emits every deferred function body), and take the
  # tree. Two callers need all four — {RubyGBA.build}, on its way to a cartridge, and
  # {Game#program}, which hands a test the tree the reference interpreter runs — and
  # written out twice the two copies drifted. `debug_halt` throws to stop the block where
  # it stands, and only one copy caught it, so a game with a `debug_halt` in it built a
  # cartridge quite happily and then raised the moment anything asked for its tree.
  #
  # IT ALSO CARRIES WHAT THE RUN LEARNED THAT IS NOT IN THE TREE. A few facts about a
  # program have nowhere to live in the tree — Conditions built and never branched on, the
  # frame syncs the game loop already covered, the software sprites (whose layer lives on
  # the handle) — and the guardrails need them. Reaching for those meant reaching into the
  # Builder, which is why the class a person learns the DSL from was also the build
  # pipeline's own surface. They come from here now, so the verb surface stays a verb
  # surface.
  class EvaluatedGame
    # MAKING ONE RUNS THE BLOCK. There is no way to hold one that has not run yet, which is
    # what stops the four steps drifting apart again: a caller cannot do three of them.
    #
    # +progress+ is what the build says it is doing while it does it, and it is carried into
    # the Builder so that anything running inside the game's own block — the game itself, an
    # effect pack's verb — can say what it is doing too. The default says nothing, which is
    # the right answer for anything that is not a person waiting at a terminal.
    def initialize(block, frame_sync: :auto, progress: Progress.silent)
      @builder = Builder.new(frame_sync: frame_sync, progress: progress)
      # `debug_halt` throws rather than returns, because it stops the game's block where it
      # stands and there is no other way out of somebody else's code. Catching it here is
      # what makes a truncated build a build like any other: everything above the call is
      # in the tree, everything below it never happened, and the tree that comes back is a
      # real (short) program rather than an exception.
      catch(:debug_halt) { @builder.instance_eval(&block) }
      # Finalizing the tree is also what paces it: `game_loop` runs once per frame and the
      # builder writes that wait itself, so nothing downstream has to think about it.
      @builder.emit_pending_functions
      @program = @builder.program
    end

    # The op-tree the block built: what a backend lowers and what the reference
    # interpreter runs.
    attr_reader :program

    # Did the block stop early at a `debug_halt`? A truncated tree is deliberate, so the
    # guardrails and the ROM validation are skipped for one — they would report on a
    # program the author already knows is half a program.
    def debug_halted? = @builder.debug_halted?

    # Conditions built but never used — each one almost always handed to a native Ruby
    # `if`, which is truthy for a Condition, so the body ran unconditionally and the
    # comparison was silently ignored.
    def pending_conditions = @builder.pending_conditions

    # How many `wait_vblank` calls the game loop already covered.
    def dropped_syncs = @builder.dropped_syncs

    # The software sprites, in the order they were declared — which on a bitmap screen is
    # the order they are painted in.
    def sprites = @builder.sprites

    # Function names `dump_func` queued, to disassemble out of the lowered ROM.
    def dump_requests = @builder.dump_requests
  end
end
