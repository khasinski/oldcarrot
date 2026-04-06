# Sixel graphics encoder for Ruby 0.49
# Encodes a 256x240 pixel framebuffer as sixel escape sequences

class SixelEncoder
  def SixelEncoder.new()
    super.init()
  end

  def init()
    @esc = 27.chr
    self
  end

  # Encode a frame and write sixel to stdout
  # pixels: array of 0xRRGGBB integers, length 256*240
  def encode(pixels)
    # 1. Build palette from unique colors
    color_map = {}
    palette = []
    idx = 0
    for i in 0..(pixels.length - 1)
      rgb = pixels[i]
      unless color_map[rgb]
        color_map[rgb] = idx
        palette.push(rgb)
        idx += 1
      end
    end
    num_colors = palette.length

    # 2. Build indexed buffer
    indexed = []
    for i in 0..(pixels.length - 1)
      indexed.push(color_map[pixels[i]])
    end

    # 3. Sixel header + color definitions
    buf = @esc + "Pq"
    for c in 0..(num_colors - 1)
      rgb = palette[c]
      rp = ((rgb >> 16) & 0xff) * 100 / 255
      gp = ((rgb >> 8) & 0xff) * 100 / 255
      bp = (rgb & 0xff) * 100 / 255
      buf = buf + sprintf("#%d;2;%d;%d;%d", c, rp, gp, bp)
    end
    $stdout.write(buf)

    # 4. Encode sixel rows
    for sr in 0..39
      base_y = sr * 6

      # Pre-compute sixel columns: for each x, build a sixel value per color
      # sixels[color][x] = 6-bit pattern
      sixels = []
      for c in 0..(num_colors - 1)
        sixels.push(nil)
      end

      for x in 0..255
        for dy in 0..5
          y = base_y + dy
          if y < 240
            c = indexed[y * 256 + x]
            unless sixels[c]
              sixels[c] = [63] * 256  # '?' = empty (0 bits + 63)
            end
            sixels[c][x] = sixels[c][x] + (1 << dy)
          end
        end
      end

      # Output each color that has data in this row
      for c in 0..(num_colors - 1)
        row = sixels[c]
        unless row
          continue
        end

        buf = sprintf("#%d", c)

        # RLE encode the row
        prev = row[0]
        run = 1
        for x in 1..255
          ch = row[x]
          if ch == prev
            run += 1
          else
            buf = buf + rle(prev, run)
            prev = ch
            run = 1
          end
        end
        buf = buf + rle(prev, run) + "$"
        $stdout.write(buf)
      end
      $stdout.write("-")
    end

    # 5. Terminator
    $stdout.write(@esc + "\\")
    $stdout.flush()
  end

  def rle(sixel_val, count)
    ch = sixel_val.chr
    if count >= 4
      sprintf("!%d%s", count, ch)
    elsif count == 3
      ch + ch + ch
    elsif count == 2
      ch + ch
    else
      ch
    end
  end
end
