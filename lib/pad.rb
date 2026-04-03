# Game pad implementation

class Pad
  %PAD_A      = 0
  %PAD_B      = 1
  %PAD_SELECT = 2
  %PAD_START  = 3
  %PAD_UP     = 4
  %PAD_DOWN   = 5
  %PAD_LEFT   = 6
  %PAD_RIGHT  = 7

  def Pad.new()
    super.init()
  end

  def init()
    @strobe = %FALSE
    @buttons = 0
    @stream = 0
    self
  end

  def reset()
    @strobe = %FALSE
    @buttons = 0
    @stream = 0
  end

  def buttons()
    @buttons
  end

  def set_buttons(v)
    @buttons = v
  end

  def poke(data)
    prev = @strobe
    @strobe = data[0] == 1
    if prev && !@strobe
      @stream = (poll_state() << 1) ^ -512
    end
  end

  def peek()
    if @strobe
      return poll_state() & 1
    end
    @stream >>= 1
    @stream[0]
  end

  def poll_state()
    state = @buttons
    # Prohibit impossible simultaneous keydown
    if (state & 0x30) == 0x30
      state &= 0xcf
    end
    if (state & 0xc0) == 0xc0
      state &= 0x3f
    end
    state
  end
end

class Pads
  def Pads.new(cpu, apu)
    super.init(cpu, apu)
  end

  def init(cpu, apu)
    @cpu = cpu
    @apu = apu
    @pad0 = Pad.new()
    @pad1 = Pad.new()
    self
  end

  def reset()
    @pad0.reset()
    @pad1.reset()
  end

  def peek_401x(addr)
    @cpu.do_update()
    if addr == 0x4016
      @pad0.peek() | 0x40
    else
      @pad1.peek() | 0x40
    end
  end

  def poke_4016(data)
    @pad0.poke(data)
    @pad1.poke(data)
  end

  def keydown(pad, btn)
    if pad == 0
      @pad0.set_buttons(@pad0.buttons() | (1 << btn))
    else
      @pad1.set_buttons(@pad1.buttons() | (1 << btn))
    end
  end

  def keyup(pad, btn)
    if pad == 0
      @pad0.set_buttons(@pad0.buttons() & ~(1 << btn))
    else
      @pad1.set_buttons(@pad1.buttons() & ~(1 << btn))
    end
  end
end
