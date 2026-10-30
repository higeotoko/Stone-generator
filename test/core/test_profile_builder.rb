# frozen_string_literal: true

require_relative '../test_helper'

class TestProfileBuilder < Minitest::Test
  include StoneTestHelpers

  def arc_points(c, r, a0, a1, n)
    (0..n).map { |i| a = a0 + (a1 - a0) * i / n; c + v2(Math.cos(a), Math.sin(a)) * r }
  end

  def test_arc_hint_is_used_exactly
    pts = arc_points(v2(2000, 500), 500, -Math::PI / 2, 0, 12)
    runs = [{ points: [v2(0, 0), v2(2000, 0)] },
            { points: pts, arc: { center: v2(2000, 500), radius: 500.0 } },
            { points: [v2(2500, 500), v2(2500, 2500)] }]
    b = ProfileBuilder.new
    prof = b.build(runs)
    assert_equal %w[line arc line], prof.segments.map(&:type)
    assert_in_delta 4000 + Math::PI * 250, prof.length, 1e-6
    assert_empty b.warnings
  end

  def test_arc_estimated_from_polyline_with_warning
    pts = [v2(0, 0)] + arc_points(v2(2000, 500), 500, -Math::PI / 2, 0, 12) + [v2(2500, 2500)]
    b = ProfileBuilder.new
    prof = b.build([{ points: pts }])
    assert_equal %w[line arc line], prof.segments.map(&:type)
    assert_in_delta 500, prof.segments[1].radius, 1.0
    assert_match(/推定/, b.warnings.first)
  end

  def test_collinear_edges_merged_and_folds_kept
    b = ProfileBuilder.new
    prof = b.build([{ points: [v2(0, 0), v2(500, 0), v2(1000, 0), v2(1000, 800)] }])
    assert_equal 2, prof.segments.size
    assert_equal [1000.0], prof.corners
  end

  def test_full_circle_hint
    pts = arc_points(v2(0, 0), 1000, 0, 2 * Math::PI, 24)
    prof = ProfileBuilder.new.build([{ points: pts, arc: { center: v2(0, 0), radius: 1000.0 } }])
    assert prof.closed?
    assert_in_delta 2 * Math::PI * 1000, prof.length, 1e-6
  end
end
