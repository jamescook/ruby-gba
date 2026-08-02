# frozen_string_literal: true

module RubyGBA
  class Builder
    # Adapters that read sprite art from files/tools (sheets, Aseprite) into the
    # frames/facing/clips the sprite builder consumes.
    module SpriteImport
      private

      # Import a sprite sheet into animation frames: slice the file into cells of the
      # given size and define each as an image, in row-major order. Returns the list
      # of frame image names, ready for the flipbook path — so `frames_from:` needs no
      # naming or numbering, just "cut it up and cycle the pieces."
      def import_frames(name:, path:, tile:, transparent:)
        tile_w, tile_h = sheet_tile_size("sprite :#{name}", tile)
        sheet = Image.slice(resolve_asset_path(path), tile_w: tile_w, tile_h: tile_h, transparent: transparent)
        (0...(sheet.cols * sheet.rows)).map do |i|
          bmp = sheet.cell(i % sheet.cols, i / sheet.cols)
          frame = :"__frame_#{name}_#{i}"
          define_pixel_image(frame, width: bmp.width, height: bmp.height, data: bmp.data,
                                    transparent: bmp.transparent)
          frame
        end
      end

      # Import a directional sprite sheet into facing: poses. The sheet is a grid: each
      # ROW is a direction (in the order dirs: gives, top to bottom), and the COLUMNS of
      # that row are its frames. So a one-column sheet gives one still pose per direction
      # (a plain facing: sprite), and a several-column sheet gives a per-direction
      # animation (a walk cycle each way it faces). Returns the facing: hash the normal
      # sprite path then handles — a single image per direction, or a list of frames.
      def import_facing(name:, path:, tile:, dirs:, transparent:)
        unless dirs.is_a?(Array) && dirs.any? && dirs.all? { |d| d.is_a?(Symbol) }
          raise ArgumentError,
                "sprite :#{name} facing_from: needs dirs: — the direction of each row of the sheet, " \
                "top to bottom, like dirs: [:down, :left, :right, :up]. Got #{dirs.inspect}."
        end

        tile_w, tile_h = sheet_tile_size("sprite :#{name}", tile)
        sheet = Image.slice(resolve_asset_path(path), tile_w: tile_w, tile_h: tile_h, transparent: transparent)
        unless sheet.rows == dirs.length
          raise ArgumentError,
                "sprite :#{name} facing_from: has #{sheet.rows} rows, but dirs: names #{dirs.length}. " \
                "Give one direction for each row of the sheet."
        end

        dirs.each_with_index.to_h do |dir, row|
          frames = (0...sheet.cols).map do |col|
            bmp = sheet.cell(col, row)
            img = :"__face_#{name}_#{dir}_#{col}"
            define_pixel_image(img, width: bmp.width, height: bmp.height, data: bmp.data, transparent: bmp.transparent)
            img
          end
          # One column: a still pose per direction. Several: this direction's frame list.
          [dir, sheet.cols == 1 ? frames.first : frames]
        end
      end

      # Import an Aseprite sprite-sheet export (a PNG plus its JSON) into sprite frames and
      # named animations. The JSON gives each frame's exact rectangle and each named
      # animation (frameTag); this slices those rectangles out of the PNG (found from the
      # JSON's own meta.image, beside the JSON) and defines one image per frame. Returns
      # [frame image names, clips, width, height, durations], where clips maps each
      # animation name to { off:, len: } (its first frame and its length) and durations is
      # each frame's own hold, in game frames — so a frame can be held longer than another.
      # A sheet with no tags becomes one clip named :all.
      def import_aseprite(name, file_path, transparent)
        frames, tags = load_aseprite(name, resolve_asset_path(file_path), transparent)
        poses = frames.each_with_index.map do |frame, i|
          img = :"__ase_#{name}_#{i}"
          define_pixel_image(img, width: frame.width, height: frame.height, data: frame.data, transparent: frame.transparent)
          img
        end
        _poses, width, height = same_size_images!(name, "Aseprite frame", poses)

        tags = [Aseprite::Tag.new(:all, 0, frames.length - 1)] if tags.empty?
        clips = tags.to_h { |tag| [tag.name, { off: tag.from, len: (tag.to - tag.from) + 1 }] }
        durations = frames.map { |frame| duration_frames(frame.duration) }
        [poses, clips, width, height, durations]
      end

      # Load an Aseprite sprite as [frames, tags], where each frame carries its pixels and
      # its duration. Reads either the native binary (.aseprite / .ase) straight — no export
      # step — or a JSON + PNG export (the JSON names its PNG, found beside it).
      def load_aseprite(name, path, transparent)
        if path.downcase.end_with?(".aseprite", ".ase")
          sprite = Aseprite.load_binary(File.binread(path))
          return [sprite.frames, sprite.tags]
        end

        doc = Aseprite.parse(File.read(path))
        unless doc.image
          raise ArgumentError,
                "sprite :#{name} from_aseprite: #{path.inspect} does not name its image. " \
                "Re-export from Aseprite with the JSON data option, which records the PNG name."
        end
        sheet = Image.load_sheet(File.expand_path(doc.image, File.dirname(path)), transparent: transparent)
        frames = doc.frames.map do |f|
          bmp = sheet.region(x: f.x, y: f.y, w: f.w, h: f.h)
          Aseprite::FrameImage.new(bmp.width, bmp.height, bmp.data, bmp.transparent, f.duration)
        end
        [frames, doc.tags]
      end
    end
  end
end
