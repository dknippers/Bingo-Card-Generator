require 'fileutils'
require 'prawn'
require "prawn/measurement_extensions"

class Bingo
  # Base case, gap = 1 cm for 2 cards. Gap gets smaller for more cards on a single page
  CARD_GAP_BASE_NUM = 2.0
  CARD_GAP_BASE = 1.cm

  # Approximate area of a cell when we have 2 cards on a page with a 5x5 grid
  LINE_BASE_AREA = 8150.0
  LINE_BASE_WIDTH = 3.0
  LINE_BASE_SPACING = 5.0

  # Maximum percentage of cell width to use for text
  # The height is calculated dynamically.
  TEXT_BOX_WIDTH = 0.9
  # For any text box, have it be a factor N wider than higher.
  # This makes sure narrow text will not get a gigantic font size, since we limit the height.
  TEXT_BOX_WH_RATIO = 8.5

  # For the header we don't mind if letters get gigantic
  HEADER_MAX_HEIGHT = 0.6

  # Built-in fraction characters
  FRACTION_CHARS = {
    '1/2'  => '½',
    '1/3'  => '⅓',
    '2/3'  => '⅔',
    '1/4'  => '¼',
    '3/4'  => '¾',
    '1/5'  => '⅕',
    '2/5'  => '⅖',
    '3/5'  => '⅗',
    '4/5'  => '⅘',
    '1/6'  => '⅙',
    '5/6'  => '⅚',
    '1/8'  => '⅛',
    '3/8'  => '⅜',
    '5/8'  => '⅝',
    '7/8'  => '⅞',
    '1/10' => '⅒'
  }

  SPECIAL_CHARS = {
    'PI' => 'π',
    'DEG' => '°',
    'SQRT' => '√',
    'PROMILLE' => '‰',
  }

  def initialize(filename: 'bingo', rows: 5, cols: 5, num_cards: 1, cards_per_page: 1, font: 'CambriaMath', header: nil, datafile: 'data.txt')
    @filename = filename
    @rows = rows.floor
    @cols = cols.floor

    @num_cards = num_cards
    @cards_per_page = cards_per_page
    @card_gap = CARD_GAP_BASE / Math.sqrt(cards_per_page / CARD_GAP_BASE_NUM)
    @pages = (num_cards / cards_per_page.to_f).ceil

    @font = font
    @header = header
    @use_header = header.is_a?(String) && header.length > 0
    @datafile = datafile

    @pdf = Prawn::Document.new(
      page_size: 'A4',
      margin: 1.cm
    )

    @pdf.font_families.update(
      'CambriaMath' => {
        normal: "fonts/CambriaMath.ttf"
      }
    )

    @pdf.font @font
    @pdf.line_width = line_width

    @generated_cards = 0
  end

  def read_data
    data = {
      right: [],
      wrong: []
    }

    # Skip possible unicode BOM header in first 3 bytes of file
    file = File.open(@datafile, 'r:bom|utf-8') rescue (raise ArgumentError.new('Cannot read data from "%s"' % @datafile))

    # First read all right answers
    read_right = true

    file.each_line do |line|
      # Skip empty lines and comments
      next if line.strip.empty? or line =~ /^#/

      # A line with exactly '---' signals the end of right answers
      if line =~ /^-{3}$/
        read_right = false
        next
      end

      # Strip anything after '#' from the line
      line = line.gsub(/#.*/, '').strip.chomp

      key = read_right ? :right : :wrong

      line.force_encoding('utf-8')

      # Replace some characters
      replace = {
        '>' => '&gt;',
        '>=' => '≥',
        '<' => '&lt;',
        '<=' => '≤'
      }
      line.gsub!(/[><]=?/, replace)


      if line =~ /^!/
        from = line[/from:\s*(-?\d+(?:\.\d+)?)/, 1]
        from = from =~ /\./ ? from.to_f : from.to_i

        to = line[/to:\s*(-?\d+(?:\.\d+)?)/, 1]
        to = to =~ /\./ ? to.to_f : to.to_i

        step = line[/step:\s*(-?\d+(?:\.\d+)?)/, 1]
        step = step =~ /\./ ? step.to_f : step.to_i

        max_decimals = [from, to, step].map { |x| (x.to_s[/\.(\d+)/, 1] || '').length }.max

        from.step(to, step).each { |num| data[key] << "%.#{num.to_s =~ /\.0+$/ ? 0 : max_decimals}f" % num }
      else
        # Fractions
        line.gsub!(%r~(\S+)/(\S+)~) do
          frac = '%s/%s' % [$1, $2]
          # Return built-in fraction or create our own one with superscript, fraction bar and subscript
          FRACTION_CHARS[frac] || '^(%s)%s_(%s)' % [$1, '⁄', $2]
        end

        SPECIAL_CHARS.each { |find, repl| line.gsub!(find, repl) }

        line.gsub!(/\^\(([^)]+)\)/, '<sup>\1</sup>')
        line.gsub!(/_\(([^)]+)\)/, '<sub>\1</sub>')
        data[key] << line
      end
    end

    # Shuffle both
    %i(right wrong).each { |k| data[k].shuffle! }

    return data
  end

  def line_spacing
    @line_spacing ||= Math.sqrt(cell_area / LINE_BASE_AREA) * LINE_BASE_SPACING
  end

  def line_width
    @line_width ||= Math.sqrt(cell_area / LINE_BASE_AREA) * LINE_BASE_WIDTH
  end

  def card_height
    @card_height ||= (@pdf.bounds.top - ((@cards_per_page - 1) * @card_gap)) / @cards_per_page.to_f
  end

  def card_width
    @card_width ||= @pdf.bounds.right
  end

  def max_cell_size
    @cell_size ||= [cell_width, cell_height].max
  end

  def cell_width
    @cell_width ||= card_width / @cols.to_f
  end

  def cell_height
    @cell_height ||= card_height / @rows.to_f
  end

  def cell_area
    (@cell_area ||= cell_width * cell_height)
  end

  def text_box_height
    @text_box_height ||= (cell_width / TEXT_BOX_WH_RATIO) / cell_height
  end

  def generate
    @pages.times do |page|
      make_page
      @pdf.start_new_page unless page == @pages - 1
    end
    save
  end

  def make_page
    # We have to randomly walk through the cells, in order to randomly distribute the right answers
    # We have to first put all right answers in place, after which we will fill the remaining cells with
    # wrong ones
    coordinates = (0 ... @rows).flat_map { |row| (0 ... @cols).map { |col| [row, col] } }

    @cards_per_page.times do |i|
      data = read_data

      coordinates.shuffle.each do |row, col|
        x = col * cell_width

        # The rectangle is drawn from the top left, thus the initial y coordinate
        # is not 0 but cell_size, hence we do (row + 1) here
        y = ((row + 1) * cell_height) + (i * (cell_height * @rows + @card_gap))

        last_row = row == @rows - 1

        # Draw the cell
        @pdf.stroke { @pdf.rectangle [x, y], cell_width, cell_height }

        # Underline header row
        @pdf.line_width.tap do |lw|
          @pdf.line_width = 2.0 * lw
          @pdf.stroke { @pdf.line(x, y - cell_height, x + cell_width, y - cell_height) }
          @pdf.line_width = lw
        end if last_row and @use_header

        text = if last_row and @use_header # Write header
		  words = @header.split
          header_idx = col - (@cols - words.length) / 2
          header_idx < 0 || header_idx >= words.length ? '' : words[header_idx]
        else # Write data
          data[:right].shift || data[:wrong].shift || ''
        end

        tbw = TEXT_BOX_WIDTH
        tbh = last_row && @use_header ? HEADER_MAX_HEIGHT : text_box_height

        x_margin = ((1 - tbw) * cell_width) / 2.0
        y_margin = ((1 - tbh) * cell_height) / 2.0
        text_box_width = cell_width * tbw
        text_box_height = cell_height * tbh

        @pdf.text_box(
          text,
          at: [x + x_margin, y - y_margin],
          size: max_cell_size,
          inline_format: true,
          align: :center,
          valign: :center,
          width: text_box_width,
          height: text_box_height,
          overflow: :shrink_to_fit,
          single_line: true,
          final_gap: false,
          leading: line_spacing,
          disable_wrap_by_char: true,
          min_font_size: 0
        )
      end

      @generated_cards += 1

      break if @generated_cards == @num_cards
    end
  end

  def save(copies: 1)
    fname = '%s.pdf' % @filename
    @pdf.render_file(fname)

    if copies > 1
      (copies - 1).times do |copy|
        FileUtils.cp(fname, fname.sub(/(\.pdf)$/, '_%d\1' % (copy + 2)))
      end
      FileUtils.mv(fname, fname.sub(/(\.pdf)$/, '_1\1'))
    end
  end
end

if ARGV.length == 0
  Bingo.new(rows: 5, cols: 5, header: 'Simple Math Bingo Card :-)', cards_per_page: 3).generate
else
  rows, cols, num, per_page, header = ARGV[0].to_i, ARGV[1].to_i, ARGV[2].to_i, ARGV[3].to_i, ARGV[4]

  Bingo.new(rows: rows, cols: cols, header: header, num_cards: num, cards_per_page: per_page).generate
end