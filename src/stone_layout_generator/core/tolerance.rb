# frozen_string_literal: true

module Higeotoko::StoneLayout::Core
  # 幾何判定の許容誤差（すべて mm）。
  #
  # SketchUp は約 0.001inch (=0.0254mm) より近い頂点を同一視するので、
  # 石の輪郭に MIN_EDGE 未満の辺を作らないようにする。
  module Tol
    POINT    = 1.0e-3  # 同一点判定 (1µm)
    PARALLEL = 1.0e-9  # 平行判定（単位ベクトルの外積）
    AREA     = 1.0e-2  # 面積ゼロ判定 (mm^2)
    MIN_EDGE = 0.05    # 3D化する輪郭の最小辺長
    KEY      = 1.0e-3  # 形状比較キーの量子化幅

    module_function

    def eq?(a, b, tol = POINT)
      (a - b).abs <= tol
    end

    def zero?(a, tol = POINT)
      a.abs <= tol
    end
  end
end
