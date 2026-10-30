# frozen_string_literal: true

module Higeotoko::StoneLayout::Core
  # bbox を持つ要素の一様グリッド索引。数千枚規模でも近傍検索を O(1) 近くに保つ。
  class SpatialGrid
    def initialize(cell = 500.0)
      @cell = cell.to_f
      @cells = Hash.new { |h, k| h[k] = [] }
      @boxes = {}
    end

    def insert(id, box)
      remove(id) if @boxes.key?(id)
      @boxes[id] = box
      each_cell(box) { |k| @cells[k] << id }
    end

    def remove(id)
      box = @boxes.delete(id)
      return unless box

      each_cell(box) do |k|
        list = @cells[k]
        list.delete(id)
        @cells.delete(k) if list.empty?
      end
    end

    def query(box)
      found = {}
      each_cell(box) do |k|
        list = @cells.fetch(k, nil)
        next unless list

        list.each do |id|
          next if found.key?(id)

          found[id] = true if Geom2.bbox_intersect?(@boxes[id], box)
        end
      end
      found.keys
    end

    def size
      @boxes.size
    end

    private

    def each_cell(box)
      x0 = (box[0] / @cell).floor
      x1 = (box[2] / @cell).floor
      y0 = (box[1] / @cell).floor
      y1 = (box[3] / @cell).floor
      (x0..x1).each do |ix|
        (y0..y1).each { |iy| yield((ix << 32) ^ (iy & 0xffffffff)) }
      end
    end
  end
end
