# CPU (6502) implementation for Ruby 0.49
# Ported from optcarrot - replaces method(:name) callbacks with direct dispatch
# and send(*DISPATCH) with a case statement

%FOREVER_CLOCK = 0x7fffffff
%RP2A03_CC = 12

%NMI_VECTOR   = 0xfffa
%RESET_VECTOR = 0xfffc
%IRQ_VECTOR   = 0xfffe

%IRQ_EXT   = 0x01
%IRQ_FRAME = 0x40
%IRQ_DMC   = 0x80

%CLK_1 = 12
%CLK_2 = 24
%CLK_3 = 36
%CLK_4 = 48
%CLK_5 = 60
%CLK_6 = 72
%CLK_7 = 84
%CLK_8 = 96

class CPU
  def CPU.new()
    super.init()
  end

  def init()
    # Main memory
    @ram = [0] * 0x800

    # Clock management
    @clk = 0
    @clk_frame = 0
    @clk_target = 0
    @clk_nmi = %FOREVER_CLOCK
    @clk_irq = %FOREVER_CLOCK
    @clk_total = 0

    # Interrupt
    @irq_flags = 0
    @jammed = %FALSE

    # Components (set externally)
    @apu = nil
    @ppu = nil
    @ppu_sync = %FALSE
    @rom = nil
    @pads = nil

    # Temporary store
    @addr = 0
    @data = 0
    @opcode = 0

    do_reset()
    self
  end

  def set_apu(a)
    @apu = a
  end

  def set_ppu(p)
    @ppu = p
  end

  def set_ppu_sync(v)
    @ppu_sync = v
  end

  def set_rom(r)
    @rom = r
  end

  def set_pads(p)
    @pads = p
  end

  def ram()
    @ram
  end

  def current_clock()
    @clk
  end

  def next_frame_clock()
    @clk_frame
  end

  def set_next_frame_clock(clk)
    @clk_frame = clk
    if clk < @clk_target
      @clk_target = clk
    end
  end

  def steal_clocks(clk)
    @clk += clk
  end

  def odd_clock()
    (@clk_total + @clk) % %CLK_2 != 0
  end

  def do_update()
    @apu.clock_dma(@clk)
    @clk
  end

  def dmc_dma(addr)
    @clk += %CLK_3
    buf = fetch(addr)
    @clk += %CLK_1
    buf
  end

  def sprite_dma(addr, sp_ram)
    for i in 0..255
      sp_ram[i] = @ram[addr + i]
    end
    for i in 0..63
      sp_ram[i * 4 + 2] &= 0xe3
    end
  end

  def do_reset()
    @_a = 0
    @_x = 0
    @_y = 0
    @_sp = 0xfd
    @_pc = 0xfffc

    # P register (decomposed)
    @_p_nz = 1
    @_p_c = 0
    @_p_v = 0
    @_p_i = 0x04
    @_p_d = 0

    @clk = 0
    @clk_total = 0

    # Fill RAM with 0xFF
    @ram.fill(0xff)
  end

  def boot()
    @clk = %CLK_7
    @_pc = peek16(%RESET_VECTOR)
  end

  def vsync()
    if @ppu_sync
      @ppu.sync(@clk)
    end

    @clk -= @clk_frame
    @clk_total += @clk_frame

    if @clk_nmi != %FOREVER_CLOCK
      @clk_nmi -= @clk_frame
    end
    if @clk_irq != %FOREVER_CLOCK
      @clk_irq -= @clk_frame
    end
    if @clk_irq < 0
      @clk_irq = 0
    end
  end

  #---------------------------------------------------------------------------
  # Memory access - direct dispatch instead of callback tables
  #---------------------------------------------------------------------------

  def fetch(addr)
    if addr < 0x2000
      return @ram[addr & 0x7ff]
    elsif addr < 0x4000
      reg = addr & 7
      if reg == 2
        return @ppu.peek_2002()
      elsif reg == 4
        return @ppu.peek_2004()
      elsif reg == 7
        return @ppu.peek_2007()
      else
        return @ppu.peek_2xxx()
      end
    elsif addr < 0x4020
      off = addr & 0x1f
      if off == 0x14
        return 0x40
      elsif off == 0x15
        return @apu.peek_4015()
      elsif off == 0x16 || off == 0x17
        return @pads.peek_401x(addr)
      else
        return 0x40
      end
    elsif addr >= 0x8000
      return @rom.prg_ref()[addr]
    elsif addr >= 0x6000
      return @rom.peek_6000(addr)
    else
      return addr >> 8
    end
  end

  def store(addr, value)
    if addr < 0x2000
      @ram[addr & 0x7ff] = value
    elsif addr < 0x4000
      reg = addr & 7
      if reg == 0
        @ppu.poke_2000(value)
      elsif reg == 1
        @ppu.poke_2001(value)
      elsif reg == 2
        @ppu.poke_2xxx(value)
      elsif reg == 3
        @ppu.poke_2003(value)
      elsif reg == 4
        @ppu.poke_2004(value)
      elsif reg == 5
        @ppu.poke_2005(value)
      elsif reg == 6
        @ppu.poke_2006(value)
      elsif reg == 7
        @ppu.poke_2007(value)
      end
    elsif addr < 0x4020
      off = addr & 0x1f
      if off <= 0x13
        @apu.poke_reg(addr, value)
      elsif off == 0x14
        @ppu.poke_4014(value)
      elsif off == 0x15
        @apu.poke_4015(value)
      elsif off == 0x16
        @pads.poke_4016(value)
      elsif off == 0x17
        @apu.poke_4017(value)
      end
    elsif addr >= 0x6000 && addr < 0x8000
      @rom.poke_6000(addr, value)
    end
    # Writes to ROM space (0x8000+) are ignored for NROM
  end

  def peek16(addr)
    fetch(addr) + (fetch(addr + 1) << 8)
  end

  #---------------------------------------------------------------------------
  # Interrupts
  #---------------------------------------------------------------------------

  def clear_irq(line)
    old = @irq_flags & (%IRQ_FRAME | %IRQ_DMC)
    @irq_flags &= line ^ (%IRQ_EXT | %IRQ_FRAME | %IRQ_DMC)
    if @irq_flags == 0
      @clk_irq = %FOREVER_CLOCK
    end
    old
  end

  def next_interrupt_clock(clk)
    clk += %CLK_1 + %CLK_1 / 2
    if @clk_target > clk
      @clk_target = clk
    end
    clk
  end

  def do_irq(line, clk)
    @irq_flags |= line
    if @clk_irq == %FOREVER_CLOCK && @_p_i == 0
      @clk_irq = next_interrupt_clock(clk)
    end
  end

  def do_nmi(clk)
    if @clk_nmi == %FOREVER_CLOCK
      @clk_nmi = next_interrupt_clock(clk)
    end
  end

  def do_isr(vector)
    if @jammed
      return
    end
    push16(@_pc)
    push8(flags_pack())
    @_p_i = 0x04
    @clk += %CLK_7
    if vector == %NMI_VECTOR
      isr_addr = %NMI_VECTOR
    else
      isr_addr = fetch_irq_isr_vector()
    end
    @_pc = peek16(isr_addr)
  end

  def fetch_irq_isr_vector()
    if @clk >= @clk_frame
      fetch(0x3000)
    end
    if @clk_nmi != %FOREVER_CLOCK
      if @clk_nmi + %CLK_2 <= @clk
        @clk_nmi = %FOREVER_CLOCK
        return %NMI_VECTOR
      end
      @clk_nmi = @clk + 1
    end
    return %IRQ_VECTOR
  end

  #---------------------------------------------------------------------------
  # P register helpers
  #---------------------------------------------------------------------------

  def flags_pack()
    ((@_p_nz | @_p_nz >> 1) & 0x80) |
      (if (@_p_nz & 0xff) != 0 then 0 else 2 end) |
      @_p_c |
      (if @_p_v != 0 then 0x40 else 0 end) |
      @_p_i |
      @_p_d |
      0x20
  end

  def flags_unpack(f)
    @_p_nz = (~f & 2) | ((f & 0x80) << 1)
    @_p_c = f & 0x01
    @_p_v = f & 0x40
    @_p_i = f & 0x04
    @_p_d = f & 0x08
  end

  #---------------------------------------------------------------------------
  # Stack
  #---------------------------------------------------------------------------

  def push8(data)
    @ram[0x0100 + @_sp] = data
    @_sp = (@_sp - 1) & 0xff
  end

  def push16(data)
    push8(data >> 8)
    push8(data & 0xff)
  end

  def pull8()
    @_sp = (@_sp + 1) & 0xff
    @ram[0x0100 + @_sp]
  end

  def pull16()
    pull8() + 256 * pull8()
  end

  #---------------------------------------------------------------------------
  # Branch helper
  #---------------------------------------------------------------------------

  def branch(cond)
    if cond
      tmp = @_pc + 1
      rel = fetch(@_pc)
      if rel < 128
        @_pc = (tmp + rel) & 0xffff
      else
        @_pc = (tmp + (rel | 0xff00)) & 0xffff
      end
      if tmp[8] == @_pc[8]
        @clk += %CLK_3
      else
        @clk += %CLK_4
      end
    else
      @_pc += 1
      @clk += %CLK_2
    end
  end

  #---------------------------------------------------------------------------
  # Addressing modes
  #---------------------------------------------------------------------------

  def addr_imm()
    @data = fetch(@_pc)
    @_pc += 1
    @clk += %CLK_2
  end

  def addr_zpg(read, write)
    @addr = fetch(@_pc)
    @_pc += 1
    @clk += %CLK_3
    if read
      @data = @ram[@addr]
      if write
        @clk += %CLK_2
      end
    end
  end

  def addr_zpg_x(read, write)
    @addr = (fetch(@_pc) + @_x) & 0xff
    @_pc += 1
    @clk += %CLK_4
    if read
      @data = @ram[@addr]
      if write
        @clk += %CLK_2
      end
    end
  end

  def addr_zpg_y(read, write)
    @addr = (fetch(@_pc) + @_y) & 0xff
    @_pc += 1
    @clk += %CLK_4
    if read
      @data = @ram[@addr]
      if write
        @clk += %CLK_2
      end
    end
  end

  def addr_abs(read, write)
    @addr = peek16(@_pc)
    @_pc += 2
    @clk += %CLK_3
    if read
      @data = fetch(@addr)
      @clk += %CLK_1
      if write
        store(@addr, @data)
        @clk += %CLK_1
      end
    end
  end

  def addr_abs_x(read, write)
    a2 = @_pc + 1
    i = @_x + fetch(@_pc)
    @addr = ((fetch(a2) << 8) + i) & 0xffff
    if write
      a3 = (@addr - (i & 0x100)) & 0xffff
      fetch(a3)
      @clk += %CLK_4
    else
      @clk += %CLK_3
      if (i & 0x100) != 0
        a3 = (@addr - 0x100) & 0xffff
        fetch(a3)
        @clk += %CLK_1
      end
    end
    if read
      @data = fetch(@addr)
      @clk += %CLK_1
      if write
        store(@addr, @data)
        @clk += %CLK_1
      end
    end
    @_pc += 2
  end

  def addr_abs_y(read, write)
    a2 = @_pc + 1
    i = @_y + fetch(@_pc)
    @addr = ((fetch(a2) << 8) + i) & 0xffff
    if write
      a3 = (@addr - (i & 0x100)) & 0xffff
      fetch(a3)
      @clk += %CLK_4
    else
      @clk += %CLK_3
      if (i & 0x100) != 0
        a3 = (@addr - 0x100) & 0xffff
        fetch(a3)
        @clk += %CLK_1
      end
    end
    if read
      @data = fetch(@addr)
      @clk += %CLK_1
      if write
        store(@addr, @data)
        @clk += %CLK_1
      end
    end
    @_pc += 2
  end

  def addr_ind_x(read, write)
    a = fetch(@_pc) + @_x
    @_pc += 1
    @clk += %CLK_5
    @addr = @ram[a & 0xff] | @ram[(a + 1) & 0xff] << 8
    if read
      @data = fetch(@addr)
      @clk += %CLK_1
      if write
        store(@addr, @data)
        @clk += %CLK_1
      end
    end
  end

  def addr_ind_y(read, write)
    a = fetch(@_pc)
    @_pc += 1
    indexed = @ram[a] + @_y
    @clk += %CLK_4
    if write
      @clk += %CLK_1
      @addr = (@ram[(a + 1) & 0xff] << 8) + indexed
      a2 = @addr - (indexed & 0x100)
      fetch(a2)
    else
      @addr = ((@ram[(a + 1) & 0xff] << 8) + indexed) & 0xffff
      if (indexed & 0x100) != 0
        a2 = (@addr - 0x100) & 0xffff
        fetch(a2)
        @clk += %CLK_1
      end
    end
    if read
      @data = fetch(@addr)
      @clk += %CLK_1
      if write
        store(@addr, @data)
        @clk += %CLK_1
      end
    end
  end

  #---------------------------------------------------------------------------
  # Store helpers
  #---------------------------------------------------------------------------

  def store_mem()
    store(@addr, @data)
    @clk += %CLK_1
  end

  def store_zpg()
    @ram[@addr] = @data
  end

  #---------------------------------------------------------------------------
  # Instructions
  #---------------------------------------------------------------------------

  # Load
  def op_lda()
    @_p_nz = @_a = @data
  end
  def op_ldx()
    @_p_nz = @_x = @data
  end
  def op_ldy()
    @_p_nz = @_y = @data
  end

  # Store
  def op_sta()
    @data = @_a
  end
  def op_stx()
    @data = @_x
  end
  def op_sty()
    @data = @_y
  end

  # Transfer
  def op_tax()
    @clk += %CLK_2
    @_p_nz = @_x = @_a
  end
  def op_tay()
    @clk += %CLK_2
    @_p_nz = @_y = @_a
  end
  def op_txa()
    @clk += %CLK_2
    @_p_nz = @_a = @_x
  end
  def op_tya()
    @clk += %CLK_2
    @_p_nz = @_a = @_y
  end

  # Flow control
  def op_jmp_a()
    @_pc = peek16(@_pc)
    @clk += %CLK_3
  end

  def op_jmp_i()
    pos = peek16(@_pc)
    low = fetch(pos)
    pos2 = (pos & 0xff00) | ((pos + 1) & 0x00ff)
    high = fetch(pos2)
    @_pc = high * 256 + low
    @clk += %CLK_5
  end

  def op_jsr()
    data = @_pc + 1
    push16(data)
    @_pc = peek16(@_pc)
    @clk += %CLK_6
  end

  def op_rts()
    @_pc = (pull16() + 1) & 0xffff
    @clk += %CLK_6
  end

  def op_rti()
    @clk += %CLK_6
    packed = pull8()
    @_pc = pull16()
    flags_unpack(packed)
    if @irq_flags == 0 || @_p_i != 0
      @clk_irq = %FOREVER_CLOCK
    else
      @clk_irq = 0
      @clk_target = 0
    end
  end

  # Branches
  def op_bne()
    branch((@_p_nz & 0xff) != 0)
  end
  def op_beq()
    branch((@_p_nz & 0xff) == 0)
  end
  def op_bmi()
    branch((@_p_nz & 0x180) != 0)
  end
  def op_bpl()
    branch((@_p_nz & 0x180) == 0)
  end
  def op_bcs()
    branch(@_p_c != 0)
  end
  def op_bcc()
    branch(@_p_c == 0)
  end
  def op_bvs()
    branch(@_p_v != 0)
  end
  def op_bvc()
    branch(@_p_v == 0)
  end

  # Math
  def op_adc()
    tmp = @_a + @data + @_p_c
    @_p_v = ~(@_a ^ @data) & (@_a ^ tmp) & 0x80
    @_p_nz = @_a = tmp & 0xff
    @_p_c = tmp[8]
  end

  def op_sbc()
    data = @data ^ 0xff
    tmp = @_a + data + @_p_c
    @_p_v = ~(@_a ^ data) & (@_a ^ tmp) & 0x80
    @_p_nz = @_a = tmp & 0xff
    @_p_c = tmp[8]
  end

  # Logic
  def op_and()
    @_p_nz = @_a = @_a & @data
  end
  def op_ora()
    @_p_nz = @_a = @_a | @data
  end
  def op_eor()
    @_p_nz = @_a = @_a ^ @data
  end

  def op_bit()
    @_p_nz = (if (@data & @_a) != 0 then 1 else 0 end) | ((@data & 0x80) << 1)
    @_p_v = @data & 0x40
  end

  def op_cmp()
    data = @_a - @data
    @_p_nz = data & 0xff
    @_p_c = 1 - data[8]
  end
  def op_cpx()
    data = @_x - @data
    @_p_nz = data & 0xff
    @_p_c = 1 - data[8]
  end
  def op_cpy()
    data = @_y - @data
    @_p_nz = data & 0xff
    @_p_c = 1 - data[8]
  end

  # Shift
  def op_asl()
    @_p_c = @data >> 7
    @data = @_p_nz = @data << 1 & 0xff
  end
  def op_lsr()
    @_p_c = @data & 1
    @data = @_p_nz = @data >> 1
  end
  def op_rol()
    @_p_nz = (@data << 1 & 0xff) | @_p_c
    @_p_c = @data >> 7
    @data = @_p_nz
  end
  def op_ror()
    @_p_nz = (@data >> 1) | (@_p_c << 7)
    @_p_c = @data & 1
    @data = @_p_nz
  end

  # Inc/Dec
  def op_dec()
    @data = @_p_nz = (@data - 1) & 0xff
  end
  def op_inc()
    @data = @_p_nz = (@data + 1) & 0xff
  end
  def op_dex()
    @clk += %CLK_2
    @data = @_p_nz = @_x = (@_x - 1) & 0xff
  end
  def op_dey()
    @clk += %CLK_2
    @data = @_p_nz = @_y = (@_y - 1) & 0xff
  end
  def op_inx()
    @clk += %CLK_2
    @data = @_p_nz = @_x = (@_x + 1) & 0xff
  end
  def op_iny()
    @clk += %CLK_2
    @data = @_p_nz = @_y = (@_y + 1) & 0xff
  end

  # Flags
  def op_clc()
    @clk += %CLK_2
    @_p_c = 0
  end
  def op_sec()
    @clk += %CLK_2
    @_p_c = 1
  end
  def op_cld()
    @clk += %CLK_2
    @_p_d = 0
  end
  def op_sed()
    @clk += %CLK_2
    @_p_d = 8
  end
  def op_clv()
    @clk += %CLK_2
    @_p_v = 0
  end

  def op_sei()
    @clk += %CLK_2
    if @_p_i == 0
      @_p_i = 0x04
      @clk_irq = %FOREVER_CLOCK
      if @irq_flags != 0
        do_isr(%IRQ_VECTOR)
      end
    end
  end

  def op_cli()
    @clk += %CLK_2
    if @_p_i != 0
      @_p_i = 0
      if @irq_flags != 0
        clk2 = @clk + 1
        @clk_irq = clk2
        if @clk_target > clk2
          @clk_target = clk2
        end
      end
    end
  end

  # Stack
  def op_pha()
    @clk += %CLK_3
    push8(@_a)
  end
  def op_php()
    @clk += %CLK_3
    push8(flags_pack() | 0x10)
  end
  def op_pla()
    @clk += %CLK_4
    @_p_nz = @_a = pull8()
  end
  def op_plp()
    @clk += %CLK_4
    i = @_p_i
    flags_unpack(pull8())
    if @irq_flags != 0
      if i > @_p_i
        clk2 = @clk + 1
        @clk_irq = clk2
        if @clk_target > clk2
          @clk_target = clk2
        end
      elsif i < @_p_i
        @clk_irq = %FOREVER_CLOCK
        do_isr(%IRQ_VECTOR)
      end
    end
  end
  def op_tsx()
    @clk += %CLK_2
    @_p_nz = @_x = @_sp
  end
  def op_txs()
    @clk += %CLK_2
    @_sp = @_x
  end

  # Undocumented
  def op_anc()
    @_p_nz = @_a = @_a & @data
    @_p_c = @_p_nz >> 7
  end
  def op_ane()
    @_a = (@_a | 0xee) & @_x & @data
    @_p_nz = @_a
  end
  def op_arr()
    @_a = ((@data & @_a) >> 1) | (@_p_c << 7)
    @_p_nz = @_a
    @_p_c = @_a[6]
    @_p_v = @_a[6] ^ @_a[5]
  end
  def op_asr()
    @_p_c = @data & @_a & 0x1
    @_p_nz = @_a = (@data & @_a) >> 1
  end
  def op_dcp()
    @data = (@data - 1) & 0xff
    op_cmp()
  end
  def op_isb()
    @data = (@data + 1) & 0xff
    op_sbc()
  end
  def op_las()
    @_sp &= @data
    @_p_nz = @_a = @_x = @_sp
  end
  def op_lax()
    @_p_nz = @_a = @_x = @data
  end
  def op_lxa()
    @_p_nz = @_a = @_x = @data
  end
  def op_rla()
    c = @_p_c
    @_p_c = @data >> 7
    @data = (@data << 1 & 0xff) | c
    @_p_nz = @_a = @_a & @data
  end
  def op_rra()
    c = @_p_c << 7
    @_p_c = @data & 1
    @data = (@data >> 1) | c
    op_adc()
  end
  def op_sax()
    @data = @_a & @_x
  end
  def op_sbx()
    @data = (@_a & @_x) - @data
    if (@data & 0xffff) <= 0xff
      @_p_c = 1
    else
      @_p_c = 0
    end
    @_p_nz = @_x = @data & 0xff
  end
  def op_sha()
    @data = @_a & @_x & ((@addr >> 8) + 1)
  end
  def op_shs()
    @_sp = @_a & @_x
    @data = @_sp & ((@addr >> 8) + 1)
  end
  def op_shx()
    @data = @_x & ((@addr >> 8) + 1)
    @addr = (@data << 8) | (@addr & 0xff)
  end
  def op_shy()
    @data = @_y & ((@addr >> 8) + 1)
    @addr = (@data << 8) | (@addr & 0xff)
  end
  def op_slo()
    @_p_c = @data >> 7
    @data = @data << 1 & 0xff
    @_p_nz = @_a = @_a | @data
  end
  def op_sre()
    @_p_c = @data & 1
    @data >>= 1
    @_p_nz = @_a = @_a ^ @data
  end

  def op_nop()
  end

  def op_brk()
    data = @_pc + 1
    push16(data)
    data = flags_pack() | 0x10
    push8(data)
    @_p_i = 0x04
    @clk_irq = %FOREVER_CLOCK
    @clk += %CLK_7
    a = fetch_irq_isr_vector()
    @_pc = peek16(a)
  end

  def op_jam()
    @_pc = (@_pc - 1) & 0xffff
    @clk += %CLK_2
    unless @jammed
      @jammed = %TRUE
      @clk_nmi = %FOREVER_CLOCK
      @clk_irq = %FOREVER_CLOCK
      @irq_flags = 0
    end unless
  end

  #---------------------------------------------------------------------------
  # Clock management
  #---------------------------------------------------------------------------

  def do_clock()
    clock = @apu.do_clock()

    if clock > @clk_frame
      clock = @clk_frame
    end

    if @clk < @clk_nmi
      if clock > @clk_nmi
        clock = @clk_nmi
      end
      if @clk < @clk_irq
        if clock > @clk_irq
          clock = @clk_irq
        end
      else
        @clk_irq = %FOREVER_CLOCK
        do_isr(%IRQ_VECTOR)
      end
    else
      @clk_nmi = %FOREVER_CLOCK
      @clk_irq = %FOREVER_CLOCK
      do_isr(%NMI_VECTOR)
    end
    @clk_target = clock
  end

  #---------------------------------------------------------------------------
  # Main run loop with giant case for opcode dispatch
  #---------------------------------------------------------------------------

  def run()
    do_clock()

    while %TRUE
      while %TRUE
        @opcode = fetch(@_pc)
        @_pc += 1
        execute_opcode()
        if @ppu_sync
          @ppu.sync(@clk)
        end
        if @clk >= @clk_target
          break
        end
      end
      do_clock()
      if @clk >= @clk_frame
        break
      end
    end
  end

  def execute_opcode()
    case @opcode
    # LDA
    when 0xa9
      addr_imm()
      op_lda()
    when 0xa5
      addr_zpg(%TRUE, %FALSE)
      op_lda()
    when 0xb5
      addr_zpg_x(%TRUE, %FALSE)
      op_lda()
    when 0xad
      addr_abs(%TRUE, %FALSE)
      op_lda()
    when 0xbd
      addr_abs_x(%TRUE, %FALSE)
      op_lda()
    when 0xb9
      addr_abs_y(%TRUE, %FALSE)
      op_lda()
    when 0xa1
      addr_ind_x(%TRUE, %FALSE)
      op_lda()
    when 0xb1
      addr_ind_y(%TRUE, %FALSE)
      op_lda()

    # LDX
    when 0xa2
      addr_imm()
      op_ldx()
    when 0xa6
      addr_zpg(%TRUE, %FALSE)
      op_ldx()
    when 0xb6
      addr_zpg_y(%TRUE, %FALSE)
      op_ldx()
    when 0xae
      addr_abs(%TRUE, %FALSE)
      op_ldx()
    when 0xbe
      addr_abs_y(%TRUE, %FALSE)
      op_ldx()

    # LDY
    when 0xa0
      addr_imm()
      op_ldy()
    when 0xa4
      addr_zpg(%TRUE, %FALSE)
      op_ldy()
    when 0xb4
      addr_zpg_x(%TRUE, %FALSE)
      op_ldy()
    when 0xac
      addr_abs(%TRUE, %FALSE)
      op_ldy()
    when 0xbc
      addr_abs_x(%TRUE, %FALSE)
      op_ldy()

    # STA
    when 0x85
      addr_zpg(%FALSE, %TRUE)
      op_sta()
      store_zpg()
    when 0x95
      addr_zpg_x(%FALSE, %TRUE)
      op_sta()
      store_zpg()
    when 0x8d
      addr_abs(%FALSE, %TRUE)
      op_sta()
      store_mem()
    when 0x9d
      addr_abs_x(%FALSE, %TRUE)
      op_sta()
      store_mem()
    when 0x99
      addr_abs_y(%FALSE, %TRUE)
      op_sta()
      store_mem()
    when 0x81
      addr_ind_x(%FALSE, %TRUE)
      op_sta()
      store_mem()
    when 0x91
      addr_ind_y(%FALSE, %TRUE)
      op_sta()
      store_mem()

    # STX
    when 0x86
      addr_zpg(%FALSE, %TRUE)
      op_stx()
      store_zpg()
    when 0x96
      addr_zpg_y(%FALSE, %TRUE)
      op_stx()
      store_zpg()
    when 0x8e
      addr_abs(%FALSE, %TRUE)
      op_stx()
      store_mem()

    # STY
    when 0x84
      addr_zpg(%FALSE, %TRUE)
      op_sty()
      store_zpg()
    when 0x94
      addr_zpg_x(%FALSE, %TRUE)
      op_sty()
      store_zpg()
    when 0x8c
      addr_abs(%FALSE, %TRUE)
      op_sty()
      store_mem()

    # Transfer
    when 0xaa
      op_tax()
    when 0xa8
      op_tay()
    when 0x8a
      op_txa()
    when 0x98
      op_tya()

    # Flow control
    when 0x4c
      op_jmp_a()
    when 0x6c
      op_jmp_i()
    when 0x20
      op_jsr()
    when 0x60
      op_rts()
    when 0x40
      op_rti()

    # Branches
    when 0xd0
      op_bne()
    when 0xf0
      op_beq()
    when 0x30
      op_bmi()
    when 0x10
      op_bpl()
    when 0xb0
      op_bcs()
    when 0x90
      op_bcc()
    when 0x70
      op_bvs()
    when 0x50
      op_bvc()

    # ADC
    when 0x69
      addr_imm()
      op_adc()
    when 0x65
      addr_zpg(%TRUE, %FALSE)
      op_adc()
    when 0x75
      addr_zpg_x(%TRUE, %FALSE)
      op_adc()
    when 0x6d
      addr_abs(%TRUE, %FALSE)
      op_adc()
    when 0x7d
      addr_abs_x(%TRUE, %FALSE)
      op_adc()
    when 0x79
      addr_abs_y(%TRUE, %FALSE)
      op_adc()
    when 0x61
      addr_ind_x(%TRUE, %FALSE)
      op_adc()
    when 0x71
      addr_ind_y(%TRUE, %FALSE)
      op_adc()

    # SBC
    when 0xe9, 0xeb
      addr_imm()
      op_sbc()
    when 0xe5
      addr_zpg(%TRUE, %FALSE)
      op_sbc()
    when 0xf5
      addr_zpg_x(%TRUE, %FALSE)
      op_sbc()
    when 0xed
      addr_abs(%TRUE, %FALSE)
      op_sbc()
    when 0xfd
      addr_abs_x(%TRUE, %FALSE)
      op_sbc()
    when 0xf9
      addr_abs_y(%TRUE, %FALSE)
      op_sbc()
    when 0xe1
      addr_ind_x(%TRUE, %FALSE)
      op_sbc()
    when 0xf1
      addr_ind_y(%TRUE, %FALSE)
      op_sbc()

    # AND
    when 0x29
      addr_imm()
      op_and()
    when 0x25
      addr_zpg(%TRUE, %FALSE)
      op_and()
    when 0x35
      addr_zpg_x(%TRUE, %FALSE)
      op_and()
    when 0x2d
      addr_abs(%TRUE, %FALSE)
      op_and()
    when 0x3d
      addr_abs_x(%TRUE, %FALSE)
      op_and()
    when 0x39
      addr_abs_y(%TRUE, %FALSE)
      op_and()
    when 0x21
      addr_ind_x(%TRUE, %FALSE)
      op_and()
    when 0x31
      addr_ind_y(%TRUE, %FALSE)
      op_and()

    # ORA
    when 0x09
      addr_imm()
      op_ora()
    when 0x05
      addr_zpg(%TRUE, %FALSE)
      op_ora()
    when 0x15
      addr_zpg_x(%TRUE, %FALSE)
      op_ora()
    when 0x0d
      addr_abs(%TRUE, %FALSE)
      op_ora()
    when 0x1d
      addr_abs_x(%TRUE, %FALSE)
      op_ora()
    when 0x19
      addr_abs_y(%TRUE, %FALSE)
      op_ora()
    when 0x01
      addr_ind_x(%TRUE, %FALSE)
      op_ora()
    when 0x11
      addr_ind_y(%TRUE, %FALSE)
      op_ora()

    # EOR
    when 0x49
      addr_imm()
      op_eor()
    when 0x45
      addr_zpg(%TRUE, %FALSE)
      op_eor()
    when 0x55
      addr_zpg_x(%TRUE, %FALSE)
      op_eor()
    when 0x4d
      addr_abs(%TRUE, %FALSE)
      op_eor()
    when 0x5d
      addr_abs_x(%TRUE, %FALSE)
      op_eor()
    when 0x59
      addr_abs_y(%TRUE, %FALSE)
      op_eor()
    when 0x41
      addr_ind_x(%TRUE, %FALSE)
      op_eor()
    when 0x51
      addr_ind_y(%TRUE, %FALSE)
      op_eor()

    # BIT
    when 0x24
      addr_zpg(%TRUE, %FALSE)
      op_bit()
    when 0x2c
      addr_abs(%TRUE, %FALSE)
      op_bit()

    # CMP
    when 0xc9
      addr_imm()
      op_cmp()
    when 0xc5
      addr_zpg(%TRUE, %FALSE)
      op_cmp()
    when 0xd5
      addr_zpg_x(%TRUE, %FALSE)
      op_cmp()
    when 0xcd
      addr_abs(%TRUE, %FALSE)
      op_cmp()
    when 0xdd
      addr_abs_x(%TRUE, %FALSE)
      op_cmp()
    when 0xd9
      addr_abs_y(%TRUE, %FALSE)
      op_cmp()
    when 0xc1
      addr_ind_x(%TRUE, %FALSE)
      op_cmp()
    when 0xd1
      addr_ind_y(%TRUE, %FALSE)
      op_cmp()

    # CPX
    when 0xe0
      addr_imm()
      op_cpx()
    when 0xe4
      addr_zpg(%TRUE, %FALSE)
      op_cpx()
    when 0xec
      addr_abs(%TRUE, %FALSE)
      op_cpx()

    # CPY
    when 0xc0
      addr_imm()
      op_cpy()
    when 0xc4
      addr_zpg(%TRUE, %FALSE)
      op_cpy()
    when 0xcc
      addr_abs(%TRUE, %FALSE)
      op_cpy()

    # ASL
    when 0x0a
      @clk += %CLK_2
      @data = @_a
      op_asl()
      @_a = @data
    when 0x06
      addr_zpg(%TRUE, %TRUE)
      op_asl()
      store_zpg()
    when 0x16
      addr_zpg_x(%TRUE, %TRUE)
      op_asl()
      store_zpg()
    when 0x0e
      addr_abs(%TRUE, %TRUE)
      op_asl()
      store_mem()
    when 0x1e
      addr_abs_x(%TRUE, %TRUE)
      op_asl()
      store_mem()

    # LSR
    when 0x4a
      @clk += %CLK_2
      @data = @_a
      op_lsr()
      @_a = @data
    when 0x46
      addr_zpg(%TRUE, %TRUE)
      op_lsr()
      store_zpg()
    when 0x56
      addr_zpg_x(%TRUE, %TRUE)
      op_lsr()
      store_zpg()
    when 0x4e
      addr_abs(%TRUE, %TRUE)
      op_lsr()
      store_mem()
    when 0x5e
      addr_abs_x(%TRUE, %TRUE)
      op_lsr()
      store_mem()

    # ROL
    when 0x2a
      @clk += %CLK_2
      @data = @_a
      op_rol()
      @_a = @data
    when 0x26
      addr_zpg(%TRUE, %TRUE)
      op_rol()
      store_zpg()
    when 0x36
      addr_zpg_x(%TRUE, %TRUE)
      op_rol()
      store_zpg()
    when 0x2e
      addr_abs(%TRUE, %TRUE)
      op_rol()
      store_mem()
    when 0x3e
      addr_abs_x(%TRUE, %TRUE)
      op_rol()
      store_mem()

    # ROR
    when 0x6a
      @clk += %CLK_2
      @data = @_a
      op_ror()
      @_a = @data
    when 0x66
      addr_zpg(%TRUE, %TRUE)
      op_ror()
      store_zpg()
    when 0x76
      addr_zpg_x(%TRUE, %TRUE)
      op_ror()
      store_zpg()
    when 0x6e
      addr_abs(%TRUE, %TRUE)
      op_ror()
      store_mem()
    when 0x7e
      addr_abs_x(%TRUE, %TRUE)
      op_ror()
      store_mem()

    # DEC
    when 0xc6
      addr_zpg(%TRUE, %TRUE)
      op_dec()
      store_zpg()
    when 0xd6
      addr_zpg_x(%TRUE, %TRUE)
      op_dec()
      store_zpg()
    when 0xce
      addr_abs(%TRUE, %TRUE)
      op_dec()
      store_mem()
    when 0xde
      addr_abs_x(%TRUE, %TRUE)
      op_dec()
      store_mem()

    # INC
    when 0xe6
      addr_zpg(%TRUE, %TRUE)
      op_inc()
      store_zpg()
    when 0xf6
      addr_zpg_x(%TRUE, %TRUE)
      op_inc()
      store_zpg()
    when 0xee
      addr_abs(%TRUE, %TRUE)
      op_inc()
      store_mem()
    when 0xfe
      addr_abs_x(%TRUE, %TRUE)
      op_inc()
      store_mem()

    # DEX, DEY, INX, INY
    when 0xca
      op_dex()
    when 0x88
      op_dey()
    when 0xe8
      op_inx()
    when 0xc8
      op_iny()

    # Flags
    when 0x18
      op_clc()
    when 0x38
      op_sec()
    when 0xd8
      op_cld()
    when 0xf8
      op_sed()
    when 0x58
      op_cli()
    when 0x78
      op_sei()
    when 0xb8
      op_clv()

    # Stack
    when 0x48
      op_pha()
    when 0x08
      op_php()
    when 0x68
      op_pla()
    when 0x28
      op_plp()
    when 0xba
      op_tsx()
    when 0x9a
      op_txs()

    # Undocumented
    when 0x0b, 0x2b
      addr_imm()
      op_anc()
    when 0x8b
      addr_imm()
      op_ane()
    when 0x6b
      addr_imm()
      op_arr()
    when 0x4b
      addr_imm()
      op_asr()

    # DCP
    when 0xc7
      addr_zpg(%TRUE, %TRUE)
      op_dcp()
      store_zpg()
    when 0xd7
      addr_zpg_x(%TRUE, %TRUE)
      op_dcp()
      store_zpg()
    when 0xc3
      addr_ind_x(%TRUE, %TRUE)
      op_dcp()
      store_mem()
    when 0xd3
      addr_ind_y(%TRUE, %TRUE)
      op_dcp()
      store_mem()
    when 0xcf
      addr_abs(%TRUE, %TRUE)
      op_dcp()
      store_mem()
    when 0xdf
      addr_abs_x(%TRUE, %TRUE)
      op_dcp()
      store_mem()
    when 0xdb
      addr_abs_y(%TRUE, %TRUE)
      op_dcp()
      store_mem()

    # ISB
    when 0xe7
      addr_zpg(%TRUE, %TRUE)
      op_isb()
      store_zpg()
    when 0xf7
      addr_zpg_x(%TRUE, %TRUE)
      op_isb()
      store_zpg()
    when 0xef
      addr_abs(%TRUE, %TRUE)
      op_isb()
      store_mem()
    when 0xff
      addr_abs_x(%TRUE, %TRUE)
      op_isb()
      store_mem()
    when 0xfb
      addr_abs_y(%TRUE, %TRUE)
      op_isb()
      store_mem()
    when 0xe3
      addr_ind_x(%TRUE, %TRUE)
      op_isb()
      store_mem()
    when 0xf3
      addr_ind_y(%TRUE, %TRUE)
      op_isb()
      store_mem()

    # LAS
    when 0xbb
      addr_abs_y(%TRUE, %FALSE)
      op_las()

    # LAX
    when 0xa7
      addr_zpg(%TRUE, %FALSE)
      op_lax()
    when 0xb7
      addr_zpg_y(%TRUE, %FALSE)
      op_lax()
    when 0xaf
      addr_abs(%TRUE, %FALSE)
      op_lax()
    when 0xbf
      addr_abs_y(%TRUE, %FALSE)
      op_lax()
    when 0xa3
      addr_ind_x(%TRUE, %FALSE)
      op_lax()
    when 0xb3
      addr_ind_y(%TRUE, %FALSE)
      op_lax()

    # LXA
    when 0xab
      addr_imm()
      op_lxa()

    # RLA
    when 0x27
      addr_zpg(%TRUE, %TRUE)
      op_rla()
      store_zpg()
    when 0x37
      addr_zpg_x(%TRUE, %TRUE)
      op_rla()
      store_zpg()
    when 0x2f
      addr_abs(%TRUE, %TRUE)
      op_rla()
      store_mem()
    when 0x3f
      addr_abs_x(%TRUE, %TRUE)
      op_rla()
      store_mem()
    when 0x3b
      addr_abs_y(%TRUE, %TRUE)
      op_rla()
      store_mem()
    when 0x23
      addr_ind_x(%TRUE, %TRUE)
      op_rla()
      store_mem()
    when 0x33
      addr_ind_y(%TRUE, %TRUE)
      op_rla()
      store_mem()

    # RRA
    when 0x67
      addr_zpg(%TRUE, %TRUE)
      op_rra()
      store_zpg()
    when 0x77
      addr_zpg_x(%TRUE, %TRUE)
      op_rra()
      store_zpg()
    when 0x6f
      addr_abs(%TRUE, %TRUE)
      op_rra()
      store_mem()
    when 0x7f
      addr_abs_x(%TRUE, %TRUE)
      op_rra()
      store_mem()
    when 0x7b
      addr_abs_y(%TRUE, %TRUE)
      op_rra()
      store_mem()
    when 0x63
      addr_ind_x(%TRUE, %TRUE)
      op_rra()
      store_mem()
    when 0x73
      addr_ind_y(%TRUE, %TRUE)
      op_rra()
      store_mem()

    # SAX
    when 0x87
      addr_zpg(%FALSE, %TRUE)
      op_sax()
      store_zpg()
    when 0x97
      addr_zpg_y(%FALSE, %TRUE)
      op_sax()
      store_zpg()
    when 0x8f
      addr_abs(%FALSE, %TRUE)
      op_sax()
      store_mem()
    when 0x83
      addr_ind_x(%FALSE, %TRUE)
      op_sax()
      store_mem()

    # SBX
    when 0xcb
      addr_imm()
      op_sbx()

    # SHA
    when 0x9f
      addr_abs_y(%FALSE, %TRUE)
      op_sha()
      store_mem()
    when 0x93
      addr_ind_y(%FALSE, %TRUE)
      op_sha()
      store_mem()

    # SHS
    when 0x9b
      addr_abs_y(%FALSE, %TRUE)
      op_shs()
      store_mem()

    # SHX
    when 0x9e
      addr_abs_y(%FALSE, %TRUE)
      op_shx()
      store_mem()

    # SHY
    when 0x9c
      addr_abs_x(%FALSE, %TRUE)
      op_shy()
      store_mem()

    # SLO
    when 0x07
      addr_zpg(%TRUE, %TRUE)
      op_slo()
      store_zpg()
    when 0x17
      addr_zpg_x(%TRUE, %TRUE)
      op_slo()
      store_zpg()
    when 0x0f
      addr_abs(%TRUE, %TRUE)
      op_slo()
      store_mem()
    when 0x1f
      addr_abs_x(%TRUE, %TRUE)
      op_slo()
      store_mem()
    when 0x1b
      addr_abs_y(%TRUE, %TRUE)
      op_slo()
      store_mem()
    when 0x03
      addr_ind_x(%TRUE, %TRUE)
      op_slo()
      store_mem()
    when 0x13
      addr_ind_y(%TRUE, %TRUE)
      op_slo()
      store_mem()

    # SRE
    when 0x47
      addr_zpg(%TRUE, %TRUE)
      op_sre()
      store_zpg()
    when 0x57
      addr_zpg_x(%TRUE, %TRUE)
      op_sre()
      store_zpg()
    when 0x4f
      addr_abs(%TRUE, %TRUE)
      op_sre()
      store_mem()
    when 0x5f
      addr_abs_x(%TRUE, %TRUE)
      op_sre()
      store_mem()
    when 0x5b
      addr_abs_y(%TRUE, %TRUE)
      op_sre()
      store_mem()
    when 0x43
      addr_ind_x(%TRUE, %TRUE)
      op_sre()
      store_mem()
    when 0x53
      addr_ind_y(%TRUE, %TRUE)
      op_sre()
      store_mem()

    # NOPs
    when 0x1a, 0x3a, 0x5a, 0x7a, 0xda, 0xea, 0xfa
      @clk += %CLK_2
    when 0x80, 0x82, 0x89, 0xc2, 0xe2
      @_pc += 1
      @clk += %CLK_2
    when 0x04, 0x44, 0x64
      @_pc += 1
      @clk += %CLK_3
    when 0x14, 0x34, 0x54, 0x74, 0xd4, 0xf4
      @_pc += 1
      @clk += %CLK_4
    when 0x0c
      @_pc += 2
      @clk += %CLK_4
    when 0x1c, 0x3c, 0x5c, 0x7c, 0xdc, 0xfc
      addr_abs_x(%TRUE, %FALSE)
      # NOP - just read and discard

    # BRK
    when 0x00
      op_brk()

    # JAM
    when 0x02, 0x12, 0x22, 0x32, 0x42, 0x52, 0x62, 0x72, 0x92, 0xb2, 0xd2, 0xf2
      op_jam()
    end
  end
end
