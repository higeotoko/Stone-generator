# frozen_string_literal: true

# SketchUp Ruby API の最小限のモック。
#
# アダプタ層（ModelStore / GeometryBuilder / LayoutController）が使う API だけを再現する。
# start_operation / commit_operation / abort_operation と Undo/Redo は、
# エンティティツリーと属性をまるごとスナップショットすることで模擬する
# （本物の SketchUp と同様に、Undo 後は古いエンティティ参照が無効になる）。
#
# これは実機の代わりではない。描画・ピック・HtmlDialog などは実機で確認すること。

module Geom
  class Point3d
    attr_reader :x, :y, :z

    def initialize(x = 0, y = 0, z = 0)
      @x = x.to_f
      @y = y.to_f
      @z = z.to_f
    end

    def transform(_t)
      self
    end

    def to_a
      [@x, @y, @z]
    end
  end

  class Vector3d < Point3d
    def dot(o)
      x * o.x + y * o.y + z * o.z
    end
  end

  class BoundingBox
    attr_reader :min, :max

    def initialize
      @min = nil
      @max = nil
    end

    def add(p)
      @min = @min ? Point3d.new([@min.x, p.x].min, [@min.y, p.y].min, [@min.z, p.z].min) : p
      @max = @max ? Point3d.new([@max.x, p.x].max, [@max.y, p.y].max, [@max.z, p.z].max) : p
      self
    end
  end
end

module Sketchup
  class Entity
    attr_reader :attrs

    def initialize
      @attrs = {}
      @valid = true
    end

    def valid?
      @valid
    end

    def invalidate!
      @valid = false
    end

    def set_attribute(dict, key, value)
      (@attrs[dict] ||= {})[key] = value
    end

    def get_attribute(dict, key, default = nil)
      d = @attrs[dict]
      d && d.key?(key) ? d[key] : default
    end

    def delete_attribute(dict)
      @attrs.delete(dict)
    end
  end

  class Vertex
    attr_reader :position

    def initialize(p)
      @position = p
    end
  end

  class Edge < Entity
    attr_accessor :soft, :smooth
    attr_reader :start, :end

    def initialize(a, b)
      super()
      @start = Vertex.new(a)
      @end = Vertex.new(b)
    end
  end

  class Face < Entity
    attr_reader :points

    def initialize(points)
      super()
      @points = points
    end

    def normal
      n = [0.0, 0.0, 0.0]
      k = @points.size
      k.times do |i|
        a = @points[i]
        b = @points[(i + 1) % k]
        n[0] += (a.y - b.y) * (a.z + b.z)
        n[1] += (a.z - b.z) * (a.x + b.x)
        n[2] += (a.x - b.x) * (a.y + b.y)
      end
      Geom::Vector3d.new(*n)
    end

    def reverse!
      @points = @points.reverse
      self
    end
  end

  class Entities
    include Enumerable

    attr_reader :list
    attr_accessor :model

    def initialize(model)
      @model = model
      @list = []
    end

    def each(&block)
      @list.each(&block)
    end

    def add_group
      g = Group.new(@model, self)
      @list << g
      g
    end

    def add_face(pts)
      f = Face.new(pts)
      @list << f
      pts.each_with_index do |a, i|
        b = pts[(i + 1) % pts.size]
        ka = a.to_a.map { |c| c.round(8) }
        kb = b.to_a.map { |c| c.round(8) }
        key = [ka, kb].sort
        next if @list.any? { |e| e.is_a?(Edge) && [e.start.position.to_a.map { |c| c.round(8) }, e.end.position.to_a.map { |c| c.round(8) }].sort == key }

        @list << Edge.new(a, b)
      end
      f
    end

    def clear!
      @list.each { |e| e.invalidate! if e.is_a?(Entity) }
      @list.clear
    end

    def remove(e)
      @list.delete(e)
    end

    def grep(klass)
      @list.select { |e| e.is_a?(klass) }
    end
  end

  class Group < Entity
    attr_accessor :name, :material
    attr_reader :entities, :parent_entities

    def initialize(model, parent)
      super()
      @model = model
      @parent_entities = parent
      @entities = Entities.new(model)
      @name = ''
    end

    attr_reader :model

    def erase!
      @parent_entities.remove(self)
      invalidate!
    end

    def transformation
      nil
    end

    def faces
      @entities.grep(Face)
    end

    def bounds
      bb = Geom::BoundingBox.new
      faces.each { |f| f.points.each { |p| bb.add(p) } }
      bb
    end
  end

  class Materials
    def initialize
      @m = {}
    end

    def [](name)
      @m[name]
    end

    def add(name)
      @m[name] = name
    end
  end

  class Model
    attr_reader :entities, :materials, :log

    def initialize
      @entities = Entities.new(self)
      @materials = Materials.new
      @undo = []
      @redo = []
      @op = nil
      @log = []
    end

    def active_entities
      @entities
    end

    def start_operation(name, _disable_ui = false)
      raise 'nested operation' if @op

      @op = [name, Marshal.dump(@entities)]
      @log << [:start, name]
    end

    def commit_operation
      name, snap = @op
      @undo << [name, snap]
      @redo.clear
      @op = nil
      @log << [:commit, name]
    end

    def abort_operation
      _name, snap = @op
      restore(snap)
      @op = nil
      @log << [:abort]
    end

    def undo
      name, snap = @undo.pop
      @redo << [name, Marshal.dump(@entities)]
      restore(snap)
    end

    def redo
      name, snap = @redo.pop
      @undo << [name, Marshal.dump(@entities)]
      restore(snap)
    end

    private

    # 本物と同様、Undo 前の参照は無効にし、エンティティは別オブジェクトとして復元する
    def restore(snap)
      invalidate_tree(@entities)
      ents = Marshal.load(snap)
      ents.list.each { |e| e.instance_variable_set(:@parent_entities, @entities) if e.is_a?(Group) }
      relink(ents)
      @entities.list.replace(ents.list)
    end

    def invalidate_tree(ents)
      ents.each do |e|
        e.invalidate! if e.is_a?(Entity)
        invalidate_tree(e.entities) if e.is_a?(Group)
      end
    end

    def relink(ents)
      ents.model = self
      ents.each do |e|
        next unless e.is_a?(Group)

        e.instance_variable_set(:@model, self)
        relink(e.entities)
      end
    end
  end
end
