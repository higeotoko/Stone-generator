# frozen_string_literal: true

require_relative '../test_helper'

# 仕様 18-7: 保存・再読み込み・再編集
class TestPersistence < Minitest::Test
  include StoneTestHelpers

  def test_roundtrip_keeps_edits_locks_and_thickness
    doc = flat_doc('pattern' => 'running', 'thickness' => 35)
    eng = EditEngine.new(doc)
    eng.apply(eng.plan_move([eng.pick(v2(900, 300), 3)], 100))
    eng.apply(eng.plan_move([eng.pick(v2(100, 1200), 3)], -30, mode: :through))
    eng.apply(eng.plan_lock([eng.pick(v2(1800, 300), 3)], true))
    eng.apply(eng.plan_add(v2(2000, 2700), :v))
    json = Serializer.dump(doc)

    loaded = Serializer.load(json)
    assert_equal json, Serializer.dump(loaded)
    assert_equal 35.0, loaded.settings['thickness']
    assert_equal doc.segments.values.map(&:status).sort, loaded.segments.values.map(&:status).sort
    assert(loaded.segments.values.any? { |s| s.status == JointSegment::LOCKED })
    assert_equal snapshot(doc), snapshot(loaded)

    # 再読み込み後もそのまま編集を継続できる
    eng2 = EditEngine.new(loaded)
    plan = eng2.plan_move([eng2.pick(v2(1000, 300), 3)], 20)
    assert plan.ok?, plan.errors.inspect
    eng2.apply(plan)
    assert_consistent(loaded)
    assert_equal doc.next_label, loaded.next_label
  end

  def test_column_roundtrip
    prof = Profile.new([ArcSegment2.new(v2(0, 0), 1000, 0, 2 * Math::PI)])
    doc = build_doc(SurfaceDefinition.rectangle(prof, 0, 1200), 'end_mode' => 'uniform')
    loaded = Serializer.load(Serializer.dump(doc))
    assert loaded.periodic?
    assert_in_delta doc.period, loaded.period
  end

  def test_corrupt_data_raises_persistence_error
    assert_raises(PersistenceError) { Serializer.load('{not json') }
    assert_raises(PersistenceError) { Serializer.load('{"schema": 1}') }
    h = Serializer.to_h(flat_doc)
    h['schema'] = 999
    assert_raises(PersistenceError) { Serializer.from_h(h) }
    h = Serializer.to_h(flat_doc)
    h['surface']['profile']['segments'] = []
    assert_raises(PersistenceError) { Serializer.from_h(h) }
  end
end
