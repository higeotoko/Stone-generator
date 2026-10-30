# frozen_string_literal: true

module Higeotoko::StoneLayout::Core
  # 割付対象面の抽象表現。
  #
  #   P(u, v, s) = ( profile.offset_point(u, s), v )
  #
  # u: 断面に沿った累積距離（基準面＝選択面上の弧長）
  # v: 高さ（z）
  # s: 法線方向オフセット（+ が外側）
  #
  # boundary は展開座標 (u, v) 上の外周多角形（CCW）。
  # 閉じた断面では u 方向が周期的になり、boundary は [0, L] x [v_min, v_max]。
  class SurfaceDefinition
    attr_reader :profile, :boundary, :source

    def self.rectangle(profile, v_min, v_max, source = {})
      l = profile.length
      boundary = [Vec2.new(0, v_min), Vec2.new(l, v_min), Vec2.new(l, v_max), Vec2.new(0, v_max)]
      new(profile, boundary, source)
    end

    # テスト・単純な平面壁用: 原点から +x 方向の幅 width、高さ height
    def self.flat_wall(width, height, origin: Vec2.new(0, 0), v_min: 0.0)
      prof = Profile.new([LineSegment2.new(origin, origin + Vec2.new(width, 0))])
      rectangle(prof, v_min, v_min + height)
    end

    def initialize(profile, boundary, source = {})
      @profile = profile
      boundary = boundary.reverse if Polygon.signed_area(boundary).negative?
      raise InvalidInput, '割付範囲の外周が不正です' unless Polygon.area(boundary) > Tol::AREA

      @boundary = boundary
      @source = source
      @bbox = Polygon.bbox(boundary)
    end

    def periodic?
      @profile.closed?
    end

    def period
      @profile.length
    end

    def bbox
      @bbox
    end

    def v_min
      @bbox[1]
    end

    def v_max
      @bbox[3]
    end

    def u_length
      @profile.length
    end

    def rectangular?
      @boundary.size == 4 && (Polygon.area(@boundary) - (@bbox[2] - @bbox[0]) * (@bbox[3] - @bbox[1])).abs < Tol::AREA
    end

    # 展開座標の点が割付範囲内か（周期方向は無視）
    def inside?(p, tol = Tol::POINT)
      if periodic?
        p.y >= v_min - tol && p.y <= v_max + tol
      else
        return true if Polygon.contains?(@boundary, p)

        Polygon.edges(@boundary).any? { |a, b| Geom2.point_on_segment?(p, a, b, tol) }
      end
    end

    # 3D 座標 [x, y, z] (mm)
    def point3d(u, v, s = 0.0)
      q = @profile.offset_point(u, s)
      [q.x, q.y, v]
    end

    def normal3d(u)
      n = @profile.normal(u)
      [n.x, n.y, 0.0]
    end

    # 3D 射線とオフセット s の面の交点 → { u:, v:, t: } （最も近いもの）
    def intersect_ray(origin, dir, s = 0.0)
      o2 = Vec2.new(origin[0], origin[1])
      d2 = Vec2.new(dir[0], dir[1])
      return nil if d2.length2 < 1e-18

      best = nil
      @profile.intersect_ray(o2, d2, s).each do |t, u|
        next if t.negative?

        v = origin[2] + dir[2] * t
        p = Vec2.new(u, v)
        next unless periodic? ? (v >= v_min - 1 && v <= v_max + 1) : inside?(p, 1.0)

        best = { u: u, v: v, t: t } if best.nil? || t < best[:t]
      end
      best
    end

    # 展開座標の折れ線を 3D 点列へ（曲面部分は分割して沿わせる）
    def polyline3d(a, b, s = 0.0)
      lo, hi = [a.x, b.x].minmax
      us = [lo]
      us.concat(@profile.breakpoints(lo, hi)) if hi - lo > Tol::POINT
      us << hi
      us.reverse! if b.x < a.x
      us.map do |u|
        t = (b.x - a.x).abs > Tol::POINT ? (u - a.x) / (b.x - a.x) : 0.0
        point3d(u, a.y + (b.y - a.y) * t, s)
      end
    end

    def to_h
      { 'profile' => @profile.to_h, 'boundary' => @boundary.map(&:to_a), 'source' => @source }
    end

    def self.from_h(h)
      new(Profile.from_h(h['profile']), h['boundary'].map { |a| Vec2.new(*a) }, h['source'] || {})
    end
  end
end
