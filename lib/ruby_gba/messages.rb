# frozen_string_literal: true

# HOW A BUILD TALKS TO THE PERSON RUNNING IT, while it is still building — the English names
# for shared things, the progress line, where the printing goes, and which line of the author's
# own file to blame. None of it needs a cartridge to exist, which is what separates it from
# Diagnostics, the part that reads a finished or running one back.

require_relative "messages/plain_words" # what a person calls this — the English a build says out loud
require_relative "messages/progress" # what a build says it is doing while it does it
require_relative "messages/build_output" # where a build prints, however the caller said it
require_relative "messages/author_source" # the first line outside the framework, to blame for a mistake
