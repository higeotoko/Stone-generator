# frozen_string_literal: true

module Higeotoko::StoneLayout::Core
  # SketchUp 非依存のポリゴンメッシュ（mm）。
  # Geometry Builder はこれを SketchUp の面に変換するだけ。
  class Mesh
    Poly = Struct.new(:indices, :soft) # soft[i]: indices[i]->indices[i+1] の辺を柔らかく（非表示に）する

    attr_reader :points, :polygons

    def initialize
      @points = []
      @index = {}
      @polygons = []
    end

    def add_point(p)
      key = p.map { |c| (c * 1.0e4).round }
      @index[key] ||= begin
        @points << p
        @points.size - 1
      end
    end

    def add_polygon(points, soft)
      idx = points.map { |p| add_point(p) }
      # 連続重複点を除去
      keep = []
      sf = []
      idx.each_with_index do |v, i|
        if keep.last == v
          sf[-1] = soft[i] # 重複点から出る辺は後の点の属性を引き継ぐ
          next
        end

        keep << v
        sf << soft[i]
      end
      if keep.size > 1 && keep.first == keep.last
        keep.pop
        sf.pop
      end
      return if keep.size < 3

      @polygons << Poly.new(keep, sf)
    end

    # すべての辺がちょうど2つの面に逆向きで共有されているか（閉じたソリッド）
    def manifold_errors
      count = Hash.new(0)
      @polygons.each do |pl|
        n = pl.indices.size
        n.times { |i| count[[pl.indices[i], pl.indices[(i + 1) % n]]] += 1 }
      end
      errs = []
      count.each do |(a, b), c|
        errs << [a, b, c, count[[b, a]]] unless c == 1 && count[[b, a]] == 1
      end
      errs
    end

    def manifold?
      manifold_errors.empty?
    end

    # 符号付き体積（外向き法線なら正）
    def volume
      v = 0.0
      @polygons.each do |pl|
        p0 = @points[pl.indices[0]]
        (1...(pl.indices.size - 1)).each do |i|
          p1 = @points[pl.indices[i]]
          p2 = @points[pl.indices[i + 1]]
          v += p0[0] * (p1[1] * p2[2] - p1[2] * p2[1]) -
               p0[1] * (p1[0] * p2[2] - p1[2] * p2[0]) +
               p0[2] * (p1[0] * p2[1] - p1[1] * p2[0])
        end
      end
      v / 6.0
    end

    def area_of(pl)
      n = [0.0, 0.0, 0.0]
      k = pl.indices.size
      k.times do |i|
        a = @points[pl.indices[i]]
        b = @points[pl.indices[(i + 1) % k]]
        n[0] += (a[1] - b[1]) * (a[2] + b[2])
        n[1] += (a[2] - b[2]) * (a[0] + b[0])
        n[2] += (a[0] - b[0]) * (a[1] + b[1])
      end
      0.5 * Math.sqrt(n.sum { |c| c * c })
    end

    # Newell 法による面法線（単位ベクトル）
    def normal_of(pl)
      n = [0.0, 0.0, 0.0]
      k = pl.indices.size
      k.times do |i|
        a = @points[pl.indices[i]]
        b = @points[pl.indices[(i + 1) % k]]
        n[0] += (a[1] - b[1]) * (a[2] + b[2])
        n[1] += (a[2] - b[2]) * (a[0] + b[0])
        n[2] += (a[0] - b[0]) * (a[1] + b[1])
      end
      l = Math.sqrt(n.sum { |c| c * c })
      l.zero? ? n : n.map { |c| c / l }
    end

    def bbox
      xs = @points.map { |p| p[0] }
      ys = @points.map { |p| p[1] }
      zs = @points.map { |p| p[2] }
      [[xs.min, ys.min, zs.min], [xs.max, ys.max, zs.max]]
    end
  end
end
