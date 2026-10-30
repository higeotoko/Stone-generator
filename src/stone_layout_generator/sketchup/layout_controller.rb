# frozen_string_literal: true

module Higeotoko
  module StoneLayout
    # 割付グループ1つ分の操作をまとめる（Undo 単位・整合性の責任者）。
    #
    # すべての変更は start_operation 〜 commit_operation の中で
    #   (1) 文書の更新 (2) 必要な石だけ再生成 (3) 属性へ保存
    # をまとめて行う。属性もジオメトリも同じ Undo 単位なので、Undo/Redo で両者は常に一致する。
    # 途中で失敗したら abort_operation し、文書を属性から読み直す。
    class LayoutController
      attr_reader :group, :doc

      Issue = Struct.new(:kind, :panel_id, :message)

      # 新規生成
      def self.create(model, entities, surface, settings)
        doc, stats = Core::LayoutBuilder.build(surface, settings)
        geo = Core::StoneGeometry.new(doc)
        built, errors = geo.build_many(doc.panels.keys)
        raise Core::GeometryError, errors.first(10).map(&:message).join("\n") unless errors.empty?

        model.start_operation('石割付を生成', true)
        begin
          group = entities.add_group
          group.name = next_layout_name(entities)
          ModelStore.save(group, doc)
          GeometryBuilder.new(group, doc).rebuild(built, {})
          model.commit_operation
        rescue StandardError
          model.abort_operation
          raise
        end
        Core::Log.info('割付を生成しました', layout: doc.id, stones: doc.panels.size)
        [new(group), stats, doc.warnings]
      end

      def self.next_layout_name(entities)
        n = entities.grep(Sketchup::Group).count { |g| ModelStore.layout_group?(g) } + 1
        format('StoneLayout_%03d', n)
      end

      def initialize(group)
        @group = group
        reload!
      end

      def model
        @group.model
      end

      def reload!
        @doc = ModelStore.load(@group)
        @index = nil
        @doc
      end

      # Undo/Redo などで保存側の revision が変わっていたら読み直す。読み直したら true。
      def refresh!
        return false unless @group.valid?
        return false if ModelStore.revision(@group) == @doc.revision

        reload!
        true
      end

      def valid?
        @group.valid?
      end

      def index
        @index = nil if @index&.values&.any? { |g| !g.valid? }
        @index ||= ModelStore.stone_index(@group)
      end
      alias index_map index

      # 割付グループのワールド変換（グループ内で編集中でも正しく描画するため）
      def world_transform
        ap = model.active_path || []
        return model.edit_transform if ap.include?(@group) # 割付グループの中に入って編集中

        path = instance_path
        # 割付グループがいま開いている階層の直下にある
        return model.edit_transform * @group.transformation if !ap.empty? && path[0...-1] == ap

        # 壁グループの中に作った割付を、外（モデル直下）から編集する場合など:
        # 祖先のグループ・コンポーネントの変換をすべて掛け合わせる
        path.map(&:transformation).reduce { |a, b| a * b }
      end

      # モデル直下から割付グループまでのインスタンスの並び
      def instance_path
        path = [@group]
        e = @group
        20.times do
          parent = e.parent
          break if parent.nil? || parent.is_a?(Sketchup::Model)
          break unless parent.respond_to?(:instances)

          inst = parent.instances.first
          break unless inst

          path.unshift(inst)
          e = inst
        end
        path
      end

      # ---- 編集の確定 -----------------------------------------------------------

      def commit_plan(plan, name)
        raise Core::Error, plan.errors.join("\n") unless plan.ok?

        engine = Core::EditEngine.new(@doc)
        change = engine.apply(plan)
        transact(name) do
          built = build_or_raise(change.all_rebuild)
          builder = GeometryBuilder.new(@group, @doc)
          builder.remove(change.removed, index)
          builder.rebuild(built, index)
          ModelStore.save(@group, @doc)
        end
        change
      end

      # 複数の編集（例: 通り目地の各辺の削除）を順に適用し、1 つの Undo にまとめる。
      # ブロックは EditEngine を受け取り、apply した ChangeSet の配列を返す。
      def commit_sequence(name)
        engine = Core::EditEngine.new(@doc)
        begin
          sets = yield engine
        rescue StandardError
          reload!
          raise
        end
        removed = sets.flat_map(&:removed).uniq
        rebuild = (sets.flat_map(&:regenerate) + sets.flat_map(&:added)).uniq - removed
        stale = removed.select { |id| index.key?(id) }
        transact(name) do
          built = build_or_raise(rebuild)
          builder = GeometryBuilder.new(@group, @doc)
          builder.remove(stale, index)
          builder.rebuild(built, index)
          ModelStore.save(@group, @doc)
        end
        Core::ChangeSet.new(rebuild - sets.flat_map(&:added), sets.flat_map(&:added) - removed, removed)
      end

      # 石厚・目地幅・生成方向など（目地位置は変えない）
      def change_settings(changes)
        new_settings = @doc.settings.merge(changes)
        new_settings.validate!
        if new_settings.layout_changed?(@doc.settings)
          raise Core::InvalidInput, '割付寸法の変更は「全体再割付」で行ってください'
        end

        old = @doc.settings
        @doc.settings = new_settings
        begin
          built = build_or_raise(@doc.panels.keys)
        rescue StandardError
          @doc.settings = old
          raise
        end
        @doc.revision += 1
        transact('石割付: 設定変更') do
          GeometryBuilder.new(@group, @doc).rebuild(built, index)
          ModelStore.save(@group, @doc)
        end
      end

      # 1つの角の納まりを変える（その角に接する石だけ作り直す）。mode=nil で全体の設定に戻す
      def set_corner_mode(index, mode)
        ov = @doc.settings['corner_overrides'].dup
        mode ? ov[index.to_s] = mode : ov.delete(index.to_s)
        old = @doc.settings
        @doc.settings = old.merge('corner_overrides' => ov)
        begin
          built = build_or_raise(Core::CornerJoint.panels_at(@doc, index))
        rescue StandardError
          @doc.settings = old
          raise
        end
        @doc.revision += 1
        transact('石割付: 角の納まり') do
          GeometryBuilder.new(@group, @doc).rebuild(built, index_map)
          ModelStore.save(@group, @doc)
        end
      end

      # 全体再割付（手動編集は失われる。呼び出し側で利用者に確認すること）
      def relayout(settings_hash)
        settings = Core::Settings.new(settings_hash)
        new_doc, = Core::LayoutBuilder.build(@doc.surface, settings, id: @doc.id)
        new_doc.revision = @doc.revision + 1
        built, errors = Core::StoneGeometry.new(new_doc).build_many(new_doc.panels.keys)
        raise Core::GeometryError, errors.first(10).map(&:message).join("\n") unless errors.empty?

        transact('石割付: 全体再割付') do
          builder = GeometryBuilder.new(@group, new_doc)
          old_index = index
          builder.remove(old_index.keys, old_index)
          @doc = new_doc
          @index = {}
          builder.rebuild(built, @index)
          ModelStore.save(@group, @doc)
        end
      end

      # ---- 整合性（通常の SketchUp 編集との関係） --------------------------------

      def check_integrity
        issues = []
        idx = index
        builder = GeometryBuilder.new(@group, @doc)
        sigs = {}
        @doc.panels.each_value do |p|
          next if p.detached?

          g = idx[p.id]
          if g.nil?
            issues << Issue.new(:missing, p.id, format('Stone_%04d が見つかりません（削除された可能性）', p.label))
            next
          end
          sig = g.get_attribute(ModelStore::DICT, 'sig')
          sigs[p.id] = sig
          unless builder.same_signature?(sig, builder.current_signature(g))
            issues << Issue.new(:modified, p.id, format('Stone_%04d は通常の編集ツールで変更されています', p.label))
          end
        end
        idx.each_key do |pid|
          next if @doc.panels.key?(pid)

          issues << Issue.new(:orphan, pid, "割付データにない石グループがあります（panel_id #{pid}）")
        end
        issues
      end

      # 変更・欠落した石をデータから作り直す
      def repair(panel_ids)
        built = build_or_raise(panel_ids)
        transact('石割付: 石を再生成') { GeometryBuilder.new(@group, @doc).rebuild(built, index) }
      end

      # 石をジェネレーターから切り離す（以後は普通の SketchUp 形状として編集可能）
      def detach(panel_ids)
        transact('石割付: 石を切り離す') do
          panel_ids.each do |id|
            p = @doc.panels[id]
            next unless p

            p.state = Core::Panel::DETACHED
            g = index[id]
            ModelStore.untag_stone(g) if g&.valid?
          end
          @doc.revision += 1
          ModelStore.save(@group, @doc)
          @index = nil
        end
      end

      private

      def build_or_raise(ids)
        built, errors = Core::StoneGeometry.new(@doc).build_many(ids)
        unless errors.empty?
          errors.each { |e| Core::Log.error(e.message, panel: e.panel_id) }
          raise Core::GeometryError, errors.first(5).map(&:message).join("\n")
        end
        built
      end

      def transact(name)
        model.start_operation(name, true)
        result = yield
        model.commit_operation
        result
      rescue StandardError => e
        model.abort_operation
        Core::Log.error("#{name} を中止しました: #{e.message}", layout: @doc&.id)
        begin
          reload!
        rescue Core::PersistenceError
          nil
        end
        raise
      end
    end
  end
end
