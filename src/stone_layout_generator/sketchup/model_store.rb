# frozen_string_literal: true

module Higeotoko
  module StoneLayout
    # 割付データの保存・読み込み（AttributeDictionary）。
    #
    # 割付グループ: DICT['schema'], ['layout_id'], ['revision'], ['data'] (JSON)
    # 石グループ:   DICT['layout_id'], ['panel_id'], ['sig']
    #
    # 読み込みに失敗しても、モデルのジオメトリには一切触らない。
    module ModelStore
      DICT = 'Higeotoko_StoneLayout'
      ROLE_LAYOUT = 'layout'
      ROLE_STONE = 'stone'

      module_function

      def layout_group?(ent)
        group_like?(ent) && ent.get_attribute(DICT, 'role') == ROLE_LAYOUT
      end

      def stone_group?(ent)
        group_like?(ent) && ent.get_attribute(DICT, 'role') == ROLE_STONE
      end

      def group_like?(ent)
        ent.is_a?(Sketchup::Group) && ent.valid?
      end

      # 選択・親階層から割付グループを探す
      def find_layout(model)
        sel = model.selection.to_a
        sel.each do |e|
          return e if layout_group?(e)
          return parent_layout(e) if stone_group?(e) && parent_layout(e)
        end
        # 割付グループの中に入って編集している場合
        path = model.active_path || []
        path.reverse_each { |e| return e if layout_group?(e) }
        nil
      end

      def parent_layout(stone)
        parent = stone.parent
        return nil unless parent.respond_to?(:instances)

        parent.instances.find { |g| layout_group?(g) }
      end

      def revision(group)
        group.get_attribute(DICT, 'revision', -1)
      end

      def save(group, doc)
        group.set_attribute(DICT, 'role', ROLE_LAYOUT)
        group.set_attribute(DICT, 'schema', SCHEMA_VERSION)
        group.set_attribute(DICT, 'layout_id', doc.id)
        group.set_attribute(DICT, 'revision', doc.revision)
        group.set_attribute(DICT, 'data', Core::Serializer.dump(doc))
      end

      # → LayoutDocument（失敗時は Core::PersistenceError）
      def load(group)
        json = group.get_attribute(DICT, 'data')
        raise Core::PersistenceError, '割付データが見つかりません' if json.nil? || json.empty?

        Core::Serializer.load(json)
      end

      def tag_stone(stone, doc, panel, sig)
        stone.set_attribute(DICT, 'role', ROLE_STONE)
        stone.set_attribute(DICT, 'layout_id', doc.id)
        stone.set_attribute(DICT, 'panel_id', panel.id)
        stone.set_attribute(DICT, 'sig', sig)
      end

      def untag_stone(stone)
        stone.delete_attribute(DICT) if stone.respond_to?(:delete_attribute)
      end

      def stone_groups(layout_group)
        layout_group.entities.grep(Sketchup::Group).select { |g| stone_group?(g) }
      end

      # panel_id => Group
      def stone_index(layout_group)
        idx = {}
        stone_groups(layout_group).each do |g|
          pid = g.get_attribute(DICT, 'panel_id')
          idx[pid] = g if pid
        end
        idx
      end
    end
  end
end
