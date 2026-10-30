# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../src/stone_layout_generator/core'

Higeotoko::StoneLayout::Core::Log.quiet = true

module StoneTestHelpers
  include Higeotoko::StoneLayout::Core

  def v2(x, y)
    Vec2.new(x, y)
  end

  def build_doc(surface, settings = {})
    LayoutBuilder.build(surface, Settings.new(settings)).first
  end

  def flat_doc(settings = {})
    build_doc(SurfaceDefinition.flat_wall(5000, 3000), settings)
  end

  # 展開座標 (u, v) を含む石
  def panel_at(doc, u, v)
    doc.panel_at(v2(u, v))&.first
  end

  def snapshot(doc)
    doc.panels.transform_values(&:shape_key)
  end

  # 平面分割を全体でやり直した結果が、局所更新した文書と一致するか
  def assert_consistent(doc)
    res = doc.extractor.extract_all(doc.segments.values)
    assert_empty res.dangling, 'dangling joints'
    full = res.faces.map { |f| Polygon.canonical_key(Polygon.translate_x(f.points, doc.extractor.normalize_shift(f.points)), f.flags) }.sort
    local = doc.panels.values.map(&:shape_key).sort
    assert_equal full, local, 'local update diverged from full recompute'
  end

  def assert_solid(doc, ids = doc.panels.keys)
    geo = StoneGeometry.new(doc)
    built, errors = geo.build_many(ids)
    assert_empty errors.map(&:message)
    built.each do |b|
      assert b.mesh.manifold?, "panel #{b.panel_id} not manifold"
      assert b.volume.positive?
    end
    built
  end
end
