# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../support/fake_view'
require_relative '../../src/stone_layout_generator/sketchup/units'
require_relative '../../src/stone_layout_generator/sketchup/face_reader'

# 選択面の読み取り（SketchUp の Face をまねた最小のモック）
class TestFaceReader < Minitest::Test
  include StoneTestHelpers
  SL = Higeotoko::StoneLayout

  FakeLoop = Struct.new(:vertices)

  class WallFace < Sketchup::Face
    attr_reader :loops, :outer_loop

    def initialize(outer, holes = [], normal = [0, -1, 0])
      pts = outer.map { |x, y, z| Geom::Point3d.new(x / 25.4, y / 25.4, z / 25.4) }
      super(pts)
      @n = Geom::Vector3d.new(*normal)
      mk = ->(list) { FakeLoop.new(list.map { |x, y, z| Sketchup::Vertex.new(Geom::Point3d.new(x / 25.4, y / 25.4, z / 25.4)) }) }
      @outer_loop = mk.call(outer)
      @loops = [@outer_loop] + holes.map { |h| mk.call(h) }
    end

    def normal
      @n
    end

    def vertices
      @outer_loop.vertices
    end

    def edges
      []
    end
  end

  Selection = Struct.new(:items) do
    def grep(k)
      items.grep(k)
    end
  end

  def wall_with_window
    WallFace.new([[0, 0, 0], [5000, 0, 0], [5000, 0, 3000], [0, 0, 3000]],
                 [[[1500, 0, 900], [2700, 0, 900], [2700, 0, 2100], [1500, 0, 2100]]])
  end

  def test_single_face_with_window
    res = SL::FaceReader.read(Selection.new([wall_with_window]))
    surf = res.surface
    assert_in_delta 5000, surf.u_length
    assert_equal 1, surf.holes.size
    assert_equal [1500.0, 900.0, 2700.0, 2100.0], Polygon.bbox(surf.holes.first)
    assert(res.warnings.any? { |w| w.include?('開口部を 1 か所') })
    doc = LayoutBuilder.build(surf, Settings.new).first
    assert_nil doc.panel_at(v2(2100, 1500))
  end

  def test_face_normal_decides_u_direction
    # 壁の外側が +y（法線 +y）なら、外から見て左→右は -x 方向
    f = WallFace.new([[0, 0, 0], [5000, 0, 0], [5000, 0, 3000], [0, 0, 3000]], [], [0, 1, 0])
    surf = SL::FaceReader.read(Selection.new([f])).surface
    p0 = surf.point3d(0, 0)
    assert_in_delta 5000, p0[0]
    assert_in_delta 0, surf.point3d(5000, 0)[0]
  end

  def test_rejects_non_vertical_only
    floor = WallFace.new([[0, 0, 0], [100, 0, 0], [100, 100, 0], [0, 100, 0]], [], [0, 0, 1])
    assert_raises(InvalidInput) { SL::FaceReader.read(Selection.new([floor])) }
    assert_raises(InvalidInput) { SL::FaceReader.read(Selection.new([])) }
  end
end
