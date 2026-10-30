# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../support/fake_view'
%w[units model_store geometry_builder layout_controller tools/edit_tool].each do |f|
  require_relative "../../src/stone_layout_generator/sketchup/#{f}"
end

# EditTool をマウス操作で動かす（ロジックの検証。実機の描画・ピックの代わりではない）
class TestEditTool < Minitest::Test
  include StoneTestHelpers
  SL = Higeotoko::StoneLayout

  def setup
    UI.messages.clear
    @model = Sketchup::Model.new
    Sketchup.active_model = @model
    @ctrl, = SL::LayoutController.create(@model, @model.entities, SurfaceDefinition.flat_wall(5000, 3000), Settings.new)
    @view = @model.active_view
    @tool = SL::EditTool.new(@ctrl)
    @tool.activate
  end

  # 壁の展開座標 (u, v) mm → 画面座標（壁は y=0、u=x、v=z）
  def at(u, v)
    @view.screen_of_mm(u, v)
  end

  def width_of(u, v)
    Polygon.min_extents(@ctrl.doc.panel_at(v2(u, v)).first.points)[0]
  end

  def stone_width_in_model(u, v)
    pid = @ctrl.doc.panel_at(v2(u, v)).first.id
    bb = SL::ModelStore.stone_index(@ctrl.group)[pid].bounds
    SL::Units.to_mm(bb.max.x - bb.min.x)
  end

  def drag(from, to, flags = 0)
    @tool.onMouseMove(0, *from, @view)
    @tool.onLButtonDown(flags, *from, @view)
    @tool.onMouseMove(1, from[0] + (to[0] - from[0]) / 2, from[1] + (to[1] - from[1]) / 2, @view)
    @tool.onMouseMove(1, *to, @view)
    @tool.onLButtonUp(0, *to, @view)
  end

  def test_drag_vertical_joint_updates_layout_and_stones
    assert_empty UI.messages, UI.messages.inspect
    drag(at(901, 300), at(1001, 300))
    assert_nil @tool.message
    assert_in_delta 1000, width_of(450, 300)
    assert_in_delta 996, stone_width_in_model(450, 300), 1e-6
    assert_in_delta 792, stone_width_in_model(1400, 300), 1e-6
    assert_equal 1, SL::ModelStore.revision(@ctrl.group)
  end

  # SketchUp の移動ツールと同じ「クリック → 動かす → クリック」
  def test_click_move_click
    @tool.onMouseMove(0, *at(900, 300), @view)
    @tool.onLButtonDown(0, *at(900, 300), @view)
    @tool.onLButtonUp(0, *at(900, 300), @view)
    @tool.onMouseMove(0, *at(950, 320), @view)
    @tool.onMouseMove(0, *at(1000, 320), @view)
    assert_in_delta 900, width_of(450, 300) # まだ確定していない
    @tool.onLButtonDown(0, *at(1000, 320), @view)
    @tool.onLButtonUp(0, *at(1000, 320), @view)
    assert_in_delta 1000, width_of(450, 300)
    # 確定後はもう追従しない
    @tool.onMouseMove(0, *at(1200, 320), @view)
    assert_in_delta 1000, width_of(450, 300)
  end

  def test_click_move_escape_cancels
    @tool.onLButtonDown(0, *at(900, 300), @view)
    @tool.onLButtonUp(0, *at(900, 300), @view)
    @tool.onMouseMove(0, *at(1000, 300), @view)
    @tool.onCancel(0, @view)
    @tool.onLButtonDown(0, *at(3000, 1500), @view) # 石の中（目地でない所）
    assert_in_delta 900, width_of(450, 300)
  end

  def test_unexpected_error_is_reported_not_swallowed
    UI.messages.clear
    @ctrl.stub(:commit_plan, ->(*) { raise NoMethodError, 'boom' }) do
      drag(at(900, 300), at(1000, 300))
    end
    assert_match(/boom/, @tool.message)
    assert(UI.messages.any? { |m| m.include?('boom') })
  end

  def test_click_then_type_value
    @tool.onLButtonDown(0, *at(900, 300), @view)
    @tool.onLButtonUp(0, *at(900, 300), @view)
    refute_empty @tool.selection
    @tool.onUserText('100', @view) # クリックで拾った状態から数値入力
    assert_in_delta 1000, width_of(450, 300)
  end

  def test_panel_nudge_moves_selected_joint
    @tool.onLButtonDown(0, *at(900, 300), @view)
    @tool.onLButtonUp(0, *at(900, 300), @view)
    @tool.move_selection(-50)
    assert_in_delta 850, width_of(450, 300)
    @tool.move_selection(-50) # 選択は移動先に追従している
    assert_in_delta 800, width_of(400, 300)
  end

  def test_drag_horizontal_joint_through
    drag(at(450, 601), at(450, 651), CONSTRAIN_MODIFIER_MASK)
    assert_in_delta 650, Polygon.min_extents(@ctrl.doc.panel_at(v2(450, 300)).first.points)[1]
  end

  def test_invalid_drag_reports_reason_and_keeps_model
    drag(at(900, 300), at(1850, 300))
    assert @tool.message
    assert_in_delta 900, width_of(450, 300)
  end

  def test_undo_while_tool_active_resyncs
    drag(at(900, 300), at(1000, 300))
    @model.undo
    group = @model.entities.grep(Sketchup::Group).first
    ctrl = SL::LayoutController.new(group)
    tool = SL::EditTool.new(ctrl)
    tool.activate
    tool.onLButtonDown(0, *at(900, 300), @view)
    refute_empty tool.selection
  end
  # 壁グループの中に作った割付を、モデル直下から編集する（祖先グループの変換を考慮）
  def test_layout_inside_moved_wall_group
    model = Sketchup::Model.new
    Sketchup.active_model = model
    wall = model.entities.add_group
    wall.transformation = Geom::Transformation.new([1000 / 25.4, 2000 / 25.4, 500 / 25.4])
    ctrl, = SL::LayoutController.create(model, wall.entities, SurfaceDefinition.flat_wall(5000, 3000), Settings.new)
    tool = SL::EditTool.new(ctrl)
    tool.activate
    view = model.active_view
    # ワールド座標では u=900 の目地は x=1900、v=300 は z=800
    from = view.screen_of_mm(1900, 800)
    to = view.screen_of_mm(2000, 800)
    tool.onMouseMove(0, *from, view)
    tool.onLButtonDown(0, *from, view)
    tool.onLButtonUp(0, *from, view)
    assert_nil tool.message
    tool.onMouseMove(0, *to, view)
    tool.onLButtonDown(0, *to, view)
    tool.onLButtonUp(0, *to, view)
    assert_in_delta 1000, Polygon.min_extents(ctrl.doc.panel_at(v2(450, 300)).first.points)[0]
  end

  def test_click_off_surface_explains_why
    @tool.onLButtonDown(0, *at(-500, 300), @view)
    assert_match(/当たっていません/, @tool.message)
    @tool.onLButtonDown(0, *at(450, 300), @view)
    assert_match(/目地が見つかりません/, @tool.message)
  end
end
