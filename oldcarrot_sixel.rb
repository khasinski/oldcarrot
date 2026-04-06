# oldcarrot with sixel display output
# Usage: ruby-0.49 oldcarrot_sixel.rb <rom_file> [frames] [scale]
# Requires a sixel-capable terminal (iTerm2, WezTerm, foot, mlterm, xterm +sixel)

$basedir = $0
$tmpidx = $basedir.rindex("/")
if $tmpidx
  $basedir = $basedir[0, $tmpidx]
else
  $basedir = "."
end

load($basedir + "/lib/palette.rb")
load($basedir + "/lib/rom.rb")
load($basedir + "/lib/pad.rb")
load($basedir + "/lib/cpu.rb")
load($basedir + "/lib/apu.rb")
load($basedir + "/lib/ppu.rb")
load($basedir + "/lib/sixel.rb")

if $*.length < 1
  print("Usage: oldcarrot_sixel.rb <rom_file> [frames] [scale]\n")
  print("  frames: 0 = unlimited (default), N = stop after N frames\n")
  print("  scale:  pixel scale factor (default: 3)\n")
  exit(1)
end

romfile = $*[0]
if $*.length >= 2
  frames = $*[1].to_i
else
  frames = 0
end
if $*.length >= 3
  scale = $*[2].to_i
else
  scale = 3
end

cpu = CPU.new()
ppu = PPU.new(cpu, %PALETTE)
apu = APU.new(cpu, 44100, 16)
rom = ROM.new(cpu, ppu, romfile)
pads = Pads.new(cpu, apu)

cpu.set_apu(apu)
cpu.set_ppu(ppu)
cpu.set_ppu_sync(%FALSE)
cpu.set_rom(rom)
cpu.set_pads(pads)
ppu.set_nametables(rom.mirroring())
ppu.set_chr_mem(rom.chr_ref(), rom.chr_ram())

cpu.do_reset()
apu.reset()
ppu.reset()
rom.reset()
pads.reset()
cpu.boot()
apu.reset_mapping()

enc = SixelEncoder.new(scale)
esc = 27.chr

# Clear screen and hide cursor
$stdout.write(esc + "[2J")
$stdout.write(esc + "[?25l")

frame = 0
t_start = Time.now()

protect
  while frames == 0 || frame < frames
    ppu.setup_frame()
    cpu.run()
    ppu.vsync()
    apu.vsync()
    cpu.vsync()
    rom.vsync()
    frame += 1

    # Move cursor to top-left and render sixel
    $stdout.write(esc + "[H")
    enc.encode(ppu.output_pixels())

    # FPS counter every 10 frames
    if (frame % 10) == 0
      t_now = Time.now()
      elapsed_ms = (t_now.tv_sec - t_start.tv_sec) * 1000 + (t_now.tv_usec - t_start.tv_usec) / 1000
      if elapsed_ms > 0
        fps_x10 = frame * 10000 / elapsed_ms
        $stderr.write(sprintf("\rframe %d  fps: %d.%d  ", frame, fps_x10 / 10, fps_x10 % 10))
      end
    end
  end
ensure
  # Show cursor
  $stdout.write(esc + "[?25h")
  $stderr.write("\n")
end
