# frozen_string_literal: true

require_relative '../test_helper'

# 仕様 18-2 / 7章: 目地ドラッグ
class TestJointEdit < Minitest::Test
  include StoneTestHelpers

  def setup
    @doc = flat_doc
    @eng = EditEngine.new(@doc)
  end

  def outline_bbox(doc, panel)
    Polygon.bbox(StoneGeometry.new(doc).build(panel).outline)
  end

  def test_move_vertical_joint_100mm_changes_only_neighbours
    left = panel_at(@doc, 450, 300)
    right = panel_at(@doc, 1350, 300)
    before = snapshot(@doc)
    piece = @eng.pick(v2(902, 300), 5)
    assert_equal :v, piece.orientation
    assert_in_delta 900, piece.position

    plan = @eng.plan_move([piece], 100)
    assert plan.ok?, plan.errors.inspect
    assert_equal [left.id, right.id].sort, plan.changed_panel_ids.sort
    cs = @eng.apply(plan)
    assert_equal [left.id, right.id].sort, cs.regenerate.sort
    assert_empty cs.added
    assert_empty cs.removed

    # 左が 100 広く、右が 100 狭く
    assert_in_delta 1000, Polygon.min_extents(@doc.panels[left.id].points)[0]
    assert_in_delta 800, Polygon.min_extents(@doc.panels[right.id].points)[0]
    # 目地幅は維持
    gap = outline_bbox(@doc, @doc.panels[right.id])[0] - outline_bbox(@doc, @doc.panels[left.id])[2]
    assert_in_delta 8, gap
    # 他の石の形状は不変
    after = snapshot(@doc)
    (before.keys - [left.id, right.id]).each { |id| assert_equal before[id], after[id], "panel #{id} changed" }
    assert_consistent(@doc)
    assert_equal JointSegment::MANUAL, @doc.segments[piece.segment_id]&.state || 'manual'
  end

  def test_undo_redo_via_serialized_state
    before = Serializer.dump(@doc)
    piece = @eng.pick(v2(900, 300), 5)
    @eng.apply(@eng.plan_move([piece], 100))
    after = Serializer.dump(@doc)
    refute_equal before, after

    # Undo: 操作前の保存状態に戻すと完全に一致
    undone = Serializer.load(before)
    assert_equal before, Serializer.dump(undone)
    # Redo: 同じ操作を再適用すると同じ結果（決定的）
    eng2 = EditEngine.new(undone)
    eng2.apply(eng2.plan_move([eng2.pick(v2(900, 300), 5)], 100))
    assert_equal Serializer.to_h(@doc).reject { |k| k == 'revision' },
                 Serializer.to_h(undone).reject { |k| k == 'revision' }
  end

  def test_plan_does_not_mutate_document
    before = Serializer.dump(@doc)
    piece = @eng.pick(v2(900, 300), 5)
    10.times { |i| @eng.plan_move([piece], i * 10 + 5) } # ドラッグ中のプレビュー
    assert_equal before, Serializer.dump(@doc)
  end

  def test_partial_vertical_move_at_cross_junction_keeps_other_rows
    # 芋目地では縦目地が十字に交わる。部分移動では上段の縦目地は動かない
    piece = @eng.pick(v2(900, 900), 5)
    upper = panel_at(@doc, 450, 1500)
    key = upper.shape_key
    @eng.apply(@eng.plan_move([piece], -50))
    assert_equal key, @doc.panels[upper.id].shape_key
    assert_in_delta 850, Polygon.min_extents(panel_at(@doc, 400, 900).points)[0]
    assert_consistent(@doc)
  end

  def test_through_move_vertical
    piece = @eng.pick(v2(900, 900), 5)
    pieces = @eng.through_pieces(piece)
    assert_equal 5, pieces.size # 芋目地の縦目地は段ごとの線分。通り目地として5段分つながる
    plan = @eng.plan_move([piece], 60, mode: :through)
    assert plan.ok?, plan.errors.inspect
    @eng.apply(plan)
    5.times do |row|
      assert_in_delta 960, Polygon.min_extents(panel_at(@doc, 100, row * 600 + 300).points)[0]
    end
    assert_consistent(@doc)
  end

  def test_through_move_horizontal_in_running_bond_stretches_t_joints
    doc = flat_doc('pattern' => 'running')
    eng = EditEngine.new(doc)
    piece = eng.pick(v2(100, 600), 5)
    assert_equal :h, piece.orientation
    plan = eng.plan_move([piece], 50, mode: :through)
    assert plan.ok?, plan.errors.inspect
    eng.apply(plan)
    assert_in_delta 650, Polygon.min_extents(panel_at(doc, 100, 100).points)[1]
    assert_in_delta 550, Polygon.min_extents(panel_at(doc, 100, 1000).points)[1]
    assert_consistent(doc)
    assert_solid(doc)
  end

  def test_partial_horizontal_move_creates_jog
    doc = flat_doc('pattern' => 'running')
    eng = EditEngine.new(doc)
    # 1段目の石(0..900)と2段目の石(450..1350)の間の辺 = 450..900
    piece = eng.pick(v2(700, 600), 5)
    assert_in_delta 450, piece.a.x
    assert_in_delta 900, piece.b.x
    plan = eng.plan_move([piece], 40)
    assert plan.ok?, plan.errors.inspect
    eng.apply(plan)
    lower = panel_at(doc, 700, 620)
    assert lower # 下の石が 40mm 突き出した形になる
    assert Polygon.simple?(lower.points)
    assert_consistent(doc)
    assert_solid(doc)
  end

  def test_rejects_too_small_stone
    piece = @eng.pick(v2(900, 300), 5)
    plan = @eng.plan_move([piece], 820) # 右の石 900 -> 80 < 最小150
    refute plan.ok?
    assert_match(/最小寸法/, plan.errors.first)
  end

  def test_rejects_crossing_neighbour_joint
    piece = @eng.pick(v2(900, 300), 5)
    plan = @eng.plan_move([piece], 950)
    refute plan.ok?
  end

  def test_rejects_moving_beyond_wall
    piece = @eng.pick(v2(900, 300), 5)
    plan = @eng.plan_move([piece], -950)
    refute plan.ok?
  end

  def test_locked_joint_cannot_move
    piece = @eng.pick(v2(900, 300), 5)
    @eng.apply(@eng.plan_lock([piece], true))
    assert_equal JointSegment::LOCKED, @doc.segments[piece.segment_id].status
    plan = @eng.plan_move([@eng.pick(v2(900, 300), 5)], 10)
    refute plan.ok?
    assert_match(/ロック/, plan.errors.first)
  end

  def test_successive_moves_and_back
    piece = @eng.pick(v2(900, 300), 5)
    start = snapshot(@doc)
    @eng.apply(@eng.plan_move([piece], 100))
    @eng.apply(@eng.plan_move([@eng.pick(v2(1000, 300), 5)], -40))
    @eng.apply(@eng.plan_move([@eng.pick(v2(960, 300), 5)], -60))
    assert_equal start.values.sort, snapshot(@doc).values.sort
    assert_equal start.keys.sort, snapshot(@doc).keys.sort
    assert_consistent(@doc)
  end

  def test_multi_select_moves_together
    a = @eng.pick(v2(900, 300), 5)
    b = @eng.pick(v2(1800, 300), 5)
    plan = @eng.plan_move([a, b], 30)
    assert plan.ok?, plan.errors.inspect
    @eng.apply(plan)
    assert_in_delta 900, Polygon.min_extents(panel_at(@doc, 1500, 300).points)[0]
    assert_consistent(@doc)
  end

  def test_snapper
    sn = Snapper.new(@doc)
    piece = @eng.pick(v2(900, 300), 5)
    r = sn.snap([piece], 897, 10) # 1797 → 既存目地 1800 にスナップ
    assert_in_delta 900, r.delta
    assert_equal '目地', r.label
    r = sn.snap([piece], 123.4, 1, step: 5)
    assert_in_delta 125, r.delta
  end

  def test_large_layout_local_edit_is_local
    doc = build_doc(SurfaceDefinition.flat_wall(30_000, 9_000))
    eng = EditEngine.new(doc)
    assert doc.panels.size > 400
    plan = eng.plan_move([eng.pick(v2(9000, 4500), 5)], 100)
    assert plan.ok?
    assert plan.affected_ids.size <= 12, "affected #{plan.affected_ids.size}"
  end
end
