# frozen_string_literal: true

module RubyGBA
  # Show long text a screenful at a time, the way `git diff` or `man` does — or
  # print it straight through when there's nothing to page onto (output piped to a
  # file or another command, or captured in a test). `ruby-gba build --format=ir`
  # is the one caller today: the IR it prints can run to hundreds of lines.
  #
  # +runner+ is the part that actually shells out to a pager; it is a plain
  # dependency, swapped for a test double so a test can assert what WOULD have run
  # without a real `less` or a real terminal.
  class Pager
    def initialize(out: $stdout, env: ENV, runner: method(:shell_out))
      @out = out
      @env = env
      @runner = runner
    end

    # Print +text+ through the pager if +out+ is an interactive terminal; otherwise
    # print it straight through, unpaged — a build piped to a file or another
    # command should get the whole thing, not whatever fit on one screen.
    def page(text)
      return @out.write(text) unless interactive?

      @runner.call(command, text)
    end

    # $PAGER, honored the way every other Unix tool does, falling back to `less`
    # (present on every platform this gem supports) when it is unset.
    def command
      pager = @env["PAGER"]
      return pager unless pager.nil? || pager.empty?

      on_path?("less") ? "less" : nil
    end

    private

    def interactive?
      @out.respond_to?(:tty?) && @out.tty?
    end

    def on_path?(name)
      @env.fetch("PATH", "").split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, name)) }
    end

    # The default runner: pipe +text+ into +cmd+, a real subprocess. Falls back to
    # printing straight through when there is no pager to run, or the pager process
    # is gone before all of +text+ is written (quitting `less` early with `q`).
    def shell_out(cmd, text)
      return @out.write(text) unless cmd

      IO.popen(cmd, "w") { |pipe| pipe.write(text) }
    rescue Errno::ENOENT, Errno::EPIPE
      @out.write(text)
    end
  end
end
