# frozen_string_literal: true

module RubyGBA
  module Console
    # WHAT EVERY VERB DOES ON A CONSOLE, decided once for each console and written down in a table
    # of its own (Console::AdvanceAnswers, Console::ColorAnswers), where the build checks and the
    # reference both read it. Every verb gets one of two answers:
    #
    # - :works — the same game, played the same way. Each lowering's run of the suite holds the
    #   game to the interpreter, so this is a promise the test suite keeps.
    # - :refused — the build stops before anything is made, naming the hardware the console lacks
    #   and what to use instead.
    #
    # NOTHING IS SHOWN DIFFERENTLY. A turned layer shown unturned, a mosaic left sharp: each is a
    # game that looks right on one console and quietly wrong on the other, which a teaching tool
    # must not ship. What a console's hardware cannot do, the author hears about while building,
    # not while playing.
    #
    # A verb that works may still have a part the console lacks — the Color reads `held`, but not
    # for a shoulder button it does not have. Which part a line asks for is
    # Guardrails::Checks::ConsoleAnswers's to work out, from the console's description; the
    # verb's answer has the words it is refused in.
    #
    # A console's table is a module that extends this one and holds:
    #
    #   ANSWERS     every verb a game can write, to its Answer. A test holds it to the builder, so a
    #               new verb has no answer on any console until somebody decides one
    #   PLAIN       what a verb that works answers when it has nothing more to say
    #   PAGE        the file under .claude/dsl/ that is the table written out
    #   reference   the text of PAGE, asked for through the console's kit (Kit#answers_page),
    #               which hands it anything the page names from the console's build.
    #               `ruby tools/console_answers.rb` writes it, and a test fails when the two
    #               differ, so the reference cannot say one thing while the build does another
    module Answers
      Answer = Data.define(:verdict, :words) do
        def works? = verdict == :works
        def refused? = verdict == :refused
      end

      VERDICTS = %i[works refused].freeze

      # How the reference names each verdict.
      VERDICT_WORDS = { works: "works", refused: "**refused**" }.freeze

      # An answer that works, in +words+, or in the table's own (PLAIN) for a verb with nothing
      # more to say.
      def works(words = self::PLAIN) = Answer.new(:works, words)

      def refused(words) = Answer.new(:refused, words)

      # The answer for +verb+, or nil for a verb nobody has decided yet.
      def answer(verb) = self::ANSWERS[verb.to_sym]

      # The reference's line for the answer to each verb in +verbs+, in the order ANSWERS gives them.
      def answer_lines(verbs = self::ANSWERS.keys)
        verbs.map do |verb|
          answer = self::ANSWERS.fetch(verb)
          "- `#{verb}` — #{VERDICT_WORDS.fetch(answer.verdict)}: #{answer.words}"
        end
      end
    end
  end
end
