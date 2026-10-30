# frozen_string_literal: true

require_relative '../test_helper'

# 開口部（窓・扉）のある壁
class TestOpenings < Minitest::Test
  include StoneTestHelpers

  WIN = [[1500, 900], [2700, 900], [2700, 2100], [1500, 2100]].freeze

  def window_wall(settings = {}, holes: [WIN])
    surf = SurfaceDefinition.flat_wall(5000, 3000, holes: holes.map { |h| h.map { |x, y| v2(x, y) } })
    build_doc(surf, settings)
  end

  def test_no_stone_over_the_window
    doc = window_wall
    assert_in_delta 5000 * 3000 - 1200 * 1200, doc.panels.values.sum(&:area), 1e-3
    assert_nil doc.panel_at(v2(2100, 1500)) # 窓の中には石がない
    assert_consistent(doc)
    assert_solid(doc)
  end

  def test_joints_aligned_to_window_edges
    doc = window_wall
    hs = doc.segments.values.select { |s| s.orientation == :h }.map { |s| s.a.y }.uniq
    [900.0, 2100.0].each { |v| assert_includes hs, v } # 窓台・まぐさの高さに横目地
    vs = doc.segments.values.select { |s| s.orientation == :v }.map { |s| s.a.x }.uniq
    [1500.0, 2700.0].each { |u| assert_includes vs, u } # 抱きの位置に縦目地
    # 窓の中を通る目地はない
    doc.segments.each_value do |s|
      refute doc.surface.in_hole?((s.a + s.b) * 0.5), "joint #{s.id} runs through the window"
    end
    # 窓の縁は「開口」の辺
    above = panel_at(doc, 2100, 2200)
    assert_includes above.flags, 'O'
  end

  def test_window_edge_does_not_create_slivers
    doc = window_wall({ 'stone_width' => 900 })
    s = doc.settings
    doc.panels.each_value do |p|
      w, h = Polygon.min_extents(p.points)
      assert w >= s.min_pitch_u - 1e-6, "sliver width #{w}"
      assert h >= s.min_pitch_v - 1e-6, "sliver height #{h}"
    end
  end

  def test_opening_gap
    doc = window_wall({ 'opening_gap' => 10 })
    below = StoneGeometry.new(doc).build(panel_at(doc, 2000, 800))
    assert_in_delta 890, Polygon.bbox(below.outline)[3], 1e-6 # 窓台 900 から 10mm 逃げる
    left = StoneGeometry.new(doc).build(panel_at(doc, 1400, 1500))
    assert_in_delta 1490, Polygon.bbox(left.outline)[2], 1e-6
  end

  def test_window_inside_one_stone_is_rejected_without_alignment
    small = [[100, 100], [300, 100], [300, 300], [100, 300]]
    err = assert_raises(InvalidInput) { window_wall({ 'align_openings' => false }, holes: [small]) }
    assert_match(/開口/, err.message)
    doc = window_wall({ 'align_openings' => true }, holes: [small])
    assert_nil doc.panel_at(v2(200, 200))
  end

  def test_edit_around_window
    doc = window_wall
    eng = EditEngine.new(doc)
    # 窓の左の縦目地（抱き）を右へ動かすと窓に入る → 拒否
    plan = eng.plan_move([eng.pick(v2(1500, 1500), 3)].compact, 100)
    refute plan.ok? # 開口の縁は目地ではないので選べない or 動かせない
    # 窓の上の段の縦目地は動かせる
    piece = eng.pick(v2(1500, 2250), 3)
    assert piece
    plan = eng.plan_move([piece], -100)
    assert plan.ok?, plan.errors.inspect
    eng.apply(plan)
    assert_consistent(doc)
    # 窓の下の石と隣を結合して、窓を囲む形になる削除は拒否（穴のある石）
    assert_solid(doc)
  end

  def test_two_windows_and_serialization
    doc = window_wall({}, holes: [WIN, [[3300, 900], [4200, 900], [4200, 2100], [3300, 2100]]])
    assert_in_delta 5000 * 3000 - 1200 * 1200 - 900 * 1200, doc.panels.values.sum(&:area), 1e-3
    loaded = Serializer.load(Serializer.dump(doc))
    assert_equal 2, loaded.surface.holes.size
    assert_equal snapshot(doc), snapshot(loaded)
  end
end
