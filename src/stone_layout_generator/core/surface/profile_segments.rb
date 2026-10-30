# frozen_string_literal: true

module Higeotoko::StoneLayout::Core
  # 水平断面を構成する要素（xy 平面, mm）。
  #
  # 法線の約束: N = T × Z = (T.y, -T.x)。
  # 壁を正面（N 側）から見たとき、u は左→右に増える。
  # 正のオフセット s は N 方向（外側＝見る人の側）。
  class LineSegment2
    attr_reader :p0, :p1, :length, :dir

    def initialize(p0, p1)
      @p0 = p0
      @p1 = p1
      @length = p0.dist(p1)
      raise InvalidInput, '長さゼロの断面要素があります' if @length <= Tol::POINT

      @dir = (p1 - p0) / @length
    end

    def type
      'line'
    end

    def point_at(s)
      @p0 + @dir * s
    end

    def tangent_at(_s)
      @dir
    end

    def normal_at(_s)
      Vec2.new(@dir.y, -@dir.x)
    end

    def offset_point(s, d)
      point_at(s) + normal_at(s) * d
    end

    def end_point
      @p1
    end

    # 2D 射線 o + t*dir と、オフセット d した線分の交点 → [[t, s_local], ...]
    def intersect_ray(o, dir, d)
      n = normal_at(0)
      a = @p0 + n * d
      e = @dir * @length
      denom = dir.cross(e)
      return [] if denom.abs < 1e-12

      w = a - o
      t = w.cross(e) / denom
      w2 = w.cross(dir) / denom
      return [] if w2 < -1e-9 || w2 > 1 + 1e-9

      [[t, w2.clamp(0.0, 1.0) * @length]]
    end

    def to_h
      { 'type' => 'line', 'p0' => @p0.to_a, 'p1' => @p1.to_a }
    end
  end

  # 円弧。sweep は符号付き（+ が CCW = 進行方向左に曲がる）。
  class ArcSegment2
    attr_reader :center, :radius, :start_angle, :sweep, :length

    def initialize(center, radius, start_angle, sweep)
      raise InvalidInput, '円弧の半径が不正です' unless radius > Tol::POINT
      raise InvalidInput, '円弧の角度がゼロです' if sweep.abs < 1e-9

      @center = center
      @radius = radius.to_f
      @start_angle = start_angle.to_f
      @sweep = sweep.to_f
      @length = @radius * @sweep.abs
    end

    def type
      'arc'
    end

    def ccw?
      @sweep.positive?
    end

    # 外側（+N）へ d オフセットしたときの半径。CCW は中心が左＝ -N 側。
    def offset_radius(d)
      ccw? ? @radius + d : @radius - d
    end

    def angle_at(s)
      @start_angle + (ccw? ? 1 : -1) * s / @radius
    end

    def point_at(s)
      a = angle_at(s)
      @center + Vec2.new(Math.cos(a), Math.sin(a)) * @radius
    end

    def tangent_at(s)
      a = angle_at(s)
      ccw? ? Vec2.new(-Math.sin(a), Math.cos(a)) : Vec2.new(Math.sin(a), -Math.cos(a))
    end

    def normal_at(s)
      t = tangent_at(s)
      Vec2.new(t.y, -t.x)
    end

    def offset_point(s, d)
      a = angle_at(s)
      @center + Vec2.new(Math.cos(a), Math.sin(a)) * offset_radius(d)
    end

    def end_point
      point_at(@length)
    end

    def intersect_ray(o, dir, d)
      r = offset_radius(d)
      return [] unless r.positive?

      f = o - @center
      a = dir.length2
      return [] if a < 1e-18

      b = 2 * f.dot(dir)
      c = f.length2 - r * r
      disc = b * b - 4 * a * c
      return [] if disc.negative?

      sq = Math.sqrt(disc)
      [(-b - sq) / (2 * a), (-b + sq) / (2 * a)].filter_map do |t|
        q = o + dir * t - @center
        ang = Math.atan2(q.y, q.x)
        delta = (ang - @start_angle) * (ccw? ? 1 : -1)
        delta %= (2 * Math::PI)
        delta = 0.0 if (2 * Math::PI - delta) < 1e-9 && @sweep.abs >= 2 * Math::PI - 1e-9
        next nil if delta > @sweep.abs + 1e-9

        [t, [delta, @sweep.abs].min * @radius]
      end
    end

    def to_h
      { 'type' => 'arc', 'center' => @center.to_a, 'radius' => @radius,
        'start_angle' => @start_angle, 'sweep' => @sweep }
    end
  end

  module ProfileSegment
    module_function

    def from_h(h)
      case h['type']
      when 'line' then LineSegment2.new(Vec2.new(*h['p0']), Vec2.new(*h['p1']))
      when 'arc' then ArcSegment2.new(Vec2.new(*h['center']), h['radius'], h['start_angle'], h['sweep'])
      else raise PersistenceError, "未知の断面要素: #{h['type']}"
      end
    end
  end
end
