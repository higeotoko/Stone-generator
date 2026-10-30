# frozen_string_literal: true

module Higeotoko::StoneLayout::Core
  # 部分目地（石と石の間の1辺）の選択単位
  Piece = Struct.new(:segment_id, :a, :b) do
    def orientation
      if (b.x - a.x).abs <= Tol::POINT
        :v
      elsif (b.y - a.y).abs <= Tol::POINT
        :h
      else
        :free
      end
    end

    def position
      orientation == :v ? a.x : a.y
    end

    def length
      a.dist(b)
    end
  end

  # 編集の計画（確定前の状態）。プレビュー表示と検証結果を持つ。
  #
  # 流れ: 操作 → 候補計算 → 接続更新 → 検証 → 影響石の特定 → プレビュー → apply
  class EditPlan
    PreviewFace = Struct.new(:points, :kind) # kind: :changed / :added

    attr_reader :op, :errors, :warnings, :segment_changes, :panel_updates, :panel_adds,
                :panel_removes, :preview_faces, :preview_lines, :next_segment_id, :affected_ids
    attr_accessor :delta

    def initialize(op)
      @op = op
      @errors = []
      @warnings = []
      @segment_changes = {}
      @panel_updates = {} # id => [points, flags, geometry_changed]
      @panel_adds = []    # [points, flags]
      @panel_removes = []
      @preview_faces = []
      @preview_lines = []
      @affected_ids = []
      @next_segment_id = nil
    end

    def ok?
      @errors.empty?
    end

    def fail(message)
      @errors << message
      self
    end

    def set_result(segment_changes:, next_segment_id:, updates:, adds:, removes:, affected:)
      @segment_changes = segment_changes
      @next_segment_id = next_segment_id
      @panel_updates = updates
      @panel_adds = adds
      @panel_removes = removes
      @affected_ids = affected
    end

    # 形状が変わる（3D 再生成が必要な）石ID
    def changed_panel_ids
      @panel_updates.select { |_, v| v[2] }.keys
    end
  end

  # apply の結果（Geometry Builder が使う）
  ChangeSet = Struct.new(:regenerate, :added, :removed) do
    def empty?
      regenerate.empty? && added.empty? && removed.empty?
    end

    def all_rebuild
      regenerate + added
    end
  end
end
