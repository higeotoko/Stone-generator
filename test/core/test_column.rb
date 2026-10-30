# frozen_string_literal: true

require_relative '../test_helper'

# 仕様 18-6: 半径 1000mm の丸柱（周方向に閉じた循環座標）
class TestColumn < Minitest::Test
  include StoneTestHelpers

  R = 1000.0

  def column(settings = {})
    prof = Profile.new([ArcSegment2.new(v2(0, 0), R, 0, 2 * Math::PI)])
    build_doc(SurfaceDefinition.rectangle(prof, 0, 2400), { 'end_mode' => 'uniform' }.merge(settings))
  end

  def test_circumference_and_closure
    doc = column
    assert doc.periodic?
    assert_in_delta 2 * Math::PI * R, doc.period, 1e-9
    n = (doc.period / 900).round
    assert_equal 7, n
    assert_equal 4 * n, doc.panels.size
    total = doc.panels.values.sum(&:area)
    assert_in_delta doc.period * 2400, total, 1e-3 # 周回を隙間なく覆う
    us = doc.segments.values.select { |s| s.orientation == :v && s.a.y < 1 }.map { |s| s.a.x }.sort
    pitches = (us + [us.first + doc.period]).each_cons(2).map { |a, b| b - a }
    assert pitches.all? { |p| (p - doc.period / n).abs < 1e-6 } # 最終目地まで正確に閉合
    assert_consistent(doc)
  end

  def test_running_bond_crosses_seam_and_solid
    doc = column('pattern' => 'running')
    seam = doc.panels.values.select { |p| p.bbox[2] > doc.period + 1 }
    refute_empty seam # 周回境界（u=0）を跨ぐ石
    assert_consistent(doc)
    built = assert_solid(doc, seam.map(&:id))
    built.each do |b|
      b.mesh.points.each do |q|
        d = Math.hypot(q[0], q[1])
        assert(((d - R).abs < 1e-6) || ((d - (R - 30)).abs < 1e-6))
      end
    end
  end

  def test_move_joint_across_seam
    doc = column
    eng = EditEngine.new(doc)
    piece = eng.pick(v2(0.0, 300), 3)
    refute_nil piece
    plan = eng.plan_move([piece], -100) # 周回境界を越えて u = L-100 へ
    assert plan.ok?, plan.errors.inspect
    eng.apply(plan)
    pitch = doc.period / 7
    widths = doc.panels.values.select { |p| p.bbox[1] < 1 }.map { |p| Polygon.min_extents(p.points)[0] }.sort
    assert_in_delta pitch - 100, widths.first, 1e-6
    assert_in_delta pitch + 100, widths.last, 1e-6
    assert_consistent(doc)
    assert_solid(doc)
  end

  def test_through_move_ring_joint
    doc = column
    eng = EditEngine.new(doc)
    piece = eng.pick(v2(100, 600), 3)
    plan = eng.plan_move([piece], 50, mode: :through)
    assert plan.ok?, plan.errors.inspect
    eng.apply(plan)
    doc.panels.values.select { |p| p.bbox[1] < 1 }.each do |p|
      assert_in_delta 650, Polygon.min_extents(p.points)[1]
    end
    assert_consistent(doc)
  end

  def test_start_angle_change
    doc = column('start_u' => 300)
    us = doc.segments.values.select { |s| s.orientation == :v && s.a.y < 1 }.map { |s| s.a.x }.sort
    assert_in_delta 300, us.first
    assert_consistent(doc)
  end
end
