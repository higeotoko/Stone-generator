# frozen_string_literal: true

require 'json'

module Higeotoko::StoneLayout::Core
  # LayoutDocument <-> Hash/JSON。3D 生成エンジンとは独立。
  #
  # 形式を変えたら SCHEMA_VERSION を上げ、MIGRATIONS に旧版からの変換を足す。
  module Serializer
    SCHEMA = Higeotoko::StoneLayout::SCHEMA_VERSION

    # { 旧バージョン => ->(hash) { 次のバージョンの hash } }
    MIGRATIONS = {}.freeze

    module_function

    def to_h(doc)
      {
        'schema' => SCHEMA,
        'generator' => "StoneLayoutGenerator #{Higeotoko::StoneLayout::VERSION}",
        'id' => doc.id,
        'revision' => doc.revision,
        'surface' => doc.surface.to_h,
        'settings' => doc.settings.to_h,
        'segments' => doc.segments.values.sort_by(&:id).map(&:to_h),
        'panels' => doc.panels.values.sort_by(&:id).map(&:to_h),
        'next_segment_id' => doc.next_segment_id,
        'next_panel_id' => doc.next_panel_id,
        'next_label' => doc.next_label
      }
    end

    def dump(doc)
      JSON.generate(to_h(doc))
    end

    def from_h(h)
      h = migrate(h)
      surface = SurfaceDefinition.from_h(h.fetch('surface'))
      segments = h.fetch('segments').to_h { |x| s = JointSegment.from_h(x); [s.id, s] }
      panels = h.fetch('panels').to_h { |x| p = Panel.from_h(x); [p.id, p] }
      LayoutDocument.new(
        id: h.fetch('id'), surface: surface, settings: Settings.new(h.fetch('settings')),
        segments: segments, panels: panels, revision: h['revision'] || 0,
        next_segment_id: h['next_segment_id'], next_panel_id: h['next_panel_id'], next_label: h['next_label']
      )
    rescue KeyError, TypeError, ArgumentError, NoMethodError, InvalidInput => e
      raise PersistenceError, "保存データが破損しています: #{e.message}"
    end

    def load(json)
      from_h(JSON.parse(json))
    rescue JSON::ParserError => e
      raise PersistenceError, "保存データを読み込めません: #{e.message}"
    end

    def migrate(h)
      v = h['schema']
      raise PersistenceError, '保存データのバージョンが不明です' unless v.is_a?(Integer)
      raise PersistenceError, "新しいバージョンで保存されたデータです（schema #{v}）" if v > SCHEMA

      while v < SCHEMA
        m = MIGRATIONS[v] or raise PersistenceError, "schema #{v} からの移行処理がありません"
        h = m.call(h)
        v += 1
      end
      h
    end
  end
end
