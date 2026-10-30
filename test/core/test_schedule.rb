# frozen_string_literal: true

require_relative '../test_helper'

# 石寸法一覧・数量集計
class TestSchedule < Minitest::Test
  include StoneTestHelpers

  def test_flat_wall_types_and_totals
    doc = flat_doc # 5000 x 3000, 900 x 600, 目地 8, 石厚 30
    res = Schedule.build(doc)
    assert_equal 30, res.totals['count']
    # 実寸: 左端の列 896 / 中の列 892 / 右端 496、上下の段 596 / 中の段 592
    sizes = res.types.map { |t| [t.width, t.height] }
    assert_equal [892.0, 592.0], sizes.first # 枚数が最も多い種別が A
    assert_equal 'A', res.types.first.code
    assert_equal 12, res.types.first.count
    assert_equal 6, res.types.size
    assert_equal 30, res.types.sum(&:count)
    area = res.rows.sum { |r| r.width * r.height } / 1e6
    assert_in_delta area, res.totals['area'], 1e-3
    assert_in_delta area * 0.03, res.totals['volume'], 1e-4
    assert_in_delta res.totals['volume'] * 2.7 * 1000, res.totals['weight'], 0.05 * 30 # 1 枚ごとに 0.1kg で丸め
    assert(res.rows.all? { |r| r.shape == '矩形' && r.type })
  end

  def test_l_shape_curved_and_corner_notes
    doc = flat_doc
    eng = EditEngine.new(doc)
    eng.apply(eng.plan_delete(eng.pick(v2(900, 300), 3)))
    eng.apply(eng.plan_delete(eng.pick(v2(450, 600), 3)))
    res = Schedule.build(doc)
    l = res.rows.find { |r| r.shape == '異形' }
    assert l
    assert_equal 28, res.totals['count']

    prof = Profile.new([LineSegment2.new(v2(0, 0), v2(2000, 0)),
                        ArcSegment2.new(v2(2000, 500), 500, -Math::PI / 2, Math::PI / 2),
                        LineSegment2.new(v2(2500, 500), v2(2500, 2500))])
    res = Schedule.build(build_doc(SurfaceDefinition.rectangle(prof, 0, 600)))
    assert(res.rows.any? { |r| r.shape.include?('曲面 R500') })

    box = Profile.new([LineSegment2.new(v2(0, 0), v2(1500, 0)), LineSegment2.new(v2(1500, 0), v2(1500, 1500))])
    res = Schedule.build(build_doc(SurfaceDefinition.rectangle(box, 0, 600), 'corner_mode' => 'win_prev'))
    assert_equal 2, res.rows.count { |r| r.note.include?('出隅左勝ち') }
  end

  def test_csv
    res = Schedule.build(flat_doc)
    csv = Schedule.to_csv(res, 'StoneLayout_001')
    assert csv.start_with?("﻿")
    lines = csv.delete_prefix("﻿").split("\r\n")
    assert_equal 'StoneLayout_001', lines[0]
    assert_includes lines, '種別,形状,幅(mm),高さ(mm),厚さ(mm),枚数,表面積計(m2),体積計(m3),重量計(kg),備考,石番号'
    detail = lines.index { |l| l.start_with?('石番号,') }
    assert_equal 30, lines[(detail + 1)..].size
    assert_match(/\AStone_0001,[A-F],矩形,896,596,30,/, lines[detail + 1])
    assert_equal '"a,b"', Schedule.csv_cell('a,b')
    assert_equal 'AA', Schedule.type_code(26)
  end

  def test_density_setting_and_detached
    doc = flat_doc('density' => 2.3)
    doc.panels.values.first.state = Panel::DETACHED
    res = Schedule.build(doc)
    assert_equal 29, res.totals['count']
    assert_equal 1, res.detached
    assert_in_delta res.totals['volume'] * 2.3 * 1000, res.totals['weight'], 0.05 * 29
    assert_match(/負/, Settings.new('density' => -1).validate.join)
  end
end
