# frozen_string_literal: true

module Higeotoko::StoneLayout::Core
  # 目地中心線の領域から、目地幅を差し引いた「石の実輪郭」を作る。
  #
  # 各辺を内側へ (目地幅/2) 平行移動し、隣り合うオフセット線の交点を取る。
  #   - 縦目地の辺: joint_v / 2
  #   - 横目地の辺: joint_h / 2
  #   - 外周境界:   edge_clearance
  #   - 開口部の縁: opening_gap（サッシとのシーリング代など）
  # 同一直線上で量が異なる辺（例: 外周と目地）の間には段差を入れる。
  # 結果は単純多角形・同じ向き・各辺が潰れていないことを検証する。
  module OutlineBuilder
    module_function

    def build(points, flags, settings)
      pts, fl = Polygon.simplify(points, flags)
      dists = Polygon.edges(pts).each_with_index.map do |(a, b), i|
        if fl[i] == 'B'
          settings['edge_clearance']
        elsif fl[i] == 'O'
          settings['opening_gap']
        else
          d = b - a
          d.x.abs < d.y.abs ? settings['joint_v'] * 0.5 : settings['joint_h'] * 0.5
        end
      end
      inset(pts, dists)
    end

    def inset(pts, dists)
      n = pts.size
      lines = Polygon.edges(pts).each_with_index.map do |(a, b), i|
        dir = (b - a).normalize
        [a + dir.left_normal * dists[i], dir]
      end
      out = []
      first_of = []
      last_of = []
      n.times do |i|
        prev = (i - 1) % n
        p1, d1 = lines[prev]
        p2, d2 = lines[i]
        first_of[i] = out.size
        if d1.cross(d2).abs < 1e-9
          raise GeometryError, '輪郭が折り返しています' if d1.dot(d2).negative?

          v = pts[i]
          out << v + d1.left_normal * dists[prev]
          out << v + d2.left_normal * dists[i] if (dists[prev] - dists[i]).abs > Tol::POINT
        else
          out << Geom2.line_intersection(p1, d1, p2, d2)
        end
        last_of[i] = out.size - 1
      end

      n.times do |i|
        a = out[last_of[i]]
        b = out[first_of[(i + 1) % n]]
        orig = pts[(i + 1) % n] - pts[i]
        if (b - a).dot(orig) <= 0 || a.dist(b) < Tol::MIN_EDGE
          raise GeometryError, '目地幅に対して石が小さすぎます（輪郭が潰れます）'
        end
      end
      raise GeometryError, '石の輪郭が自己交差します' unless Polygon.simple?(out) && Polygon.signed_area(out).positive?

      out
    end
  end
end
