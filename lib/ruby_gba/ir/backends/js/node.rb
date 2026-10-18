# frozen_string_literal: true

require "open3"
require "tmpdir"

module RubyGBA
  module IR
    module Backends
      class JS
        # Runs the windowless program (JS#build_headless) with node, the JavaScript a machine runs
        # without a browser. Only the tests need it: a page needs nothing but a browser.
        module Node
          # The oldest node the runtime is written for: it uses nothing newer than what node 18
          # carries, which every supported node has.
          OLDEST = 18

          # Raised when node is missing or too old, or the program it ran stopped with an error of
          # its own (a fault in the runtime, rather than in the game).
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

          # The command that runs +script+ with +args+.
          def command(script, *args) = ["node", script, *args.map(&:to_s)]

          # Runs +script+ with +args+, feeding it +input+, and gives back what it printed. Through
          # files rather than pipes, for the reason Native::Zig.run_program gives.
          def run_program(script, args: [], input: "", seconds: 60)
            Dir.mktmpdir("ruby-gba-run") do |dir|
              fed, printed, complained = %w[fed printed complained].map { |name| File.join(dir, name) }
              File.binwrite(fed, input)
              pid = Process.spawn(*command(script, *args), in: fed, out: printed, err: complained)
              waiter = Process.detach(pid)
              begin
                finished = waiter.join(seconds)
              ensure
                Native::Zig.stop_program(pid) if waiter.alive?
              end
              status = waiter.value
              raise Error, "#{File.basename(script)} was still running after #{seconds} seconds, and was stopped" unless finished

              refuse_stopped_program!(script, status, File.read(complained))
              File.read(printed)
            end
          end

          # Raises for a program that did not end well: IR::ProgramError, with the program's own
          # sentence, for a game that went wrong — the error the interpreter raises for the same
          # game — and Error for anything else.
          def refuse_stopped_program!(script, status, complaint)
            return if status.success?
            raise IR::ProgramError, complaint.strip if status.exitstatus == Native::Zig::GAME_WENT_WRONG

            raise Error, "#{File.basename(script)} stopped (#{status}):\n#{complaint}"
          end
        end
      end
    end
  end
end
