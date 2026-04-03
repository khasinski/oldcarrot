# PPU (Picture Processing Unit) implementation for Ruby 0.49
# Uses state-machine approach (case on @hclk) instead of Fiber

%RP2C02_CC      = 4
%RP2C02_HACTIVE = %RP2C02_CC * 256
%RP2C02_HBLANK  = %RP2C02_CC * 85
%RP2C02_HSYNC   = %RP2C02_HACTIVE + %RP2C02_HBLANK

%RP2C02_VACTIVE = 240
%RP2C02_VSLEEP  = 1
%RP2C02_VINT    = 20
%RP2C02_VDUMMY  = 1
%RP2C02_VBLANK  = %RP2C02_VSLEEP + %RP2C02_VINT + %RP2C02_VDUMMY
%RP2C02_VSYNC   = %RP2C02_VACTIVE + %RP2C02_VBLANK

%RP2C02_HVSYNCBOOT = %RP2C02_VACTIVE * %RP2C02_HSYNC + %RP2C02_CC * 312
%RP2C02_HVINT      = %RP2C02_VINT * %RP2C02_HSYNC
%RP2C02_HVSYNC_0   = %RP2C02_VSYNC * %RP2C02_HSYNC
%RP2C02_HVSYNC_1   = %RP2C02_VSYNC * %RP2C02_HSYNC - %RP2C02_CC

%SCANLINE_HDUMMY = -1
%SCANLINE_VBLANK = 240

%HCLOCK_DUMMY    = 341
%HCLOCK_VBLANK_0 = 681
%HCLOCK_VBLANK_1 = 682
%HCLOCK_VBLANK_2 = 684
%HCLOCK_BOOT     = 685

# Sprite pixel position LUTs
%SP_POS_NORMAL = [3, 7, 2, 6, 1, 5, 0, 4]
%SP_POS_FLIP   = [4, 0, 5, 1, 6, 2, 7, 3]

class PPU
  def PPU.new(cpu, palette)
    super.init(cpu, palette)
  end

  def init(cpu, palette)
    @cpu = cpu
    @palette = palette

    # Nametable memory (2 pages of 1KB each)
    @nmt_mem_0 = [0xff] * 0x400
    @nmt_mem_1 = [0xff] * 0x400
    # nmt_ref maps nametable indices 0-3 to nmt_mem pages
    @nmt_ref_0 = @nmt_mem_0
    @nmt_ref_1 = @nmt_mem_1
    @nmt_ref_2 = @nmt_mem_0
    @nmt_ref_3 = @nmt_mem_1

    @output_pixels = []
    @output_color = []
    for i in 0..0x1f
      @output_color.push(palette[0])
    end

    @chr_mem = nil
    @chr_mem_writable = %FALSE

    do_reset(%FALSE)
    self
  end

  def output_pixels()
    @output_pixels
  end

  def set_chr_mem(mem, writable)
    @chr_mem = mem
    @chr_mem_writable = writable
  end

  def set_nametables(mode)
    # mode: 0=horizontal, 1=vertical, 2=four_screen
    if mode == 0  # horizontal
      @nmt_ref_0 = @nmt_mem_0
      @nmt_ref_1 = @nmt_mem_0
      @nmt_ref_2 = @nmt_mem_1
      @nmt_ref_3 = @nmt_mem_1
    elsif mode == 1  # vertical
      @nmt_ref_0 = @nmt_mem_0
      @nmt_ref_1 = @nmt_mem_1
      @nmt_ref_2 = @nmt_mem_0
      @nmt_ref_3 = @nmt_mem_1
    end
    # four_screen would need 4 pages but we skip it
  end

  def nmt_ref(idx)
    if idx == 0
      @nmt_ref_0
    elsif idx == 1
      @nmt_ref_1
    elsif idx == 2
      @nmt_ref_2
    else
      @nmt_ref_3
    end
  end

  def do_reset(mapping)
    @palette_ram = [
      0x3f, 0x01, 0x00, 0x01, 0x00, 0x02, 0x02, 0x0d,
      0x08, 0x10, 0x08, 0x24, 0x00, 0x00, 0x04, 0x2c,
      0x09, 0x01, 0x34, 0x03, 0x00, 0x04, 0x00, 0x14,
      0x08, 0x3a, 0x00, 0x02, 0x00, 0x20, 0x2c, 0x08]
    @coloring = 0x3f
    @emphasis = 0
    update_output_color()

    @hclk = %HCLOCK_BOOT
    @vclk = 0
    @hclk_target = %FOREVER_CLOCK

    @io_latch = 0
    @io_buffer = 0xe8

    @regs_oam = 0
    @vram_addr_inc = 1
    @need_nmi = %FALSE
    @pattern_end = 0x0ff0
    @any_show = %FALSE
    @sp_overflow = %FALSE
    @sp_zero_hit = %FALSE
    @vblanking = %FALSE
    @vblank = %FALSE
    @vblank_triggered = %FALSE

    @io_addr = 0
    @io_pattern = 0

    @odd_frame = %FALSE
    @scanline = %SCANLINE_VBLANK

    @scroll_toggle = %FALSE
    @scroll_latch = 0
    @scroll_xfine = 0
    @scroll_addr_0_4 = 0
    @scroll_addr_5_14 = 0
    @name_io_addr = 0x2000

    # BG state
    @bg_enabled = %FALSE
    @bg_show = %FALSE
    @bg_show_edge = %FALSE
    @bg_pixels = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    @bg_pattern_base = 0
    @bg_pattern = 0

    # Sprite state
    @sp_enabled = %FALSE
    @sp_active = %FALSE
    @sp_show = %FALSE
    @sp_show_edge = %FALSE
    @sp_base = 0
    @sp_height = 8
    @sp_phase = 0
    @sp_ram = [0xff] * 0x100
    @sp_index = 0
    @sp_addr = 0
    @sp_latch = 0
    @sp_limit = 32  # 8 sprites * 4 bytes
    @sp_buffer = [0] * @sp_limit
    @sp_buffered = 0
    @sp_visible = %FALSE
    @sp_zero_in_line = %FALSE

    # Sprite map: array of 264 entries, each nil or [behind, zero, color]
    @sp_map = [nil] * 264
    @sp_map_buf = []
    for i in 0..263
      @sp_map_buf.push([%FALSE, %FALSE, 0])
    end
  end

  def reset()
    do_reset(%TRUE)
  end

  def update_output_color()
    for i in 0..0x1f
      @output_color[i] = @palette[@palette_ram[i] & @coloring | @emphasis]
    end
  end

  #---------------------------------------------------------------------------
  # Tile pixel computation (inline, replacing TILE_LUT)
  #---------------------------------------------------------------------------

  def compute_tile_pixels(pattern, attr_base)
    # pattern is 16-bit: high_byte * 256 + low_byte
    # Returns 8 pixels
    result = [0, 0, 0, 0, 0, 0, 0, 0]
    for j in 0..7
      clr = pattern[15 - j] * 2 + pattern[7 - j]
      if clr != 0
        result[j] = attr_base | clr
      end
    end
    result
  end

  def get_attr_base()
    io_addr = 0x23c0 | (@scroll_addr_5_14 & 0x0c00) | (@scroll_addr_5_14 >> 4 & 0x0038) | (@scroll_addr_0_4 >> 2 & 0x0007)
    bank = nmt_ref(io_addr >> 10 & 3)
    attr_shift = (@scroll_addr_0_4 & 2) | (@scroll_addr_5_14[6] * 4)
    (bank[io_addr & 0x03ff] >> attr_shift & 3) << 2
  end

  #---------------------------------------------------------------------------
  # Memory-mapped handlers
  #---------------------------------------------------------------------------

  def peek_2xxx()
    @io_latch
  end

  def poke_2xxx(data)
    @io_latch = data
  end

  def poke_2000(data)
    update_ppu(%RP2C02_CC)
    need_nmi_old = @need_nmi

    @scroll_latch = (@scroll_latch & 0x73ff) | (data & 0x03) << 10
    if data[2] == 1
      @vram_addr_inc = 32
    else
      @vram_addr_inc = 1
    end
    if data[3] == 1
      @sp_base = 0x1000
    else
      @sp_base = 0x0000
    end
    if data[4] == 1
      @bg_pattern_base = 0x1000
    else
      @bg_pattern_base = 0x0000
    end
    if data[5] == 1
      @sp_height = 16
    else
      @sp_height = 8
    end
    @need_nmi = data[7] == 1

    @io_latch = data
    if @sp_base != 0 || @sp_height == 16
      @pattern_end = 0x1ff0
    else
      @pattern_end = 0x0ff0
    end

    if @need_nmi && @vblank && !need_nmi_old
      clock = @cpu.current_clock() + %RP2C02_CC
      if clock < %RP2C02_HVINT
        @cpu.do_nmi(clock)
      end
    end
  end

  def poke_2001(data)
    update_ppu(%RP2C02_CC)
    any_show_old = @any_show
    coloring_old = @coloring
    emphasis_old = @emphasis

    @bg_show = data[3] == 1
    @bg_show_edge = data[1] == 1 && @bg_show
    @sp_show = data[4] == 1
    @sp_show_edge = data[2] == 1 && @sp_show
    @any_show = @bg_show || @sp_show
    if data[0] == 1
      @coloring = 0x30
    else
      @coloring = 0x3f
    end
    @emphasis = (data & 0xe0) << 1
    @io_latch = data

    if @hclk < 8 || @hclk >= 248
      update_enabled_flags_edge()
    else
      update_enabled_flags()
    end
    if any_show_old && !@any_show
      update_scroll_address_line()
    end

    if coloring_old != @coloring || emphasis_old != @emphasis
      update_output_color()
    end
  end

  def peek_2002()
    # Check if we should be in vblank based on CPU clock timing
    # Only set vblank once per frame (track with @vblank_triggered)
    if !@vblank_triggered
      cpu_clk = @cpu.current_clock()
      vblank_start = %RP2C02_VACTIVE * %RP2C02_HSYNC  # 240 * 1364 = 327360
      if cpu_clk >= vblank_start
        @vblank = %TRUE
        @vblank_triggered = %TRUE
      end
    end

    v = @io_latch & 0x1f
    if @vblank
      v |= 0x80
    end
    if @sp_zero_hit
      v |= 0x40
    end
    if @sp_overflow
      v |= 0x20
    end
    @io_latch = v
    @scroll_toggle = %FALSE
    @vblanking = %FALSE
    @vblank = %FALSE
    @io_latch
  end

  def poke_2003(data)
    update_ppu(%RP2C02_CC)
    @regs_oam = data
    @io_latch = data
  end

  def poke_2004(data)
    update_ppu(%RP2C02_CC)
    if @any_show
      data &= 0xff
    elsif (@regs_oam & 0x03) == 0x02
      data &= 0xe3
    end
    @io_latch = data
    @sp_ram[@regs_oam] = data
    @regs_oam = (@regs_oam + 1) & 0xff
  end

  def peek_2004()
    if !@any_show || @cpu.current_clock() - (@cpu.next_frame_clock() - (341 * 241) * %RP2C02_CC) >= (341 * 240) * %RP2C02_CC
      @io_latch = @sp_ram[@regs_oam]
    else
      update_ppu(%RP2C02_CC)
      @io_latch = @sp_latch
    end
    @io_latch
  end

  def poke_2005(data)
    update_ppu(%RP2C02_CC)
    @io_latch = data
    @scroll_toggle = !@scroll_toggle
    if @scroll_toggle
      @scroll_latch = @scroll_latch & 0x7fe0 | (data >> 3)
      xfine = 8 - (data & 0x7)
      # rotate bg_pixels by (scroll_xfine - xfine) positions
      diff = @scroll_xfine - xfine
      if diff != 0
        rotate_bg_pixels(diff)
      end
      @scroll_xfine = xfine
    else
      @scroll_latch = (@scroll_latch & 0x0c1f) | ((data << 2 | data << 12) & 0x73e0)
    end
  end

  def poke_2006(data)
    update_ppu(%RP2C02_CC)
    @io_latch = data
    @scroll_toggle = !@scroll_toggle
    if @scroll_toggle
      @scroll_latch = @scroll_latch & 0x00ff | (data & 0x3f) << 8
    else
      @scroll_latch = (@scroll_latch & 0x7f00) | data
      @scroll_addr_0_4 = @scroll_latch & 0x001f
      @scroll_addr_5_14 = @scroll_latch & 0x7fe0
      update_scroll_address_line()
    end
  end

  def poke_2007(data)
    update_ppu(%RP2C02_CC * 4)
    addr = @scroll_addr_0_4 | @scroll_addr_5_14
    update_vram_addr()
    @io_latch = data
    if (addr & 0x3f00) == 0x3f00
      addr &= 0x1f
      final = @palette[data & @coloring | @emphasis]
      @palette_ram[addr] = data
      @output_color[addr] = final
      if (addr & 3) == 0
        @palette_ram[addr ^ 0x10] = data
        @output_color[addr ^ 0x10] = final
      end
    else
      addr &= 0x3fff
      if addr >= 0x2000
        bank = nmt_ref(addr >> 10 & 0x3)
        idx = addr & 0x03ff
        bank[idx] = data
      elsif @chr_mem_writable
        @chr_mem[addr] = data
      end
    end
  end

  def peek_2007()
    update_ppu(%RP2C02_CC)
    addr = (@scroll_addr_0_4 | @scroll_addr_5_14) & 0x3fff
    update_vram_addr()
    if (addr & 0x3f00) != 0x3f00
      @io_latch = @io_buffer
    else
      @io_latch = @palette_ram[addr & 0x1f] & @coloring
    end
    if addr >= 0x2000
      @io_buffer = nmt_ref(addr >> 10 & 0x3)[addr & 0x3ff]
    else
      @io_buffer = @chr_mem[addr]
    end
    @io_latch
  end

  def peek_3000()
    update_ppu(%RP2C02_CC)
    @io_latch
  end

  def poke_4014(data)
    if @cpu.odd_clock()
      @cpu.steal_clocks(%CLK_1)
    end
    update_ppu(%RP2C02_CC)
    @cpu.steal_clocks(%CLK_1)
    data <<= 8
    if @regs_oam == 0 && data < 0x2000 && (!@any_show || @cpu.current_clock() <= %RP2C02_HVINT - %CLK_1 * 512)
      @cpu.steal_clocks(%CLK_1 * 512)
      @cpu.sprite_dma(data & 0x7ff, @sp_ram)
      @io_latch = @sp_ram[0xff]
    else
      while %TRUE
        @io_latch = @cpu.fetch(data)
        data += 1
        @cpu.steal_clocks(%CLK_1)
        update_ppu(%RP2C02_CC)
        @cpu.steal_clocks(%CLK_1)
        if @any_show
          @io_latch &= 0xff
        elsif (@regs_oam & 0x03) == 0x02
          @io_latch &= 0xe3
        end
        @sp_ram[@regs_oam] = @io_latch
        @regs_oam = (@regs_oam + 1) & 0xff
        if (data & 0xff) == 0
          break
        end
      end
    end
  end

  #---------------------------------------------------------------------------
  # Helpers
  #---------------------------------------------------------------------------

  def rotate_bg_pixels(n)
    if n > 0
      while n > 0
        tmp = @bg_pixels.shift()
        @bg_pixels.push(tmp)
        n -= 1
      end
    elsif n < 0
      n = -n
      while n > 0
        tmp = @bg_pixels.pop()
        @bg_pixels.unshift(tmp)
        n -= 1
      end
    end
  end

  def update_ppu(data_setup)
    # No-op: PPU sync is driven by cpu.run() and vsync(), not per-write updates
  end

  def update_vram_addr()
    if @vram_addr_inc == 32
      if ppu_active()
        if (@scroll_addr_5_14 & 0x7000) == 0x7000
          @scroll_addr_5_14 &= 0x0fff
          mask = @scroll_addr_5_14 & 0x03e0
          if mask == 0x03a0
            @scroll_addr_5_14 ^= 0x0800
          elsif mask == 0x03e0
            @scroll_addr_5_14 &= 0x7c00
          else
            @scroll_addr_5_14 += 0x20
          end
        else
          @scroll_addr_5_14 += 0x1000
        end
      else
        @scroll_addr_5_14 += 0x20
      end
    elsif @scroll_addr_0_4 < 0x1f
      @scroll_addr_0_4 += 1
    else
      @scroll_addr_0_4 = 0
      @scroll_addr_5_14 = (@scroll_addr_5_14 + 0x20) & 0x7fe0
    end
    update_scroll_address_line()
  end

  def update_scroll_address_line()
    @name_io_addr = (@scroll_addr_0_4 | @scroll_addr_5_14) & 0x0fff | 0x2000
  end

  def ppu_active()
    @scanline != %SCANLINE_VBLANK && @any_show
  end

  def sync(elapsed)
    if @hclk_target < elapsed
      # Only run PPU during visible area, not during vblank.
      # During vblank, game writes palette/nametable via $2006/$2007
      # and we must not modify scroll registers via the state machine.
      vblank_cpu_clk = %RP2C02_VACTIVE * %RP2C02_HSYNC  # 327360
      if elapsed < vblank_cpu_clk
        @hclk_target = elapsed / %RP2C02_CC - @vclk
        run()
      end
    end
  end

  def update_enabled_flags()
    if @any_show
      @bg_enabled = @bg_show
      @sp_enabled = @sp_show
      @sp_active = @sp_enabled && @sp_visible
    end
  end

  def update_enabled_flags_edge()
    @bg_enabled = @bg_show_edge
    @sp_enabled = @sp_show_edge
    @sp_active = @sp_enabled && @sp_visible
  end

  def setup_frame()
    @output_pixels.clear()
    @odd_frame = !@odd_frame
    @vblank_triggered = %FALSE
    if @hclk == %HCLOCK_DUMMY
      # DUMMY_FRAME
      @vclk = %RP2C02_HVINT / %RP2C02_CC - %HCLOCK_DUMMY
      @hclk_target = %RP2C02_HVINT
      @cpu.set_next_frame_clock(%RP2C02_HVSYNC_0)
    else
      # BOOT_FRAME
      @vclk = %RP2C02_HVSYNCBOOT / %RP2C02_CC - %HCLOCK_BOOT
      @hclk_target = %RP2C02_HVSYNCBOOT
      @cpu.set_next_frame_clock(%RP2C02_HVSYNCBOOT)
    end
    # Schedule NMI at vblank start if NMI is enabled
    if @need_nmi
      vblank_nmi_clk = %RP2C02_VACTIVE * %RP2C02_HSYNC + %RP2C02_CC
      @cpu.do_nmi(vblank_nmi_clk)
    end
  end

  def vsync()
    # Refresh output_color from palette_ram before rendering
    # (ensures NMI palette updates are reflected)
    update_output_color()
    if @hclk_target != %FOREVER_CLOCK
      @hclk_target = %FOREVER_CLOCK
      run()
    end
    # Fill missing pixels with black
    while @output_pixels.length < 256 * 240
      @output_pixels.push(@palette[15])
    end
  end

  def dispose()
  end

  #---------------------------------------------------------------------------
  # Sprite helpers
  #---------------------------------------------------------------------------

  def open_sprite_addr(buffer_idx)
    flip_v = @sp_buffer[buffer_idx + 2][7]
    tmp = (@scanline - @sp_buffer[buffer_idx]) ^ (flip_v * 0xf)
    byte1 = @sp_buffer[buffer_idx + 1]
    if @sp_height == 16
      addr = ((byte1 & 0x01) << 12) | ((byte1 & 0xfe) << 4) | (tmp[3] * 0x10)
    else
      addr = @sp_base | byte1 << 4
    end
    addr | (tmp & 7)
  end

  def load_sprite(pat0, pat1, buffer_idx)
    byte2 = @sp_buffer[buffer_idx + 2]
    if byte2[6] == 1
      pos = %SP_POS_FLIP
    else
      pos = %SP_POS_NORMAL
    end
    pat = (pat0 >> 1 & 0x55) | (pat1 & 0xaa) | ((pat0 & 0x55) | (pat1 << 1 & 0xaa)) << 8
    x_base = @sp_buffer[buffer_idx + 3]
    palette_base = 0x10 + ((byte2 & 3) << 2)
    @sp_visible = %TRUE
    for i in 0..263
      @sp_map[i] = nil
    end

    for dx in 0..7
      x = x_base + dx
      clr = (pat >> (pos[dx] * 2)) & 3
      if clr == 0
        continue
      end
      if @sp_map[x]
        continue
      end
      sprite = @sp_map_buf[x]
      sprite[0] = byte2[5] == 1
      sprite[1] = buffer_idx == 0 && @sp_zero_in_line
      sprite[2] = palette_base + clr
      @sp_map[x] = sprite
    end
    @sp_active = @sp_enabled
  end

  #---------------------------------------------------------------------------
  # Sprite evaluation phases
  #---------------------------------------------------------------------------

  def evaluate_sprites_even()
    if @any_show
      @sp_latch = @sp_ram[@sp_addr]
    end
  end

  def evaluate_sprites_odd()
    if !@any_show
      return
    end

    if @sp_phase.is_nil  # phase 1
      eval_sp_phase_1()
    elsif @sp_phase == 9
      @sp_addr = (@sp_addr + 4) & 0xff
    elsif @sp_phase == 2
      eval_sp_phase_2()
    elsif @sp_phase == 3
      eval_sp_phase_3()
    elsif @sp_phase == 4
      eval_sp_phase_4()
    elsif @sp_phase == 5
      eval_sp_phase_5()
    elsif @sp_phase == 6
      @sp_phase = 7
      @sp_addr = (@sp_addr + 1) & 0xff
    elsif @sp_phase == 7
      @sp_phase = 8
      @sp_addr = (@sp_addr + 1) & 0xff
    elsif @sp_phase == 8
      @sp_phase = 9
      @sp_addr = (@sp_addr + 1) & 0xff
      if (@sp_addr & 3) == 3
        @sp_addr += 1
      end
      @sp_addr &= 0xfc
    end
  end

  def eval_sp_phase_1()
    @sp_index += 1
    if @sp_latch <= @scanline && @scanline < @sp_latch + @sp_height
      @sp_addr += 1
      @sp_phase = 2
      @sp_buffer[@sp_buffered] = @sp_latch
    elsif @sp_index == 64
      @sp_addr = 0
      @sp_phase = 9
    elsif @sp_index == 2
      @sp_addr = 8
    else
      @sp_addr += 4
    end
  end

  def eval_sp_phase_2()
    @sp_addr += 1
    @sp_phase = 3
    @sp_buffer[@sp_buffered + 1] = @sp_latch
  end

  def eval_sp_phase_3()
    @sp_addr += 1
    @sp_phase = 4
    @sp_buffer[@sp_buffered + 2] = @sp_latch
  end

  def eval_sp_phase_4()
    @sp_buffer[@sp_buffered + 3] = @sp_latch
    @sp_buffered += 4
    if @sp_index != 64
      if @sp_buffered != @sp_limit
        @sp_phase = nil
      else
        @sp_phase = 5
      end
      if @sp_index != 2
        @sp_addr += 1
        if @sp_index == 1
          @sp_zero_in_line = %TRUE
        end
      else
        @sp_addr = 8
      end
    else
      @sp_addr = 0
      @sp_phase = 9
    end
  end

  def eval_sp_phase_5()
    if @sp_latch <= @scanline && @scanline < @sp_latch + @sp_height
      @sp_phase = 6
      @sp_addr = (@sp_addr + 1) & 0xff
      @sp_overflow = %TRUE
    else
      @sp_addr = ((@sp_addr + 4) & 0xfc) + ((@sp_addr + 1) & 3)
      if @sp_addr <= 5
        @sp_phase = 9
        @sp_addr &= 0xfc
      end
    end
  end

  #---------------------------------------------------------------------------
  # Rendering
  #---------------------------------------------------------------------------

  def render_pixel()
    # Only render on visible scanlines (0-239)
    if @scanline < 0 || @scanline >= 240
      return
    end
    if @any_show
      if @bg_enabled
        pixel = @bg_pixels[@hclk % 8]
      else
        pixel = 0
      end
      if @sp_active
        sprite = @sp_map[@hclk]
        if sprite
          if pixel % 4 == 0
            pixel = sprite[2]
          else
            if sprite[1] && @hclk != 255
              @sp_zero_hit = %TRUE
            end
            if !sprite[0]
              pixel = sprite[2]
            end
          end
        end
      end
    else
      if (@scroll_addr_5_14 & 0x3f00) == 0x3f00
        pixel = @scroll_addr_0_4
      else
        pixel = 0
      end
      @bg_pixels[@hclk % 8] = 0
    end
    @output_pixels.push(@output_color[pixel])
  end

  #---------------------------------------------------------------------------
  # Scroll helpers
  #---------------------------------------------------------------------------

  def scroll_clock_x()
    if !@any_show
      return
    end
    if @scroll_addr_0_4 < 0x001f
      @scroll_addr_0_4 += 1
      @name_io_addr += 1
    else
      @scroll_addr_0_4 = 0
      @scroll_addr_5_14 ^= 0x0400
      @name_io_addr ^= 0x041f
    end
  end

  def scroll_reset_x()
    if !@any_show
      return
    end
    @scroll_addr_0_4 = @scroll_latch & 0x001f
    @scroll_addr_5_14 = (@scroll_addr_5_14 & 0x7be0) | (@scroll_latch & 0x0400)
    @name_io_addr = (@scroll_addr_0_4 | @scroll_addr_5_14) & 0x0fff | 0x2000
  end

  def scroll_clock_y()
    if !@any_show
      return
    end
    if (@scroll_addr_5_14 & 0x7000) != 0x7000
      @scroll_addr_5_14 += 0x1000
    else
      mask = @scroll_addr_5_14 & 0x03e0
      if mask == 0x03a0
        @scroll_addr_5_14 ^= 0x0800
        @scroll_addr_5_14 &= 0x0c00
      elsif mask == 0x03e0
        @scroll_addr_5_14 &= 0x0c00
      else
        @scroll_addr_5_14 = (@scroll_addr_5_14 & 0x0fe0) + 32
      end
    end
    @name_io_addr = (@scroll_addr_0_4 | @scroll_addr_5_14) & 0x0fff | 0x2000
  end

  #---------------------------------------------------------------------------
  # Tile loading
  #---------------------------------------------------------------------------

  def fetch_name_byte()
    if !@any_show
      return
    end
    addr = @scroll_addr_0_4 + @scroll_addr_5_14
    bank = nmt_ref((addr >> 10) & 3)
    tile = bank[addr & 0x03ff]
    @io_pattern = @bg_pattern_base | (tile << 4) | (@scroll_addr_5_14 >> 12 & 7)
  end

  def fetch_bg_pattern_0()
    if @any_show
      @bg_pattern = @chr_mem[@io_pattern & 0x1fff]
    end
  end

  def fetch_bg_pattern_1()
    if @any_show
      @bg_pattern |= @chr_mem[(@io_pattern | 8) & 0x1fff] * 0x100
    end
  end

  def preload_tiles()
    if !@any_show
      return
    end
    attr = get_attr_base()
    pixels = compute_tile_pixels(@bg_pattern, attr)
    for i in 0..7
      @bg_pixels[@scroll_xfine + i] = pixels[i]
    end
  end

  def load_tiles()
    if !@any_show
      return
    end
    # rotate bg_pixels left by 8
    rotate_bg_pixels(8)
    attr = get_attr_base()
    pixels = compute_tile_pixels(@bg_pattern, attr)
    for i in 0..7
      @bg_pixels[@scroll_xfine + i] = pixels[i]
    end
  end

  #---------------------------------------------------------------------------
  # Main PPU run loop (state machine)
  #---------------------------------------------------------------------------

  def run()
    while @hclk_target > @hclk

      if @hclk == %HCLOCK_BOOT
        # Boot
        @vblank = %TRUE
        @hclk = %HCLOCK_DUMMY
        @hclk_target = %FOREVER_CLOCK
        return

      elsif @hclk == %HCLOCK_VBLANK_0
        @vblanking = %TRUE
        @hclk = %HCLOCK_VBLANK_1
        continue

      elsif @hclk == %HCLOCK_VBLANK_1
        if @vblanking
          @vblank = %TRUE
        end
        @vblanking = %FALSE
        @sp_visible = %FALSE
        @sp_active = %FALSE
        @hclk = %HCLOCK_VBLANK_2
        continue

      elsif @hclk == %HCLOCK_VBLANK_2
        if @vblanking
          @vblank = %TRUE
        end
        @vblanking = %FALSE
        @hclk = %HCLOCK_DUMMY
        @hclk_target = %FOREVER_CLOCK
        if @need_nmi && @vblank
          @cpu.do_nmi(@cpu.next_frame_clock())
        end
        return

      elsif @hclk >= 341 && @hclk <= 659
        # Pre-render scanline
        if @hclk == 341
          @sp_overflow = %FALSE
          @sp_zero_hit = %FALSE
          @vblanking = %FALSE
          @vblank = %FALSE
          @scanline = %SCANLINE_HDUMMY
        end

        phase = (@hclk - 341) % 8
        if phase == 0
          # open_name (do nothing visible)
          @hclk += 2
        elsif phase == 2
          # open_attr
          @hclk += 2
        elsif phase == 4
          # open_pattern
          @hclk += 2
        elsif phase == 6
          # open_pattern|8
          if @hclk == 659
            @hclk = 320
            @vclk += %HCLOCK_DUMMY
            @hclk_target -= %HCLOCK_DUMMY
          else
            @hclk += 2
          end
        end
        # Handle scroll reset at hclk 645
        if @hclk >= 597 && @hclk <= 659 && @any_show
          if @hclk == 645 || (@hclk == 647 && @scroll_addr_0_4 == 0)
            @scroll_addr_0_4 = @scroll_latch & 0x001f
            @scroll_addr_5_14 = @scroll_latch & 0x7fe0
            @name_io_addr = (@scroll_addr_0_4 | @scroll_addr_5_14) & 0x0fff | 0x2000
          end
        end
        continue

      elsif @hclk >= 320 && @hclk <= 337
        # Visible scanline - tile prefetch (not shown)
        if @hclk == 320
          # load_extended_sprites (simplified)
          if @any_show
            @sp_latch = @sp_ram[0]
          end
          @sp_buffered = 0
          @sp_zero_in_line = %FALSE
          @sp_index = 0
          @sp_phase = 0
          @hclk += 1
        elsif @hclk == 321
          fetch_name_byte()
          @hclk += 1
        elsif @hclk == 322
          @hclk += 1
        elsif @hclk == 323
          scroll_clock_x()
          @hclk += 1
        elsif @hclk == 324
          @hclk += 1
        elsif @hclk == 325
          fetch_bg_pattern_0()
          @hclk += 1
        elsif @hclk == 326
          @hclk += 1
        elsif @hclk == 327
          fetch_bg_pattern_1()
          @hclk += 1
        elsif @hclk == 328
          preload_tiles()
          fetch_name_byte()
          @hclk += 1
        elsif @hclk == 329
          fetch_name_byte()
          @hclk += 1
        elsif @hclk == 330
          @hclk += 1
        elsif @hclk == 331
          scroll_clock_x()
          @hclk += 1
        elsif @hclk == 332
          @hclk += 1
        elsif @hclk == 333
          fetch_bg_pattern_0()
          @hclk += 1
        elsif @hclk == 334
          @hclk += 1
        elsif @hclk == 335
          fetch_bg_pattern_1()
          @hclk += 1
        elsif @hclk == 336
          @hclk += 1
        elsif @hclk == 337
          if @any_show
            update_enabled_flags_edge()
            if @scanline == %SCANLINE_HDUMMY && @odd_frame
              @cpu.set_next_frame_clock(%RP2C02_HVSYNC_1)
            end
          end
          @hclk += 1
        end
        continue

      elsif @hclk == 338
        # Increment scanline
        @scanline += 1
        if @scanline != %SCANLINE_VBLANK
          if @any_show
            if @scanline != 0 || !@odd_frame
              line = 341
            else
              line = 340
            end
          else
            update_enabled_flags_edge()
            line = 341
          end
          @hclk = 0
          @vclk += line
          @hclk_target = if @hclk_target <= line then 0 else @hclk_target - line end
        else
          @hclk = %HCLOCK_VBLANK_0
        end
        continue

      elsif @hclk >= 0 && @hclk <= 255
        # Visible scanline - render pixels
        pixel_phase = @hclk % 8
        if pixel_phase == 0
          if @any_show
            if @hclk == 64
              @sp_addr = @regs_oam & 0xf8
              @sp_phase = nil
              @sp_latch = 0xff
            end
            load_tiles()
            if @hclk >= 64
              evaluate_sprites_even()
            end
          end
          render_pixel()
          @hclk += 1
        elsif pixel_phase == 1
          if @any_show
            fetch_name_byte()
            if @hclk >= 64
              evaluate_sprites_odd()
            end
          end
          render_pixel()
          @hclk += 1
        elsif pixel_phase == 2
          if @any_show && @hclk >= 64
            evaluate_sprites_even()
          end
          render_pixel()
          @hclk += 1
        elsif pixel_phase == 3
          if @any_show
            if @hclk >= 64
              evaluate_sprites_odd()
            end
            if @hclk == 251
              scroll_clock_y()
            end
            scroll_clock_x()
          end
          render_pixel()
          @hclk += 1
        elsif pixel_phase == 4
          if @any_show && @hclk >= 64
            evaluate_sprites_even()
          end
          render_pixel()
          @hclk += 1
        elsif pixel_phase == 5
          if @any_show
            fetch_bg_pattern_0()
            if @hclk >= 64
              evaluate_sprites_odd()
            end
          end
          render_pixel()
          @hclk += 1
        elsif pixel_phase == 6
          if @any_show && @hclk >= 64
            evaluate_sprites_even()
          end
          render_pixel()
          @hclk += 1
        elsif pixel_phase == 7
          if @any_show
            fetch_bg_pattern_1()
            if @hclk >= 64
              evaluate_sprites_odd()
            end
          end
          render_pixel()
          if @any_show && @hclk != 255
            update_enabled_flags()
          end
          @hclk += 1
        end
        continue

      elsif @hclk >= 256 && @hclk <= 319
        # Sprite fetch phase
        if @hclk == 256
          if @any_show
            @sp_latch = 0xff
          end
          @hclk += 1
          continue
        end
        if @hclk == 257
          scroll_reset_x()
          @sp_visible = %FALSE
          @sp_active = %FALSE
          @hclk += 1
          continue
        end
        # hclk 258-319: sprite pattern fetches (8 cycles per sprite)
        sprite_phase = (@hclk - 258) % 8
        if sprite_phase < 2
          @hclk += 1
        elsif sprite_phase == 2
          # open_pattern for sprite
          if @any_show
            buffer_idx = (@hclk - 260) / 2
            if buffer_idx < @sp_buffered
              @io_addr = open_sprite_addr(buffer_idx)
            end
            if @scanline == 238 && @hclk == 316
              @regs_oam = 0
            end
          end
          @hclk += 1
        elsif sprite_phase == 3
          if @any_show
            buffer_idx = (@hclk - 261) / 2
            if buffer_idx < @sp_buffered
              @io_pattern = @chr_mem[@io_addr & 0x1fff]
            end
          end
          @hclk += 1
        elsif sprite_phase == 4
          @hclk += 1
        elsif sprite_phase == 5
          if @any_show
            buffer_idx = (@hclk - 263) / 2
            if buffer_idx < @sp_buffered
              pat0 = @io_pattern
              pat1 = @chr_mem[@io_addr & 0x1fff]
              if pat0 != 0 || pat1 != 0
                load_sprite(pat0, pat1, buffer_idx)
              end
            end
          end
          @hclk += 1
        else
          @hclk += 1
        end
        continue

      else
        # Unknown hclk, advance
        @hclk += 1
      end
    end
  end
end
