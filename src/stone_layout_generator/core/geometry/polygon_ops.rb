# frozen_string_literal: true

module Higeotoko::StoneLayout::Core
  # Arrangement を使う多角形演算
  module PolygonOps
    module_function

    # 2つの単純多角形の共通部分の面積（重なりによる石IDの引き継ぎ判定に使う）
    def intersection_area(p, q)
      bp = Polygon.bbox(p)
      bq = Polygon.bbox(q)
      return 0.0 unless Geom2.bbox_intersect?(bp, bq, 0.0)

      arr = Arrangement.new
      Polygon.edges(p).each { |a, b| arr.add_segment(a, b, :p) }
      Polygon.edges(q).each { |a, b| arr.add_segment(a, b, :q) }
      arr.compute
      arr.faces.sum do |f|
        s = Polygon.interior_point(f.points)
        s && Polygon.contains?(p, s) && Polygon.contains?(q, s) ? f.area : 0.0
      end
    end
  end
end
