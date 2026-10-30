# frozen_string_literal: true

module Higeotoko::StoneLayout::Core
  # 目地線分 + 外周境界 → 石の領域（面）。
  #
  # window を指定すると、その矩形の中だけで平面分割を行う（局所再計算）。
  # 周期断面（丸柱）では線分を ±周期 だけずらしたコピーを置き、
  # 「最小頂点（アンカー）が [0, L) にある面」を代表として採用する。
  class FaceExtractor
    ExtractedFace = Struct.new(:points, :flags, :sample) do
      def bbox
        Polygon.bbox(points)
      end
    end

    Result = Struct.new(:faces, :dangling, :components, :errors)

    def initialize(surface)
      @surface = surface
    end

    # placed: [[a, b, id], ...]（window の座標フレームに置かれた線分）
    def extract(placed, window)
      arr = Arrangement.new
      placed.each do |a, b, id|
        clipped = Geom2.clip_segment(a, b, window)
        arr.add_segment(clipped[0], clipped[1], id) if clipped
      end
      boundary_edges(window).each { |a, b| arr.add_segment(a, b, :boundary) }
      Geom2.rect_edges(window).each { |a, b| arr.add_segment(a, b, :window) }
      arr.compute

      faces = arr.faces.map do |f|
        flags = f.edge_tags.map do |tags|
          if tags.any? { |t| t.is_a?(Integer) }
            'J'
          elsif tags.include?(:boundary)
            'B'
          else
            'W'
          end
        end
        ExtractedFace.new(f.points, flags, Polygon.interior_point(f.points))
      end
      faces.select! { |f| f.sample && @surface.inside?(f.sample, 0.0) }
      Result.new(faces, arr.dangling, arr.component_count, [])
    end

    # 文書全体の面を求める
    def extract_all(segments)
      if @surface.periodic?
        l = @surface.period
        window = [-l, @surface.v_min, 2 * l, @surface.v_max]
        placed = []
        segments.each { |s| [-l, 0.0, l].each { |dx| placed << [s.a.shift_x(dx), s.b.shift_x(dx), s.id] } }
        res = extract(placed, window)
        res.faces.select! { |f| !f.flags.include?('W') && anchor_in_period?(f.points) }
        res
      else
        b = @surface.bbox
        res = extract(segments.map { |s| [s.a, s.b, s.id] }, b)
        res
      end
    end

    def anchor(points)
      points.min_by { |p| [p.x.round(6), p.y.round(6)] }
    end

    def anchor_in_period?(points)
      x = anchor(points).x
      x >= -Tol::POINT && x < @surface.period - Tol::POINT
    end

    # 面を「アンカーが [0, L) に入るフレーム」へ平行移動する量
    def normalize_shift(points)
      return 0.0 unless @surface.periodic?

      l = @surface.period
      x = anchor(points).x
      k = ((x + Tol::POINT) / l).floor
      -k * l
    end

    private

    def boundary_edges(window)
      if @surface.periodic?
        [@surface.v_min, @surface.v_max].filter_map do |v|
          next nil if v < window[1] - Tol::POINT || v > window[3] + Tol::POINT

          [Vec2.new(window[0], v), Vec2.new(window[2], v)]
        end
      else
        Polygon.edges(@surface.boundary).filter_map { |a, b| Geom2.clip_segment(a, b, window) }
      end
    end
  end
end
