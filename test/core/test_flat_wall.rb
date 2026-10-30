# frozen_string_literal: true

require_relative '../test_helper'

# 仕様 18-1: W5000 x H3000, 900 x 600, 目地 8mm, 石厚 30mm
class TestFlatWall < Minitest::Test
  include StoneTestHelpers

  def setup
    @doc = flat_doc('stone_width' => 900, 'stone_height' => 600, 'joint_v' => 8, 'joint_h' => 8, 'thickness' => 30)
  end

  def test_counts_and_positions
    assert_equal 30, @doc.panels.size # 5段 x 6列（900x5 + 半端500）
    us = @doc.segments.values.select { |s| s.orientation == :v }.map { |s| s.a.x }.uniq.sort
    assert_equal [900, 1800, 2700, 3600, 4500].map(&:to_f), us
    vs = @doc.segments.values.select { |s| s.orientation == :h }.map { |s| s.a.y }.uniq.sort
    assert_equal [600, 1200, 1800, 2400].map(&:to_f), vs
  end

  def test_end_remainder
    last = panel_at(@doc, 4900, 300)
    w, h = Polygon.min_extents(last.points)
    assert_in_delta 500, w
    assert_in_delta 600, h
  end

  def test_joint_width_and_thickness
    geo = StoneGeometry.new(@doc)
    a = geo.build(panel_at(@doc, 1000, 900))   # 内部の石
    bb = Polygon.bbox(a.outline)
    assert_in_delta 892, bb[2] - bb[0]
    assert_in_delta 592, bb[3] - bb[1]
    b = geo.build(panel_at(@doc, 1900, 900))
    gap = Polygon.bbox(b.outline)[0] - bb[2]
    assert_in_delta 8, gap # 縦目地幅

    lo, hi = a.mesh.bbox
    assert_in_delta 30, hi[1] - lo[1] # 壁は +x 方向、法線 -y、内側へ 30mm
    assert_in_delta 0, lo[1]          # 仕上げ面 = 選択面 (y=0)
    assert_in_delta 892 * 592 * 30, a.volume, 1e-3
  end

  def test_corner_stone_is_flush_with_wall_edge
    first = StoneGeometry.new(@doc).build(panel_at(@doc, 10, 10))
    bb = Polygon.bbox(first.outline)
    assert_in_delta 0, bb[0]
    assert_in_delta 0, bb[1]
    assert_in_delta 896, bb[2]
  end

  def test_all_stones_are_closed_solids
    built = assert_solid(@doc)
    assert_equal 30, built.size
    total = built.sum(&:face_area)
    # 壁面積 - 目地面積（縦目地 5本 x 3000 x 8 + 横目地 4本 x 5000 x 8 - 交点の重複 20 x 64）
    assert_in_delta 5000 * 3000 - 5 * 3000 * 8 - 4 * 5000 * 8 + 20 * 64, total, 1e-3
  end

  def test_running_bond
    doc = flat_doc('pattern' => 'running')
    row2 = doc.segments.values.select { |s| s.orientation == :v && s.a.y >= 599 && s.b.y <= 1201 }.map { |s| s.a.x }.sort
    assert_equal [450, 1350, 2250, 3150, 4050, 4950].map(&:to_f).reject { |x| 5000 - x < 150 }, row2
    assert_consistent(doc)
    assert_solid(doc)
  end

  def test_balanced_and_uniform
    doc = flat_doc('end_mode' => 'balanced')
    us = doc.segments.values.select { |s| s.orientation == :v }.map { |s| s.a.x }.uniq.sort
    assert_in_delta us.first, 5000 - us.last # 左右対称
    doc = flat_doc('end_mode' => 'uniform')
    us = doc.segments.values.select { |s| s.orientation == :v }.map { |s| s.a.x }.uniq.sort
    pitches = ([0.0] + us + [5000.0]).each_cons(2).map { |a, b| b - a }
    assert pitches.all? { |p| (p - pitches.first).abs < 1e-6 }
  end

  def test_min_width_merges_end_piece
    doc = build_doc(SurfaceDefinition.flat_wall(1850, 600), 'min_width' => 150)
    us = doc.segments.values.select { |s| s.orientation == :v }.map { |s| s.a.x }
    assert_equal [900.0], us # 残り 50 は最後の石へ結合 → 900 + 950
  end

  def test_right_and_center_alignment
    doc = flat_doc('align_u' => 'right')
    us = doc.segments.values.select { |s| s.orientation == :v }.map { |s| s.a.x }.uniq.sort
    assert_in_delta 4100, us.last
    doc = flat_doc('align_u' => 'center')
    us = doc.segments.values.select { |s| s.orientation == :v }.map { |s| s.a.x }.uniq.sort
    assert_in_delta us.first, 5000 - us.last
  end

  def test_stone_size_basis
    doc = flat_doc('size_basis' => 'stone', 'stone_width' => 892, 'stone_height' => 592)
    assert_equal 30, doc.panels.size
  end

  def test_gable_wall_boundary
    prof = Profile.new([LineSegment2.new(v2(0, 0), v2(4000, 0))])
    boundary = [v2(0, 0), v2(4000, 0), v2(4000, 2000), v2(2000, 3000), v2(0, 2000)]
    doc = LayoutBuilder.build(SurfaceDefinition.new(prof, boundary), Settings.new).first
    assert_in_delta Polygon.area(boundary), doc.panels.values.sum(&:area), 1e-3
    assert_consistent(doc)
  end

  def test_substrate_reference_and_outward
    doc = flat_doc('reference' => 'substrate', 'face_offset' => 50, 'direction' => 'inward')
    a = StoneGeometry.new(doc).build(doc.panels.values.first)
    lo, hi = a.mesh.bbox
    assert_in_delta(-50, lo[1]) # 仕上げ面は外側 50mm（法線 -y）
    assert_in_delta(-20, hi[1])
  end
end
