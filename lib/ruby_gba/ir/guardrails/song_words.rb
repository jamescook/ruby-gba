# frozen_string_literal: true

module RubyGBA
  module IR
    module Guardrails
      # HOW THE MUSIC CHECKS NAME WHAT THEY FOUND, so every one of them names it the same way.
      #
      # A song written with `song :title do ... end` is known by that name. One handed over in a
      # list — `songs :music, [...]` — is known by where it sits in the list, since that is how
      # the game plays it: the IR calls it :"music.2", which is nobody's name for it.
      #
      # A part of a song block is known by the name its `voice` gave it, or else by where it
      # stands — the first part, the second. A part of a Score is known by its index into
      # `parts:`, counting from 0, which is what a program that builds Scores has in its hands
      # and what the Score's own errors already say.
      module SongWords
        module_function

        ORDINALS = %w[first second third fourth fifth sixth seventh eighth ninth tenth].freeze

        # "the song :title", "song 2 of :music", "the song :forest of :music".
        def song(program, node)
          list = list_of(program, node)
          return "the song :#{node.name}" unless list

          key = node.name.to_s.delete_prefix("#{list.name}.")
          key.match?(/\A\d+\z/) ? "song #{key} of :#{list.name}" : "the song :#{key} of :#{list.name}"
        end

        # The same, to start a sentence with.
        def song_capitalized(program, node) = song(program, node).sub(/\A./, &:upcase)

        # Did the song come from a list of Scores, rather than a `song` block?
        def score?(program, node) = !list_of(program, node).nil?

        # "the part :bass" / "the second part" for a song block, "part 1" for a Score.
        def part(program, node, index)
          return "part #{index}" if score?(program, node)

          name = node.voices[index].name
          return "the part :#{name}" if name

          ORDINALS[index] ? "the #{ORDINALS[index]} part" : "part #{index + 1}"
        end

        # How far into the song a frame is, for a person: "0.2 seconds".
        def seconds(frame)
          value = (frame / Score::FRAME_RATE.to_f).round(2)
          "#{value.to_s.delete_suffix('.0')} second#{'s' unless value == 1}"
        end

        def list_of(program, node)
          program.walk.find { |candidate| candidate.kind == :song_list && candidate.songs.include?(node.name) }
        end
      end
    end
  end
end
