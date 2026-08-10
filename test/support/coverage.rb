# frozen_string_literal: true

# The SimpleCov setup shared by `test/test_helper.rb` (which starts measuring,
# in both `rake test` and each `rake test:parallel` shard) and the Rakefile
# (which renders the parallel run's merged report, after every shard has
# exited). Kept in one place so the two never drift into disagreement about
# what counts as coverable.
module Coverage
  FILTERS = proc do
    add_filter "/test/"
    add_filter "/gemba-core/" # a separate vendored project with its own test suite
    add_filter "/tools/"      # dev tooling, not part of the shipped library
  end
end
