# frozen_string_literal: true

require_relative '../test_helper'

# 仕様 18-5: R500 の 90度コーナーを含む壁
class TestRCorner < Minitest::Test
  include StoneTestHelpers

  R = 500.0

  def setup
    @prof = Profile.new([
                          LineSegment2.new(v2(0, 0), v2(2000, 0)),
                          ArcSegment2.new(v2(2000, R), R, -Math::PI / 2, Math::PI / 2),
                          LineSegment2.new(v2(2000 + R, R), v2(2000 + R, R + 2000))
                        ])
    @surf = SurfaceDefinition.rectangle(@prof, 0, 1800)
  end

  def test_unrolled_length_and_continuity
    assert_in_delta 4000 + Math::PI * R / 2, @prof.length, 1e-9
    u_arc = 2000.0
    [u_arc, u_arc + Math::PI * R / 2].each do |u|
      a = @prof.point(u - 1e-7)
      b = @prof.point(u + 1e-7)
      assert a.dist(b) < 1e-5
      assert @prof.tangent(u - 1e-7).dist(@prof.tangent(u + 1e-7)) < 1e-5
    end
    assert_empty @prof.corners # 接線連続なので折れ点なし
    mid = @prof.point(2000 + Math::PI * R / 4)
    assert_in_delta R, mid.dist(v2(2000, R)), 1e-9
  end

  def test_layout_spans_corner_and_stones_are_curved_solids
    doc = build_doc(@surf)
    us = doc.segments.values.select { |s| s.orientation == :v }.map { |s| s.a.x }.uniq.sort
    pitches = us.each_cons(2).map { |a, b| b - a }
    assert pitches.all? { |p| (p - 900).abs < 1e-6 } # R部分も同じ 900 ピッチ（弧長）
    # R を跨ぐ石（1800..2700）
    cross = panel_at(doc, 2300, 300)
    built = StoneGeometry.new(doc).build(cross)
    assert built.mesh.manifold?
    # 石表面の点はすべて R500 の円上（円弧部分）か直線上にある
    built.mesh.points.each do |p|
      next unless p[0] > 2000 + 1e-6 && p[1] < R - 1e-6

      d = Math.hypot(p[0] - 2000, p[1] - R)
      assert(((d - R).abs < 1e-6) || ((d - (R - 30)).abs < 1e-6), "point off arc: #{d}")
    end
    assert_consistent(doc)
    assert_solid(doc)
  end

  def test_volume_matches_annulus_for_arc_stone
    s = Settings.new('stone_width' => 400, 'min_width' => 50)
    doc = LayoutBuilder.build(SurfaceDefinition.rectangle(
                                Profile.new([ArcSegment2.new(v2(0, 0), R, 0, Math::PI / 2)]), 0, 600
                              ), s).first
    p = panel_at(doc, 200, 300)
    built = StoneGeometry.new(doc).build(p)
    # 輪郭 u: [0, 396]（左端は外周、右は目地）, v: [0, 600]（1段なので上下とも外周）
    ang = 396 / R
    exact = 0.5 * ang * (R**2 - (R - 30)**2) * 600
    assert_in_delta exact, built.volume, exact * 2e-3 # ポリゴン近似誤差
  end

  def test_drag_joint_on_arc_moves_by_arc_length
    doc = build_doc(@surf)
    eng = EditEngine.new(doc)
    piece = eng.pick(v2(2700, 300), 3)
    assert_in_delta 2700, piece.position
    plan = eng.plan_move([piece], -120)
    assert plan.ok?, plan.errors.inspect
    eng.apply(plan)
    assert_in_delta 780, Polygon.min_extents(panel_at(doc, 2300, 300).points)[0]
    p3 = doc.surface.point3d(2580, 0)
    assert_in_delta R, Math.hypot(p3[0] - 2000, p3[1] - R), 1e-9 # 目地は円弧上
    assert_solid(doc)
  end

  def test_too_small_radius_is_rejected
    prof = Profile.new([
                         LineSegment2.new(v2(0, 0), v2(1000, 0)),
                         ArcSegment2.new(v2(1000, 20), 20, -Math::PI / 2, Math::PI / 2),
                         LineSegment2.new(v2(1020, 20), v2(1020, 1000))
                       ])
    doc = build_doc(SurfaceDefinition.rectangle(prof, 0, 600))
    _, errors = StoneGeometry.new(doc).build_many(doc.panels.keys)
    refute_empty errors
    assert_match(/R20/, errors.first.message)
  end

  def test_sharp_corner_gets_joint_and_miter
    prof = Profile.new([
                         LineSegment2.new(v2(0, 0), v2(1500, 0)),
                         LineSegment2.new(v2(1500, 0), v2(1500, 1500))
                       ])
    assert_equal [1500.0], prof.corners
    doc = build_doc(SurfaceDefinition.rectangle(prof, 0, 600))
    us = doc.segments.values.select { |s| s.orientation == :v }.map { |s| s.a.x }
    assert_includes us, 1500.0
    m = prof.offset_point(1500, -30)
    assert m.dist(v2(1470, 30)) < 1e-9
    assert_solid(doc)
  end

  def test_ray_intersection_on_arc
    hit = @surf.intersect_ray([2000 + 1000, -1000, 500], [-1, 1, 0])
    assert hit
    q = @prof.point(hit[:u])
    assert_in_delta R, q.dist(v2(2000, R)), 1e-6
    assert_in_delta 500, hit[:v]
  end
end
