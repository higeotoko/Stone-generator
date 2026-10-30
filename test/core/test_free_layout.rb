# frozen_string_literal: true

require_relative '../test_helper'

# 仕様 18-3 / 18-4 / シナリオD: 目地の追加・削除、L字石、石厚変更
class TestFreeLayout < Minitest::Test
  include StoneTestHelpers

  def setup
    @doc = flat_doc
    @eng = EditEngine.new(@doc)
  end

  def make_l_shape
    # 芋目地: A=[0,900]x[0,600], B=[900,1800]x[0,600], C=[0,900]x[600,1200]
    a = panel_at(@doc, 450, 300)
    plan = @eng.plan_delete(@eng.pick(v2(900, 300), 3)) # A|B を結合
    assert plan.ok?, plan.errors.inspect
    @eng.apply(plan)
    plan = @eng.plan_delete(@eng.pick(v2(450, 600), 3)) # AB|C を結合 → L字
    assert plan.ok?, plan.errors.inspect
    @eng.apply(plan)
    l = panel_at(@doc, 450, 900)
    assert_equal l, panel_at(@doc, 1350, 300)
    [a, l]
  end

  def test_add_joint_splits_stone
    target = panel_at(@doc, 450, 300)
    plan = @eng.plan_add(v2(300, 300), :v)
    assert plan.ok?, plan.errors.inspect
    cs = @eng.apply(plan)
    assert_equal 1, cs.added.size
    assert_includes cs.regenerate, target.id # 大きい方が元のIDを引き継ぐ
    assert_in_delta 600, Polygon.min_extents(@doc.panels[target.id].points)[0]
    assert_equal 31, @doc.panels.size
    assert_consistent(@doc)
  end

  def test_add_horizontal_joint
    plan = @eng.plan_add(v2(300, 250), :h)
    assert plan.ok?, plan.errors.inspect
    @eng.apply(plan)
    assert_equal 31, @doc.panels.size
    assert_consistent(@doc)
  end

  def test_add_joint_too_close_rejected
    plan = @eng.plan_add(v2(50, 300), :v)
    refute plan.ok?
  end

  def test_delete_joint_merges
    plan = @eng.plan_delete(@eng.pick(v2(900, 300), 3))
    assert plan.ok?, plan.errors.inspect
    cs = @eng.apply(plan)
    assert_equal 1, cs.removed.size
    assert_equal 29, @doc.panels.size
    assert_in_delta 1800, Polygon.min_extents(panel_at(@doc, 100, 300).points)[0]
    assert_consistent(@doc)
  end

  def test_delete_boundary_rejected
    piece = Piece.new(nil, v2(0, 0), v2(0, 600))
    refute @eng.plan_delete(piece).ok?
  end

  def test_l_shaped_stone_is_valid_solid
    a, l = make_l_shape
    assert_equal a.id, l.id # 元の石IDを保持
    assert Polygon.simple?(l.points)
    sp, = Polygon.simplify(l.points, l.flags)
    assert_equal 6, sp.size
    built = assert_solid(@doc, [l.id]).first
    expected = (1800 * 600 + 900 * 600) - # 中心線の面積
               (1800 * 4 + 1200 * 0) # 概算は下で厳密に比較
    assert built.face_area < expected
    # 輪郭: 外周側は逃げ0、目地側は 4mm 内側
    assert_in_delta 1796 * 596 + 896 * 600, built.face_area, 1e-3
    assert_in_delta built.face_area * 30, built.volume, 1e-2
    assert_consistent(@doc)
  end

  def test_thickness_change_keeps_l_and_joints
    _, l = make_l_shape
    joints = @doc.segments.transform_values(&:to_h)
    shape = l.shape_key
    s_before = StoneGeometry.new(@doc).build(l)
    @doc.settings = @doc.settings.merge('thickness' => 40)
    s_after = StoneGeometry.new(@doc).build(@doc.panels[l.id])
    assert_equal joints, @doc.segments.transform_values(&:to_h) # 目地位置は不変
    assert_equal shape, @doc.panels[l.id].shape_key            # 異形石の輪郭も不変
    assert_in_delta s_before.face_area, s_after.face_area, 1e-6
    lo0, = s_before.mesh.bbox
    lo1, hi1 = s_after.mesh.bbox
    assert_in_delta lo0[1], lo1[1] # 仕上げ面（y=0）は不変
    assert_in_delta 40, hi1[1] - lo1[1]
    assert_in_delta s_after.face_area * 40, s_after.volume, 1e-2
  end

  def test_joint_width_change_keeps_centerlines
    joints = @doc.segments.transform_values(&:to_h)
    @doc.settings = @doc.settings.merge('joint_v' => 10, 'joint_h' => 10)
    a = StoneGeometry.new(@doc).build(panel_at(@doc, 1000, 900))
    bb = Polygon.bbox(a.outline)
    assert_in_delta 890, bb[2] - bb[0]
    assert_in_delta 905, bb[0] # 目地芯 900 から 5mm
    assert_equal joints, @doc.segments.transform_values(&:to_h)
  end

  def test_t_joint_edit_after_split
    # 石を横目地で分割すると T 字ができる。縦目地を動かすと T の横目地が伸縮する
    @eng.apply(@eng.plan_add(v2(450, 300), :h))
    # 部分移動: 下半分だけ動き、T字点の上側は段差（ジョグ）で接続を保つ
    plan = @eng.plan_move([@eng.pick(v2(900, 100), 3)], 80)
    assert plan.ok?, plan.errors.inspect
    @eng.apply(plan)
    assert_in_delta 980, Polygon.min_extents(panel_at(@doc, 100, 100).points)[0]
    assert_in_delta 900, Polygon.min_extents(panel_at(@doc, 100, 500).points)[0]
    assert_consistent(@doc)
    assert_solid(@doc)
  end

  def test_t_joint_follows_through_move
    @eng.apply(@eng.plan_add(v2(450, 300), :h))
    # 通り移動: 縦目地 0..600 全体が動き、端点を載せている横目地（T字）が伸びる
    plan = @eng.plan_move([@eng.pick(v2(900, 100), 3)], 80, mode: :through)
    assert plan.ok?, plan.errors.inspect
    @eng.apply(plan)
    assert_in_delta 980, Polygon.min_extents(panel_at(@doc, 100, 100).points)[0]
    assert_in_delta 980, Polygon.min_extents(panel_at(@doc, 100, 500).points)[0]
    t = @doc.segments.values.find { |s| s.orientation == :h && (s.a.y - 300).abs < 1e-6 }
    assert_in_delta 980, t.b.x
    assert_consistent(@doc)
  end
end
