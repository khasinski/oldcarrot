# ROM loader - NROM mapper (mapper 0) only
# Reads iNES format ROM files

class ROM
  attr("mirroring")
  attr("prg_ref")
  attr("chr_ref")
  attr("chr_ram")

  def ROM.new(cpu, ppu, filename)
    super.init(cpu, ppu, filename)
  end

  def init(cpu, ppu, filename)
    @cpu = cpu
    @ppu = ppu

    # Read file
    f = open(filename, "r")
    f.binmode()
    raw = f.read()
    f.close()

    # Convert to byte array
    @bytes = []
    do raw.each_byte() using b
      @bytes.push(b)
    end

    # Parse header
    if @bytes.length < 16
      fail("Missing 16-byte header")
    end
    if @bytes[0] != 78 || @bytes[1] != 69 || @bytes[2] != 83 || @bytes[3] != 26
      fail("Missing NES constant in header")
    end

    prg_count = @bytes[4]
    chr_count = @bytes[5]
    flags6 = @bytes[6]
    flags7 = @bytes[7]

    if flags6[2] == 1
      fail("trainer not supported")
    end

    # Mirroring: 0=horizontal, 1=vertical
    if flags6[3] == 1
      @mirroring = 2  # four_screen
    elsif flags6[0] == 0
      @mirroring = 0  # horizontal
    else
      @mirroring = 1  # vertical
    end

    @battery = flags6[1] == 1
    @mapper = (flags6 >> 4) | (flags7 & 0xf0)

    if @mapper != 0
      fail(sprintf("Unsupported mapper type 0x%02x (only NROM/mapper 0 supported)", @mapper))
    end

    ram_count = @bytes[8]
    if ram_count < 1
      ram_count = 1
    end

    # Skip header (16 bytes)
    pos = 16

    # Load PRG banks (16KB each)
    if @bytes.length < pos + 0x4000 * prg_count
      fail("EOF in ROM bank data")
    end
    @prg_banks = []
    for i in 0..(prg_count - 1)
      bank = @bytes[pos, 0x4000]
      @prg_banks.push(bank)
      pos += 0x4000
    end

    # Load CHR banks (8KB each)
    if @bytes.length < pos + 0x2000 * chr_count
      fail("EOF in CHR bank data")
    end
    @chr_banks = []
    for i in 0..(chr_count - 1)
      bank = @bytes[pos, 0x2000]
      @chr_banks.push(bank)
      pos += 0x2000
    end

    # Setup PRG reference (64KB address space, only 0x8000-0xFFFF used for PRG)
    @prg_ref = [0] * 0x10000
    # Copy first bank to 0x8000
    for i in 0..0x3fff
      @prg_ref[0x8000 + i] = @prg_banks[0][i]
    end
    # Copy last bank to 0xC000
    last = @prg_banks[@prg_banks.length - 1]
    for i in 0..0x3fff
      @prg_ref[0xc000 + i] = last[i]
    end

    # Setup CHR
    @chr_ram = chr_count == 0
    if @chr_ram
      @chr_ref = [0] * 0x2000
    else
      # Copy first CHR bank
      @chr_ref = []
      for i in 0..0x1fff
        @chr_ref.push(@chr_banks[0][i])
      end
    end

    # Setup work RAM
    @wrk_readable = ram_count > 0
    @wrk_writable = %FALSE
    if ram_count > 0
      @wrk = []
      for addr in 0x6000..0x7fff
        @wrk.push(addr >> 8)
      end
    else
      @wrk = nil
    end

    self
  end

  def reset()
    # NROM: PRG ROM is already mapped, nothing else to do
  end

  def vsync()
    # NROM has no scanline counter
  end

  def peek_6000(addr)
    if @wrk_readable
      @wrk[addr - 0x6000]
    else
      addr >> 8
    end
  end

  def poke_6000(addr, data)
    if @wrk_writable
      @wrk[addr - 0x6000] = data
    end
  end

  def load_battery()
    # Skip battery save for now
  end

  def save_battery()
    # Skip battery save for now
  end
end
