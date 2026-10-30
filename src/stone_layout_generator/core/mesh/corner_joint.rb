# frozen_string_literal: true

module Higeotoko::StoneLayout::Core
  # 折れ点（出隅・入隅）での石の納まり。
  #
  # 角に目地がある場合、角の両側の石は「自分の面で止まる」のではなく、次のどれかで納める:
  #   miter    留め        … 角の二等分面で切り、目地幅ぶん離す
  #   win_prev 左の石が勝ち … u の手前側（壁を外から見て左）の石が角まで伸び、小口を見せる
  #   win_next 右の石が勝ち … 奥側（右）の石が伸びる
  #
  # 結果は「石の端（輪郭の最小/最大 u）の表面・背面の xy 座標」の上書きとして StoneMesh に渡す。
  # 目地の位置（割付データ）は一切変えない。
  module CornerJoint
    Corner = Struct.new(:index, :u, :point, :n1, :n2, :t1, :t2, :outer)

    MIN_ANGLE = 3 * Math::PI / 180 # これより浅い折れは納まり処理をしない

    module_function

    def corners(profile)
      profile.corners.each_with_index.filter_map do |c, i|
        n1, n2 = profile.corner_normals(c)
        t1 = Vec2.new(-n1.y, n1.x)
        t2 = Vec2.new(-n2.y, n2.x)
        next nil if Math.atan2(t1.cross(t2).abs, t1.dot(t2)) < MIN_ANGLE

        Corner.new(i, c, profile.point(c), n1, n2, t1, t2, t1.cross(t2).positive?)
      end
    end

    # 石の中心線領域 points と実輪郭 outline から、角に接する端の上書きを作る
    # → { u_end => { s_out => Vec2, s_in => Vec2 } }
    def end_overrides(surface, settings, points, outline)
      list = corners(surface.profile)
      return {} if list.empty?

      s_in, s_out = settings.s_range
      jv = settings['joint_v']
      bb = Polygon.bbox(points)
      umin, umax = outline.map(&:x).minmax
      out = {}
      list.each do |c|
        mode = settings.corner_mode_at(c.index)
        if at?(surface, bb[2], c.u) # 石の右端が角 → この石は角の手前側（壁1）
          out[umax] = ends(c, :prev, mode, s_in, s_out, jv)
        end
        if at?(surface, bb[0], c.u) # 石の左端が角 → 奥側（壁2）
          out[umin] = ends(c, :next, mode, s_in, s_out, jv)
        end
      end
      out
    end

    def at?(surface, u, c)
      return (u - c).abs <= Tol::POINT * 10 unless surface.periodic?

      l = surface.period
      d = (u - c) % l
      d <= Tol::POINT * 10 || (l - d) <= Tol::POINT * 10
    end

    # side: :prev（角の手前の壁1の石） / :next（角の先の壁2の石）
    def ends(c, side, mode, s_in, s_out, jv)
      own_n, own_t = side == :prev ? [c.n1, c.t1] : [c.n2, c.t2]
      other_n, other_t = side == :prev ? [c.n2, c.t2] : [c.n1, c.t1]
      own = ->(s) { [c.point + own_n * s, own_t] }
      other = ->(s) { [c.point + other_n * s, other_t] }

      case mode
      when 'miter'
        d = c.n1 + c.n2
        raise GeometryError, '角が折り返しているため留めにできません' if d.length < 1e-6

        d = d.normalize
        m = d.left_normal
        toward = side == :prev ? -c.t1 : c.t2 # 自分の壁の方へ目地幅/2 ずらす
        m = -m if m.dot(toward).negative?
        cut = [c.point + m * (jv * 0.5), d]
        { s_out => meet(own.call(s_out), cut), s_in => meet(own.call(s_in), cut) }
      when (side == :prev ? 'win_prev' : 'win_next')
        # 勝ち: 相手の壁の表面まで伸ばす（出隅では小口が見える）
        plane = other.call(s_out)
        { s_out => meet(own.call(s_out), plane), s_in => meet(own.call(s_in), plane) }
      else
        # 負け: 勝ち側の石の面から目地幅だけ離して止める
        into = side == :prev ? -c.t1 : c.t2 # 角から自分の壁へ向かう向き
        depth = into.dot(other_n) # 自分の石が相手の壁のどちら側にあるか
        plane = depth.negative? ? other.call(s_in - jv) : other.call(s_out + jv)
        { s_out => meet(own.call(s_out), plane), s_in => meet(own.call(s_in), plane) }
      end
    end

    def meet(a, b)
      p = Geom2.line_intersection(a[0], a[1], b[0], b[1])
      raise GeometryError, '角の納まりを計算できません（面がほぼ平行です）' unless p

      p
    end

    # 角 index に接する石の ID
    def panels_at(doc, index)
      c = corners(doc.surface.profile).find { |x| x.index == index }
      return [] unless c

      doc.panels.values.select do |p|
        at?(doc.surface, p.bbox[0], c.u) || at?(doc.surface, p.bbox[2], c.u)
      end.map(&:id)
    end

    # 展開座標 u に最も近い角（max_dist 以内）
    def nearest(profile, u, max_dist)
      list = corners(profile)
      best = list.min_by { |c| dist_u(profile, u, c.u) }
      best && dist_u(profile, u, best.u) <= max_dist ? best : nil
    end

    def dist_u(profile, a, b)
      d = (a - b).abs
      profile.closed? ? [d % profile.length, profile.length - (d % profile.length)].min : d
    end
  end
end
