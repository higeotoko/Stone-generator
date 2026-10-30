# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../support/fake_sketchup'
require_relative '../../src/stone_layout_generator/sketchup/units'
require_relative '../../src/stone_layout_generator/sketchup/model_store'
require_relative '../../src/stone_layout_generator/sketchup/geometry_builder'
require_relative '../../src/stone_layout_generator/sketchup/layout_controller'

# SketchUp アダプタ層をモックで検証（実機の代わりではない）
class TestController < Minitest::Test
  include StoneTestHelpers
  SL = Higeotoko::StoneLayout

  def setup
    @model = Sketchup::Model.new
    @ctrl, = SL::LayoutController.create(@model, @model.entities, SurfaceDefinition.flat_wall(5000, 3000), Settings.new)
  end

  def stones(ctrl = @ctrl)
    SL::ModelStore.stone_index(ctrl.group)
  end

  def test_create_builds_one_group_per_stone
    assert_equal 'StoneLayout_001', @ctrl.group.name
    idx = stones
    assert_equal 30, idx.size
    g = idx.values.first
    assert_match(/\AStone_\d{4}\z/, g.name)
    assert_equal 6, g.faces.size # 直方体
    assert_equal [[:start, '石割付を生成'], [:commit, '石割付を生成']], @model.log
    assert_empty @ctrl.check_integrity
  end

  def test_joint_move_rebuilds_only_neighbours_in_one_operation
    before = stones.transform_values { |g| [g, g.faces.map(&:points)] }
    eng = EditEngine.new(@ctrl.doc)
    plan = eng.plan_move([eng.pick(v2(900, 300), 3)], 100)
    change = @ctrl.commit_plan(plan, '石割付: 目地移動')
    assert_equal 2, change.regenerate.size
    after = stones
    before.each do |pid, (g, faces)|
      assert after[pid].equal?(g), 'group object must be reused'
      next if change.regenerate.include?(pid)

      assert_equal faces, after[pid].faces.map(&:points), "stone #{pid} geometry touched"
    end
    assert_equal 1, @model.log.count { |e| e == [:commit, '石割付: 目地移動'] }
    assert_empty @ctrl.check_integrity
  end

  def test_undo_and_redo_restore_data_and_geometry
    original = Serializer.dump(@ctrl.doc)
    eng = EditEngine.new(@ctrl.doc)
    @ctrl.commit_plan(eng.plan_move([eng.pick(v2(900, 300), 3)], 100), '石割付: 目地移動')
    moved = Serializer.dump(@ctrl.doc)
    left = @ctrl.doc.panel_at(v2(450, 300)).first.id

    @model.undo
    group = @model.entities.grep(Sketchup::Group).first
    refute @ctrl.group.valid? # 本物と同様、古い参照は無効
    ctrl = SL::LayoutController.new(group)
    assert_equal original, Serializer.dump(ctrl.doc)
    bb = stones(ctrl)[left].bounds
    assert_in_delta 896, SL::Units.to_mm(bb.max.x - bb.min.x), 1e-6
    assert_empty ctrl.check_integrity

    @model.redo
    ctrl = SL::LayoutController.new(@model.entities.grep(Sketchup::Group).first)
    assert_equal moved, Serializer.dump(ctrl.doc)
    bb = stones(ctrl)[left].bounds
    assert_in_delta 996, SL::Units.to_mm(bb.max.x - bb.min.x), 1e-6
  end

  def test_refresh_detects_revision_change
    eng = EditEngine.new(@ctrl.doc)
    other = SL::LayoutController.new(@ctrl.group)
    @ctrl.commit_plan(eng.plan_move([eng.pick(v2(900, 300), 3)], 50), 'move')
    assert other.refresh!
    refute other.refresh!
    assert_equal @ctrl.doc.revision, other.doc.revision
  end

  def test_thickness_change_keeps_joints
    eng = EditEngine.new(@ctrl.doc)
    @ctrl.commit_plan(eng.plan_move([eng.pick(v2(900, 300), 3)], 100), 'move')
    joints = @ctrl.doc.segments.transform_values(&:to_h)
    @ctrl.change_settings('thickness' => 40)
    reopened = SL::LayoutController.new(@ctrl.group)
    assert_equal joints, reopened.doc.segments.transform_values(&:to_h)
    assert_equal 40.0, reopened.doc.settings['thickness']
    bb = stones(reopened).values.first.bounds
    assert_in_delta 40, SL::Units.to_mm(bb.max.y - bb.min.y), 1e-6
    assert_raises(Higeotoko::StoneLayout::Core::InvalidInput) { @ctrl.change_settings('stone_width' => 800) }
  end

  def test_failed_geometry_aborts_and_keeps_model
    prof = Profile.new([LineSegment2.new(v2(0, 0), v2(2000, 0)),
                        ArcSegment2.new(v2(2000, 500), 500, -Math::PI / 2, Math::PI / 2),
                        LineSegment2.new(v2(2500, 500), v2(2500, 2500))])
    ctrl, = SL::LayoutController.create(@model, @model.entities, SurfaceDefinition.rectangle(prof, 0, 1200), Settings.new)
    data = ctrl.group.get_attribute(SL::ModelStore::DICT, 'data')
    assert_raises(GeometryError) { ctrl.change_settings('thickness' => 600) }
    assert_equal data, ctrl.group.get_attribute(SL::ModelStore::DICT, 'data')
    assert_equal 30.0, ctrl.doc.settings['thickness']
  end

  def test_save_and_reopen_file
    eng = EditEngine.new(@ctrl.doc)
    @ctrl.commit_plan(eng.plan_move([eng.pick(v2(900, 300), 3)], 100), 'move')
    eng = EditEngine.new(@ctrl.doc)
    @ctrl.commit_plan(eng.plan_lock([eng.pick(v2(1800, 300), 3)], true), 'lock')
    file = Marshal.dump(@model.entities) # 保存して閉じる
    ents = Marshal.load(file)            # 開く
    group = ents.grep(Sketchup::Group).first
    group.instance_variable_set(:@model, @model)
    ctrl = SL::LayoutController.new(group)
    assert_equal Serializer.dump(@ctrl.doc), Serializer.dump(ctrl.doc)
    eng = EditEngine.new(ctrl.doc)
    assert eng.plan_move([eng.pick(v2(1000, 300), 3)], 10).ok? # そのまま編集を継続できる
  end

  def test_integrity_detects_direct_edits_and_repairs
    g = stones.values[3]
    g.entities.add_face([Geom::Point3d.new(0, 0, 0), Geom::Point3d.new(100, 0, 0), Geom::Point3d.new(100, 0, 100)])
    victim = stones.values[5]
    victim.erase!
    issues = @ctrl.check_integrity
    assert_equal %i[missing modified].sort, issues.map(&:kind).sort
    @ctrl.repair(issues.map(&:panel_id))
    assert_empty @ctrl.check_integrity
  end

  def test_detach_excludes_stone_from_regeneration
    pid = @ctrl.doc.panel_at(v2(450, 300)).first.id
    @ctrl.detach([pid])
    assert @ctrl.doc.panels[pid].detached?
    eng = EditEngine.new(@ctrl.doc)
    plan = eng.plan_move([eng.pick(v2(900, 300), 3)], 100)
    refute plan.ok?
    assert_match(/切り離された/, plan.errors.first)
  end

  def test_corrupt_data_does_not_touch_geometry
    @ctrl.group.set_attribute(SL::ModelStore::DICT, 'data', '{broken')
    assert_raises(PersistenceError) { SL::LayoutController.new(@ctrl.group) }
    assert_equal 30, stones.size
  end
  def test_corner_mode_rebuilds_only_that_corner
    prof = Profile.new([LineSegment2.new(v2(0, 0), v2(1500, 0)), LineSegment2.new(v2(1500, 0), v2(1500, 1500))])
    ctrl, = SL::LayoutController.create(@model, @model.entities, SurfaceDefinition.rectangle(prof, 0, 1200), Settings.new)
    before = stones(ctrl).transform_values { |g| g.faces.map(&:points) }
    touched = CornerJoint.panels_at(ctrl.doc, 0)
    ctrl.set_corner_mode(0, 'win_prev')
    after = stones(ctrl).transform_values { |g| g.faces.map(&:points) }
    changed = after.keys.reject { |k| after[k] == before[k] }
    assert_equal touched.sort, changed.sort
    assert_equal 'win_prev', SL::LayoutController.new(ctrl.group).doc.settings.corner_mode_at(0)
    ctrl.set_corner_mode(0, nil)
    assert_equal 'miter', ctrl.doc.settings.corner_mode_at(0)
  end
end
