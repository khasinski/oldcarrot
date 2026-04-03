# APU (Audio Processing Unit) implementation for Ruby 0.49

%APU_CLK_M2_MUL   = 6
%APU_CLK_NTSC     = 39375000 * %APU_CLK_M2_MUL
%APU_CLK_NTSC_DIV = 11

%CHANNEL_OUTPUT_MUL   = 256
%CHANNEL_OUTPUT_DECAY = %CHANNEL_OUTPUT_MUL / 4 - 1

# Pre-computed: FRAME_CLOCKS = [29830, 1, 1, 29828].map {|n| RP2A03_CC * n }
%FRAME_CLOCKS_0 = 357960
%FRAME_CLOCKS_1 = 12
%FRAME_CLOCKS_2 = 12
%FRAME_CLOCKS_3 = 357936

# Pre-computed OSCILLATOR_CLOCKS
%OSC_CLOCKS_0 = [89496, 89472, 89496, 89496]
%OSC_CLOCKS_1 = [89496, 89472, 89496, 178920]

#---------------------------------------------------------------------------
# Length Counter LUT
#---------------------------------------------------------------------------
%LENGTH_LUT = [
  0x0a, 0xfe, 0x14, 0x02, 0x28, 0x04, 0x50, 0x06, 0xa0, 0x08, 0x3c, 0x0a, 0x0e, 0x0c, 0x1a, 0x0e,
  0x0c, 0x10, 0x18, 0x12, 0x30, 0x14, 0x60, 0x16, 0xc0, 0x18, 0x48, 0x1a, 0x10, 0x1c, 0x20, 0x1e]

#---------------------------------------------------------------------------
# Noise LUT
#---------------------------------------------------------------------------
%NOISE_LUT = [4, 8, 16, 32, 64, 96, 128, 160, 202, 254, 380, 508, 762, 1016, 2034, 4068]

#---------------------------------------------------------------------------
# DMC LUT
#---------------------------------------------------------------------------
%DMC_LUT_RAW = [428, 380, 340, 320, 286, 254, 226, 214, 190, 160, 142, 128, 106, 84, 72, 54]

class LengthCounter
  def LengthCounter.new()
    super.init()
  end

  def init()
    @enabled = %FALSE
    @count = 0
    self
  end

  def reset()
    @enabled = %FALSE
    @count = 0
  end

  def count()
    @count
  end

  def enable(en)
    @enabled = en
    if !@enabled
      @count = 0
    end
    @enabled
  end

  def write(data, fc_delta)
    if fc_delta || @count == 0
      if @enabled
        @count = %LENGTH_LUT[data]
      else
        @count = 0
      end
    end
  end

  def clock()
    if @count == 0
      return %FALSE
    end
    @count -= 1
    @count == 0
  end
end

class Envelope
  def Envelope.new()
    super.init()
  end

  def init()
    @output = 0
    @count = 0
    @volume_base = 0
    @volume = 0
    @constant = %TRUE
    @looping = %FALSE
    @reset = %FALSE
    self
  end

  def output()
    @output
  end

  def looping()
    @looping
  end

  def reset_clock()
    @reset = %TRUE
  end

  def reset()
    @output = 0
    @count = 0
    @volume_base = 0
    @volume = 0
    @constant = %TRUE
    @looping = %FALSE
    @reset = %FALSE
    update_output()
  end

  def clock()
    if @reset
      @reset = %FALSE
      @volume = 0x0f
    else
      if @count != 0
        @count -= 1
        return
      end
      if @volume != 0 || @looping
        @volume = (@volume - 1) & 0x0f
      end
    end
    @count = @volume_base
    update_output()
  end

  def write(data)
    @volume_base = data & 0x0f
    @constant = data[4] == 1
    @looping = data[5] == 1
    update_output()
  end

  def update_output()
    if @constant
      @output = @volume_base * %CHANNEL_OUTPUT_MUL
    else
      @output = @volume * %CHANNEL_OUTPUT_MUL
    end
  end
end

#---------------------------------------------------------------------------
# Mixer
#---------------------------------------------------------------------------
%MIX_VOL   = 192
%MIX_P_F   = 900
%MIX_P_0   = 9552 * %CHANNEL_OUTPUT_MUL * %MIX_VOL * (%MIX_P_F / 100)
%MIX_P_1   = 8128 * %CHANNEL_OUTPUT_MUL * %MIX_P_F
%MIX_P_2   = %MIX_P_F * 100
%MIX_TND_F = 500
%MIX_TND_0 = 16367 * %CHANNEL_OUTPUT_MUL * %MIX_VOL * (%MIX_TND_F / 100)
%MIX_TND_1 = 24329 * %CHANNEL_OUTPUT_MUL * %MIX_TND_F
%MIX_TND_2 = %MIX_TND_F * 100

class Mixer

  def Mixer.new(p0, p1, tri, noise, dmc)
    super.init(p0, p1, tri, noise, dmc)
  end

  def init(p0, p1, tri, noise, dmc)
    @pulse_0 = p0
    @pulse_1 = p1
    @triangle = tri
    @noise = noise
    @dmc = dmc
    @acc = 0
    @prev = 0
    @next = 0
    self
  end

  def reset()
    @acc = 0
    @prev = 0
    @next = 0
  end

  def sample()
    dac0 = @pulse_0.sample() + @pulse_1.sample()
    dac1 = @triangle.sample() + @noise.sample() + @dmc.sample()

    s = 0
    if dac0 != 0
      s += %MIX_P_0 * dac0 / (%MIX_P_1 + %MIX_P_2 * dac0)
    end
    if dac1 != 0
      s += %MIX_TND_0 * dac1 / (%MIX_TND_1 + %MIX_TND_2 * dac1)
    end

    @acc -= @prev
    @prev = s << 15
    @acc += @prev - @next * 3
    s = @next = @acc >> 15

    if s < -32767
      s = -32767
    end
    if s > 0x7fff
      s = 0x7fff
    end
    s
  end
end

#---------------------------------------------------------------------------
# Pulse channel
#---------------------------------------------------------------------------
%PULSE_MIN_FREQ = 0x0008
%PULSE_MAX_FREQ = 0x07ff

# Pre-computed waveforms
%PULSE_WAVE_0 = [1, 0, 31, 31, 31, 31, 31, 31]
%PULSE_WAVE_1 = [1, 0, 0, 31, 31, 31, 31, 31]
%PULSE_WAVE_2 = [1, 0, 0, 0, 0, 31, 31, 31]
%PULSE_WAVE_3 = [0, 31, 31, 0, 0, 0, 0, 0]

class Pulse
  def Pulse.new(apu)
    super.init(apu)
  end

  def init(apu)
    @apu = apu
    @rate = 1
    @fixed = 1
    @envelope = Envelope.new()
    @length_counter = LengthCounter.new()
    @wave_length = 0
    @timer = 2048
    @freq = 1
    @amp = 0
    @step = 0
    @form = %PULSE_WAVE_0
    @valid_freq = %FALSE
    @active = %FALSE
    @sweep_rate = 0
    @sweep_count = 1
    @sweep_reload = %FALSE
    @sweep_increase = -1
    @sweep_shift = 0
    self
  end

  def reset()
    @timer = 2048 * @fixed
    @freq = @fixed * 2
    @amp = 0
    @wave_length = 0
    @envelope.reset()
    @length_counter.reset()
    @valid_freq = %FALSE
    @step = 0
    @form = %PULSE_WAVE_0
    @sweep_rate = 0
    @sweep_count = 1
    @sweep_reload = %FALSE
    @sweep_increase = -1
    @sweep_shift = 0
    @active = %FALSE
  end

  def is_active()
    @length_counter.count() != 0 && @envelope.output() != 0 && @valid_freq
  end

  def update_freq()
    if @wave_length >= %PULSE_MIN_FREQ && @wave_length + (@sweep_increase & @wave_length >> @sweep_shift) <= %PULSE_MAX_FREQ
      @freq = (@wave_length + 1) * 2 * @fixed
      @valid_freq = %TRUE
    else
      @valid_freq = %FALSE
    end
    @active = is_active()
  end

  def poke_0(data)
    @apu.update_latency()
    @envelope.write(data)
    @form = [%PULSE_WAVE_0, %PULSE_WAVE_1, %PULSE_WAVE_2, %PULSE_WAVE_3][data >> 6 & 3]
    @active = is_active()
  end

  def poke_1(data)
    @apu.do_apu_update()
    @sweep_increase = if data[3] != 0 then 0 else -1 end
    @sweep_shift = data & 0x07
    @sweep_rate = 0
    if data[7] == 1 && @sweep_shift > 0
      @sweep_rate = ((data >> 4) & 0x07) + 1
      @sweep_reload = %TRUE
    end
    update_freq()
  end

  def poke_2(data)
    @apu.do_apu_update()
    @wave_length = (@wave_length & 0x0700) | (data & 0x00ff)
    update_freq()
  end

  def poke_3(data)
    delta = @apu.update_delta()
    @wave_length = (@wave_length & 0x00ff) | ((data & 0x07) << 8)
    update_freq()
    @envelope.reset_clock()
    @length_counter.write(data >> 3, delta)
    @step = 0
    @active = is_active()
  end

  def enable(en)
    @length_counter.enable(en)
    @active = is_active()
  end

  def update_settings(r, f)
    @freq = @freq / @fixed * f
    @timer = @timer / @fixed * f
    @rate = r
    @fixed = f
  end

  def status()
    @length_counter.count() > 0
  end

  def clock_envelope()
    @envelope.clock()
    @active = is_active()
  end

  def clock_sweep(complement)
    if !@envelope.looping() && @length_counter.clock()
      @active = %FALSE
    end
    if @sweep_rate != 0
      @sweep_count -= 1
      if @sweep_count == 0
        @sweep_count = @sweep_rate
        if @wave_length >= %PULSE_MIN_FREQ
          shifted = @wave_length >> @sweep_shift
          if @sweep_increase == 0
            @wave_length += complement - shifted
            update_freq()
          elsif @wave_length + shifted <= %PULSE_MAX_FREQ
            @wave_length += shifted
            update_freq()
          end
        end
      end
    end
    if @sweep_reload
      @sweep_reload = %FALSE
      @sweep_count = @sweep_rate
    end
  end

  def sample()
    sum = @timer
    @timer -= @rate
    if @active
      if @timer < 0
        sum >>= @form[@step]
        while @timer < 0
          v = -@timer
          if v > @freq
            v = @freq
          end
          @step = (@step + 1) & 7
          sum += v >> @form[@step]
          @timer += @freq
        end
        @amp = (sum * @envelope.output() + @rate / 2) / @rate
      else
        @amp = @envelope.output() >> @form[@step]
      end
    else
      if @timer < 0
        count = (-@timer + @freq - 1) / @freq
        @step = (@step + count) & 7
        @timer += count * @freq
      end
      if @amp < %CHANNEL_OUTPUT_DECAY
        return 0
      end
      @amp -= %CHANNEL_OUTPUT_DECAY
    end
    @amp
  end
end

#---------------------------------------------------------------------------
# Triangle channel
#---------------------------------------------------------------------------
%TRI_MIN_FREQ = 3
%TRI_WAVE = [0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,15,14,13,12,11,10,9,8,7,6,5,4,3,2,1,0]

class Triangle
  def Triangle.new(apu)
    super.init(apu)
  end

  def init(apu)
    @apu = apu
    @rate = 1
    @fixed = 1
    @length_counter = LengthCounter.new()
    @wave_length = 0
    @timer = 2048
    @freq = 1
    @amp = 0
    @step = 7
    @status = 0  # 0=counting, 1=reload
    @linear_counter_load = 0
    @linear_counter_start = %TRUE
    @linear_counter = 0
    @active = %FALSE
    self
  end

  def reset()
    @timer = 2048 * @fixed
    @freq = @fixed
    @amp = 0
    @wave_length = 0
    @length_counter.reset()
    @step = 7
    @status = 0
    @linear_counter_load = 0
    @linear_counter_start = %TRUE
    @linear_counter = 0
    @active = %FALSE
  end

  def is_active()
    @length_counter.count() != 0 && @linear_counter != 0 && @wave_length >= %TRI_MIN_FREQ
  end

  def update_freq()
    @freq = (@wave_length + 1) * @fixed
    @active = is_active()
  end

  def poke_0(data)
    @apu.do_apu_update()
    @linear_counter_load = data & 0x7f
    @linear_counter_start = data[7] == 0
  end

  def poke_2(data)
    @apu.do_apu_update()
    @wave_length = (@wave_length & 0x0700) | (data & 0x00ff)
    update_freq()
  end

  def poke_3(data)
    delta = @apu.update_delta()
    @wave_length = (@wave_length & 0x00ff) | ((data & 0x07) << 8)
    update_freq()
    @length_counter.write(data >> 3, delta)
    @status = 1  # reload
    @active = is_active()
  end

  def enable(en)
    @length_counter.enable(en)
    @active = is_active()
  end

  def update_settings(r, f)
    @freq = @freq / @fixed * f
    @timer = @timer / @fixed * f
    @rate = r
    @fixed = f
  end

  def status()
    @length_counter.count() > 0
  end

  def clock_linear_counter()
    if @status == 0  # counting
      if @linear_counter != 0
        @linear_counter -= 1
      end
    else
      if @linear_counter_start
        @status = 0  # counting
      end
      @linear_counter = @linear_counter_load
    end
    @active = is_active()
  end

  def clock_length_counter()
    if @linear_counter_start && @length_counter.clock()
      @active = %FALSE
    end
  end

  def sample()
    if @active
      sum = @timer
      @timer -= @rate
      if @timer < 0
        sum *= %TRI_WAVE[@step]
        while @timer < 0
          v = -@timer
          if v > @freq
            v = @freq
          end
          @step = (@step + 1) & 0x1f
          sum += v * %TRI_WAVE[@step]
          @timer += @freq
        end
        @amp = (sum * %CHANNEL_OUTPUT_MUL + @rate / 2) / @rate * 3
      else
        @amp = %TRI_WAVE[@step] * %CHANNEL_OUTPUT_MUL * 3
      end
    else
      if @amp < %CHANNEL_OUTPUT_DECAY
        return 0
      end
      @amp -= %CHANNEL_OUTPUT_DECAY
      @step = 0
    end
    @amp
  end
end

#---------------------------------------------------------------------------
# Noise channel
#---------------------------------------------------------------------------
class Noise
  def Noise.new(apu)
    super.init(apu)
  end

  def init(apu)
    @apu = apu
    @rate = 1
    @fixed = 1
    @envelope = Envelope.new()
    @length_counter = LengthCounter.new()
    @timer = 2048
    @freq = %NOISE_LUT[0]
    @amp = 0
    @bits = 0x4000
    @shifter_mode = 0  # 0=mode1, 1=mode6
    @active = %FALSE
    self
  end

  def reset()
    @timer = 2048 * @fixed
    @freq = %NOISE_LUT[0] * @fixed
    @amp = 0
    @bits = 0x4000
    @shifter_mode = 0
    @envelope.reset()
    @length_counter.reset()
    @active = %FALSE
  end

  def is_active()
    @length_counter.count() != 0 && @envelope.output() != 0
  end

  def next_bits(bits)
    if @shifter_mode == 0
      # mode 1: bits 0 and 1
      if bits[0] == bits[1]
        bits / 2
      else
        bits / 2 + 0x4000
      end
    else
      # mode 6: bits 0 and 6
      if bits[0] == bits[6]
        bits / 2
      else
        bits / 2 + 0x4000
      end
    end
  end

  def poke_0(data)
    @apu.update_latency()
    @envelope.write(data)
    @active = is_active()
  end

  def poke_2(data)
    @apu.do_apu_update()
    @freq = %NOISE_LUT[data & 0x0f] * @fixed
    if data[7] != 0
      @shifter_mode = 1
    else
      @shifter_mode = 0
    end
  end

  def poke_3(data)
    delta = @apu.update_delta()
    @envelope.reset_clock()
    @length_counter.write(data >> 3, delta)
    @active = is_active()
  end

  def enable(en)
    @length_counter.enable(en)
    @active = is_active()
  end

  def update_settings(r, f)
    @freq = @freq / @fixed * f
    @timer = @timer / @fixed * f
    @rate = r
    @fixed = f
  end

  def status()
    @length_counter.count() > 0
  end

  def clock_envelope()
    @envelope.clock()
    @active = is_active()
  end

  def clock_length_counter()
    if !@envelope.looping() && @length_counter.clock()
      @active = %FALSE
    end
  end

  def sample()
    @timer -= @rate
    if @active
      if @timer >= 0
        if (@bits & 1) == 0
          return @envelope.output() * 2
        else
          return 0
        end
      end

      if (@bits & 1) == 0
        sum = @timer + @rate
      else
        sum = 0
      end
      while @timer < 0
        @bits = next_bits(@bits)
        if (@bits & 1) == 0
          v = -@timer
          if v > @freq
            v = @freq
          end
          sum += v
        end
        @timer += @freq
      end
      return (sum * @envelope.output() + @rate / 2) / @rate * 2
    else
      while @timer < 0
        @bits = next_bits(@bits)
        @timer += @freq
      end
      return 0
    end
  end
end

#---------------------------------------------------------------------------
# DMC channel
#---------------------------------------------------------------------------
class DMC
  def DMC.new(cpu, apu)
    super.init(cpu, apu)
  end

  def init(cpu, apu)
    @cpu = cpu
    @apu = apu
    @freq = %DMC_LUT_RAW[0] * %RP2A03_CC
    @cur_sample = 0
    @lin_sample = 0
    @is_loop = %FALSE
    @irq_enable = %FALSE
    @regs_length_counter = 1
    @regs_address = 0xc000
    @out_active = %FALSE
    @out_shifter = 0
    @out_dac = 0
    @out_buffer = 0x00
    @dma_length_counter = 0
    @dma_buffered = %FALSE
    @dma_address = 0xc000
    @dma_buffer = 0x00
    self
  end

  def freq()
    @freq
  end

  def reset()
    @cur_sample = 0
    @lin_sample = 0
    @freq = %DMC_LUT_RAW[0] * %RP2A03_CC
    @is_loop = %FALSE
    @irq_enable = %FALSE
    @regs_length_counter = 1
    @regs_address = 0xc000
    @out_active = %FALSE
    @out_shifter = 0
    @out_dac = 0
    @out_buffer = 0x00
    @dma_length_counter = 0
    @dma_buffered = %FALSE
    @dma_address = 0xc000
    @dma_buffer = 0x00
  end

  def enable(en)
    @cpu.clear_irq(%IRQ_DMC)
    if !en
      @dma_length_counter = 0
    elsif @dma_length_counter == 0
      @dma_length_counter = @regs_length_counter
      @dma_address = @regs_address
      if !@dma_buffered
        do_dma()
      end
    end
  end

  def sample()
    if @cur_sample != @lin_sample
      step = %CHANNEL_OUTPUT_MUL * 8
      if @lin_sample + step < @cur_sample
        @lin_sample += step
      elsif @cur_sample < @lin_sample - step
        @lin_sample -= step
      else
        @lin_sample = @cur_sample
      end
    end
    @lin_sample
  end

  def do_dma()
    @dma_buffer = @cpu.dmc_dma(@dma_address)
    @dma_address = 0x8000 | ((@dma_address + 1) & 0x7fff)
    @dma_buffered = %TRUE
    @dma_length_counter -= 1
    if @dma_length_counter == 0
      if @is_loop
        @dma_address = @regs_address
        @dma_length_counter = @regs_length_counter
      elsif @irq_enable
        @cpu.do_irq(%IRQ_DMC, @cpu.current_clock())
      end
    end
  end

  def update()
    @cur_sample = @out_dac * %CHANNEL_OUTPUT_MUL
  end

  def poke_0(data)
    @is_loop = data[6] != 0
    @irq_enable = data[7] != 0
    @freq = %DMC_LUT_RAW[data & 0x0f] * %RP2A03_CC
    if !@irq_enable
      @cpu.clear_irq(%IRQ_DMC)
    end
  end

  def poke_1(data)
    @apu.do_apu_update()
    @out_dac = data & 0x7f
    update()
  end

  def poke_2(data)
    @regs_address = 0xc000 | (data << 6)
  end

  def poke_3(data)
    @regs_length_counter = (data << 4) + 1
  end

  def clock_dac()
    if @out_active
      n = @out_dac + ((@out_buffer & 1) << 2) - 2
      @out_buffer >>= 1
      if 0 <= n && n <= 0x7f && n != @out_dac
        @out_dac = n
        return %TRUE
      end
    end
    return %FALSE
  end

  def clock_dma()
    if @out_shifter == 0
      @out_shifter = 7
      @out_active = @dma_buffered
      if @out_active
        @dma_buffered = %FALSE
        @out_buffer = @dma_buffer
        if @dma_length_counter != 0
          do_dma()
        end
      end
    else
      @out_shifter -= 1
    end
  end

  def dmc_status()
    @dma_length_counter > 0
  end
end

#---------------------------------------------------------------------------
# APU main class
#---------------------------------------------------------------------------
class APU
  def APU.new(cpu, rate, bits)
    super.init(cpu, rate, bits)
  end

  def init(cpu, rate, bits)
    @cpu = cpu
    @pulse_0 = Pulse.new(self)
    @pulse_1 = Pulse.new(self)
    @triangle = Triangle.new(self)
    @noise = Noise.new(self)
    @dmc = DMC.new(@cpu, self)
    @mixer = Mixer.new(@pulse_0, @pulse_1, @triangle, @noise, @dmc)

    @settings_rate = rate
    @output = []
    @buffer = []

    @fixed_clock = 1
    @rate_clock = 1
    @rate_counter = 0
    @frame_counter = 0
    @frame_divider = 0
    @frame_irq_clock = 0
    @frame_irq_repeat = 0
    @dmc_clock = 0

    @oscillator_clocks = %OSC_CLOCKS_0

    reset_internal(%FALSE)
    self
  end

  def output()
    @output
  end

  def spec()
    [@settings_rate, 16]
  end

  def reset_mapping()
    @frame_counter /= @fixed_clock
    @rate_counter /= @fixed_clock
    multiplier = 0
    while %TRUE
      multiplier += 1
      if multiplier >= 512
        break
      end
      if %APU_CLK_NTSC * multiplier % @settings_rate == 0
        break
      end
    end
    @rate_clock = %APU_CLK_NTSC * multiplier / @settings_rate
    @fixed_clock = %APU_CLK_NTSC_DIV * multiplier
    @frame_counter *= @fixed_clock
    @rate_counter *= @fixed_clock

    @mixer.reset()
    @buffer.clear()

    multiplier = 0
    while %TRUE
      multiplier += 1
      if multiplier >= 0x1000
        break
      end
      if %APU_CLK_NTSC * (multiplier + 1) / @settings_rate > 0x7ffff
        break
      end
      if %APU_CLK_NTSC * multiplier % @settings_rate == 0
        break
      end
    end
    r = %APU_CLK_NTSC * multiplier / @settings_rate
    f = %APU_CLK_NTSC_DIV * %CLK_1 * multiplier

    @pulse_0.update_settings(r, f)
    @pulse_1.update_settings(r, f)
    @triangle.update_settings(r, f)
    @noise.update_settings(r, f)

    @frame_irq_clock = (@frame_counter / @fixed_clock) - %CLK_1
  end

  def reset()
    reset_internal(%TRUE)
  end

  def reset_internal(mapping)
    @cycles_ratecounter = 0
    @frame_divider = 0
    @frame_irq_clock = %FOREVER_CLOCK
    @frame_irq_repeat = 0
    @dmc_clock = %DMC_LUT_RAW[0] * %RP2A03_CC
    @frame_counter = %FRAME_CLOCKS_0 * @fixed_clock

    if mapping
      reset_mapping()
    end

    @pulse_0.reset()
    @pulse_1.reset()
    @triangle.reset()
    @noise.reset()
    @dmc.reset()
    @mixer.reset()
    @buffer.clear()
    @oscillator_clocks = %OSC_CLOCKS_0
  end

  # APIs
  def do_clock()
    clock_dma(@cpu.current_clock())
    if @frame_irq_clock <= @cpu.current_clock()
      clock_frame_irq(@cpu.current_clock())
    end
    if @dmc_clock < @frame_irq_clock
      @dmc_clock
    else
      @frame_irq_clock
    end
  end

  def clock_dma(clk)
    if @dmc_clock <= clk
      clock_dmc(clk)
    end
  end

  def do_apu_update()
    target = @cpu.do_update() * @fixed_clock
    proceed(target)
    if @frame_counter < target
      clock_frame_counter()
    end
  end

  def update_latency()
    do_apu_update_at(@cpu.do_update() + 1)
  end

  def do_apu_update_at(t)
    target = t * @fixed_clock
    proceed(target)
    if @frame_counter < target
      clock_frame_counter()
    end
  end

  def update_delta()
    elapsed = @cpu.do_update()
    delta = @frame_counter != elapsed * @fixed_clock
    do_apu_update_at(elapsed + 1)
    delta
  end

  def vsync()
    flush_sound()
    do_apu_update_at(@cpu.current_clock())
    frame = @cpu.next_frame_clock()
    @dmc_clock -= frame
    if @frame_irq_clock != %FOREVER_CLOCK
      @frame_irq_clock -= frame
    end
    frame_fixed = frame * @fixed_clock
    @rate_counter -= frame_fixed
    @frame_counter -= frame_fixed
  end

  # Helpers
  def clock_oscillators(two_clocks)
    @pulse_0.clock_envelope()
    @pulse_1.clock_envelope()
    @triangle.clock_linear_counter()
    @noise.clock_envelope()
    if two_clocks
      @pulse_0.clock_sweep(-1)
      @pulse_1.clock_sweep(0)
      @triangle.clock_length_counter()
      @noise.clock_length_counter()
    end
  end

  def clock_dmc(target)
    while %TRUE
      if @dmc.clock_dac()
        do_apu_update_at(@dmc_clock)
        @dmc.update()
      end
      @dmc_clock += @dmc.freq()
      @dmc.clock_dma()
      if @dmc_clock > target
        break
      end
    end
  end

  def clock_frame_counter()
    clock_oscillators(@frame_divider[0] == 1)
    @frame_divider = (@frame_divider + 1) & 3
    @frame_counter += @oscillator_clocks[@frame_divider] * @fixed_clock
  end

  def clock_frame_irq(target)
    @cpu.do_irq(%IRQ_FRAME, @frame_irq_clock)
    while %TRUE
      fc = [%FRAME_CLOCKS_1, %FRAME_CLOCKS_2, %FRAME_CLOCKS_3]
      @frame_irq_clock += fc[@frame_irq_repeat % 3]
      @frame_irq_repeat += 1
      if @frame_irq_clock > target
        break
      end
    end
  end

  def flush_sound()
    rate_per_frame = @settings_rate / 60
    if @buffer.length < rate_per_frame
      target = @cpu.current_clock() * @fixed_clock
      proceed(target)
      if @buffer.length < rate_per_frame
        if @frame_counter < target
          clock_frame_counter()
        end
        while @buffer.length < rate_per_frame
          @buffer.push(@mixer.sample())
        end
      end
    end
    @output.clear()
    for i in 0..(@buffer.length - 1)
      @output.push(@buffer[i])
    end
    @buffer.clear()
  end

  def proceed(target)
    rate_per_frame = @settings_rate / 60
    while @rate_counter < target && @buffer.length < rate_per_frame
      @buffer.push(@mixer.sample())
      if @frame_counter <= @rate_counter
        clock_frame_counter()
      end
      @rate_counter += @rate_clock
    end
  end

  # Memory-mapped register handlers (called from CPU)
  def poke_reg(addr, data)
    off = addr & 0x1f
    if off == 0x00
      @pulse_0.poke_0(data)
    elsif off == 0x01
      @pulse_0.poke_1(data)
    elsif off == 0x02
      @pulse_0.poke_2(data)
    elsif off == 0x03
      @pulse_0.poke_3(data)
    elsif off == 0x04
      @pulse_1.poke_0(data)
    elsif off == 0x05
      @pulse_1.poke_1(data)
    elsif off == 0x06
      @pulse_1.poke_2(data)
    elsif off == 0x07
      @pulse_1.poke_3(data)
    elsif off == 0x08
      @triangle.poke_0(data)
    elsif off == 0x0a
      @triangle.poke_2(data)
    elsif off == 0x0b
      @triangle.poke_3(data)
    elsif off == 0x0c
      @noise.poke_0(data)
    elsif off == 0x0e
      @noise.poke_2(data)
    elsif off == 0x0f
      @noise.poke_3(data)
    elsif off == 0x10
      @dmc.poke_0(data)
    elsif off == 0x11
      @dmc.poke_1(data)
    elsif off == 0x12
      @dmc.poke_2(data)
    elsif off == 0x13
      @dmc.poke_3(data)
    end
  end

  def poke_4015(data)
    do_apu_update()
    @pulse_0.enable(data[0] == 1)
    @pulse_1.enable(data[1] == 1)
    @triangle.enable(data[2] == 1)
    @noise.enable(data[3] == 1)
    @dmc.enable(data[4] == 1)
  end

  def peek_4015()
    elapsed = @cpu.do_update()
    if @frame_irq_clock <= elapsed
      clock_frame_irq(elapsed)
    end
    if @frame_counter < elapsed * @fixed_clock
      do_apu_update_at(elapsed)
    end
    v = @cpu.clear_irq(%IRQ_FRAME)
    if @pulse_0.status()
      v |= 0x01
    end
    if @pulse_1.status()
      v |= 0x02
    end
    if @triangle.status()
      v |= 0x04
    end
    if @noise.status()
      v |= 0x08
    end
    if @dmc.dmc_status()
      v |= 0x10
    end
    v
  end

  def poke_4017(data)
    n = @cpu.do_update()
    if @cpu.odd_clock()
      n += %CLK_1
    end
    do_apu_update_at(n)
    if @frame_irq_clock <= n
      clock_frame_irq(n)
    end
    n += %CLK_1
    if data[7] == 0
      @oscillator_clocks = %OSC_CLOCKS_0
    else
      @oscillator_clocks = %OSC_CLOCKS_1
    end
    @frame_counter = (n + @oscillator_clocks[0]) * @fixed_clock
    @frame_divider = 0
    if (data & 0xc0) != 0
      @frame_irq_clock = %FOREVER_CLOCK
    else
      @frame_irq_clock = n + %FRAME_CLOCKS_0
    end
    @frame_irq_repeat = 0
    if data[6] != 0
      @cpu.clear_irq(%IRQ_FRAME)
    end
    if data[7] != 0
      clock_oscillators(%TRUE)
    end
  end
end
