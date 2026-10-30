# frozen_string_literal: true

module Higeotoko::StoneLayout::Core
  # 目地中心線（Layout Graph の基本要素）。
  #
  # 割付の正規データは「目地線分の集合 + 外周境界」。
  # 石の領域（Panel）はこの集合の平面分割として導かれる。
  #   - T字接続: 線分の端点が別の線分の途中に乗っている
  #   - 十字接続: 2本の線分が交差、または4本の線分が1点に集まる
  #   - 通り目地: 同一直線上で端点を共有する線分の連なり
  #
  # state: auto（自動生成） / manual（手動調整）。locked は独立フラグ。
  class JointSegment
    AUTO = 'auto'
    MANUAL = 'manual'
    LOCKED = 'locked'

    attr_reader :id, :a, :b, :state, :locked

    def initialize(id, a, b, state: AUTO, locked: false)
      @id = id
      # 向きを正規化（縦は下→上、横は左→右）
      if (b.x - a.x).abs <= Tol::POINT ? b.y < a.y : b.x < a.x
        a, b = b, a
      end
      @a = a
      @b = b
      @state = state
      @locked = locked
    end

    def with(a: @a, b: @b, state: @state, locked: @locked, id: @id)
      JointSegment.new(id, a, b, state: state, locked: locked)
    end

    # 編集状態（AUTO / MANUAL / LOCKED）
    def status
      @locked ? LOCKED : @state
    end

    def orientation
      if (b.x - a.x).abs <= Tol::POINT
        :v
      elsif (b.y - a.y).abs <= Tol::POINT
        :h
      else
        :free
      end
    end

    def length
      @a.dist(@b)
    end

    def bbox
      [[@a.x, @b.x].min, [@a.y, @b.y].min, [@a.x, @b.x].max, [@a.y, @b.y].max]
    end

    def shift_x(dx)
      dx.zero? ? self : with(a: @a.shift_x(dx), b: @b.shift_x(dx))
    end

    def to_h
      h = { 'id' => @id, 'a' => @a.to_a, 'b' => @b.to_a, 'state' => @state }
      h['locked'] = true if @locked
      h
    end

    def self.from_h(h)
      new(h['id'], Vec2.new(*h['a']), Vec2.new(*h['b']), state: h['state'] || AUTO, locked: h['locked'] ? true : false)
    end

    def inspect
      "#<Joint #{@id} #{@a}-#{@b} #{status}>"
    end
  end

  # 線分と、それを置く座標フレームのずれ（周期方向 dx）の組
  Placed = Struct.new(:seg, :dx) do
    def a
      seg.a.shift_x(dx)
    end

    def b
      seg.b.shift_x(dx)
    end

    def id
      seg.id
    end
  end
end
