# frozen_string_literal: true

module Higeotoko
  module StoneLayout
    # SketchUp 内部単位（inch）とエンジン単位（mm）の変換はここだけで行う。
    module Units
      MM_PER_INCH = 25.4

      module_function

      def to_mm(inches)
        inches.to_f * MM_PER_INCH
      end

      def to_inch(mm)
        mm.to_f / MM_PER_INCH
      end

      # Geom::Point3d（inch, 割付グループのローカル座標）→ [x, y, z] mm
      def point_mm(pt)
        [to_mm(pt.x), to_mm(pt.y), to_mm(pt.z)]
      end

      # [x, y, z] mm → Geom::Point3d（inch）
      def point_in(arr)
        Geom::Point3d.new(to_inch(arr[0]), to_inch(arr[1]), to_inch(arr[2]))
      end

      # VCB に入力された文字列 → mm。モデルの単位設定に従う（"100" は mm 設定なら 100mm）。
      def parse_length_mm(text)
        s = text.to_s.strip
        raise ArgumentError, '空の入力です' if s.empty?

        neg = s.start_with?('-')
        s = s[1..] if neg || s.start_with?('+')
        mm = to_mm(s.to_l)
        neg ? -mm : mm
      end

      def format_mm(mm)
        format('%.1f mm', mm)
      end
    end
  end
end
