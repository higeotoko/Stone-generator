# frozen_string_literal: true

module Higeotoko::StoneLayout::Core
  # 文書 → 各石の実輪郭とメッシュ。SketchUp に触る前に全数を検証できる。
  class StoneGeometry
    Built = Struct.new(:panel_id, :outline, :mesh, :face_area, :volume)

    def initialize(doc)
      @doc = doc
      s = doc.settings
      @s_in, @s_out = s.s_range
      @mesher = StoneMesh.new(doc.surface, @s_in, @s_out, **s.arc_options)
    end

    def build(panel)
      outline = OutlineBuilder.build(panel.points, panel.flags, @doc.settings)
      ends = CornerJoint.end_overrides(@doc.surface, @doc.settings, panel.points, outline)
      mesh = @mesher.build(outline, ends)
      errs = mesh.manifold_errors
      raise GeometryError.new("石の形状が閉じません（#{errs.size}辺）", panel.id) unless errs.empty?

      vol = mesh.volume
      raise GeometryError.new('石の体積が不正です', panel.id) unless vol.positive?

      Built.new(panel.id, outline, mesh, Polygon.area(outline), vol)
    rescue GeometryError => e
      raise GeometryError.new("Stone_#{format('%04d', panel.label)}: #{e.message}", panel.id)
    end

    # ids の全石を作る → [built_list, errors]
    def build_many(ids)
      built = []
      errors = []
      ids.each do |id|
        panel = @doc.panels[id]
        next unless panel && !panel.detached?

        built << build(panel)
      rescue GeometryError => e
        errors << e
      end
      [built, errors]
    end
  end
end
