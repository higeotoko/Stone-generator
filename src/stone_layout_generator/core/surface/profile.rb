# frozen_string_literal: true

module Higeotoko::StoneLayout::Core
  # 水平断面（直線と円弧の連続）。u = 断面に沿った累積距離（基準面の弧長）。
  #
  # 閉じた断面（丸柱など）は周期 length の循環座標として扱う。
  class Profile
    DEFAULT_MAX_ANGLE = 7.5 * Math::PI / 180 # 曲面の最大分割角
    DEFAULT_MAX_ERROR = 0.5                  # 曲面の最大弦誤差 (mm)

    attr_reader :segments, :starts, :length

    def initialize(segments, closed: nil)
      raise InvalidInput, '断面要素がありません' if segments.empty?

      @segments = segments
      @starts = []
      acc = 0.0
      segments.each_with_index do |s, i|
        if i.positive?
          gap = segments[i - 1].end_point.dist(s.point_at(0))
          raise InvalidInput, "断面が不連続です（要素#{i - 1}と#{i}の間 #{gap.round(3)}mm）" if gap > 0.01
        end
        @starts << acc
        acc += s.length
      end
      @length = acc
      auto_closed = segments.last.end_point.dist(segments.first.point_at(0)) <= 0.01
      @closed = closed.nil? ? auto_closed : closed
      raise InvalidInput, '閉じた断面として指定されましたが始点と終点が一致しません' if @closed && !auto_closed
    end

    def closed?
      @closed
    end

    def wrap(u)
      return u unless @closed

      r = u % @length
      r = 0.0 if (@length - r) < 1e-9
      r
    end

    # [segment_index, local_s]
    def locate(u)
      u = @closed ? wrap(u) : u.clamp(0.0, @length)
      i = @starts.bsearch_index { |s0| s0 > u }
      i = i.nil? ? @segments.size - 1 : [i - 1, 0].max
      [i, (u - @starts[i]).clamp(0.0, @segments[i].length)]
    end

    def point(u)
      i, s = locate(u)
      @segments[i].point_at(s)
    end

    def tangent(u)
      i, s = locate(u)
      @segments[i].tangent_at(s)
    end

    def normal(u)
      i, s = locate(u)
      @segments[i].normal_at(s)
    end

    # 要素境界で接線が折れている位置（u のリスト）
    def corners
      @corners ||= begin
        list = []
        @segments.each_with_index do |seg, i|
          nxt = i + 1 < @segments.size ? @segments[i + 1] : (@closed ? @segments[0] : nil)
          next unless nxt

          t1 = seg.tangent_at(seg.length)
          t2 = nxt.tangent_at(0)
          next if t1.cross(t2).abs < 1e-7 && t1.dot(t2).positive?

          list << (i + 1 < @segments.size ? @starts[i + 1] : 0.0)
        end
        list
      end
    end

    # u が折れ点なら [前の要素の法線, 次の要素の法線]
    def corner_normals(u)
      w = wrap(u)
      corners.each do |c|
        next unless (w - c).abs <= Tol::POINT || (@closed && (w - c - @length).abs <= Tol::POINT) ||
                    (@closed && (w + @length - c).abs <= Tol::POINT)

        i = @starts.index { |s0| (s0 - c).abs <= Tol::POINT } || 0
        prev = @segments[(i - 1) % @segments.size]
        return [prev.normal_at(prev.length), @segments[i].normal_at(0)]
      end
      nil
    end

    # 法線方向に d オフセットした点。折れ点ではマイター（オフセット線どうしの交点）。
    def offset_point(u, d)
      if d != 0 && (cn = corner_normals(u))
        n1, n2 = cn
        denom = 1 + n1.dot(n2)
        raise GeometryError, '断面が折り返しているため厚みを付けられません' if denom < 1e-6

        return point(u) + (n1 + n2) * (d / denom)
      end
      i, s = locate(u)
      @segments[i].offset_point(s, d)
    end

    # [ua, ub] の間で 3D 化に必要な分割位置（要素境界・円弧分割点）。両端は含まない。
    def breakpoints(ua, ub, max_angle: DEFAULT_MAX_ANGLE, max_error: DEFAULT_MAX_ERROR)
      result = []
      shifts = @closed ? (((ua / @length).floor - 1)..((ub / @length).floor + 1)) : (0..0)
      shifts.each do |k|
        base = k * @length
        @segments.each_with_index do |seg, i|
          s0 = base + @starts[i]
          s1 = s0 + seg.length
          next if s1 < ua || s0 > ub

          result << s0
          next unless seg.is_a?(ArcSegment2)

          n = arc_steps(seg, max_angle, max_error)
          step = seg.length / n
          (1...n).each { |j| result << s0 + j * step }
        end
        result << base + @length
      end
      result.select { |u| u > ua + Tol::POINT && u < ub - Tol::POINT }.sort.uniq
    end

    def arc_steps(seg, max_angle, max_error)
      by_angle = (seg.sweep.abs / max_angle).ceil
      by_error = if max_error < seg.radius
                   (seg.sweep.abs / (2 * Math.acos(1 - max_error / seg.radius))).ceil
                 else
                   1
                 end
      [by_angle, by_error, 1].max
    end

    # [ua, ub] を d1..d2 オフセットしたとき円弧の半径が成立するか検査
    def check_offset(ua, ub, d_min, d_max)
      each_segment_in(ua, ub) do |seg|
        next unless seg.is_a?(ArcSegment2)

        [d_min, d_max].each do |d|
          r = seg.offset_radius(d)
          next if r > 1.0

          raise GeometryError, "R#{seg.radius.round(1)} では指定の石厚・オフセットを確保できません（内側半径 #{r.round(1)}mm）"
        end
      end
    end

    def each_segment_in(ua, ub)
      shifts = @closed ? (((ua / @length).floor - 1)..((ub / @length).floor + 1)) : (0..0)
      shifts.each do |k|
        @segments.each_with_index do |seg, i|
          s0 = k * @length + @starts[i]
          next if s0 + seg.length < ua || s0 > ub

          yield seg
        end
      end
    end

    # 平面上の点 p に最も近い断面上の位置 → [u, 距離]
    def project(p)
      best = nil
      @segments.each_with_index do |seg, i|
        s = if seg.is_a?(LineSegment2)
              (p - seg.p0).dot(seg.dir).clamp(0.0, seg.length)
            else
              ang = Math.atan2(p.y - seg.center.y, p.x - seg.center.x)
              delta = ((ang - seg.start_angle) * (seg.ccw? ? 1 : -1)) % (2 * Math::PI)
              sweep = seg.sweep.abs
              if delta > sweep
                # 弧の外側: 近い方の端
                delta = (2 * Math::PI - delta) < (delta - sweep) ? 0.0 : sweep
              end
              delta * seg.radius
            end
        d = seg.point_at(s).dist(p)
        best = [@starts[i] + s, d] if best.nil? || d < best[1]
      end
      best
    end

    # 3D の射線（xy 成分）と、オフセット d の断面との交点 → [[t, u], ...]
    def intersect_ray(o, dir, d)
      hits = []
      @segments.each_with_index do |seg, i|
        seg.intersect_ray(o, dir, d).each { |t, s| hits << [t, @starts[i] + s] }
      end
      hits
    end

    def to_h
      { 'segments' => @segments.map(&:to_h), 'closed' => @closed }
    end

    def self.from_h(h)
      new(h['segments'].map { |s| ProfileSegment.from_h(s) }, closed: h['closed'])
    end
  end
end
