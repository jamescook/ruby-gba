# frozen_string_literal: true

# The SimpleCov setup `test/test_helper.rb` starts measuring with, under
# COVERAGE=1. The whole suite is one process, so there is one result and
# nothing to merge.
module Coverage
  FILTERS = proc do
    add_filter "/test/"
    add_filter "/ruby-gba-emulator/" # a separate gem in this repo, with its own test suite
    add_filter "/tools/"      # dev tooling, not part of the shipped library
  end
end
