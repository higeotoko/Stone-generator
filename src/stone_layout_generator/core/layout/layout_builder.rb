# frozen_string_literal: true

module Higeotoko::StoneLayout::Core
  # 自動割付から LayoutDocument を組み立てる
  module LayoutBuilder
    module_function

    def build(surface, settings, id: nil)
      settings.validate!
      auto = AutoLayout.new(surface, settings).generate
      doc = LayoutDocument.new(id: id || new_id, surface: surface, settings: settings)
      auto.segments.each do |a, b|
        seg = JointSegment.new(doc.next_segment_id, a, b)
        doc.next_segment_id += 1
        doc.put_segment(normalize_segment(doc, seg))
      end
      res = doc.extractor.extract_all(doc.segments.values)
      raise InvalidInput, '目地の端点が浮いています（割付が閉じません）' unless res.dangling.empty?

      faces = res.faces.sort_by { |f| [f.bbox[1].round(3), f.bbox[0].round(3)] }
      faces.each do |f|
        pts = Polygon.translate_x(f.points, doc.extractor.normalize_shift(f.points))
        panel = Panel.new(doc.next_panel_id, pts, f.flags, label: doc.allocate_label)
        doc.next_panel_id += 1
        doc.put_panel(panel)
      end
      doc.warnings.concat(auto.warnings)
      doc.warnings.concat(size_warnings(doc))
      [doc, auto.stats]
    end

    def normalize_segment(doc, seg)
      return seg unless doc.periodic?

      l = doc.period
      x = [seg.a.x, seg.b.x].min
      k = ((x + Tol::POINT) / l).floor
      seg.shift_x(-k * l)
    end

    def size_warnings(doc)
      s = doc.settings
      doc.panels.values.filter_map do |p|
        w, h = Polygon.min_extents(p.points)
        next nil unless w < s.min_pitch_u - Tol::POINT || h < s.min_pitch_v - Tol::POINT

        format('Stone_%04d が最小寸法未満です（%.1f x %.1f mm）', p.label, w, h)
      end
    end

    def new_id
      t = Time.now
      format('SL%<t>s%<r>04d', t: t.strftime('%Y%m%d%H%M%S'), r: rand(10_000))
    end
  end
end
