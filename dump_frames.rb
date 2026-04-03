# Dump frames as PPM image files
# Usage: ruby-0.49 dump_frames.rb <rom> [frames] [output_dir]

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

if $*.length < 1
  print("Usage: dump_frames.rb <rom> [frames] [output_dir]\n")
  exit(1)
end

romfile = $*[0]
if $*.length >= 2
  frames = $*[1].to_i
else
  frames = 10
end
if $*.length >= 3
  outdir = $*[2]
else
  outdir = "."
end

# Use real RGB palette for rendering
cpu = CPU.new()
ppu = PPU.new(cpu, %PALETTE)
apu = APU.new(cpu, 44100, 16)
rom = ROM.new(cpu, ppu, romfile)
pads = Pads.new(cpu, apu)

cpu.set_apu(apu)
cpu.set_ppu(ppu)
cpu.set_ppu_sync(%TRUE)
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

for f in 1..frames
  ppu.setup_frame()
  cpu.run()
  ppu.vsync()
  apu.vsync()
  cpu.vsync()
  rom.vsync()

  # Write PPM file
  filename = sprintf("%s/frame_%03d.ppm", outdir, f)
  out = open(filename, "w")
  out.binmode()
  out.write("P6\n256 240\n255\n")

  px = ppu.output_pixels()
  for i in 0..(px.length - 1)
    rgb = px[i]
    r = (rgb >> 16) & 0xff
    g = (rgb >> 8) & 0xff
    b = rgb & 0xff
    out.write(sprintf("%c%c%c", r, g, b))
  end
  out.close()
  printf("frame %3d -> %s\n", f, filename)
end

print("Done.\n")
