# frozen_string_literal: true

require "open3"

module VBlank
  module IR
    module Backends
      class JS
        # Runs the windowless program (JS#build_headless) with node, the JavaScript a machine runs
        # without a browser. Only the tests need it: a page needs nothing but a browser.
        module Node
          # The oldest node the runtime is written for: it uses nothing newer than what node 18
          # carries, which every supported node has.
          OLDEST = 18

          # Raised when node is missing or too old.
          class Error < StandardError; end

          module_function

          # The installed node's version, refusing one older than OLDEST.
          def version
            out, status = Open3.capture2e("node", "--version")
            raise Error, "node could not tell its version:\n#{out}" unless status.success?

            found = out.strip
            return found if found.delete_prefix("v").to_i >= OLDEST

            raise Error, "this needs node #{OLDEST} or later, and the node installed is #{found}."
          rescue Errno::ENOENT
            raise Error, "node was not found. Install node #{OLDEST} or later to play the JavaScript lowering's tests."
          end

          # Runs +script+ with node, handing it +args+ and feeding it +input+, and gives back what
          # it printed. It is the native lowering's own runner with node as the program, so a
          # script is held to everything a C program is: stopped after +seconds+, stopped if it
          # prints more than Native::Zig::MOST_PRINTED_BYTES, and its ending read the same way —
          # IR::ProgramError for a game that went wrong, Native::Zig::Error for anything else.
          def run_program(script, args: [], input: "", seconds: 60)
            Native::Zig.run_program("node", args: [script, *args], input: input, seconds: seconds)
          end
        end
      end
    end
  end
end
