# frozen_string_literal: true

module Higeotoko::StoneLayout::Core
  # 線分集合の平面分割（arrangement）。
  #
  # 1. 線分どうしの交点・T字接点・重なりで線分を分割
  # 2. 近接頂点を統合（Tol::POINT）
  # 3. ハーフエッジ構造を作り、各頂点で角度順に並べる
  # 4. 面（閉路）をたどる。符号付き面積 > 0 が有界面（CCW）
  #
  # 目地中心線 + 外周境界 を入れると、各有界面がそのまま「石の領域」になる。
  # 片側にしか面を持たない辺（浮いた目地端）は dangling として報告する。
  class Arrangement
    Face = Struct.new(:points, :edge_tags, :area)

    attr_reader :faces, :dangling, :component_count, :vertices

    def initialize(tol = Tol::POINT)
      @tol = tol
      @segs = []
    end

    def add_segment(a, b, tag)
      return if a.dist(b) <= @tol

      @segs << [a, b, tag]
    end

    def segment_count
      @segs.size
    end

    def compute
      splits = Array.new(@segs.size) { [] }
      each_candidate_pair { |i, j| intersect(i, j, splits) }
      build_edges(splits)
      build_faces
      self
    end

    private

    # ---- 1. 交点計算 -------------------------------------------------------

    def each_candidate_pair
      n = @segs.size
      return if n < 2

      boxes = @segs.map { |a, b, _| [[a.x, b.x].min, [a.y, b.y].min, [a.x, b.x].max, [a.y, b.y].max] }
      all = boxes.reduce { |m, b| Geom2.bbox_union(m, b) }
      w = [all[2] - all[0], 1.0].max
      h = [all[3] - all[1], 1.0].max
      cell = [Math.sqrt(w * h / n) * 2.0, @tol * 100].max
      grid = Hash.new { |hh, k| hh[k] = [] }
      boxes.each_with_index do |b, i|
        x0 = ((b[0] - @tol - all[0]) / cell).floor
        x1 = ((b[2] + @tol - all[0]) / cell).floor
        y0 = ((b[1] - @tol - all[1]) / cell).floor
        y1 = ((b[3] + @tol - all[1]) / cell).floor
        (x0..x1).each { |ix| (y0..y1).each { |iy| grid[(ix << 32) ^ (iy & 0xffffffff)] << i } }
      end
      seen = {}
      grid.each_value do |list|
        next if list.size < 2

        list.each_with_index do |i, a|
          ((a + 1)...list.size).each do |b|
            j = list[b]
            key = i < j ? i * n + j : j * n + i
            next if seen.key?(key)

            seen[key] = true
            next unless Geom2.bbox_intersect?(boxes[i], boxes[j], @tol)

            yield(i, j)
          end
        end
      end
    end

    def intersect(i, j, splits)
      a1, b1, = @segs[i]
      a2, b2, = @segs[j]
      d1 = b1 - a1
      d2 = b2 - a2
      l1 = d1.length
      l2 = d2.length
      denom = d1.cross(d2)
      if (denom / (l1 * l2)).abs > Tol::PARALLEL
        w = a2 - a1
        t = w.cross(d2) / denom
        s = w.cross(d1) / denom
        et = @tol / l1
        es = @tol / l2
        return unless t >= -et && t <= 1 + et && s >= -es && s <= 1 + es

        t_end = t <= et || t >= 1 - et
        s_end = s <= es || s >= 1 - es
        p = if t_end
              t <= et ? a1 : b1
            elsif s_end
              s <= es ? a2 : b2
            else
              a1 + d1 * t
            end
        splits[i] << [t.clamp(0.0, 1.0), p] unless t_end
        splits[j] << [s.clamp(0.0, 1.0), p] unless s_end
      else
        # 平行：同一直線上で重なる場合だけ互いの端点で分割
        return if (d1.cross(a2 - a1) / l1).abs > @tol

        et = @tol / l1
        es = @tol / l2
        [a2, b2].each do |p|
          t = (p - a1).dot(d1) / (l1 * l1)
          splits[i] << [t, p] if t > et && t < 1 - et
        end
        [a1, b1].each do |p|
          s = (p - a2).dot(d2) / (l2 * l2)
          splits[j] << [s, p] if s > es && s < 1 - es
        end
      end
    end

    # ---- 2. 頂点統合とエッジ化 --------------------------------------------

    def vertex_id(p)
      cell = @tol * 4
      kx = (p.x / cell).floor
      ky = (p.y / cell).floor
      (-1..1).each do |dx|
        (-1..1).each do |dy|
          list = @vgrid[((kx + dx) << 32) ^ ((ky + dy) & 0xffffffff)]
          next unless list

          list.each { |id| return id if @vertices[id].dist(p) <= @tol }
        end
      end
      id = @vertices.size
      @vertices << p
      (@vgrid[(kx << 32) ^ (ky & 0xffffffff)] ||= []) << id
      id
    end

    def build_edges(splits)
      @vertices = []
      @vgrid = {}
      @edges = {}
      @segs.each_with_index do |(a, b, tag), i|
        pts = [[0.0, a]] + splits[i].sort_by(&:first) + [[1.0, b]]
        ids = pts.map { |_, p| vertex_id(p) }
        ids.each_cons(2) do |p, q|
          next if p == q

          key = p < q ? [p, q] : [q, p]
          tags = (@edges[key] ||= [])
          tags << tag unless tags.include?(tag)
        end
      end
    end

    # ---- 3/4. ハーフエッジと面 ---------------------------------------------

    def build_faces
      org = []
      dst = []
      tags = []
      out = Array.new(@vertices.size) { [] }
      @edges.each do |(p, q), t|
        h = org.size
        org << p << q
        dst << q << p
        tags << t << t
        out[p] << h
        out[q] << (h + 1)
      end
      angle = Array.new(org.size) do |h|
        d = @vertices[dst[h]] - @vertices[org[h]]
        Math.atan2(d.y, d.x)
      end
      pos = Array.new(org.size)
      out.each do |list|
        list.sort_by! { |h| angle[h] }
        list.each_with_index { |h, k| pos[h] = k }
      end

      face_of = Array.new(org.size)
      cycles = []
      org.size.times do |start|
        next if face_of[start]

        cyc = []
        h = start
        until face_of[h]
          face_of[h] = cycles.size
          cyc << h
          v = dst[h]
          list = out[v]
          h = list[(pos[h ^ 1] - 1) % list.size]
        end
        cycles << cyc
      end

      @faces = []
      @dangling = []
      (0...org.size).step(2) do |h|
        @dangling << [@vertices[org[h]], @vertices[dst[h]]] if face_of[h] == face_of[h + 1]
      end
      cycles.each do |cyc|
        pts = cyc.map { |h| @vertices[org[h]] }
        a = Polygon.signed_area(pts)
        next unless a > Tol::AREA

        @faces << Face.new(pts, cyc.map { |h| tags[h] }, a)
      end
      @component_count = count_components
    end

    def count_components
      parent = (0...@vertices.size).to_a
      find = lambda do |x|
        x = parent[x] = parent[parent[x]] while parent[x] != x
        x
      end
      @edges.each_key { |p, q| parent[find.call(p)] = find.call(q) }
      @vertices.size.times.map { |v| find.call(v) }.uniq.size
    end
  end
end
