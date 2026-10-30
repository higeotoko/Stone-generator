# frozen_string_literal: true

module Higeotoko::StoneLayout::Core
  # 割付設定（すべて mm）。
  #
  # 区分:
  #   - 割付パラメータ（変更すると再割付が必要）: LAYOUT_KEYS
  #   - 物理パラメータ（変更しても目地位置は不変、形状のみ再生成）: それ以外
  class Settings
    DEFAULTS = {
      # 石寸法
      'stone_width' => 900.0,
      'stone_height' => 600.0,
      'size_basis' => 'pitch',   # pitch: 目地芯々寸法 / stone: 石の実寸（ピッチ=実寸+目地）
      'min_width' => 150.0,
      'min_height' => 100.0,
      'max_width' => nil,
      'max_height' => nil,
      'thickness' => 30.0,
      # 目地
      'joint_v' => 8.0,          # 縦目地幅
      'joint_h' => 8.0,          # 横目地幅
      'edge_clearance' => 0.0,   # 壁面外周からの逃げ
      'opening_gap' => 0.0,      # 開口部（窓・扉）の縁からの逃げ
      'align_openings' => true,  # 開口の縁（まぐさ・窓台・抱き）に目地を合わせる
      # 割付基準
      'align_u' => 'left',       # left / right / center / custom
      'align_v' => 'bottom',     # bottom / top / center / custom
      'origin_u' => 0.0,         # custom のときの基準目地位置
      'origin_v' => 0.0,
      'pattern' => 'stack',      # stack: 芋目地 / running: 馬踏み / offset: 任意オフセット
      'row_offset' => 300.0,     # offset のときの段ごとのずれ
      'end_mode' => 'cut',       # cut: 端部に半端石 / balanced: 左右均等 / uniform: 全体均等
      'start_u' => 0.0,          # 丸柱の割付開始位置（周方向）
      'joint_at_corners' => true, # 折れ角（R でない入隅・出隅）に縦目地を入れる
      'corner_mode' => 'miter',  # 角の納まり: miter 留め / win_prev 左の石が勝ち / win_next 右の石が勝ち
      'corner_overrides' => {},  # 角ごとの納まり { "角の番号" => corner_mode }
      # 生成位置
      'reference' => 'finish',   # finish: 選択面＝仕上げ面 / substrate: 選択面＝躯体面
      'face_offset' => 0.0,      # 選択面から仕上げ面までの距離（substrate 用, +が外側）
      'direction' => 'inward',   # inward / outward（仕上げ面から厚みを付ける向き）
      # 曲面の分割精度
      'max_arc_angle' => 7.5,    # 度
      'max_arc_error' => 0.5,    # mm
      # 編集
      'snap_step' => 1.0,
      'material' => nil
    }.freeze

    LAYOUT_KEYS = %w[stone_width stone_height size_basis min_width min_height max_width max_height
                     align_u align_v origin_u origin_v pattern row_offset end_mode start_u joint_at_corners align_openings].freeze

    ENUMS = {
      'size_basis' => %w[pitch stone],
      'align_u' => %w[left right center custom],
      'align_v' => %w[bottom top center custom],
      'pattern' => %w[stack running offset],
      'end_mode' => %w[cut balanced uniform],
      'reference' => %w[finish substrate],
      'direction' => %w[inward outward],
      'corner_mode' => %w[miter win_prev win_next]
    }.freeze

    def initialize(values = {})
      @values = DEFAULTS.dup
      values.each { |k, v| @values[k.to_s] = v }
      normalize!
    end

    def [](key)
      @values.fetch(key.to_s)
    end

    def merge(changes)
      Settings.new(@values.merge(changes.transform_keys(&:to_s)))
    end

    def to_h
      h = @values.dup
      h['corner_overrides'] = h['corner_overrides'].dup
      h
    end

    # 角 index の納まり
    def corner_mode_at(index)
      self['corner_overrides'][index.to_s] || self['corner_mode']
    end

    def layout_changed?(other)
      LAYOUT_KEYS.any? { |k| self[k] != other[k] }
    end

    # ---- 派生値 ---------------------------------------------------------------

    def pitch_u
      self['size_basis'] == 'stone' ? self['stone_width'] + self['joint_v'] : self['stone_width']
    end

    def pitch_v
      self['size_basis'] == 'stone' ? self['stone_height'] + self['joint_h'] : self['stone_height']
    end

    # 最小寸法を目地芯基準に換算
    def min_pitch_u
      self['size_basis'] == 'stone' ? self['min_width'] + self['joint_v'] : self['min_width']
    end

    def min_pitch_v
      self['size_basis'] == 'stone' ? self['min_height'] + self['joint_h'] : self['min_height']
    end

    def max_pitch_u
      m = self['max_width']
      m && (self['size_basis'] == 'stone' ? m + self['joint_v'] : m)
    end

    def max_pitch_v
      m = self['max_height']
      m && (self['size_basis'] == 'stone' ? m + self['joint_h'] : m)
    end

    # 仕上げ面の位置（選択面からのオフセット）
    def finish_offset
      self['reference'] == 'finish' ? 0.0 : self['face_offset']
    end

    # 石が占める法線方向の範囲 [s_inner, s_outer]
    def s_range
      p = finish_offset
      t = self['thickness']
      self['direction'] == 'inward' ? [p - t, p] : [p, p + t]
    end

    def arc_options
      { max_angle: self['max_arc_angle'] * Math::PI / 180, max_error: self['max_arc_error'] }
    end

    # ---- 検証 -----------------------------------------------------------------

    def validate
      errors = []
      positive = { 'stone_width' => '基本石幅', 'stone_height' => '基本石高さ', 'thickness' => '石厚',
                   'max_arc_angle' => '最大分割角', 'max_arc_error' => '最大弦誤差' }
      positive.each do |k, label|
        v = self[k]
        if v.zero?
          errors << "#{label}がゼロです"
        elsif v.negative?
          errors << "#{label}が負の値です（#{v}）"
        end
      end
      %w[joint_v joint_h min_width min_height edge_clearance opening_gap].each do |k|
        errors << "#{k} が負の値です" if self[k].negative?
      end
      errors << '縦目地幅が石幅以上です' if self['joint_v'] >= pitch_u
      errors << '横目地幅が石高さ以上です' if self['joint_h'] >= pitch_v
      errors << '最小石幅が基本石幅を超えています' if self['min_width'] > self['stone_width']
      errors << '最小石高さが基本石高さを超えています' if self['min_height'] > self['stone_height']
      if self['max_width'] && self['max_width'] < self['stone_width']
        errors << '最大石幅が基本石幅より小さいです'
      end
      if self['max_height'] && self['max_height'] < self['stone_height']
        errors << '最大石高さが基本石高さより小さいです'
      end
      ENUMS.each { |k, vals| errors << "#{k} の値が不正です: #{self[k]}" unless vals.include?(self[k]) }
      self['corner_overrides'].each_value do |m|
        errors << "角の納まりの値が不正です: #{m}" unless ENUMS['corner_mode'].include?(m)
      end
      errors
    end

    def validate!
      errs = validate
      raise InvalidInput, errs.join("\n") unless errs.empty?

      self
    end

    private

    def normalize!
      DEFAULTS.each do |k, d|
        v = @values[k]
        if d.is_a?(Hash)
          @values[k] = v.is_a?(Hash) ? v.to_h { |kk, vv| [kk.to_s, vv.to_s] } : {}
        elsif d.is_a?(Float) || %w[max_width max_height].include?(k)
          @values[k] = v.nil? || v == '' ? (d.nil? ? nil : d) : Float(v)
        elsif d == true || d == false
          @values[k] = [true, 'true', '1', 1].include?(v)
        elsif !v.nil?
          @values[k] = v.to_s
        end
      end
    rescue ArgumentError, TypeError => e
      raise InvalidInput, "数値の形式が不正です: #{e.message}"
    end
  end
end
