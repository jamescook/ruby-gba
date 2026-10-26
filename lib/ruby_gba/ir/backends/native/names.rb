# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class Native
        # WHAT THE GAME'S NAMES ARE CALLED IN C.
        #
        # A game names its variables, routines, lists and pictures with Ruby symbols, and the
        # framework adds names of its own (`__frames`, a pool's hidden columns). Not all of
        # those are legal C, and some that are legal are still off limits: C keeps every name
        # that starts with two underscores for itself, so `__frames` cannot be written as it
        # is. So each kind of thing gets a prefix of its own (v_ for a variable, f_ for a
        # routine, ...), which also keeps a variable and a routine of the same name apart, and
        # any character C does not allow in a name is written as its hex code: `a.b` is
        # `v_a_x2e_b`.
        #
        # That escaping can, in principle, send two different names to the same C name (`a.b`
        # and a name really spelt `a_x2e_b`). Rather than make every name harder to read to rule
        # that out, two names that collide are refused outright.
        class Names
          PREFIXES = Ractor.make_shareable({
                                             variable: "v_", routine: "f_", list: "l_", table: "t_",
                                             data: "d_", local: "i_", table_of_routines: "r_",
                                             colors: "c_", song_list: "m_", sound_effect_list: "e_"
                                           })

          def initialize
            @given = {} # [kind, IR name] -> C::Name
            @taken = {} # C text -> [kind, IR name] it was given to
          end

          # The C name of +name+, a thing of +kind+ (a key of PREFIXES). The same thing always
          # gets the same name back.
          def of(kind, name)
            @given[[kind, name]] ||= begin
              text = PREFIXES.fetch(kind) + escape(name.to_s)
              holder = @taken[text]
              if holder
                raise LoweringError,
                      "two names, #{holder.last.inspect} and #{name.inspect}, would both be written " \
                      "#{text} in the C. Rename one of them."
              end

              @taken[text] = [kind, name]
              C::Name.new(text)
            end
          end

          # A name the generated file uses for itself, which no game name can reach: a game
          # name always carries one of the prefixes above.
          def own(text) = C::Name.new("rg_game_#{text}")

          private

          def escape(text)
            text.gsub(/[^A-Za-z0-9_]/) { |char| char.bytes.map { |byte| format("_x%02x_", byte) }.join }
          end
        end

        # Raised when a program cannot be written as C: a kind of node this backend does not
        # lower yet, or a name that cannot be given a C name of its own.
        class LoweringError < RubyGBA::BuildError; end
      end
    end
  end
end
