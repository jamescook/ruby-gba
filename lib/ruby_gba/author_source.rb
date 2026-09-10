# frozen_string_literal: true

module RubyGBA
  # WHERE THE AUTHOR WROTE IT — the first stack frame outside the framework.
  #
  # A handle, a comparison and an alignment error are all created deep inside the
  # library, several calls below the line the person actually wrote, so a diagnostic
  # that named its own birthplace would send them to framework code every time. Skipping
  # frames under here and taking the first one outside is what turns "value.rb:388" into
  # "hero.rb:42".
  module AuthorSource
    # The library's own directory. Frames under it are the framework's own workings.
    LIB_DIR = __dir__

    module_function

    # "file.rb:12", or nil when every frame is the framework's own — which happens when
    # the framework builds something for the author rather than at their asking.
    def author_source
      frame = caller_locations.find { |loc| !loc.path.start_with?(LIB_DIR) }
      "#{frame.path}:#{frame.lineno}" if frame
    end

    # The same thing as a phrase to hang on the end of an error message, and empty when
    # there is no line to name.
    def at_author_line
      where = author_source
      where ? " (at #{where[%r{[^/]+\.rb:\d+}] || where})" : ""
    end
  end
end
