# frozen_string_literal: true

module Higeotoko::StoneLayout::Core
  # 単純多角形（Vec2 の配列、閉じ点は含まない）に関する関数群。
  module Polygon
    module_function

    def signed_area(pts)
      s = 0.0
      n = pts.size
      n.times do |i|
        a = pts[i]
        b = pts[(i + 1) % n]
        s += a.x * b.y - b.x * a.y
      end
      s * 0.5
    end

    def area(pts)
      signed_area(pts).abs
    end

    def bbox(pts)
      Geom2.bbox(pts)
    end

    def edges(pts)
      n = pts.size
      Array.new(n) { |i| [pts[i], pts[(i + 1) % n]] }
    end

    def translate_x(pts, dx)
      dx.zero? ? pts : pts.map { |p| p.shift_x(dx) }
    end

    # 偶奇規則による内外判定（境界上の点は不定。内部点判定用）
    def contains?(pts, p)
      inside = false
      n = pts.size
      j = n - 1
      n.times do |i|
        a = pts[i]
        b = pts[j]
        if (a.y > p.y) != (b.y > p.y)
          x = a.x + (p.y - a.y) * (b.x - a.x) / (b.y - a.y)
          inside = !inside if p.x < x
        end
        j = i
      end
      inside
    end

    # 確実に内部にある点を1つ返す。
    # 頂点を通らない水平走査線を選び、最も長い内部区間の中点を取る。
    def interior_point(pts)
      ys = pts.map(&:y).sort
      best_gap = nil
      ys.each_cons(2) do |y0, y1|
        next if y1 - y0 <= Tol::POINT
        best_gap = [y0, y1] if best_gap.nil? || (y1 - y0) > (best_gap[1] - best_gap[0])
      end
      return nil unless best_gap

      y = (best_gap[0] + best_gap[1]) * 0.5
      xs = []
      edges(pts).each do |a, b|
        next unless (a.y > y) != (b.y > y)

        xs << a.x + (y - a.y) * (b.x - a.x) / (b.y - a.y)
      end
      xs.sort!
      best = nil
      xs.each_slice(2) do |x0, x1|
        next if x1.nil?
        best = [x0, x1] if best.nil? || (x1 - x0) > (best[1] - best[0])
      end
      return nil unless best

      Vec2.new((best[0] + best[1]) * 0.5, y)
    end

    # 自己交差がないか（隣接しない辺どうしの接触も不可）
    def simple?(pts, tol = Tol::POINT)
      n = pts.size
      return false if n < 3

      es = edges(pts)
      n.times do |i|
        a, b = es[i]
        return false if a.dist(b) <= tol

        # 隣接辺の折り返し（スパイク）
        c, d = es[(i + 1) % n]
        u = b - a
        w = d - c
        return false if (u.cross(w) / (u.length * w.length)).abs < Tol::PARALLEL && u.dot(w).negative?

        ((i + 2)...n).each do |j|
          next if i.zero? && j == n - 1

          c, d = es[j]
          return false if segments_touch?(a, b, c, d, tol)
        end
      end
      true
    end

    def segments_touch?(a, b, c, d, tol)
      return true if Geom2.point_on_segment?(a, c, d, tol) || Geom2.point_on_segment?(b, c, d, tol)
      return true if Geom2.point_on_segment?(c, a, b, tol) || Geom2.point_on_segment?(d, a, b, tol)

      d1 = (b - a).cross(c - a)
      d2 = (b - a).cross(d - a)
      d3 = (d - c).cross(a - c)
      d4 = (d - c).cross(b - c)
      ((d1.positive? && d2.negative?) || (d1.negative? && d2.positive?)) &&
        ((d3.positive? && d4.negative?) || (d3.negative? && d4.positive?))
    end

    # 同一直線上の中間頂点を取り除く。flags（辺ごとの属性）が異なる場合は残す。
    # 戻り値 [pts, flags]。flags[i] は pts[i] -> pts[i+1] の辺の属性。
    def simplify(pts, flags = nil, tol = Tol::POINT)
      flags ||= Array.new(pts.size, nil)
      pts = pts.dup
      flags = flags.dup
      changed = true
      while changed && pts.size > 3
        changed = false
        n = pts.size
        n.times do |i|
          prev = (i - 1) % n
          a = pts[prev]
          b = pts[i]
          c = pts[(i + 1) % n]
          next unless flags[prev] == flags[i]

          ac = c - a
          l = ac.length
          next if l.zero?
          next unless (ac.cross(b - a) / l).abs <= tol && (b - a).dot(c - b) > -tol

          pts.delete_at(i)
          flags.delete_at(i)
          changed = true
          break
        end
      end
      [pts, flags]
    end

    # 形状比較用キー（始点・回転に依存しない）
    def canonical_key(pts, flags = nil, q = Tol::KEY)
      sp, sf = simplify(pts, flags)
      start = (0...sp.size).min_by { |i| [(sp[i].x / q).round, (sp[i].y / q).round] }
      parts = sp.size.times.map do |k|
        i = (start + k) % sp.size
        "#{(sp[i].x / q).round},#{(sp[i].y / q).round},#{sf[i]}"
      end
      parts.join(';')
    end

    # 最小の幅（水平方向の内部区間長）と高さ（鉛直方向）を走査で求める。
    def min_extents(pts)
      [min_chord(pts, :x), min_chord(pts, :y)]
    end

    # axis=:x なら水平走査線上の内部区間の最小長。
    def min_chord(pts, axis)
      along = axis == :x ? :x : :y
      across = axis == :x ? :y : :x
      levels = pts.map(&across).sort.each_with_object([]) do |c, acc|
        acc << c if acc.empty? || c - acc.last > Tol::POINT
      end
      best = Float::INFINITY
      levels.each_cons(2) do |c0, c1|
        c = (c0 + c1) * 0.5
        vals = []
        edges(pts).each do |a, b|
          ac = a.send(across)
          bc = b.send(across)
          next unless (ac > c) != (bc > c)

          vals << a.send(along) + (c - ac) * (b.send(along) - a.send(along)) / (bc - ac)
        end
        vals.sort!
        vals.each_slice(2) { |v0, v1| best = [best, v1 - v0].min if v1 }
      end
      best
    end
  end
end
