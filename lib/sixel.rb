# Sixel graphics encoder for Ruby 0.49
# Encodes a 256x240 pixel framebuffer as sixel escape sequences

class SixelEncoder
  def SixelEncoder.new(scale)
    super.init(scale)
  end

  def init(scale)
    @esc = 27.chr
    @scale = scale
    self
  end

  # Encode a frame and write sixel to stdout
  # pixels: array of 0xRRGGBB integers, length 256*240
  def encode(pixels)
    sc = @scale

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

    # 2. Build indexed buffer (original 256x240)
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
    # Each sixel row covers 6 rows of the SCALED image.
    # 6 scaled rows = 6/sc source rows (possibly fractional).
    # We iterate in source-pixel space for efficiency.
    #
    # Total scaled height = 240 * sc. Sixel rows = ceil(240*sc / 6).
    out_height = 240 * sc
    out_width = 256 * sc
    total_sixel_rows = (out_height + 5) / 6

    for sr in 0..(total_sixel_rows - 1)
      # This sixel row covers scaled Y range [sr*6 .. sr*6+5]
      # = source Y range [sr*6/sc .. (sr*6+5)/sc]
      sy_start = sr * 6

      # Build sixel data per color per column
      sixels = []
      for c in 0..(num_colors - 1)
        sixels.push(nil)
      end

      for src_x in 0..255
        for dy in 0..5
          sy = sy_start + dy
          src_y = sy / sc
          if src_y < 240
            c = indexed[src_y * 256 + src_x]
            unless sixels[c]
              sixels[c] = [63] * 256
            end
            # Set bit dy for ALL sc columns of this source pixel
            sixels[c][src_x] = sixels[c][src_x] + (1 << dy)
          end
        end
      end

      # Output each color - with horizontal scaling via RLE
      for c in 0..(num_colors - 1)
        row = sixels[c]
        unless row
          continue
        end

        buf = sprintf("#%d", c)

        # RLE encode with horizontal scale factor
        prev = row[0]
        run = sc  # first pixel repeated sc times
        for src_x in 1..255
          ch = row[src_x]
          if ch == prev
            run += sc
          else
            buf = buf + rle(prev, run)
            prev = ch
            run = sc
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
