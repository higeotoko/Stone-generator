# frozen_string_literal: true

module Higeotoko::StoneLayout::Core
  # 編集計画中の目地線分（文書を書き換えずに差分だけ持つ）
  class WorkingSet
    attr_reader :changed, :touched

    def initialize(doc)
      @doc = doc
      @changed = {} # id => JointSegment or nil(削除)
      @next_id = doc.next_segment_id
      @touched = nil
    end

    def next_id
      id = @next_id
      @next_id += 1
      id
    end

    def next_segment_id
      @next_id
    end

    def [](id)
      @changed.key?(id) ? @changed[id] : @doc.segments[id]
    end

    def put(seg)
      @changed[seg.id] = LayoutBuilder.normalize_segment(@doc, seg)
    end

    def remove(id)
      @changed[id] = nil
    end

    def touch(*points)
      box = Geom2.bbox(points)
      @touched = Geom2.bbox_union(@touched, box)
    end

    # bbox 付近の線分 → [Placed, ...]（周期方向のコピーを含む）
    def near(box)
      out = []
      @doc.shifts.each do |dx|
        q = Geom2.bbox_shift_x(box, -dx)
        ids = @doc.segment_grid.query(q)
        ids.concat(@changed.keys)
        ids.uniq.each do |id|
          seg = self[id]
          next unless seg && Geom2.bbox_intersect?(seg.bbox, q)

          out << Placed.new(seg, dx)
        end
      end
      out
    end
  end
end
