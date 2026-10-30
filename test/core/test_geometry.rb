# frozen_string_literal: true

require_relative '../test_helper'

class TestGeometry < Minitest::Test
  include StoneTestHelpers

  def rect(x0, y0, x1, y1)
    [v2(x0, y0), v2(x1, y0), v2(x1, y1), v2(x0, y1)]
  end

  def test_polygon_basics
    sq = rect(0, 0, 10, 10)
    assert_in_delta 100, Polygon.signed_area(sq)
    assert Polygon.contains?(sq, v2(5, 5))
    refute Polygon.contains?(sq, v2(15, 5))
    ip = Polygon.interior_point(sq)
    assert Polygon.contains?(sq, ip)
    assert Polygon.simple?(sq)
    refute Polygon.simple?([v2(0, 0), v2(10, 10), v2(10, 0), v2(0, 10)])
  end

  def test_simplify_and_key_ignore_t_vertices
    a = [v2(0, 0), v2(5, 0), v2(10, 0), v2(10, 10), v2(0, 10)]
    b = [v2(10, 10), v2(0, 10), v2(0, 0), v2(10, 0)]
    assert_equal Polygon.canonical_key(a, %w[J J J J J]), Polygon.canonical_key(b, %w[J J J J])
    refute_equal Polygon.canonical_key(a, %w[B J J J J]), Polygon.canonical_key(b, %w[J J J J])
  end

  def test_min_extents_of_l_shape
    l = [v2(0, 0), v2(1800, 0), v2(1800, 600), v2(900, 600), v2(900, 1200), v2(0, 1200)]
    w, h = Polygon.min_extents(l)
    assert_in_delta 900, w
    assert_in_delta 600, h
  end

  def test_arrangement_t_and_cross_junctions
    arr = Arrangement.new
    Polygon.edges(rect(0, 0, 20, 10)).each { |a, b| arr.add_segment(a, b, :boundary) }
    arr.add_segment(v2(0, 5), v2(20, 5), 1)     # 通り横目地
    arr.add_segment(v2(10, 0), v2(10, 5), 2)    # T字（下から）
    arr.add_segment(v2(5, 5), v2(5, 10), 3)     # T字（上から）
    arr.compute
    assert_equal 4, arr.faces.size
    assert_empty arr.dangling
    assert_in_delta 200, arr.faces.sum(&:area)
  end

  def test_arrangement_reports_dangling
    arr = Arrangement.new
    Polygon.edges(rect(0, 0, 20, 10)).each { |a, b| arr.add_segment(a, b, :boundary) }
    arr.add_segment(v2(10, 0), v2(10, 6), 1)
    arr.compute
    assert_equal 1, arr.faces.size
    refute_empty arr.dangling
  end

  def test_arrangement_collinear_overlap
    arr = Arrangement.new
    Polygon.edges(rect(0, 0, 20, 10)).each { |a, b| arr.add_segment(a, b, :boundary) }
    arr.add_segment(v2(0, 5), v2(12, 5), 1)
    arr.add_segment(v2(8, 5), v2(20, 5), 2)
    arr.compute
    assert_equal 2, arr.faces.size
  end

  def test_inset_rectangle_and_l
    out = OutlineBuilder.inset(rect(0, 0, 900, 600), [4, 4, 4, 4])
    assert_in_delta 892 * 592, Polygon.area(out)
    l = [v2(0, 0), v2(1800, 0), v2(1800, 600), v2(900, 600), v2(900, 1200), v2(0, 1200)]
    out = OutlineBuilder.inset(l, [4] * 6)
    assert Polygon.simple?(out)
    assert_in_delta 1792 * 592 + 892 * 600, Polygon.area(out), 1e-6
  end

  def test_inset_step_between_different_offsets_on_collinear_edges
    pts = [v2(0, 0), v2(50, 0), v2(100, 0), v2(100, 100), v2(0, 100)]
    out = OutlineBuilder.inset(pts, [0, 4, 4, 4, 4])
    assert_equal 6, out.size
    assert Polygon.simple?(out)
  end

  def test_inset_collapses_tiny_stone
    assert_raises(GeometryError) { OutlineBuilder.inset(rect(0, 0, 6, 600), [4, 4, 4, 4]) }
  end

  def test_intersection_area
    assert_in_delta 25, PolygonOps.intersection_area(rect(0, 0, 10, 10), rect(5, 5, 15, 15))
    assert_in_delta 0, PolygonOps.intersection_area(rect(0, 0, 10, 10), rect(20, 20, 30, 30))
  end

  def test_spatial_grid
    g = SpatialGrid.new(100)
    g.insert(1, [0, 0, 10, 10])
    g.insert(2, [500, 500, 510, 510])
    assert_equal [1], g.query([5, 5, 6, 6])
    g.remove(1)
    assert_empty g.query([5, 5, 6, 6])
  end

  # プレビュー・ハイライト用の 3D 線（縦目地が長さゼロにならないこと）
  def test_polyline3d_vertical_horizontal_and_arc
    surf = SurfaceDefinition.flat_wall(5000, 3000)
    pts = surf.polyline3d(v2(900, 0), v2(900, 600))
    assert_equal [[900.0, 0.0, 0.0], [900.0, 0.0, 600.0]], pts
    pts = surf.polyline3d(v2(0, 600), v2(5000, 600))
    assert_equal [[0.0, 0.0, 600.0], [5000.0, 0.0, 600.0]], pts
    arc = SurfaceDefinition.rectangle(Profile.new([ArcSegment2.new(v2(0, 0), 1000, 0, Math::PI / 2)]), 0, 600)
    pts = arc.polyline3d(v2(0, 300), v2(Math::PI * 500, 300))
    assert pts.size > 3
    pts.each { |p| assert_in_delta 1000, Math.hypot(p[0], p[1]), 1e-9 }
  end

  def test_profile_project
    prof = Profile.new([LineSegment2.new(v2(0, 0), v2(2000, 0)),
                        ArcSegment2.new(v2(2000, 500), 500, -Math::PI / 2, Math::PI / 2),
                        LineSegment2.new(v2(2500, 500), v2(2500, 2500))])
    u, d = prof.project(v2(900, -300)) # 壁の手前 300 にある別の箱の角
    assert_in_delta 900, u
    assert_in_delta 300, d
    q = v2(2000, 500) + v2(Math.cos(-Math::PI / 4), Math.sin(-Math::PI / 4)) * 700
    u, d = prof.project(q)
    assert_in_delta 2000 + Math::PI * 500 / 4, u, 1e-9
    assert_in_delta 200, d, 1e-9
    u, = prof.project(v2(2700, 1500))
    assert_in_delta 2000 + Math::PI * 250 + 1000, u, 1e-9
  end
end
