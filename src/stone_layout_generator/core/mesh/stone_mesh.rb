# frozen_string_literal: true

module Higeotoko::StoneLayout::Core
  # 石1枚の閉じたソリッド（Mesh）を作る。
  #
  # 方法: 輪郭（展開座標）を、u の分割位置（輪郭の頂点 u + 断面の要素境界 +
  # 円弧の分割点）で縦の帯に切り、各帯を台形に分解する（台形分割）。
  # 台形の4隅は帯の両端の鉛直線上にあるので、3D でも必ず平面になる。
  # 円弧上の各分割位置は真円上の点なので、目地位置や石端は近似の影響を受けない。
  #
  # 表面: s_out（法線 +N）/ 背面: s_in（法線 -N）/ 側面: 輪郭の各辺
  # T字頂点（隣の台形の頂点が辺の途中に来る状態）は分割点を挿入して避ける。
  class StoneMesh
    def initialize(surface, s_in, s_out, max_angle: Profile::DEFAULT_MAX_ANGLE, max_error: Profile::DEFAULT_MAX_ERROR)
      @surface = surface
      @profile = surface.profile
      @s_in = s_in
      @s_out = s_out
      @opts = { max_angle: max_angle, max_error: max_error }
    end

    def build(outline)
      raise GeometryError, '石厚がゼロです' if (@s_out - @s_in).abs < Tol::POINT

      pts = outline
      umin, umax = pts.map(&:x).minmax
      @profile.check_offset(umin, umax, @s_in, @s_out)

      crit = merge_sorted(pts.map(&:x) + @profile.breakpoints(umin, umax, **@opts))
      check_fold(crit)
      @crit = crit
      edges = Polygon.edges(pts)
      traps = trapezoids(edges, crit)
      vset = Array.new(crit.size) { [] }
      vertical = Array.new(crit.size) { [] }
      traps.each do |i, la, ha, lb, hb|
        vset[i].push(la, ha)
        vset[i + 1].push(lb, hb)
      end
      pts.each { |p| vset[ci(p.x)] << p.y }
      edges.each do |a, b|
        next unless (b.x - a.x).abs <= Tol::POINT

        vertical[ci(a.x)] << [a.y, b.y].minmax
      end
      vset.map! { |list| merge_sorted(list) }

      mesh = Mesh.new
      traps.each { |t| add_cap(mesh, t, crit, vset, vertical) }
      edges.each { |a, b| add_side(mesh, a, b, crit, vset) }
      mesh
    end

    private

    def merge_sorted(list)
      list.sort.each_with_object([]) { |x, acc| acc << x if acc.empty? || x - acc.last > Tol::POINT }
    end

    # u に最も近い分割位置の index
    def ci(u)
      i = @crit.bsearch_index { |c| c >= u - Tol::POINT } || (@crit.size - 1)
      i -= 1 if i.positive? && (@crit[i - 1] - u).abs < (@crit[i] - u).abs
      i
    end

    def check_fold(crit)
      [@s_in, @s_out].each do |s|
        crit.each_cons(2) do |u0, u1|
          p0 = @profile.offset_point(u0, s)
          p1 = @profile.offset_point(u1, s)
          t = @profile.tangent((u0 + u1) * 0.5)
          next if (p1 - p0).dot(t) > Tol::POINT * 0.1

          raise GeometryError, '入隅・小さいRの部分で厚み方向の形状が自己交差します（石厚を確保できません）'
        end
      end
    end

    def trapezoids(edges, crit)
      traps = []
      crit.each_cons(2).with_index do |(ua, ub), i|
        um = (ua + ub) * 0.5
        xs = edges.filter_map do |a, b|
          next nil if (b.x - a.x).abs <= Tol::POINT

          lo, hi = [a.x, b.x].minmax
          next nil unless lo < um && hi > um

          f = ->(u) { a.y + (b.y - a.y) * (u - a.x) / (b.x - a.x) }
          [f.call(um), f.call(ua), f.call(ub)]
        end
        xs.sort_by!(&:first)
        raise GeometryError, '石の輪郭が不正です（台形分割に失敗）' if xs.size.odd?

        xs.each_slice(2) { |l, h| traps << [i, l[1], h[1], l[2], h[2]] }
      end
      traps
    end

    def covered?(vertical, i, v0, v1)
      lo, hi = [v0, v1].minmax
      vertical[i].any? { |a, b| a <= lo + Tol::POINT && b >= hi - Tol::POINT }
    end

    def xyz(u, v, s)
      @surface.point3d(u, v, s)
    end

    def add_cap(mesh, trap, crit, vset, vertical)
      i, la, ha, lb, hb = trap
      ua = crit[i]
      ub = crit[i + 1]
      uv = [[ua, la]]
      soft = [false] # 下辺（輪郭）
      right = vset[i + 1].select { |v| v > lb + Tol::POINT && v < hb - Tol::POINT }
      ([lb] + right + [hb]).each_cons(2) do |v0, v1|
        uv << [ub, v0]
        soft << !covered?(vertical, i + 1, v0, v1)
      end
      uv << [ub, hb]
      soft << false # 上辺（輪郭）
      left = vset[i].select { |v| v > la + Tol::POINT && v < ha - Tol::POINT }.reverse
      ([ha] + left + [la]).each_cons(2) do |v0, v1|
        uv << [ua, v0]
        soft << !covered?(vertical, i, v0, v1)
      end

      mesh.add_polygon(uv.map { |u, v| xyz(u, v, @s_out) }, soft)
      n = uv.size
      inner = uv.reverse.map { |u, v| xyz(u, v, @s_in) }
      mesh.add_polygon(inner, Array.new(n) { |k| soft[(n - 2 - k) % n] })
    end

    def add_side(mesh, a, b, crit, vset)
      seq = if (b.x - a.x).abs <= Tol::POINT
              i = ci(a.x)
              lo, hi = [a.y, b.y].minmax
              mids = vset[i].select { |v| v > lo + Tol::POINT && v < hi - Tol::POINT }
              mids.reverse! if b.y < a.y
              [a] + mids.map { |v| Vec2.new(a.x, v) } + [b]
            else
              lo, hi = [a.x, b.x].minmax
              mids = crit.select { |u| u > lo + Tol::POINT && u < hi - Tol::POINT }
              mids.reverse! if b.x < a.x
              [a] + mids.map { |u| Vec2.new(u, a.y + (b.y - a.y) * (u - a.x) / (b.x - a.x)) } + [b]
            end
      vertical_edge = (b.x - a.x).abs <= Tol::POINT
      corners = @profile.corners
      seq.each_cons(2).with_index do |(p, q), k|
        op = xyz(p.x, p.y, @s_out)
        oq = xyz(q.x, q.y, @s_out)
        ip = xyz(p.x, p.y, @s_in)
        iq = xyz(q.x, q.y, @s_in)
        crease_p = k.zero? || (!vertical_edge && corner_u?(corners, p.x))
        crease_q = k == seq.size - 2 || (!vertical_edge && corner_u?(corners, q.x))
        if planar?(oq, op, ip, iq)
          mesh.add_polygon([oq, op, ip, iq], [false, !crease_p, false, !crease_q])
        else
          mesh.add_polygon([oq, op, ip], [false, !crease_p, true])
          mesh.add_polygon([oq, ip, iq], [true, false, !crease_q])
        end
      end
    end

    def corner_u?(corners, u)
      w = @profile.wrap(u)
      corners.any? { |c| (c - w).abs <= Tol::POINT }
    end

    def planar?(a, b, c, d)
      ab = sub(b, a)
      ac = sub(c, a)
      ad = sub(d, a)
      n = cross(ab, ac)
      ln = Math.sqrt(dot(n, n))
      return true if ln < 1e-12

      (dot(n, ad) / ln).abs < 1e-6
    end

    def sub(a, b)
      [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
    end

    def cross(a, b)
      [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
    end

    def dot(a, b)
      a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
    end
  end
end
