# frozen_string_literal: true

module Higeotoko::StoneLayout::Core
  # 1つの割付グループの全データ（Surface + Layout Graph + Panels + Settings）。
  # SketchUp の形状はこの文書から再生成できる。
  class LayoutDocument
    GRID_CELL = 600.0

    attr_reader :id, :surface, :segments, :panels, :warnings
    attr_accessor :settings, :revision, :next_segment_id, :next_panel_id, :next_label

    def initialize(id:, surface:, settings:, segments: {}, panels: {}, revision: 0,
                   next_segment_id: nil, next_panel_id: nil, next_label: nil)
      @id = id
      @surface = surface
      @settings = settings
      @segments = segments
      @panels = panels
      @revision = revision
      @next_segment_id = next_segment_id || ((segments.keys.max || 0) + 1)
      @next_panel_id = next_panel_id || ((panels.keys.max || 0) + 1)
      @next_label = next_label || ((panels.values.map(&:label).max || 0) + 1)
      @warnings = []
      invalidate_indexes
    end

    def periodic?
      @surface.periodic?
    end

    def period
      @surface.period
    end

    def extractor
      @extractor ||= FaceExtractor.new(@surface)
    end

    def invalidate_indexes
      @segment_grid = nil
      @panel_grid = nil
      @edge_map = nil
    end

    def segment_grid
      @segment_grid ||= begin
        g = SpatialGrid.new(GRID_CELL)
        @segments.each_value { |s| g.insert(s.id, s.bbox) }
        g
      end
    end

    def panel_grid
      @panel_grid ||= begin
        g = SpatialGrid.new(GRID_CELL)
        @panels.each_value { |p| g.insert(p.id, p.bbox) }
        g
      end
    end

    # 周期方向の候補ずれ
    def shifts
      periodic? ? [0.0, -period, period] : [0.0]
    end

    # bbox 付近の石 → [[panel, dx], ...]（panel.points + dx がクエリ座標系）
    def panels_near(box)
      found = {}
      shifts.each do |dx|
        panel_grid.query(Geom2.bbox_shift_x(box, -dx)).each do |pid|
          found[pid] = dx unless found.key?(pid)
        end
      end
      found.map { |pid, dx| [@panels[pid], dx] }
    end

    def panel_at(p)
      panels_near([p.x, p.y, p.x, p.y]).each do |panel, dx|
        return [panel, dx] if Polygon.contains?(Polygon.translate_x(panel.points, dx), p)
      end
      nil
    end

    # ---- 辺 → 両側の石 -----------------------------------------------------

    def edge_key(a, b)
      if periodic?
        dx = -((([a.x, b.x].min + Tol::POINT) / period).floor * period)
        a = a.shift_x(dx)
        b = b.shift_x(dx)
      end
      q = Tol::KEY
      ka = [(a.x / q).round, (a.y / q).round]
      kb = [(b.x / q).round, (b.y / q).round]
      (ka <=> kb) <= 0 ? [ka, kb] : [kb, ka]
    end

    def edge_map
      @edge_map ||= begin
        m = Hash.new { |h, k| h[k] = [] }
        @panels.each_value { |p| add_panel_edges(m, p) }
        m
      end
    end

    def panels_on_edge(a, b)
      edge_map.fetch(edge_key(a, b), [])
    end

    # ---- 変更の反映（EditEngine から呼ばれる） ------------------------------

    def put_segment(seg)
      @segments[seg.id] = seg
      segment_grid.insert(seg.id, seg.bbox) if @segment_grid
    end

    def delete_segment(id)
      @segments.delete(id)
      @segment_grid&.remove(id)
    end

    def put_panel(panel)
      old = @panels[panel.id]
      remove_panel_edges(old) if old && @edge_map
      @panels[panel.id] = panel
      @panel_grid&.insert(panel.id, panel.bbox)
      add_panel_edges(@edge_map, panel) if @edge_map
    end

    def update_panel_shape(panel, points, flags)
      remove_panel_edges(panel) if @edge_map
      panel.set_shape(points, flags)
      @panel_grid&.insert(panel.id, panel.bbox)
      add_panel_edges(@edge_map, panel) if @edge_map
    end

    def delete_panel(id)
      old = @panels.delete(id)
      return unless old

      @panel_grid&.remove(id)
      remove_panel_edges(old) if @edge_map
    end

    def allocate_label
      l = @next_label
      @next_label += 1
      l
    end

    def manual_edits?
      @segments.values.any? { |s| s.state != JointSegment::AUTO || s.locked }
    end

    def stats
      {
        'stones' => @panels.size,
        'joints' => @segments.size,
        'manual_joints' => @segments.values.count { |s| s.state == JointSegment::MANUAL },
        'locked_joints' => @segments.values.count(&:locked),
        'face_area_m2' => (@panels.values.sum(&:area) / 1.0e6).round(3)
      }
    end

    private

    def add_panel_edges(map, panel)
      panel.edges.each { |a, b| map[edge_key(a, b)] << panel.id }
    end

    def remove_panel_edges(panel)
      panel.edges.each do |a, b|
        k = edge_key(a, b)
        list = @edge_map[k]
        list.delete(panel.id)
        @edge_map.delete(k) if list.empty?
      end
    end
  end
end
