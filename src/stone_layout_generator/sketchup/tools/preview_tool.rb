# frozen_string_literal: true

module Higeotoko
  module StoneLayout
    # 生成前の割付プレビュー。ジオメトリは作らず、目地中心線を View に描くだけ。
    class PreviewTool
      attr_reader :doc, :error, :active

      def initialize(surface)
        @surface = surface
        @doc = nil
        @error = nil
        @transform = Sketchup.active_model.edit_transform
      end

      # → [stats_hash, warnings] / 失敗時は例外
      def update(settings)
        @doc, stats = Core::LayoutBuilder.build(@surface, settings)
        @error = nil
        Sketchup.active_model.active_view.invalidate
        [stats.merge('stones' => @doc.panels.size), @doc.warnings]
      rescue Core::Error => e
        @doc = nil
        @error = e.message
        Sketchup.active_model.active_view.invalidate
        raise
      end

      def activate
        @active = true
        Sketchup.status_text = '石割付プレビュー（ダイアログで寸法を調整して［生成］）'
      end

      def deactivate(view)
        @active = false
        view.invalidate
      end

      def onCancel(_reason, _view)
        Sketchup.active_model.select_tool(nil)
      end

      def draw(view)
        s = 1.0
        view.line_stipple = ''
        view.drawing_color = [255, 120, 0]
        view.line_width = 2
        Core::Polygon.edges(@surface.boundary).each { |a, b| line(view, a, b, s) }
        @surface.holes.each { |h| Core::Polygon.edges(h).each { |a, b| line(view, a, b, s) } }
        return unless @doc

        view.drawing_color = [0, 120, 255]
        view.line_width = 1
        @doc.segments.each_value { |seg| line(view, seg.a, seg.b, s) }
      end

      def getExtents
        bb = Geom::BoundingBox.new
        @surface.boundary.each do |p|
          bb.add(Units.point_in(@surface.point3d(p.x, p.y, 0)).transform(@transform))
        end
        bb
      end

      private

      def line(view, a, b, s)
        pts = @surface.polyline3d(a, b, s).map { |p| Units.point_in(p).transform(@transform) }
        view.draw(GL_LINE_STRIP, pts) if pts.size > 1
      end
    end
  end
end
