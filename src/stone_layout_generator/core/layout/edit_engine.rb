# frozen_string_literal: true

module Higeotoko::StoneLayout::Core
  # 目地編集エンジン（SketchUp 非依存）。
  #
  # すべての操作は「計画 (plan_*) → 確定 (apply)」の2段階。
  # plan は文書を変更しないので、ドラッグ中のプレビューに何度でも使える。
  #
  # 局所性: 変更した線分の範囲 R に接する石だけを集め、その外接矩形の中だけで
  # 平面分割をやり直す。R に触れない石は ID も形状もそのまま。
  class EditEngine
    MIN_SEGMENT = 0.5 # mm: これより短い目地線分は作らない

    attr_reader :doc

    def initialize(doc)
      @doc = doc
    end

    # ---- 選択 -------------------------------------------------------------------

    # 展開座標の点 p に最も近い目地辺（半径 radius 以内）
    def pick(p, radius)
      box = [p.x - radius, p.y - radius, p.x + radius, p.y + radius]
      best = nil
      @doc.panels_near(box).each do |panel, dx|
        pts = Polygon.translate_x(panel.points, dx)
        n = pts.size
        n.times do |i|
          next unless panel.flags[i] == 'J'

          a = pts[i]
          b = pts[(i + 1) % n]
          d = Geom2.dist_point_segment(p, a, b)
          next if d > radius

          best = [d, a, b] if best.nil? || d < best[0]
        end
      end
      return nil unless best

      piece_for(best[1], best[2])
    end

    def piece_for(a, b)
      a, b = b, a if (b.x - a.x).abs <= Tol::POINT ? b.y < a.y : b.x < a.x
      host = find_host(a, b, WorkingSet.new(@doc))
      host && Piece.new(host.id, a, b)
    end

    # 部分目地 → 通り目地（同一直線上で連続する線分すべて）
    def through_pieces(piece)
      work = WorkingSet.new(@doc)
      host = find_host(piece.a, piece.b, work)
      return [] unless host

      through_chain(host, work).map { |pl| Piece.new(pl.id, pl.a, pl.b) }
    end

    def segment_of(piece)
      @doc.segments[piece.segment_id]
    end

    # ---- 移動 -------------------------------------------------------------------

    # mode: :partial（選択した辺だけ） / :through（通り目地ごと）
    def plan_move(pieces, delta, mode: :partial)
      plan = EditPlan.new(:move)
      plan.delta = delta
      return plan.fail('目地が選択されていません') if pieces.empty? || pieces.any?(&:nil?)

      orient = pieces.first.orientation
      return plan.fail('斜めの目地の移動はまだ対応していません') if orient == :free
      return plan.fail('縦目地と横目地は同時に移動できません') unless pieces.all? { |pc| pc.orientation == orient }
      return plan.fail('移動量がゼロです') if delta.abs < Tol::POINT

      dvec = orient == :v ? Vec2.new(delta, 0) : Vec2.new(0, delta)
      work = WorkingSet.new(@doc)
      moved = collect_moved(plan, pieces, work, mode)
      return plan unless plan.ok?

      moved_list = moved.values
      copies = periodic_copies(moved_list)

      # 1) 端点で同一直線上の目地が続く場合は「段差（ジョグ）」の目地を足す
      jog_points = []
      jogs = []
      moved_list.each do |m|
        [m.a, m.b].each do |e|
          cont = work.near(point_box(e)).any? do |c|
            !moved.key?(c.id) && collinear?(c, m) && Geom2.point_on_segment?(e, c.a, c.b)
          end
          next unless cont

          jog_points << e
          jogs << [e, e + dvec]
        end
        work.touch(m.a, m.b, m.a + dvec, m.b + dvec)
      end

      # 2) 動かす目地に端点を載せている目地（T字）を伸縮させて接続を保つ
      region = moved_list.map { |m| Geom2.bbox([m.a, m.b]) }.reduce { |x, y| Geom2.bbox_union(x, y) }
      seen = {}
      work.near(Geom2.bbox_expand(region, Tol::POINT * 10)).each do |c|
        next if moved.key?(c.id) || seen.key?(c.id)

        seen[c.id] = true
        na = c.a
        nb = c.b
        changed = false
        [[0, c.a], [1, c.b]].each do |which, e|
          next if jog_points.any? { |j| j.near?(e) }
          next unless copies.any? { |m| !collinear?(m, c) && Geom2.point_on_segment?(e, m.a, m.b) }
          # 同一直線上の目地がその先に続いている点（十字点・丸柱の周回継ぎ目）は端点ではない
          next if work.near(point_box(e)).any? do |o|
            (o.id != c.id || o.dx != c.dx) && !moved.key?(o.id) && collinear?(o, c) &&
              Geom2.point_on_segment?(e, o.a, o.b)
          end

          e2 = e + dvec
          which.zero? ? na = e2 : nb = e2
          changed = true
          work.touch(e, e2)
        end
        next unless changed

        if (nb - na).dot(c.b - c.a) <= 0 || na.dist(nb) < MIN_SEGMENT
          return plan.fail("接続している目地（ID #{c.id}）が潰れます。移動量を小さくしてください")
        end

        work.put(c.seg.with(a: na.shift_x(-c.dx), b: nb.shift_x(-c.dx)))
      end

      # 3) 本体を移動
      moved_list.each do |m|
        work.put(m.seg.with(a: m.seg.a + dvec, b: m.seg.b + dvec, state: JointSegment::MANUAL))
      end

      # 4) ジョグ目地（既存の目地と重なる部分は足さない）
      jogs.each do |j0, j1|
        add_uncovered(work, j0, j1, JointSegment::MANUAL)
        work.touch(j0, j1)
      end

      return plan unless check_inside(plan, work)

      finalize(plan, work, 0)
    end

    # ---- 追加・削除 ---------------------------------------------------------------

    # 点 p を通る目地を、その石の内部だけに追加して分割する
    def plan_add(p, orient)
      plan = EditPlan.new(:add)
      hit = @doc.panel_at(p)
      return plan.fail('目地を追加する石の上を指定してください') unless hit

      panel, dx = hit
      return plan.fail("切り離された石 Stone_#{format('%04d', panel.label)} は分割できません") if panel.detached?

      pts = Polygon.translate_x(panel.points, dx)
      seg = chord(pts, p, orient)
      return plan.fail('この位置では石を分割できません') unless seg

      work = WorkingSet.new(@doc)
      add_uncovered(work, seg[0], seg[1], JointSegment::MANUAL)
      work.touch(seg[0], seg[1])
      finalize(plan, work, 1)
    end

    # 目地辺を削除して両側の石を結合する
    def plan_delete(piece)
      plan = EditPlan.new(:delete)
      ids = @doc.panels_on_edge(piece.a, piece.b)
      return plan.fail('外周の境界は削除できません') if ids.size < 2

      p1 = @doc.panels[ids[0]]
      p2 = @doc.panels[ids[1]]
      if p1.detached? || p2.detached?
        return plan.fail('切り離された石に接する目地は削除できません')
      end

      keys2 = p2.edges.map { |a, b| @doc.edge_key(a, b) }
      shared = p1.edges.select { |a, b| keys2.include?(@doc.edge_key(a, b)) }
      work = WorkingSet.new(@doc)
      shared.each do |a, b|
        host = find_host(a, b, work)
        return plan.fail('目地データが見つかりません（データ不整合）') unless host
        return plan.fail("ロックされた目地（ID #{host.id}）は削除できません") if host.seg.locked

        replace_with_parts(work, host, a, b, keep_middle: false)
        work.touch(a, b)
      end
      finalize(plan, work, -1)
    end

    # ---- ロック -------------------------------------------------------------------

    def plan_lock(pieces, locked, mode: :partial)
      plan = EditPlan.new(:lock)
      work = WorkingSet.new(@doc)
      pieces.each do |pc|
        host = find_host(pc.a, pc.b, work)
        next unless host

        list = mode == :through ? through_chain(host, work) : [host]
        list.each { |pl| work.put(pl.seg.with(locked: locked)) }
      end
      plan.set_result(segment_changes: work.changed, next_segment_id: work.next_segment_id,
                      updates: {}, adds: [], removes: [], affected: [])
      plan
    end

    # ---- 確定 -------------------------------------------------------------------

    def apply(plan)
      raise Error, plan.errors.join("\n") unless plan.ok?

      plan.segment_changes.each { |id, seg| seg ? @doc.put_segment(seg) : @doc.delete_segment(id) }
      @doc.next_segment_id = [@doc.next_segment_id, plan.next_segment_id].compact.max
      regen = []
      plan.panel_updates.each do |id, (pts, flags, geo)|
        @doc.update_panel_shape(@doc.panels[id], pts, flags)
        regen << id if geo
      end
      plan.panel_removes.each { |id| @doc.delete_panel(id) }
      added = plan.panel_adds.map do |pts, flags|
        panel = Panel.new(@doc.next_panel_id, pts, flags, label: @doc.allocate_label)
        @doc.next_panel_id += 1
        @doc.put_panel(panel)
        panel.id
      end
      @doc.revision += 1
      Log.info("#{plan.op}: 再生成 #{regen.size} / 追加 #{added.size} / 削除 #{plan.panel_removes.size}",
               regen: regen.first(20), added: added, removed: plan.panel_removes)
      ChangeSet.new(regen, added, plan.panel_removes.dup)
    end

    private

    def collect_moved(plan, pieces, work, mode)
      moved = {}
      ref = pieces.first.a
      pieces.each do |pc|
        pc = align_piece(pc, ref)
        host = find_host(pc.a, pc.b, work)
        unless host
          plan.fail('目地データが見つかりません（データ不整合）')
          break
        end
        next if moved.key?(host.id)

        if mode == :through
          chain = through_chain(host, work)
          if (lk = chain.find { |pl| pl.seg.locked })
            plan.fail("ロックされた目地（ID #{lk.id}）を含むため移動できません")
            break
          end
          chain.each { |pl| moved[pl.id] ||= pl }
        else
          if host.seg.locked
            plan.fail("ロックされた目地（ID #{host.id}）は移動できません")
            break
          end
          mid = replace_with_parts(work, host, pc.a, pc.b, keep_middle: true)
          moved[mid.id] = mid
        end
      end
      moved
    end

    # host を [a, b] の区間で切り分ける。keep_middle なら中央部分を Placed で返す。
    def replace_with_parts(work, host, a, b, keep_middle:)
      len = host.seg.length
      dir = (host.b - host.a) / len
      t0, t1 = [(a - host.a).dot(dir), (b - host.a).dot(dir)].minmax
      t0 = 0.0 if t0 < MIN_SEGMENT
      t1 = len if len - t1 < MIN_SEGMENT
      if keep_middle && t0.zero? && t1 == len
        return host
      end

      work.remove(host.id)
      base = host.seg.a
      sdir = (host.seg.b - host.seg.a) / len
      middle = nil
      [[0.0, t0, false], [t0, t1, true], [t1, len, false]].each do |s0, s1, is_mid|
        next if s1 - s0 < MIN_SEGMENT
        next if is_mid && !keep_middle

        seg = JointSegment.new(work.next_id, base + sdir * s0, base + sdir * s1,
                               state: host.seg.state, locked: host.seg.locked)
        work.put(seg)
        middle = Placed.new(seg, host.dx) if is_mid
      end
      middle
    end

    def find_host(a, b, work)
      box = Geom2.bbox_expand(Geom2.bbox([a, b]), Tol::POINT)
      work.near(box).find do |pl|
        Geom2.point_on_segment?(a, pl.a, pl.b) && Geom2.point_on_segment?(b, pl.a, pl.b)
      end
    end

    def through_chain(host, work)
      chain = { host.id => host }
      queue = [host]
      until queue.empty?
        cur = queue.shift
        [cur.a, cur.b].each do |e|
          work.near(point_box(e)).each do |c|
            next if chain.key?(c.id)
            next unless collinear?(c, cur)
            next unless Geom2.point_on_segment?(e, c.a, c.b) ||
                        Geom2.point_on_segment?(c.a, cur.a, cur.b) || Geom2.point_on_segment?(c.b, cur.a, cur.b)

            chain[c.id] = c
            queue << c
          end
        end
      end
      chain.values
    end

    def align_piece(pc, ref)
      return pc unless @doc.periodic?

      l = @doc.period
      k = ((ref.x - pc.a.x) / l).round
      return pc if k.zero?

      Piece.new(pc.segment_id, pc.a.shift_x(k * l), pc.b.shift_x(k * l))
    end

    def periodic_copies(list)
      return list unless @doc.periodic?

      l = @doc.period
      list + list.flat_map { |m| [Placed.new(m.seg, m.dx - l), Placed.new(m.seg, m.dx + l)] }
    end

    def collinear?(p, q)
      Geom2.collinear?(p.a, p.b, q.a, q.b)
    end

    def point_box(p)
      [p.x - Tol::POINT * 2, p.y - Tol::POINT * 2, p.x + Tol::POINT * 2, p.y + Tol::POINT * 2]
    end

    # j0-j1 のうち既存の同一直線上の目地で覆われていない部分だけを追加する
    def add_uncovered(work, j0, j1, state)
      len = j0.dist(j1)
      return if len < MIN_SEGMENT

      dir = (j1 - j0) / len
      intervals = [[0.0, len]]
      work.near(Geom2.bbox_expand(Geom2.bbox([j0, j1]), Tol::POINT)).each do |c|
        next unless Geom2.collinear?(j0, j1, c.a, c.b)

        lo, hi = [(c.a - j0).dot(dir), (c.b - j0).dot(dir)].minmax
        intervals = intervals.flat_map do |s0, s1|
          next [[s0, s1]] if hi <= s0 || lo >= s1

          [[s0, lo], [hi, s1]].select { |x0, x1| x1 - x0 >= MIN_SEGMENT }
        end
      end
      intervals.each do |s0, s1|
        work.put(JointSegment.new(work.next_id, j0 + dir * s0, j0 + dir * s1, state: state))
      end
    end

    def check_inside(plan, work)
      work.changed.each_value do |seg|
        next unless seg

        [seg.a, seg.b, (seg.a + seg.b) * 0.5].each do |p|
          next if @doc.surface.inside?(p, Tol::POINT * 10)

          plan.fail('目地が壁面の範囲外に出ます')
          return false
        end
      end
      true
    end

    # 点 p を通る縦（:v）または横（:h）の弦のうち、p を含む区間
    def chord(pts, p, orient)
      vertex_near = pts.find { |q| (orient == :v ? (q.x - p.x).abs : (q.y - p.y).abs) < MIN_SEGMENT }
      c = if vertex_near
            orient == :v ? vertex_near.x : vertex_near.y
          else
            orient == :v ? p.x : p.y
          end
      side = (orient == :v ? p.x : p.y) >= c ? 1e-6 : -1e-6
      probe = c + side
      vals = []
      Polygon.edges(pts).each do |a, b|
        ac = orient == :v ? a.x : a.y
        bc = orient == :v ? b.x : b.y
        next unless (ac > probe) != (bc > probe)

        t = (probe - ac) / (bc - ac)
        vals << (orient == :v ? a.y + (b.y - a.y) * t : a.x + (b.x - a.x) * t)
      end
      vals.sort!
      target = orient == :v ? p.y : p.x
      vals.each_slice(2) do |v0, v1|
        next unless v1 && target >= v0 - Tol::POINT && target <= v1 + Tol::POINT

        return orient == :v ? [Vec2.new(c, v0), Vec2.new(c, v1)] : [Vec2.new(v0, c), Vec2.new(v1, c)]
      end
      nil
    end

    # 局所平面分割・検証・石IDの引き継ぎ
    def finalize(plan, work, expected_delta)
      r = work.touched
      return plan.fail('変更がありません') unless r

      r = Geom2.bbox_expand(r, Tol::POINT * 10)
      affected = @doc.panels_near(r)
      return plan.fail('影響範囲に石がありません') if affected.empty?

      polys = affected.map { |panel, dx| Polygon.translate_x(panel.points, dx) }
      win = polys.reduce(r) { |m, pg| Geom2.bbox_union(m, Polygon.bbox(pg)) }
      win = Geom2.bbox_expand(win, 1.0)
      placed = work.near(win).map { |pl| [pl.a, pl.b, pl.id] }
      res = @doc.extractor.extract(placed, win)
      return plan.fail('目地の端点が他の目地に接続していません') unless res.dangling.empty?

      faces = res.faces.select { |f| polys.any? { |pg| Polygon.contains?(pg, f.sample) } }
      return plan.fail('内部エラー: 局所再計算の範囲が不足しています') if faces.any? { |f| f.flags.include?('W') }

      old_area = polys.sum { |pg| Polygon.area(pg) }
      new_area = faces.sum { |f| Polygon.area(f.points) }
      return plan.fail('孤立した目地、または穴のある石ができます') if (old_area - new_area).abs > [old_area * 1e-6, 1.0].max

      expected = affected.size + expected_delta
      if faces.size != expected
        msg = case plan.op
              when :move then faces.size < expected ? '石が消失します（目地が隣の目地を越えます）' : '目地が他の目地と交差します'
              when :add then '目地の追加で想定外の分割が起きます'
              else '目地を削除しても石が結合できません（穴のある石になります）'
              end
        return plan.fail(msg)
      end

      old = affected.each_with_index.map do |(panel, _dx), i|
        { panel: panel, pts: polys[i], key: Polygon.canonical_key(polys[i], panel.flags) }
      end
      newf = faces.map { |f| { face: f, key: Polygon.canonical_key(f.points, f.flags) } }
      pairs = match(old, newf)

      s = @doc.settings
      updates = {}
      adds = []
      used_old = {}
      newf.each_with_index do |nf, i|
        f = nf[:face]
        o = pairs[i]
        same = o && o[:key] == nf[:key]
        unless same
          w, h = Polygon.min_extents(f.points)
          if w < s.min_pitch_u - Tol::POINT || h < s.min_pitch_v - Tol::POINT
            return plan.fail(format('石が最小寸法未満になります（%.1f x %.1f mm / 最小 %.1f x %.1f mm）',
                                    w, h, s.min_pitch_u, s.min_pitch_v))
          end
          begin
            OutlineBuilder.build(f.points, f.flags, s)
          rescue GeometryError => e
            return plan.fail(e.message)
          end
          if o && o[:panel].detached?
            return plan.fail("切り離された石 Stone_#{format('%04d', o[:panel].label)} の形状が変わる編集はできません")
          end

          plan.preview_faces << EditPlan::PreviewFace.new(f.points, o ? :changed : :added)
        end
        pts = Polygon.translate_x(f.points, @doc.extractor.normalize_shift(f.points))
        if o
          used_old[o[:panel].id] = true
          updates[o[:panel].id] = [pts, f.flags, !same] unless same && o[:panel].points == pts
        else
          adds << [pts, f.flags]
        end
      end
      removes = old.map { |o| o[:panel] }.reject { |pn| used_old.key?(pn.id) }
      if (dp = removes.find(&:detached?))
        return plan.fail("切り離された石 Stone_#{format('%04d', dp.label)} が消える編集はできません")
      end

      work.changed.each_value { |seg| plan.preview_lines << [seg.a, seg.b] if seg }
      plan.set_result(segment_changes: work.changed, next_segment_id: work.next_segment_id,
                      updates: updates, adds: adds, removes: removes.map(&:id),
                      affected: affected.map { |pn, _| pn.id })
      plan
    end

    # 新しい面 → 旧い石 の対応（同形状優先、次に重なり面積の大きい順）
    def match(old, newf)
      pairs = {}
      taken = {}
      newf.each_with_index do |nf, i|
        o = old.find { |x| !taken.key?(x[:panel].id) && x[:key] == nf[:key] }
        next unless o

        pairs[i] = o
        taken[o[:panel].id] = true
      end
      cands = []
      newf.each_with_index do |nf, i|
        next if pairs.key?(i)

        old.each do |o|
          next if taken.key?(o[:panel].id)

          a = PolygonOps.intersection_area(o[:pts], nf[:face].points)
          cands << [a, i, o] if a > Tol::AREA
        end
      end
      cands.sort_by { |a, _, _| -a }.each do |_, i, o|
        next if pairs.key?(i) || taken.key?(o[:panel].id)

        pairs[i] = o
        taken[o[:panel].id] = true
      end
      pairs
    end
  end
end
