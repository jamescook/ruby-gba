# frozen_string_literal: true

require "rbconfig"
require "socket"
require "tmpdir"
require "open3"
require "cgi/escape"

module RubyGBA
  module IR
    module Backends
      class JS
        # THE GAME IN A BROWSER TAB, BUILT AGAIN ON EVERY RELOAD: `ruby-gba preview game.rb`. Edit
        # the game, reload the page, and the game starts again as the file now says — no cartridge
        # built, no emulator started.
        #
        # What it shows is the game as the IR says it, which is what the browser runs: a mistake in
        # the game's logic (a collision off by a pixel, a scene that never hands over, something
        # drawn in the wrong place) shows here. A mistake only the console makes — something about
        # its memory, its timing or the machine code a cartridge is made of — does not, and is the
        # cartridge's to find. So a fault that shows here is in the game, and one that shows only
        # on the console is in the build of it.
        #
        # Each page is built by a run of `ruby-gba build --format=web` of its own, so the game's
        # files are read afresh every time, and a build that stops — a guardrail's error, a Ruby
        # mistake — is shown in the page in its own words instead of a game.
        class Preview
          # +game_file+ is the game; +settings+ are what `--set` hands its build; +page+ is the
          # template every page is written from, nil for the default; +port+ is the one to serve on,
          # 0 for any that is free; +out+ is told where the page is and what happens.
          def initialize(game_file, settings: [], page: nil, host: "127.0.0.1", port: 8000, out: $stdout)
            @game_file = File.expand_path(game_file)
            @settings = settings
            @page = page && File.expand_path(page)
            @server = TCPServer.new(host, port)
            @out = out
          end

          # Where the page is.
          def url = "http://#{@server.addr[3]}:#{@server.addr[1]}/"

          # Answers one browser after another until stopped (Ctrl-C, or #stop from another thread).
          def serve
            @out.puts "Playing #{File.basename(@game_file)} at #{url} — reload the page to play it as the file is now. " \
                      "Ctrl-C stops."
            loop do
              client = @server.accept
              answer(client)
            rescue IOError, Errno::EBADF
              break # the server was stopped
            end
          end

          def stop = @server.close

          private

          def answer(client)
            request = client.gets.to_s
            client.gets("\r\n\r\n") # the request's headers, which say nothing this needs
            path = request.split(" ")[1].to_s
            if request.start_with?("GET ") && ["/", "/index.html"].include?(path.split("?").first)
              respond(client, 200, page)
            else
              respond(client, 404, "<!doctype html><title>Not here</title><p>The game is at <a href=\"/\">/</a>.</p>")
            end
          rescue Errno::EPIPE, Errno::ECONNRESET
            nil # the browser went away before it was answered
          ensure
            client.close
          end

          def respond(client, status, body)
            reason = status == 200 ? "OK" : "Not Found"
            client.write("HTTP/1.1 #{status} #{reason}\r\nContent-Type: text/html; charset=utf-8\r\n" \
                         "Content-Length: #{body.bytesize}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n")
            client.write(body)
          end

          # The page as the game file says now, or what stopped the build.
          def page
            Dir.mktmpdir("ruby-gba-preview") do |dir|
              path = File.join(dir, "game.html")
              said, status = Open3.capture2e(RbConfig.ruby, RubyGBA.root.join("bin", "ruby-gba").to_s, "build", @game_file,
                                             "--format", "web", "-o", path, *(["--page", @page] if @page),
                                             *settings_arguments)
              built = status.success? && File.exist?(path)
              @out.puts(built ? "Built #{File.basename(@game_file)}" : "The build stopped:\n#{said}")
              built ? File.read(path, encoding: Encoding::UTF_8) : stopped_page(said)
            end
          end

          # Every setting after one --set: the command line keeps only the last of several --set
          # flags, so one flag a setting would hand the build only the last.
          def settings_arguments = @settings.empty? ? [] : ["--set", *@settings]

          def stopped_page(said)
            <<~HTML
              <!doctype html>
              <html lang="en"><head><meta charset="utf-8"><title>The build stopped</title>
              <style>body { background: #111; color: #ddd; font: 14px/1.5 system-ui, sans-serif; margin: 24px; }
              pre { white-space: pre-wrap; background: #1c1c1c; padding: 12px; border-radius: 4px; }</style></head>
              <body><h1>The game did not build</h1><p>Change the game file, then reload this page.</p>
              <pre>#{CGI.escapeHTML(said)}</pre></body></html>
            HTML
          end
        end
      end
    end
  end
end
