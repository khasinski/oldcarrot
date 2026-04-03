# oldcarrot - NES emulator for Ruby 0.49
# Ported from optcarrot by mame
# https://github.com/mame/optcarrot

# Determine script directory
$basedir = $0
$tmpidx = $basedir.rindex("/")
if $tmpidx
  $basedir = $basedir[0, $tmpidx]
else
  $basedir = "."
end

# Load components
load($basedir + "/lib/palette.rb")
load($basedir + "/lib/rom.rb")
load($basedir + "/lib/pad.rb")
load($basedir + "/lib/cpu.rb")
load($basedir + "/lib/apu.rb")
load($basedir + "/lib/ppu.rb")

class NES
  def NES.new(romfile, frames)
    super.init(romfile, frames)
  end

  def init(romfile, frames)
    @frames = frames

    # Create CPU first
    @cpu = CPU.new()

    # Create PPU with dummy palette (indices 0..4096, same as optcarrot headless)
    @dummy_palette = []
    for i in 0..4096
      @dummy_palette.push(i)
    end
    @ppu = PPU.new(@cpu, @dummy_palette)

    # Create APU
    @apu = APU.new(@cpu, 44100, 16)

    # Load ROM
    @rom = ROM.new(@cpu, @ppu, romfile)

    # Create pads
    @pads = Pads.new(@cpu, @apu)

    # Wire components
    @cpu.set_apu(@apu)
    @cpu.set_ppu(@ppu)
    @cpu.set_ppu_sync(%FALSE)
    @cpu.set_rom(@rom)
    @cpu.set_pads(@pads)

    # Set nametable mirroring from ROM
    @ppu.set_nametables(@rom.mirroring())
    @ppu.set_chr_mem(@rom.chr_ref(), @rom.chr_ram())

    @frame = 0
    self
  end

  def reset()
    @cpu.do_reset()
    @apu.reset()
    @ppu.reset()
    @rom.reset()
    @pads.reset()
    @cpu.boot()
    @apu.reset_mapping()
  end

  def step()
    @ppu.setup_frame()
    @cpu.run()
    @ppu.vsync()
    @apu.vsync()
    @cpu.vsync()
    @rom.vsync()
    @frame += 1
  end

  def run()
    reset()

    t_start = Time.now()
    while @frame < @frames
      step()
    end
    t_end = Time.now()

    elapsed_s = t_end.tv_sec - t_start.tv_sec
    elapsed_us = t_end.tv_usec - t_start.tv_usec
    elapsed_ms = elapsed_s * 1000 + elapsed_us / 1000
    if elapsed_ms > 0
      fps_x100 = @frames * 100000 / elapsed_ms
      printf("fps: %d.%02d\n", fps_x100 / 100, fps_x100 % 100)
    else
      print("fps: (too fast to measure)\n")
    end
    # Compute video checksum
    pixels = @ppu.output_pixels()
    checksum = 0
    for i in 0..(pixels.length - 1)
      checksum += pixels[i] & 0xff
    end
    # Match Ruby's String#sum which returns sum % 2^16
    checksum = checksum & 0xffff
    printf("checksum: %d\n", checksum)
  end
end

# Parse arguments
if $*.length < 1
  print("Usage: oldcarrot <rom_file> [frames]\n")
  print("  rom_file: path to .nes ROM file (NROM/mapper 0 only)\n")
  print("  frames: number of frames to run (default: 180)\n")
  exit(1)
end

romfile = $*[0]
if $*.length >= 2
  frames = $*[1].to_i
else
  frames = 180
end

printf("oldcarrot - NES emulator for Ruby 0.49\n")
printf("ROM: %s\n", romfile)
printf("Frames: %d\n", frames)

nes = NES.new(romfile, frames)
nes.run()
