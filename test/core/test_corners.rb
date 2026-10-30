# frozen_string_literal: true

require_relative '../test_helper'

# 出隅・入隅の納まり（留め / 勝ち負け）と、角柱・立方体の外周
class TestCorners < Minitest::Test
  include StoneTestHelpers

  T = 30.0
  J = 8.0

  # 1500 進んで左折（出隅）または右折（入隅）
  def l_wall(turn)
    second = turn == :outer ? v2(1500, 1500) : v2(1500, -1500)
    prof = Profile.new([LineSegment2.new(v2(0, 0), v2(1500, 0)), LineSegment2.new(v2(1500, 0), second)])
    SurfaceDefinition.rectangle(prof, 0, 600)
  end

  def corner_stones(doc)
    left = panel_at(doc, 1400, 300)
    right = panel_at(doc, 1600, 300)
    geo = StoneGeometry.new(doc)
    [geo.build(left), geo.build(right)]
  end

  # 石の平面形（xy）。角付近の石は z 方向に一定なので、z=0 の点で十分
  def footprint(built)
    pts = built.mesh.points.select { |p| p[2].abs < 1e-6 }.map { |p| v2(p[0], p[1]) }
    c = pts.reduce(v2(0, 0)) { |a, b| a + b } / pts.size
    pts.uniq { |p| [p.x.round(6), p.y.round(6)] }.sort_by { |p| Math.atan2(p.y - c.y, p.x - c.x) }
  end

  def gap(a, b)
    fa = footprint(a)
    fb = footprint(b)
    d = Float::INFINITY
    Polygon.edges(fa).each { |p, q| fb.each { |r| d = [d, Geom2.dist_point_segment(r, p, q)].min } }
    Polygon.edges(fb).each { |p, q| fa.each { |r| d = [d, Geom2.dist_point_segment(r, p, q)].min } }
    d
  end

  def test_outer_corner_miter
    doc = build_doc(l_wall(:outer), 'corner_mode' => 'miter')
    a, b = corner_stones(doc)
    assert a.mesh.manifold? && b.mesh.manifold?
    assert_in_delta 0, PolygonOps.intersection_area(footprint(a), footprint(b))
    assert_in_delta J, gap(a, b), 1e-6 # 留めの目地幅
    # 表面の角は角の点から目地/2 だけ二等分面に沿って離れる
    front = a.mesh.points.map { |p| v2(p[0], p[1]) }.select { |p| p.y.abs < 1e-6 }.max_by(&:x)
    assert_in_delta 1500 - J / 2 * Math.sqrt(2), front.x, 1e-6
    back = a.mesh.points.map { |p| v2(p[0], p[1]) }.select { |p| (p.y - T).abs < 1e-6 }.max_by(&:x)
    assert_in_delta 1500 - T - J / 2 * Math.sqrt(2), back.x, 1e-6
  end

  def test_outer_corner_left_wins
    doc = build_doc(l_wall(:outer), 'corner_mode' => 'win_prev')
    a, b = corner_stones(doc)
    xs = footprint(a).map(&:x)
    assert_in_delta 1500, xs.max, 1e-6 # 勝ち: 相手の表面まで伸びて小口を見せる
    ys = footprint(b).map(&:y)
    assert_in_delta T + J, ys.min, 1e-6 # 負け: 勝ちの石の背面から目地幅
    assert_in_delta 0, PolygonOps.intersection_area(footprint(a), footprint(b))
    assert_in_delta J, gap(a, b), 1e-6
  end

  def test_outer_corner_right_wins
    doc = build_doc(l_wall(:outer), 'corner_mode' => 'win_next')
    a, b = corner_stones(doc)
    assert_in_delta 1500 - T - J, footprint(a).map(&:x).max, 1e-6
    assert_in_delta 0, footprint(b).map(&:y).min, 1e-6
    assert_in_delta J, gap(a, b), 1e-6
  end

  def test_inner_corner_butt_and_miter
    %w[win_prev win_next miter].each do |mode|
      doc = build_doc(l_wall(:inner), 'corner_mode' => mode)
      a, b = corner_stones(doc)
      assert a.mesh.manifold? && b.mesh.manifold?, mode
      assert_in_delta 0, PolygonOps.intersection_area(footprint(a), footprint(b)), 1e-6, mode
      assert gap(a, b) >= J - 1e-6, "#{mode}: gap #{gap(a, b)}"
    end
    doc = build_doc(l_wall(:inner), 'corner_mode' => 'win_prev')
    _, b = corner_stones(doc)
    assert_in_delta(-J, footprint(b).map(&:y).max, 1e-6) # 入隅の負け: 勝ちの石の表面から目地幅
  end

  def test_per_corner_override_only_touches_that_corner
    doc = build_doc(l_wall(:outer))
    assert_equal 'miter', doc.settings.corner_mode_at(0)
    ids = CornerJoint.panels_at(doc, 0)
    assert_equal 2, ids.size
    doc.settings = doc.settings.merge('corner_overrides' => { '0' => 'win_prev' })
    assert_equal 'win_prev', doc.settings.corner_mode_at(0)
    loaded = Serializer.load(Serializer.dump(doc))
    assert_equal({ '0' => 'win_prev' }, loaded.settings['corner_overrides'])
    refute loaded.settings.layout_changed?(doc.settings.merge('corner_overrides' => {}))
  end

  def test_short_stone_rejected_for_butt
    doc2 = build_doc(l_wall(:outer), 'corner_mode' => 'win_prev', 'min_width' => 10)
    eng2 = EditEngine.new(doc2)
    # 角の先の石を 30mm 幅にすると、負け側の止まり（石厚30 + 目地8）より短い
    plan = eng2.plan_add(v2(1500 + 30, 300), :v)
    assert plan.ok?, plan.errors.inspect
    eng2.apply(plan)
    _, errors = StoneGeometry.new(doc2).build_many(doc2.panels.keys)
    assert errors.any? { |e| e.message.include?('短すぎ') }
  end

  def test_box_column_all_four_corners
    pts = [v2(0, 0), v2(1200, 0), v2(1200, 800), v2(0, 800), v2(0, 0)]
    prof = Profile.new(pts.each_cons(2).map { |a, b| LineSegment2.new(a, b) })
    assert prof.closed?
    assert_equal 4, prof.corners.size
    doc = build_doc(SurfaceDefinition.rectangle(prof, 0, 1200), 'stone_width' => 600, 'end_mode' => 'balanced')
    us = doc.segments.values.select { |s| s.orientation == :v && s.a.y < 1 }.map { |s| s.a.x }.sort
    [0.0, 1200.0, 2000.0, 3200.0].each { |c| assert(us.any? { |u| (u - c).abs < 1e-6 }, "no joint at corner #{c}") }
    built = assert_solid(doc)
    # 隣り合う角の石どうしは重ならない
    by_id = built.to_h { |b| [b.panel_id, b] }
    4.times do |i|
      ids = CornerJoint.panels_at(doc, i).select { |id| doc.panels[id].bbox[1] < 1 }
      assert_equal 2, ids.size
      assert_in_delta 0, PolygonOps.intersection_area(footprint(by_id[ids[0]]), footprint(by_id[ids[1]])), 1e-6
    end
  end
end
