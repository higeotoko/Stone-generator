# frozen_string_literal: true

module Higeotoko::StoneLayout::Core
  # 石1枚の定義。
  #
  # points: 目地中心線で囲まれた領域（展開座標, CCW）。平面分割の生の閉路なので、
  #         隣の石の目地が当たる T 字点も頂点として含む（＝辺が「部分目地」の単位）。
  # flags:  points[i] -> points[i+1] の辺種別。'J'=目地 / 'B'=外周境界
  # id:     永続ID（内部参照用）。label: 表示番号（Stone_0001 の番号）
  class Panel
    ACTIVE = 'active'
    DETACHED = 'detached' # ジェネレーターから切り離された石

    attr_reader :id, :points, :flags
    attr_accessor :label, :state, :material

    def initialize(id, points, flags, label: nil, state: ACTIVE, material: nil)
      raise ArgumentError, 'points/flags size mismatch' unless points.size == flags.size

      @id = id
      @points = points
      @flags = flags
      @label = label || id
      @state = state
      @material = material
    end

    def detached?
      @state == DETACHED
    end

    def set_shape(points, flags)
      @points = points
      @flags = flags
      @bbox = nil
      @key = nil
    end

    def bbox
      @bbox ||= Polygon.bbox(@points)
    end

    def area
      Polygon.area(@points)
    end

    # 形状比較キー（T字点の有無に依存しない）
    def shape_key
      @key ||= Polygon.canonical_key(@points, @flags)
    end

    def edges
      Polygon.edges(@points)
    end

    def to_h
      h = { 'id' => @id, 'label' => @label, 'points' => @points.map(&:to_a), 'flags' => @flags.join }
      h['state'] = @state unless @state == ACTIVE
      h['material'] = @material if @material
      h
    end

    def self.from_h(h)
      new(h['id'], h['points'].map { |a| Vec2.new(*a) }, h['flags'].chars,
          label: h['label'], state: h['state'] || ACTIVE, material: h['material'])
    end
  end
end
