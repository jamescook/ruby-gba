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
      Finding = Data.define(:check, :severity, :message, :fix) do
        def error?
          severity == :error
        end

        def warning?
          severity == :warning
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

          raise ValidationError, errors.map(&:message).join("\n\n")
        end
      end

      # The validation pass. Runs each check over the tree in order. When autofix
      # is on and a check offers a safe fix, it applies the fix — threading the
      # corrected program into the checks that follow — and downgrades that
      # finding from an error to a warning. With autofix off, problems are left
      # as errors and the tree is returned untouched.
      class Validator
        def initialize(checks: BUILTIN_CHECKS)
          @checks = checks
        end

        def run(program, autofix: true)
          findings = []
          @checks.each do |check|
            check.detect(program).each do |finding|
              if autofix && finding.fix
                program = finding.fix.apply.call(program)
                findings << Finding.new(check: finding.check, severity: :warning,
                                        message: finding.fix.message, fix: nil)
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

require_relative "guardrails/display_mode_set"
require_relative "guardrails/vblank_sync"
require_relative "guardrails/termination"

module RubyGBA
  module IR
    module Guardrails
      # The checks that run by default, in order. A plain frozen list so the
      # registry is visible data, not hidden behind a method — instantiate a
      # Validator with your own list to run a different set.
      BUILTIN_CHECKS = [
        Checks::DisplayModeSet.new,
        Checks::VblankSync.new,
        Checks::Termination.new,
      ].freeze
    end
  end
end
