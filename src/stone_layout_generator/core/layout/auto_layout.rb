# frozen_string_literal: true

module Higeotoko::StoneLayout::Core
  # 自動割付。初期状態の目地線分を作るだけで、以降の編集には関与しない。
  #
  # 横目地: 割付範囲の全幅にわたる線分（通り目地）
  # 縦目地: 段ごとの線分（馬踏みでは段ごとにずれる）
  class AutoLayout
    Result = Struct.new(:segments, :stats, :warnings)

    def initialize(surface, settings)
      @surface = surface
      @s = settings
    end

    def generate
      warnings = []
      b = @surface.bbox
      u_lo = b[0]
      u_hi = b[2]
      v_lo = b[1]
      v_hi = b[3]

      rows_v = positions(v_lo, v_hi, @s.pitch_v, @s['align_v'], @s['origin_v'], @s['end_mode'],
                         @s.min_pitch_v, @s.max_pitch_v, 0.0)
      levels = [v_lo] + rows_v + [v_hi]
      segs = []
      rows_v.each do |v|
        segs.concat(clip(Vec2.new(u_lo, v), Vec2.new(u_hi, v)))
      end

      corners = @s['joint_at_corners'] ? @surface.profile.corners.reject { |c| c <= Tol::POINT || c >= u_hi - Tol::POINT } : []
      row_stats = []
      levels.each_cons(2).with_index do |(v0, v1), k|
        shift = row_shift(k)
        us = if @surface.periodic?
               periodic_positions(shift)
             else
               spans = ([u_lo] + corners + [u_hi]).each_cons(2).to_a
               spans.flat_map.with_index do |(a, c), si|
                 inner = positions(a, c, @s.pitch_u, si.zero? ? @s['align_u'] : 'left', @s['origin_u'],
                                   @s['end_mode'], @s.min_pitch_u, @s.max_pitch_u, shift)
                 si.zero? ? inner : [a] + inner
               end
             end
        us.each { |u| segs.concat(clip(Vec2.new(u, v0), Vec2.new(u, v1))) }
        all = ([u_lo] + us + [u_hi]).sort
        row_stats << { 'v' => [v0, v1], 'first' => (all[1] - all[0]).round(2), 'last' => (all[-1] - all[-2]).round(2) }
      end

      Result.new(segs, { 'rows' => row_stats, 'row_count' => levels.size - 1 }, warnings)
    end

    # 範囲 (lo, hi) の内部に置く目地位置（両端は含まない）
    def positions(lo, hi, pitch, align, origin, end_mode, min, max, shift)
      len = hi - lo
      ps = case end_mode
           when 'uniform'
             n = [(len / pitch).round, 1].max
             p = len / n
             s = (shift / pitch) * p
             grid(lo, hi, lo + s, p)
           when 'balanced'
             n = (len / pitch).floor
             r = len - n * pitch
             o = lo + r * 0.5
             o -= pitch * 0.5 if r * 0.5 < min && n.positive? # 端部が小さすぎるときは1枚減らして均等
             grid(lo, hi, o + shift, pitch)
           else
             o = case align
                 when 'right' then hi
                 when 'center' then center_origin(lo, hi, pitch, min)
                 when 'custom' then origin
                 else lo
                 end
             grid(lo, hi, o + shift, pitch)
           end
      fix_ends(lo, hi, ps, min, max)
    end

    def center_origin(lo, hi, pitch, min)
      mid = (lo + hi) * 0.5
      # 目地芯を中央に置く案と石を中央に置く案のうち、端部が大きくなる方
      cand = [mid, mid - pitch * 0.5]
      cand.max_by do |o|
        g = grid(lo, hi, o, pitch)
        g.empty? ? 0 : [g.first - lo, hi - g.last].min
      end
    end

    def grid(lo, hi, origin, pitch)
      k0 = ((lo - origin) / pitch).floor - 1
      k1 = ((hi - origin) / pitch).ceil + 1
      (k0..k1).map { |k| origin + k * pitch }.select { |x| x > lo + Tol::POINT && x < hi - Tol::POINT }
    end

    # 端部の半端石が最小寸法未満なら、隣と結合するか2等分する
    def fix_ends(lo, hi, ps, min, max)
      ps = ps.dup
      return ps if ps.empty?

      if ps.first - lo < min - Tol::POINT
        nxt = ps[1] || hi
        merged = nxt - lo
        if max.nil? || merged <= max + Tol::POINT || ps.size < 2
          ps.shift
        else
          ps[0] = lo + merged * 0.5
        end
      end
      return ps if ps.empty?

      if hi - ps.last < min - Tol::POINT
        prv = ps.size >= 2 ? ps[-2] : lo
        merged = hi - prv
        if max.nil? || merged <= max + Tol::POINT || ps.size < 2
          ps.pop
        else
          ps[-1] = prv + merged * 0.5
        end
      end
      ps
    end

    def periodic_positions(shift)
      l = @surface.period
      pitch = @s.pitch_u
      n = @s['end_mode'] == 'uniform' ? [(l / pitch).round, 1].max : [(l / pitch).floor, 1].max
      p = @s['end_mode'] == 'uniform' ? l / n : pitch
      start = @s['start_u'] + (@s['end_mode'] == 'uniform' ? shift / pitch * p : shift)
      us = (0...n).map { |i| (start + i * p) % l }
      if @s['end_mode'] != 'uniform'
        rest = l - n * pitch
        us.pop if rest > Tol::POINT && rest < @s.min_pitch_u && n > 1 # 残りが小さい場合は最後の石と結合
      end
      us.map { |u| (l - u) < Tol::POINT ? 0.0 : u }.sort.uniq
    end

    def row_shift(k)
      case @s['pattern']
      when 'running' then k.odd? ? @s.pitch_u * 0.5 : 0.0
      when 'offset' then (k * @s['row_offset']) % @s.pitch_u
      else 0.0
      end
    end

    # 外周多角形でクリップ（長方形以外の壁にも対応）
    def clip(a, b)
      return [[a, b]] if @surface.periodic? || @surface.rectangular?

      ts = [0.0, 1.0]
      d = b - a
      Polygon.edges(@surface.boundary).each do |c, e|
        f = e - c
        den = d.cross(f)
        next if den.abs < 1e-12

        t = (c - a).cross(f) / den
        s = (c - a).cross(d) / den
        ts << t if t > 0 && t < 1 && s >= -1e-9 && s <= 1 + 1e-9
      end
      ts.sort.uniq.each_cons(2).filter_map do |t0, t1|
        mid = a + d * ((t0 + t1) * 0.5)
        next nil unless Polygon.contains?(@surface.boundary, mid)

        [a + d * t0, a + d * t1]
      end
    end
  end
end
