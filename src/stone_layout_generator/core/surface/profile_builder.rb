# frozen_string_literal: true

module Higeotoko::StoneLayout::Core
  # SketchUp から取り出した断面の折れ線（＋円弧情報）を Profile に変換する。
  #
  # runs: [{ points: [Vec2...], arc: { center: Vec2, radius: Float } or nil }, ...]
  #   連続する点列。arc が与えられた run は（SketchUp の ArcCurve 由来なので）円弧として扱う。
  #   arc がない run は、直線の統合と円弧の推定を試みる。
  #
  # 推定した円弧は warnings に記録する（無条件に正確な円弧として扱わない）。
  class ProfileBuilder
    FIT_TOLERANCE = 0.5          # 円弧推定の許容誤差 (mm)
    MIN_FIT_EDGES = 3            # 推定に使う最小エッジ数
    MAX_FIT_TURN = 30 * Math::PI / 180 # 1エッジあたりの最大折れ角

    attr_reader :warnings

    def initialize(estimate_arcs: true)
      @estimate_arcs = estimate_arcs
      @warnings = []
    end

    def build(runs, closed: nil)
      segs = []
      runs.each do |run|
        pts = dedupe(run[:points])
        next if pts.size < 2

        segs.concat(run[:arc] ? arc_from_run(pts, run[:arc]) : polyline_segments(pts))
      end
      segs = merge_collinear_lines(segs)
      Profile.new(segs, closed: closed)
    end

    private

    def dedupe(pts)
      pts.each_with_object([]) { |p, acc| acc << p if acc.empty? || acc.last.dist(p) > Tol::POINT }
    end

    def arc_from_run(pts, arc)
      c = arc[:center]
      r = arc[:radius]
      a0 = Math.atan2(pts.first.y - c.y, pts.first.x - c.x)
      # 各区間の回転角を符号付きで積算（向きは点列の進行方向に従う）
      sweep = 0.0
      pts.each_cons(2) do |p, q|
        d = Math.atan2((p - c).cross(q - c), (p - c).dot(q - c))
        sweep += d
      end
      [ArcSegment2.new(c, r, a0, sweep)]
    end

    def polyline_segments(pts)
      return pts.each_cons(2).map { |p, q| LineSegment2.new(p, q) } unless @estimate_arcs

      out = []
      i = 0
      n = pts.size
      while i < n - 1
        j = longest_arc_run(pts, i)
        if j
          fit = fit_circle(pts[i..j])
          out << arc_from_run(pts[i..j], fit).first
          @warnings << format('円弧を推定しました: R%.1f / %d分割 / 最大誤差 %.3fmm（必要なら R と中心を補正してください）',
                              fit[:radius], j - i, fit[:error])
          i = j
        else
          out << LineSegment2.new(pts[i], pts[i + 1])
          i += 1
        end
      end
      out
    end

    # i から始まって円弧とみなせる最長の終点 index（なければ nil）
    def longest_arc_run(pts, i)
      best = nil
      j = i + MIN_FIT_EDGES
      while j < pts.size
        sub = pts[i..j]
        break unless consistent_turning?(sub)

        fit = fit_circle(sub)
        break unless fit && fit[:error] <= FIT_TOLERANCE

        best = j
        j += 1
      end
      best
    end

    def consistent_turning?(pts)
      signs = pts.each_cons(3).map do |a, b, c|
        cr = (b - a).cross(c - b)
        turn = Math.atan2(cr, (b - a).dot(c - b))
        return false if turn.abs < 1e-4 || turn.abs > MAX_FIT_TURN

        turn.positive?
      end
      signs.uniq.size == 1
    end

    # 代数的円フィット（Kasa法）+ 最大誤差
    def fit_circle(pts)
      mx = pts.sum(&:x) / pts.size
      my = pts.sum(&:y) / pts.size
      suu = suv = svv = suuu = svvv = suvv = svuu = 0.0
      pts.each do |p|
        u = p.x - mx
        v = p.y - my
        suu += u * u
        suv += u * v
        svv += v * v
        suuu += u * u * u
        svvv += v * v * v
        suvv += u * v * v
        svuu += v * u * u
      end
      det = suu * svv - suv * suv
      return nil if det.abs < 1e-12

      b1 = 0.5 * (suuu + suvv)
      b2 = 0.5 * (svvv + svuu)
      uc = (b1 * svv - b2 * suv) / det
      vc = (suu * b2 - suv * b1) / det
      c = Vec2.new(uc + mx, vc + my)
      r = pts.sum { |p| p.dist(c) } / pts.size
      err = pts.map { |p| (p.dist(c) - r).abs }.max
      # 弦の中点も円から外れすぎていないか（折れ線の頂点が円上でも辺は弦）
      { center: c, radius: r, error: err }
    end

    def merge_collinear_lines(segs)
      out = []
      segs.each do |s|
        last = out.last
        if last.is_a?(LineSegment2) && s.is_a?(LineSegment2) &&
           last.dir.cross(s.dir).abs < 1e-9 && last.dir.dot(s.dir).positive?
          out[-1] = LineSegment2.new(last.p0, s.p1)
        else
          out << s
        end
      end
      out
    end
  end
end
