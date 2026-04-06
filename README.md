# oldcarrot

A port of the [optcarrot](https://github.com/mame/optcarrot/) NES emulator to [Ruby 0.49](https://github.com/sampersand/ruby-0.49) -- the oldest surviving version of Ruby from 1994.

## What is this?

oldcarrot is a working NES (Nintendo Entertainment System) emulator written entirely in Ruby 0.49 syntax. It was ported from mame's optcarrot, a well-known Ruby NES emulator benchmark.

Ruby 0.49 has fundamental differences from modern Ruby:
- No string interpolation, ternary operator, or modifier `if`
- Blocks use `do method() using var; end` instead of `{ |var| }`
- Class inheritance: `class Foo : Bar` instead of `class Foo < Bar`
- Constants use `%` prefix: `%CONST` instead of `CONST`
- `protect/resque` instead of `begin/rescue`
- `fail()` instead of `raise`
- No `Fiber`, `Proc`, `method()`, `send()`, `Array#map`
- 32-bit signed integers only (no bignum)
- `&` has lower precedence than `==` (major pitfall!)

## Features

- Full 6502 CPU emulation with all official and unofficial opcodes
- PPU (Picture Processing Unit) with background and sprite rendering
- APU (Audio Processing Unit) with all 5 channels
- NROM mapper (mapper 0) support
- NMI interrupt handling
- Headless benchmark mode
- PPM frame dump support

## Usage

```
ruby-0.49 oldcarrot.rb <rom_file> [frames]
```

- `rom_file`: path to a .nes ROM file (NROM/mapper 0 only)
- `frames`: number of frames to run (default: 180)

### Sixel display (terminal graphics)

```
ruby-0.49 oldcarrot_sixel.rb <rom_file> [frames]
```

Renders frames directly in the terminal using Sixel graphics at ~3.6 FPS.
Requires a sixel-capable terminal (iTerm2, WezTerm, foot, mlterm, xterm).
Pass 0 for frames (or omit) to run indefinitely.

### Dumping frames

```
ruby-0.49 dump_frames.rb <rom_file> [frames] [output_dir]
```

Outputs PPM image files that can be converted to PNG with ImageMagick.

### Example

```
$ ruby-0.49 oldcarrot.rb Lan_Master.nes 180
oldcarrot - NES emulator for Ruby 0.49
ROM: Lan_Master.nes
Frames: 180
fps: 4.84
checksum: 56574
```

## Architecture

The emulator is split into components loaded via `load()`:

| File | Description | Lines |
|------|-------------|-------|
| `oldcarrot.rb` | Entry point, NES orchestrator | ~100 |
| `lib/cpu.rb` | 6502 CPU with case-based opcode dispatch | ~1800 |
| `lib/ppu.rb` | PPU state machine (replaces Fiber from optcarrot) | ~1200 |
| `lib/apu.rb` | Audio processing (Pulse, Triangle, Noise, DMC, Mixer) | ~1200 |
| `lib/rom.rb` | iNES ROM loader (NROM mapper 0) | ~160 |
| `lib/pad.rb` | Game controller input | ~110 |
| `lib/palette.rb` | Pre-computed 512-color NES palette | ~65 |
| `lib/sixel.rb` | Sixel graphics encoder for terminal display | ~100 |

### Key porting decisions

- **No Fiber** -- PPU uses a state-machine (`case @hclk`) instead of cooperative multitasking
- **No method() callbacks** -- CPU memory mapping uses direct dispatch in `fetch()`/`store()`
- **No send()** -- CPU opcode dispatch uses a giant `case @opcode` statement
- **No TILE_LUT** -- tile pixels computed inline (the original 2M-entry lookup table won't fit)
- **Clock-based vblank** -- `peek_2002()` checks CPU clock vs vblank timing
- **NMI scheduling** -- scheduled in `setup_frame()` based on `@need_nmi`

## Accuracy

Compared to the reference optcarrot at frame 180 of Lan Master:

- Background tiles: correct layout and colors
- Sprites: correct positions and rendering
- Palette: correct (after fade-in completes)
- Checksum: 56574 vs 59662 reference (~95% match)
- Remaining differences due to fine PPU timing

## Credits

- [optcarrot](https://github.com/mame/optcarrot/) by Yusuke Endoh (mame) -- the original Ruby NES emulator
- [ruby-0.49](https://github.com/sampersand/ruby-0.49) by sampersand -- the restored Ruby 0.49 interpreter
