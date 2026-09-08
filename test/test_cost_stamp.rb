# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require_relative "../tools/cost_stamp"

# The watermark the pre-commit hook reads (tools/cost_stamp.rb): proof that the corpus was
# scored against the code as it stands, so "run rake cost:check when you touch the model" is
# enforced by the machine rather than remembered by a person.
#
# What matters here is the STALENESS: a stamp that survived an edit would say the corpus had
# been scored when it had not, which is worse than no stamp at all — it would turn the hook
# into a rubber stamp and everyone would trust it.
class TestCostStamp < Minitest::Test
  def stamp_path(dir) = File.join(dir, "stamp")

  def test_writing_a_stamp_makes_it_current
    Dir.mktmpdir do |dir|
      path = stamp_path(dir)

      refute CostStamp.current?(path), "no stamp yet, so nothing has been verified"
      CostStamp.write(path)
      assert CostStamp.current?(path)
    end
  end

  # THE ONE THAT MATTERS. Edit a watched file and the stamp must stop counting, or the check
  # is run once and the hook waves everything through for ever after.
  def test_a_stamp_goes_stale_when_a_watched_file_changes
    Dir.mktmpdir do |dir|
      path = stamp_path(dir)
      CostStamp.write(path)
      watched = File.join(CostStamp::ROOT, "lib/ruby_gba/ir/measured_weights.rb")
      was = File.read(watched)

      begin
        File.write(watched, "#{was}\n# a change that moves what a frame costs\n")
        refute CostStamp.current?(path), "editing a watched file must make the stamp stale"
      ensure
        File.write(watched, was)
      end

      assert CostStamp.current?(path), "and putting it back makes the same stamp good again"
    end
  end

  # A file nothing prices is not watched, so ordinary work does not keep asking for ten
  # seconds of emulator. A hook that fires on everything is a hook people bypass.
  def test_an_unwatched_file_leaves_the_stamp_alone
    Dir.mktmpdir do |dir|
      path = stamp_path(dir)
      CostStamp.write(path)
      unwatched = File.join(CostStamp::ROOT, "README.md")
      was = File.read(unwatched)

      begin
        File.write(unwatched, "#{was}\n")
        assert CostStamp.current?(path), "a README edit cannot change what a frame costs"
      ensure
        File.write(unwatched, was)
      end
    end
  end

  # The watched set is the claim this whole thing rests on, so it is named rather than
  # implied: these are the things that decide what a frame costs or what the corpus reads.
  def test_it_watches_the_model_the_weights_the_lowering_and_the_examples
    watched = CostStamp.files.map { |path| path.delete_prefix("#{CostStamp::ROOT}/") }

    assert_includes watched, "lib/ruby_gba/ir/cost_model.rb"
    assert_includes watched, "lib/ruby_gba/ir/measured_weights.rb"
    assert_includes watched, "lib/ruby_gba/ir/cost_model/pricing.rb"
    assert_includes watched, "tools/cost_accuracy_baseline.json", "the recorded readings are an input too"
    assert(watched.any? { |path| path.start_with?("lib/ruby_gba/ir/backends/gba/") },
           "the lowering decides what the emitted code costs")
    assert(watched.any? { |path| path.start_with?("examples/") },
           "an example edit moves that example's own recorded reading")
    refute_includes watched, "README.md"
  end
end
