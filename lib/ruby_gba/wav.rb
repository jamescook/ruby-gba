# frozen_string_literal: true

module RubyGBA
  # Loads a .wav file into the 8-bit signed mono PCM the sampled-audio hardware plays.
  #
  # A WAV is a RIFF container: a short header, a "fmt " chunk describing the audio (how
  # many channels, the sample rate, how many bits per sample), and a "data" chunk of the
  # raw samples. We read those and convert whatever the file holds — 8- or 16-bit, mono
  # or stereo — down to a single channel of 8-bit signed samples, keeping the file's own
  # sample rate. (Compressed or float WAVs aren't supported — export plain PCM.)
  module Wav
    module_function

    # Raised for a file that isn't a plain PCM WAV we can read.
    class Error < StandardError; end

    PCM_FORMAT = 1 # the "fmt " audio-format code for uncompressed PCM

    # Load +path+ and return { bytes:, rate: } — the converted 8-bit signed PCM (a binary
    # String) and the sample rate in Hz read from the file.
    def load(path)
      parse(File.binread(path), path)
    end

    # Parse a WAV file's bytes into { bytes:, rate: }. +source+ names it in errors.
    def parse(riff, source = "the WAV data")
      unless riff.byteslice(0, 4) == "RIFF" && riff.byteslice(8, 4) == "WAVE"
        raise Error, "#{source} is not a WAV file. It has no RIFF/WAVE header. Use a plain PCM WAV file."
      end

      fmt = find_chunk(riff, "fmt ") or raise Error, "#{source} has no fmt chunk. The fmt chunk holds the audio format. Export the file as a plain PCM WAV file."
      data = find_chunk(riff, "data") or raise Error, "#{source} has no data chunk. The data chunk holds the samples. Export the file as a plain PCM WAV file."
      format, channels, rate, _byte_rate, _align, bits = fmt.unpack("vvVVvv")
      unless format == PCM_FORMAT
        raise Error, "#{source} is not uncompressed PCM (format #{format}). This framework loads only uncompressed PCM. Export it as a plain PCM WAV file."
      end

      { bytes: to_signed_8bit_mono(data, channels, bits, source), rate: rate }
    end

    # The bytes of the first chunk named +id+. RIFF chunks are [4-byte id][4-byte
    # little-endian size][that many bytes], each padded to an even length; we skip past
    # any chunk that isn't the one we want.
    def find_chunk(riff, id)
      offset = 12 # past "RIFF", the file size, and "WAVE"
      while offset + 8 <= riff.bytesize
        size = riff.byteslice(offset + 4, 4).unpack1("V")
        return riff.byteslice(offset + 8, size) if riff.byteslice(offset, 4) == id

        offset += 8 + size + (size.odd? ? 1 : 0)
      end
      nil
    end

    # Convert the raw sample bytes to one channel of 8-bit signed PCM.
    def to_signed_8bit_mono(data, channels, bits, path)
      samples =
        case bits
        when 8  then data.unpack("C*").map { |b| b - 128 }  # WAV 8-bit is unsigned (0..255) — recenter to -128..127
        when 16 then data.unpack("s<*").map { |s| s >> 8 }  # keep the signed high byte of each 16-bit sample
        else raise Error, "#{path} is #{bits}-bit. This framework loads only 8-bit or 16-bit PCM. Export the file as 8-bit or 16-bit PCM."
        end
      # Stereo (or more) interleaves the channels sample-by-sample; average them to mono.
      mono = channels <= 1 ? samples : samples.each_slice(channels).map { |group| group.sum / group.size }
      mono.pack("c*")
    end
  end
end
