# frozen_string_literal: true

module Higeotoko
  module StoneLayout
    # 選択された SketchUp の面 → Core::SurfaceDefinition
    #
    # - 鉛直な面のみ対象
    # - 1枚の曲面ファセットを選ぶと、柔らかい（soft）エッジでつながる面を自動で集める
    #   （円弧面は多数の平面 Face でできているため。soft でない境界は越えない）
    # - 下端エッジを連結して水平断面を作る。ArcCurve 由来のエッジは真円として扱う
    module FaceReader
      Result = Struct.new(:surface, :faces, :warnings)

      VERTICAL_TOL = 1.0e-3

      module_function

      def read(selection, expand: true)
        faces = selection.grep(Sketchup::Face)
        raise Core::InvalidInput, '割付する面を選択してください' if faces.empty?

        warnings = []
        faces = expand_smooth(faces) if expand
        bad = faces.reject { |f| f.normal.z.abs < VERTICAL_TOL }
        unless bad.empty?
          raise Core::InvalidInput, "鉛直でない面が #{bad.size} 枚含まれています（壁面のみ対象です）"
        end

        surface = faces.size == 1 ? single_face(faces.first, warnings) : multi_face(faces, warnings)
        Result.new(surface, faces, warnings)
      end

      def expand_smooth(faces)
        seen = {}
        queue = faces.dup
        faces.each { |f| seen[f] = true }
        until queue.empty?
          f = queue.shift
          f.edges.each do |e|
            next unless e.soft?

            e.faces.each do |g|
              next if seen[g] || g.normal.z.abs >= VERTICAL_TOL

              seen[g] = true
              queue << g
            end
          end
        end
        seen.keys
      end

      # 平面壁: 面の外周をそのまま割付範囲にする（切妻などの非矩形にも対応）
      def single_face(face, warnings)
        n = face.normal
        t = [-n.y, n.x] # T = Z × N
        tl = Math.hypot(*t)
        t = t.map { |c| c / tl }
        pts = face.outer_loop.vertices.map { |v| Units.point_mm(v.position) }
        us = pts.map { |p| p[0] * t[0] + p[1] * t[1] }
        umin, umax = us.minmax
        o = pts[us.index(umin)]
        # u=0 の点を通る水平直線（断面）
        base = Core::Vec2.new(o[0], o[1])
        dir = Core::Vec2.new(*t)
        prof = Core::Profile.new([Core::LineSegment2.new(base, base + dir * (umax - umin))])
        boundary = pts.each_with_index.map { |p, i| Core::Vec2.new(us[i] - umin, p[2]) }
        warnings << '開口部（内側の輪郭）は現在のバージョンでは無視されます' if face.loops.size > 1
        Core::SurfaceDefinition.new(prof, boundary, source(face))
      end

      def multi_face(faces, warnings)
        zs = faces.flat_map { |f| f.vertices.map { |v| Units.to_mm(v.position.z) } }
        zmin, zmax = zs.minmax
        tops = faces.map { |f| f.vertices.map { |v| Units.to_mm(v.position.z) }.max }
        bottoms = faces.map { |f| f.vertices.map { |v| Units.to_mm(v.position.z) }.min }
        if (tops.max - tops.min) > 1 || (bottoms.max - bottoms.min) > 1
          warnings << '面の高さがそろっていません。外接する高さ範囲で割り付けます'
        end

        edges = faces.flat_map { |f| bottom_edges(f) }.uniq
        raise Core::InvalidInput, '面の下端エッジが見つかりません' if edges.empty?

        chain, closed = order_chain(edges)
        chain = orient_chain(chain, faces.first)
        runs = to_runs(chain)
        builder = Core::ProfileBuilder.new
        prof = builder.build(runs, closed: closed)
        warnings.concat(builder.warnings)
        check_normals(prof, faces, warnings)
        Core::SurfaceDefinition.rectangle(prof, zmin, zmax, source(*faces))
      end

      def bottom_edges(face)
        zmin = face.vertices.map { |v| v.position.z }.min
        tol = 0.01 / Units::MM_PER_INCH
        face.edges.select { |e| (e.start.position.z - zmin).abs < tol && (e.end.position.z - zmin).abs < tol }
      end

      # エッジ集合 → 1本の経路 [[edge, reversed?], ...], closed
      def order_chain(edges)
        by_vertex = Hash.new { |h, k| h[k] = [] }
        edges.each { |e| [e.start, e.end].each { |v| by_vertex[v] << e } }
        branch = by_vertex.find { |_, list| list.size > 2 }
        raise Core::InvalidInput, '選択した面の下端が枝分かれしています（連続した壁面を選択してください）' if branch

        ends = by_vertex.select { |_, list| list.size == 1 }.keys
        closed = ends.empty?
        start_v = closed ? edges.first.start : ends.first
        chain = []
        used = {}
        v = start_v
        loop do
          e = by_vertex[v].find { |x| !used[x] }
          break unless e

          used[e] = true
          rev = e.end == v
          chain << [e, rev]
          v = rev ? e.start : e.end
        end
        raise Core::InvalidInput, '選択した面が連続していません（不連続な対象面）' if used.size != edges.size

        [chain, closed]
      end

      # 断面の向き: 壁を外から見て左→右（T = Z × N）
      def orient_chain(chain, face)
        n = face.normal
        e, rev = chain.find { |ed, _| face.edges.include?(ed) } || chain.first
        a = rev ? e.end.position : e.start.position
        b = rev ? e.start.position : e.end.position
        d = [b.x - a.x, b.y - a.y]
        t = [-n.y, n.x]
        return chain if d[0] * t[0] + d[1] * t[1] >= 0

        chain.reverse.map { |ed, r| [ed, !r] }
      end

      def to_runs(chain)
        runs = []
        chain.each do |e, rev|
          a = Units.point_mm(rev ? e.end.position : e.start.position)
          b = Units.point_mm(rev ? e.start.position : e.end.position)
          curve = e.curve
          arc = curve.is_a?(Sketchup::ArcCurve) ? curve : nil
          last = runs.last
          if last && last[:curve_obj] == arc && (arc || last[:arc].nil?)
            last[:points] << Core::Vec2.new(b[0], b[1])
          else
            run = { points: [Core::Vec2.new(a[0], a[1]), Core::Vec2.new(b[0], b[1])], curve_obj: arc }
            if arc
              c = Units.point_mm(arc.center)
              run[:arc] = { center: Core::Vec2.new(c[0], c[1]), radius: Units.to_mm(arc.radius) }
            end
            runs << run
          end
        end
        runs
      end

      def check_normals(prof, faces, warnings)
        flipped = faces.count do |f|
          c = Units.point_mm(f.bounds.center)
          hits = prof.intersect_ray(Core::Vec2.new(c[0], c[1]), Core::Vec2.new(f.normal.x, f.normal.y), 0)
          u = hits.min_by { |t, _| t.abs }&.last
          next false unless u

          n = prof.normal(u)
          n.x * f.normal.x + n.y * f.normal.y < 0
        end
        warnings << "裏向きの面が #{flipped} 枚あります（外側を表にしてください）" if flipped.positive?
      end

      def source(*faces)
        { 'face_pids' => faces.map { |f| f.respond_to?(:persistent_id) ? f.persistent_id : nil }.compact }
      end
    end
  end
end
