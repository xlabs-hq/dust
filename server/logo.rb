#!/usr/bin/env ruby
# frozen_string_literal: true

# Generates the Dust logo as SVG and PNG.
#
# Renders the word "dust" as a 2x2 grid of 4x4 pixel-font glyphs:
#
#   +----+----+
#   | d  | u  |
#   +----+----+
#   | s  | t  |
#   +----+----+
#
# Outputs both a light variant and a literal-inverted dark variant:
#   server/logo.{svg,png}        — light theme
#   server/logo-dark.{svg,png}   — dark theme (every color inverted)
#
# Usage: ruby logo.rb [basename]
#   basename defaults to ./logo
#
# Requires `rsvg-convert` on PATH for the PNG step.
#   brew install librsvg

require "fileutils"

# ---------- Color Variables (edit me) ----------

WHITE = "#ffffff"
GREY  = "#dcdcdc"
BLACK = "#222222"

ON_COLOR   = BLACK
OFF_COLOR  = GREY
BACKGROUND = WHITE

# ---------- Glyph Definitions ----------
#
# Each glyph is GLYPH_HEIGHT rows of GLYPH_WIDTH characters.
# X = filled pixel, . = empty pixel.
#
# Edit these freely — change GLYPH_WIDTH and GLYPH_HEIGHT below to
# resize the grid. The renderer uses the dimensions you set, so all
# four glyphs must agree.

GLYPH_WIDTH  = 3
GLYPH_HEIGHT = 4

GLYPHS = {
  "d" => [
    "..X",
    "XXX",
    "X.X",
    "XXX",
  ],
  "u" => [
    "...",
    "X.X",
    "X.X",
    "XX.",
  ],
  "s" => [
    ".XX",
    "X..",
    "..X",
    "XX.",
  ],
  "t" => [
    "X..",
    "XX.",
    "X..",
    "XXX",
  ],
}.freeze

LAYOUT = [
  ["d", "u"],
  ["s", "t"],
].freeze

# ---------- Render Settings ----------

PIXEL_SIZE = 48  # SVG units per pixel cell
PIXEL_GAP  = 4   # gap between adjacent pixels within a panel
PANEL_GAP  = 32  # gap between adjacent panels
MARGIN     = 32  # canvas margin around the whole logo

# ---------- Color Helpers ----------

def invert_hex(hex)
  raise "expected #rrggbb, got #{hex.inspect}" unless hex =~ /\A#([0-9a-fA-F]{6})\z/

  digits = Regexp.last_match(1)
  r = 255 - digits[0, 2].to_i(16)
  g = 255 - digits[2, 2].to_i(16)
  b = 255 - digits[4, 2].to_i(16)
  format("#%02x%02x%02x", r, g, b)
end

# ---------- Layout / Render ----------

def panel_width
  GLYPH_WIDTH * PIXEL_SIZE + (GLYPH_WIDTH - 1) * PIXEL_GAP
end

def panel_height
  GLYPH_HEIGHT * PIXEL_SIZE + (GLYPH_HEIGHT - 1) * PIXEL_GAP
end

def canvas_width
  cols = LAYOUT.first.length
  cols * panel_width + (cols - 1) * PANEL_GAP + 2 * MARGIN
end

def canvas_height
  rows = LAYOUT.length
  rows * panel_height + (rows - 1) * PANEL_GAP + 2 * MARGIN
end

def render_pixel(x, y, color)
  %(  <rect x="#{x}" y="#{y}" width="#{PIXEL_SIZE}" height="#{PIXEL_SIZE}" fill="#{color}" />)
end

def render_panel(glyph_rows, origin_x, origin_y, on_color, off_color)
  rects = []
  GLYPH_HEIGHT.times do |row|
    GLYPH_WIDTH.times do |col|
      x = origin_x + col * (PIXEL_SIZE + PIXEL_GAP)
      y = origin_y + row * (PIXEL_SIZE + PIXEL_GAP)
      filled = glyph_rows[row][col] == "X"
      color = filled ? on_color : off_color
      rects << render_pixel(x, y, color)
    end
  end
  rects
end

def render_svg(on_color, off_color, background)
  w = canvas_width
  h = canvas_height
  out = []
  out << %(<svg xmlns="http://www.w3.org/2000/svg" width="#{w}" height="#{h}" viewBox="0 0 #{w} #{h}">)
  out << %(  <rect width="#{w}" height="#{h}" fill="#{background}" />)

  LAYOUT.each_with_index do |row, panel_row|
    row.each_with_index do |letter, panel_col|
      origin_x = MARGIN + panel_col * (panel_width + PANEL_GAP)
      origin_y = MARGIN + panel_row * (panel_height + PANEL_GAP)
      out.concat(render_panel(GLYPHS.fetch(letter), origin_x, origin_y, on_color, off_color))
    end
  end

  out << "</svg>"
  out.join("\n")
end

def write_png(svg_path, png_path)
  w = canvas_width
  h = canvas_height
  ok = system("rsvg-convert", "-w", w.to_s, "-h", h.to_s, svg_path, "-o", png_path)
  warn "rsvg-convert failed; install with `brew install librsvg`." unless ok
end

def render(basename, on_color, off_color, background)
  svg_path = "#{basename}.svg"
  png_path = "#{basename}.png"
  FileUtils.mkdir_p(File.dirname(svg_path))
  File.write(svg_path, render_svg(on_color, off_color, background))
  write_png(svg_path, png_path)
  puts "Wrote #{svg_path}"
  puts "Wrote #{png_path}" if File.exist?(png_path)
end

# ---------- Main ----------

basename = ARGV[0] || File.join(__dir__, "assets", "public", "images", "logo")

render(basename, ON_COLOR, OFF_COLOR, BACKGROUND)
render("#{basename}-dark",
       invert_hex(ON_COLOR),
       invert_hex(OFF_COLOR),
       invert_hex(BACKGROUND))
