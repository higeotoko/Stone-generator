# frozen_string_literal: true

module Higeotoko::StoneLayout::Core
  # 2D の基本幾何関数。bbox は [minx, miny, maxx, maxy] の配列で表す。
  module Geom2
    module_function

    def dist_point_segment(p, a, b)
      d = b - a
      l2 = d.length2
      return p.dist(a) if l2.zero?

      t = ((p - a).dot(d) / l2).clamp(0.0, 1.0)
      p.dist(a + d * t)
    end

    def point_on_segment?(p, a, b, tol = Tol::POINT)
      dist_point_segment(p, a, b) <= tol
    end

    # a-b と c-d が同一直線上にあるか
    def collinear?(a, b, c, d, tol = Tol::POINT)
      dir = b - a
      l = dir.length
      return false if l.zero?

      (dir.cross(c - a) / l).abs <= tol && (dir.cross(d - a) / l).abs <= tol
    end

    def bbox(points)
      xs = points.map(&:x)
      ys = points.map(&:y)
      [xs.min, ys.min, xs.max, ys.max]
    end

    def bbox_union(a, b)
      return b if a.nil?
      return a if b.nil?

      [[a[0], b[0]].min, [a[1], b[1]].min, [a[2], b[2]].max, [a[3], b[3]].max]
    end

    def bbox_expand(b, d)
      [b[0] - d, b[1] - d, b[2] + d, b[3] + d]
    end

    def bbox_shift_x(b, dx)
      [b[0] + dx, b[1], b[2] + dx, b[3]]
    end

    def bbox_intersect?(a, b, tol = Tol::POINT)
      a[0] <= b[2] + tol && b[0] <= a[2] + tol && a[1] <= b[3] + tol && b[1] <= a[3] + tol
    end

    # Liang-Barsky による矩形クリップ。矩形の辺上にある線分は残す。
    def clip_segment(a, b, rect, tol = Tol::POINT)
      t0 = 0.0
      t1 = 1.0
      dx = b.x - a.x
      dy = b.y - a.y
      [[-dx, a.x - rect[0]], [dx, rect[2] - a.x], [-dy, a.y - rect[1]], [dy, rect[3] - a.y]].each do |p, q|
        if p.abs < 1e-12
          return nil if q < -tol
        else
          r = q / p
          if p.negative?
            return nil if r > t1
            t0 = r if r > t0
          else
            return nil if r < t0
            t1 = r if r < t1
          end
        end
      end
      return nil if t1 - t0 <= 0

      na = t0.zero? ? a : Vec2.new(a.x + dx * t0, a.y + dy * t0)
      nb = t1 == 1.0 ? b : Vec2.new(a.x + dx * t1, a.y + dy * t1)
      return nil if na.dist(nb) <= tol

      [na, nb]
    end

    def rect_edges(rect)
      p0 = Vec2.new(rect[0], rect[1])
      p1 = Vec2.new(rect[2], rect[1])
      p2 = Vec2.new(rect[2], rect[3])
      p3 = Vec2.new(rect[0], rect[3])
      [[p0, p1], [p1, p2], [p2, p3], [p3, p0]]
    end

    # 2直線 (p + t*r), (q + s*s_dir) の交点
    def line_intersection(p, r, q, s)
      denom = r.cross(s)
      return nil if denom.abs < 1e-12

      t = (q - p).cross(s) / denom
      p + r * t
    end
  end
end
