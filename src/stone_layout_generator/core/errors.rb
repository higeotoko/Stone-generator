# frozen_string_literal: true

module Higeotoko::StoneLayout::Core
  class Error < StandardError; end

  # 入力値・設定値の不正
  class InvalidInput < Error; end

  # 石の3D形状を作れない（R が小さすぎる、自己交差など）
  class GeometryError < Error
    attr_reader :panel_id

    def initialize(message, panel_id = nil)
      super(message)
      @panel_id = panel_id
    end
  end

  # 保存データの読み込み失敗
  class PersistenceError < Error; end
end
