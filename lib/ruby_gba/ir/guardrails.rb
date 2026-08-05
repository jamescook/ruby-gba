# frozen_string_literal: true

module RubyGBA
  module IR
    # Guardrails turn known footguns into friendly, plain-language messages by
    # inspecting the IR *before* it is lowered to a target. That's the payoff of
    # having the whole program as inspectable data: a check can walk the semantic
    # tree and say "you drew but never turned the display on" far more reliably
    # than anything scanning finished machine code could.
    #
    # This file is only the *mechanism* — a registry of checks and a pass that
    # runs them. Each check is target knowledge (what's a footgun on this
    # hardware and how to phrase it); those live in Guardrails::Checks. A check
    # does three things: detect a problem, explain it in plain language, and —
    # where it's safe — offer a fix the pass can apply automatically.
    module Guardrails
      # Raised by Report#raise_on_error! when validation found a real problem
      # that wasn't (or couldn't be) auto-fixed.
      class ValidationError < StandardError; end

      # One problem a guardrail found.
      #   severity — :error (would break the ROM) or :warning (advisory — a
      #              non-fatal footgun, or an error the pass auto-fixed for you)
      #   message  — plain language written for the person, not a log
      #   fix      — an optional Fix the pass may apply; nil if there's no safe one
      #   source   — the DSL call site of the offending node ("hero.rb:42"), or nil.
      #              A check just hands over the node's source; the "(at …)" suffix is
      #              appended in one place (#full_message), so no check formats it into
      #              its own sentence and a new guardrail gets it for free.
      Finding = Data.define(:check, :severity, :message, :fix, :source) do
        def initialize(check:, severity:, message:, fix: nil, source: nil)
          super
        end

        def error?
          severity == :error
        end

        def warning?
          severity == :warning
        end

        # The message shown to the person: the plain message, plus the source
        # location appended when the check knew which node was at fault.
        def full_message
          source ? "#{message} (at #{source})" : message
        end
      end

      # A safe, automatic correction a check offers.
      #   message — what we changed and why, for the person to read
      #   apply   — a callable taking the program and returning the fixed program
      Fix = Data.define(:message, :apply)

      # The result of a validation pass: the program (possibly auto-fixed) plus
      # every finding, so a caller can print warnings, raise on errors, or lower
      # the corrected tree.
      Report = Data.define(:program, :findings) do
        def errors
          findings.select(&:error?)
        end

        def warnings
          findings.select(&:warning?)
        end

        # True when nothing remains that would break the ROM (warnings are fine —
        # they mean we already fixed something for you).
        def ok?
          errors.empty?
        end

        def raise_on_error!
          return self if ok?

          raise ValidationError, errors.map(&:full_message).join("\n\n")
        end

        # Write every finding's plain-language message to +to+, in order — the one
        # place guardrail findings become human-visible text. A caller (a build, a
        # CLI, a test) hands its output here instead of formatting and printing
        # findings by hand, so the wording and destination live in one spot and the
        # stream is injectable: $stderr for a real build, a StringIO to capture it in
        # a test, or a null sink to silence it. Returns self so it chains.
        def emit(to: $stderr)
          # A blank line between findings so two or more don't run together as one
          # wall of text.
          findings.each_with_index do |finding, i|
            to.puts if i.positive?
            to.puts(finding.full_message)
          end
          self
        end
      end

      # The extension hook. BUILTIN_CHECKS are always on; these are the extra
      # whole-program checks something adds at runtime — an effect pack's own
      # guardrails, or a one-off a game registers. They're kept separate from the
      # frozen builtins because they're only active while whoever added them is
      # loaded: a pack's footgun checks travel with the pack and never fire for a
      # verb you aren't using.
      #
      # A check is anything with #detect(program) -> [Finding] — the same contract
      # the builtins honor, so a registered check may warn, error, or offer a Fix
      # just like a builtin. This hook is for WHOLE-PROGRAM checks that can only be
      # judged once the full IR exists (state left un-restored, a pool declared but
      # never drawn, an asset referenced but never defined). Cheap argument checks
      # (a rate of 0, an unknown color) belong inline in the verb as an immediate
      # error, not here.
      @registered_checks = []

      class << self
        # Register a whole-program check so it runs in every validation pass from
        # now on. Idempotent for the same check instance. Returns the check.
        def register(check)
          @registered_checks << check unless @registered_checks.include?(check)
          check
        end

        # The checks registered so far — a copy, so the registry stays visible data
        # a caller can read without being able to mutate it by accident.
        def registered_checks
          @registered_checks.dup
        end

        # The full set a Validator runs by default: the always-on builtins plus
        # everything registered. Read fresh each pass (not frozen at construction),
        # so a check registered after a Validator was built still takes effect.
        def default_checks
          BUILTIN_CHECKS + @registered_checks
        end

        # Drop every registered check, back to builtins only. For tests, so one
        # test's registration can't leak into the next, and for any caller that
        # wants a clean slate.
        def clear_registered!
          @registered_checks = []
        end
      end

      # The validation pass. Runs each check over the tree in order. When autofix
      # is on and a check offers a safe fix, it applies the fix — threading the
      # corrected program into the checks that follow — and downgrades that
      # finding from an error to a warning. With autofix off, problems are left
      # as errors and the tree is returned untouched.
      #
      # A check is just something with #detect(program) -> findings. Most inspect
      # the tree; a stateful one may ignore it and report from data it was built
      # with (the orphaned-Condition check does this — its data is the builder's
      # leftover Conditions, not the tree). Either way the pass treats them alike;
      # pass your own list via +checks:+ to run a different set.
      class Validator
        def initialize(checks: Guardrails.default_checks)
          @checks = checks
        end

        def run(program, autofix: true)
          findings = []
          @checks.each do |check|
            check.detect(program).each do |finding|
              if autofix && finding.fix
                program = finding.fix.apply.call(program)
                findings << Finding.new(check: finding.check, severity: :warning,
                                        message: finding.fix.message, fix: nil, source: finding.source)
              else
                findings << finding
              end
            end
          end
          Report.new(program: program, findings: findings)
        end
      end
    end
  end
end

require_relative "guardrails/frame_reach"
require_relative "guardrails/screen_mode_set"
require_relative "guardrails/empty_tiled_screen"
require_relative "guardrails/vblank_sync"
require_relative "guardrails/termination"
require_relative "guardrails/off_screen_draw"
require_relative "guardrails/orphaned_condition"
require_relative "guardrails/draw_budget"
require_relative "guardrails/budget_threshold"
require_relative "guardrails/channel_conflict"
require_relative "guardrails/redraw_everything"
require_relative "guardrails/sprite_cleared_each_frame"
require_relative "guardrails/manual_sprite_blit"
require_relative "guardrails/per_frame_scope" # shared by the one-time-setup checks below
require_relative "guardrails/seed_in_loop"
require_relative "guardrails/list_in_loop"
require_relative "guardrails/iwram_budget"

module RubyGBA
  module IR
    module Guardrails
      # The always-on checks, in order — the base every validation pass runs. A
      # plain frozen list so it's visible data, not hidden behind a method.
      # Guardrails.default_checks appends whatever's been registered on top of
      # these; instantiate a Validator with your own list to run a different set.
      BUILTIN_CHECKS = [
        Checks::ScreenModeSet.new,
        Checks::EmptyTiledScreen.new,
        Checks::VblankSync.new,
        Checks::Termination.new,
        Checks::OffScreenDraw.new,
        Checks::DrawBudget.new,
        Checks::BudgetThreshold.new,
        Checks::ChannelConflict.new,
        Checks::RedrawEverything.new,
        Checks::SpriteClearedEachFrame.new,
        Checks::ManualSpriteBlit.new,
        Checks::SeedInLoop.new,
        Checks::ListInLoop.new,
        Checks::IwramBudget.new,
      ].freeze
    end
  end
end
