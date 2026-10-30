# frozen_string_literal: true

# EditTool をマウス操作で動かすための追加モック（正面からの平行投影ビュー）。
# 画面座標 (x, y) = (ワールド x, -ワールド z) / SCALE。手前（-y）から +y 方向を見る。
require_relative 'fake_sketchup'

COPY_MODIFIER_MASK = 4
CONSTRAIN_MODIFIER_MASK = 1
ALT_MODIFIER_MASK = 32
GL_LINE_STRIP = 3
GL_LINES = 1
MB_YESNOCANCEL = 3
MB_OKCANCEL = 1
IDYES = 6
IDNO = 7
IDOK = 1
IDCANCEL = 2
MF_ENABLED = 0
MF_GRAYED = 1
MF_CHECKED = 8

# モデル単位 mm 相当: "100" → 100mm（inch で返す）
class String
  def to_l
    Float(strip.sub(/mm\z/, '')) / 25.4
  end
end

module Geom
  # 平行移動だけのモック（入れ子グループの座標変換の確認用）
  class Transformation
    attr_reader :off

    def initialize(off = [0.0, 0.0, 0.0])
      @off = off.map(&:to_f)
    end

    def inverse
      Transformation.new(@off.map(&:-@))
    end

    def *(other)
      return Transformation.new(@off.zip(other.off).map(&:sum)) if other.is_a?(Transformation)
      return other.transform(self) if other.is_a?(Point3d)

      other
    end
  end

  class Point3d
    def transform(t)
      return self if is_a?(Vector3d) || !t.is_a?(Transformation)

      Point3d.new(x + t.off[0], y + t.off[1], z + t.off[2])
    end
  end

  class BoundingBox
    def corner(i)
      Point3d.new(i & 1 == 1 ? @max.x : @min.x, i & 2 == 2 ? @max.y : @min.y, i & 4 == 4 ? @max.z : @min.z)
    end
  end
end

module Sketchup
  class Group
    attr_writer :transformation

    def transformation
      @transformation ||= Geom::Transformation.new
    end

    # 本物はグループの定義（ComponentDefinition）。定義の instances で親グループへたどれる
    def parent
      owner = @parent_entities.owner
      owner.nil? || owner.is_a?(Model) ? owner : FakeDefinition.new(owner)
    end
  end

  FakeDefinition = Struct.new(:group) do
    def instances
      [group]
    end
  end

  class Entities
    attr_accessor :owner
  end

  class Model
    attr_accessor :tool

    def active_path
      nil
    end

    def edit_transform
      Geom::Transformation.new
    end

    def select_tool(tool)
      @tool = tool
    end

    def active_view
      @view ||= FakeView.new
    end
  end

  class << self
    attr_accessor :active_model, :status_text, :vcb_label, :vcb_value
  end

  # 1px = SCALE inch
  class FakeView
    SCALE = 1.0 / 25.4 # 1px = 1mm
    attr_reader :invalidations

    def initialize
      @invalidations = 0
    end

    def screen_of_mm(x_mm, z_mm)
      [x_mm, -z_mm]
    end

    def pickray(x, y)
      [Geom::Point3d.new(x * SCALE, -1000.0, -y * SCALE), Geom::Vector3d.new(0, 1, 0)]
    end

    def pixels_to_model(px, _pt)
      px * SCALE
    end

    def screen_coords(p)
      Geom::Point3d.new(p.x / SCALE, -p.z / SCALE, 0)
    end

    def invalidate
      @invalidations += 1
    end

    attr_writer :drawing_color, :line_width, :line_stipple

    def draw(*); end

    def draw_text(*); end
  end
end

module UI
  @messages = []
  class << self
    attr_reader :messages

    def beep; end

    def messagebox(msg, _type = nil)
      @messages << msg
      IDCANCEL
    end
  end
end

module Higeotoko
  module StoneLayout
    # 本物は UI::HtmlDialog。テストでは呼び出しだけ受ける
    class EditPanel
      def self.instance
        @instance ||= new
      end

      def attach(_t); end

      def detach(_t); end

      def refresh(_t); end
    end
  end
end
