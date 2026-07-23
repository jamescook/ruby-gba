# License

## MIT License

Copyright (c) 2026 James Cook

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

---

## Trademarks

"Nintendo" and "Game Boy Advance" are trademarks of Nintendo. This project is an
independent, unofficial developer tool. It is **not** affiliated with, authorized
by, sponsored by, or endorsed by Nintendo. References to the Game Boy Advance
identify the hardware platform this tool targets (nominative use) and imply no
association with or endorsement by Nintendo.

## The Nintendo boot logo (important)

The Game Boy Advance BIOS will not boot a cartridge unless its header (offset
`0x04`–`0x9F`) contains a specific 156-byte Nintendo logo bitmap. To produce ROMs
that run on real hardware and on accuracy-focused emulators, this tool writes those
bytes into the ROM header (see `HEADER_LOGO_BYTES` in
`lib/ruby_gba/constants.rb`).

That logo is the intellectual property of Nintendo. It is reproduced here **solely
for interoperability** — it is functionally required for a cartridge to boot — and
it is **NOT** covered by the MIT license above. No rights to the Nintendo logo are
claimed or granted by this project, and Nintendo retains all rights to it. If you
distribute ROMs built with this tool, you are responsible for your own compliance.
