# frozen_string_literal: true

module Higeotoko::StoneLayout::Core
  # ドラッグ中の目地スナップ。候補は少数に絞る（既存目地・壁端・壁中央）。
  class Snapper
    Result = Struct.new(:delta, :label)

    RANGE = 3000.0 # 候補を探す範囲 (mm)

    def initialize(doc)
      @doc = doc
    end

    # base: 選択目地の現在位置, raw: 生の移動量, tol: スナップ距離 (mm)
    def snap(pieces, raw, tol, step: nil)
      step ||= @doc.settings['snap_step']
      pc = pieces.first
      base = pc.position
      target = base + raw
      best = nil
      candidates(pc).each do |pos, label|
        next if (pos - base).abs < Tol::POINT

        d = (pos - target).abs
        best = [d, pos, label] if d <= tol && (best.nil? || d < best[0])
      end
      return Result.new(best[1] - base, best[2]) if best

      delta = step && step.positive? ? (raw / step).round * step : raw
      Result.new(delta, nil)
    end

    def candidates(pc)
      orient = pc.orientation
      list = []
      b = @doc.surface.bbox
      if orient == :v
        unless @doc.periodic?
          list << [b[0], '壁端'] << [b[2], '壁端'] << [(b[0] + b[2]) * 0.5, '壁中央']
        end
        box = [pc.a.x - RANGE, pc.a.y - RANGE, pc.a.x + RANGE, pc.b.y + RANGE]
        WorkingSet.new(@doc).near(box).each { |s| list << [s.a.x, '目地'] if s.seg.orientation == :v }
      elsif orient == :h
        list << [b[1], '壁端'] << [b[3], '壁端'] << [(b[1] + b[3]) * 0.5, '壁中央']
        box = [pc.a.x - RANGE, pc.a.y - RANGE, pc.b.x + RANGE, pc.a.y + RANGE]
        WorkingSet.new(@doc).near(box).each { |s| list << [s.a.y, '目地'] if s.seg.orientation == :h }
      end
      list
    end
  end
end
