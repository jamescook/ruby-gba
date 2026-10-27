# frozen_string_literal: true

require "vblank/live/window_menu"

module VBlank
  module IR
    module Backends
      class Native
        # THE WINDOW MENU AS C DATA, for the desktop build's copy of it (runtime/rg_window_menu.c):
        # what it holds, its sizes and its colours, from Live::WindowMenu, and the letters it is
        # written in, from Graphics::MenuFont. The menu is written down once, in the library, so a
        # line added there is a line in the desktop build's menu with nothing written in C.
        #
        # Live::WindowMenu is plain data, which the live window's front door loads along with SDL
        # and the rest; this needs the description alone, so it loads that one file.
        module MenuData
          # The file the build writes it to, beside the runtime's own.
          FILE = "rg_window_menu_data.c"

          # Numbers to a line in a picture's bytes.
          BYTES_A_LINE = 32

          module_function

          # The C text. +menu+ false is a game that says it has no menu.
          def source(menu: true)
            [header, headings, sizes_and_colors, "const int rg_game_has_menu = #{menu ? 1 : 0};\n", *[1, 2].map { |density| atlas(density) },
             "const rg_menu_atlas rg_menu_atlases[2] = {#{[1, 2].map { |density| atlas_entry(density) }.join(', ')}};\n"].join("\n")
          end

          def header
            <<~C
              /* Written by the build from Live::WindowMenu and Graphics::MenuFont (Native::MenuData). */
              #include <stddef.h>
              #include <stdint.h>
              #include "rg_menu_font.h"
              #include "rg_window_menu.h"
            C
          end

          def headings
            lines = Live::WindowMenu::HEADINGS.each_with_index.map do |heading, index|
              "static const rg_menu_line heading_#{index}[] = {\n#{heading.lines.map { |line| "  #{line_entry(line)},\n" }.join}};\n"
            end
            entries = Live::WindowMenu::HEADINGS.each_with_index.map do |heading, index|
              "{#{c_string(heading.name)}, heading_#{index}, #{heading.lines.size}}"
            end
            scales = Live::WindowMenu::SCALES
            "#{lines.join}const rg_menu_heading rg_menu_headings[] = {#{entries.join(', ')}};\n" \
              "const int rg_menu_heading_count = #{entries.size};\n" \
              "const int rg_menu_scale_least = #{scales.min}, rg_menu_scale_most = #{scales.max};\n"
          end

          def line_entry(line)
            fields = [c_string(line.label), enum_name(line.kind), line.does ? enum_name(line.does) : "RG_MENU_NOTHING",
                      line.setting ? enum_name(line.setting) : "RG_MENU_NO_SETTING", line.range&.min || 0, line.range&.max || 0,
                      line.step || 0, line.written ? enum_name(line.written) : "RG_MENU_NOT_WRITTEN",
                      line.shortcut ? c_string(line.shortcut) : "NULL", line.line_before ? 1 : 0]
            "{#{fields.join(', ')}}"
          end

          # What a symbol of the description is called in rg_window_menu.h. One the header does not
          # have stops the build there, which is where a new kind of line is to be written in C.
          def enum_name(symbol) = "RG_MENU_#{symbol.to_s.upcase}"

          def sizes_and_colors
            sizes = Live::WindowMenu::SIZES.map { |name, points| ".#{name} = #{points}" }
            colors = Live::WindowMenu::COLORS.map { |name, parts| ".#{name} = {#{parts.join(', ')}}" }
            "const rg_menu_sizes rg_menu_size = {#{sizes.join(', ')}};\n" \
              "const rg_menu_colors rg_menu_color = {#{colors.join(', ')}};\n"
          end

          # One density's picture and measures, as arrays named for the density.
          def atlas(density)
            font = Graphics::MenuFont.load
            bytes = font.atlas(density).alpha.bytes.each_slice(BYTES_A_LINE).map { |row| "  #{row.join(',')},\n" }
            glyphs = font.glyphs(density).sort_by { |letter, _| letter.ord }.map do |letter, measures|
              "  {#{letter.ord}, #{measures.join(', ')}},\n"
            end
            kerning = font.kerning(density).map { |pair, amount| [pair.chars.map(&:ord), amount] }.sort.map do |(first, second), amount|
              "  {#{first}, #{second}, #{amount}},\n"
            end
            "static const uint8_t alpha_#{density}[] = {\n#{bytes.join}};\n" \
              "static const rg_menu_glyph glyphs_#{density}[] = {\n#{glyphs.join}};\n" \
              "static const rg_menu_kerning kerning_#{density}[] = {\n#{kerning.join}};\n"
          end

          def atlas_entry(density)
            font = Graphics::MenuFont.load
            picture = font.atlas(density)
            "{#{density}, #{font.line_height(density)}, #{picture.width}, #{picture.height}, alpha_#{density}, " \
              "glyphs_#{density}, #{font.glyphs(density).size}, kerning_#{density}, #{font.kerning(density).size}}"
          end

          # +text+ as a C string, any byte that is not plain printable ASCII written by its number.
          def c_string(text)
            inside = text.bytes.map do |byte|
              if byte == 34 || byte == 92 then "\\#{byte.chr}"
              elsif byte.between?(32, 126) then byte.chr
              else format("\\%03o", byte)
              end
            end
            "\"#{inside.join}\""
          end
        end
      end
    end
  end
end
