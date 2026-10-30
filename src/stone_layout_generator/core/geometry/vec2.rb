# frozen_string_literal: true

module Higeotoko::StoneLayout::Core
  # 2次元ベクトル。割付の展開座標 (u, v) にも、水平断面 (x, y) にも使う。
  class Vec2
    attr_reader :x, :y

    def self.[](x, y)
      new(x, y)
    end

    def initialize(x, y)
      @x = x.to_f
      @y = y.to_f
    end

    alias u x
    alias v y

    def +(other)
      Vec2.new(@x + other.x, @y + other.y)
    end

    def -(other)
      Vec2.new(@x - other.x, @y - other.y)
    end

    def *(other)
      Vec2.new(@x * other, @y * other)
    end

    def /(other)
      Vec2.new(@x / other, @y / other)
    end

    def -@
      Vec2.new(-@x, -@y)
    end

    def dot(other)
      @x * other.x + @y * other.y
    end

    def cross(other)
      @x * other.y - @y * other.x
    end

    def length2
      @x * @x + @y * @y
    end

    def length
      Math.sqrt(length2)
    end

    def normalize
      l = length
      raise ZeroDivisionError, 'zero-length vector' if l.zero?

      Vec2.new(@x / l, @y / l)
    end

    # 左法線（進行方向に対して左向き）。CCW 多角形では内側を向く。
    def left_normal
      Vec2.new(-@y, @x)
    end

    def dist(other)
      dx = @x - other.x
      dy = @y - other.y
      Math.sqrt(dx * dx + dy * dy)
    end

    def near?(other, tol = Tol::POINT)
      dist(other) <= tol
    end

    def shift_x(dx)
      dx.zero? ? self : Vec2.new(@x + dx, @y)
    end

    def to_a
      [@x, @y]
    end

    def ==(other)
      other.is_a?(Vec2) && other.x == @x && other.y == @y
    end
    alias eql? ==

    def hash
      [@x, @y].hash
    end

    def to_s
      "(#{@x.round(3)}, #{@y.round(3)})"
    end
    alias inspect to_s
  end
end
