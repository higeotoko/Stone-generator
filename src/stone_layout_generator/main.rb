# frozen_string_literal: true

require 'sketchup.rb'
require_relative 'core'
%w[
  units model_store face_reader geometry_builder layout_controller
  tools/preview_tool tools/edit_tool ui/generate_dialog ui/edit_panel ui/schedule_dialog ui/toolbar
].each { |f| require_relative File.join('sketchup', f) }

module Higeotoko
  module StoneLayout
    module Commands
      module_function

      def generate
        run { GenerateDialog.create(Sketchup.active_model) }
      end

      def edit
        run do
          ctrl = controller_for_selection or next
          Sketchup.active_model.select_tool(EditTool.new(ctrl))
        end
      end

      def settings
        run do
          ctrl = controller_for_selection or next
          GenerateDialog.edit(ctrl)
        end
      end

      def schedule
        run do
          ctrl = controller_for_selection or next
          ScheduleDialog.show(ctrl)
        end
      end

      def check
        run do
          ctrl = controller_for_selection or next
          issues = ctrl.check_integrity
          UI.messagebox(issues.empty? ? '割付データと石の形状は一致しています。' : issues.map(&:message).join("\n"))
        end
      end

      # コマンドの想定外のエラーを黙って捨てない
      def run
        yield
      rescue Core::Error => e
        UI.messagebox(e.message)
      rescue StandardError => e
        Core::Log.error("コマンドの実行に失敗: #{e.class}: #{e.message}", at: (e.backtrace || []).first(6))
        UI.messagebox("エラーが発生しました。\n#{e.class}: #{e.message}\n\n詳細は ウィンドウ → Ruby コンソール に出力しています。")
      end

      def show_log
        UI.messagebox(Core::Log.entries.last(30).join("\n").then { |s| s.empty? ? 'ログはありません' : s })
      end

      def controller_for_selection
        # 目地編集中なら、その割付を使う（編集中は割付グループの選択を外しているため）
        return EditTool.active.controller if EditTool.active&.controller&.valid?

        model = Sketchup.active_model
        group = ModelStore.find_layout(model)
        unless group
          UI.messagebox('石割付グループ（StoneLayout_xxx）を選択してください。')
          return nil
        end
        LayoutController.new(group)
      rescue Core::PersistenceError => e
        # データが壊れていてもジオメトリは消さない
        UI.messagebox("割付データを読み込めませんでした。形状はそのまま残しています。\n#{e.message}")
        nil
      end
    end

    unless file_loaded?(__FILE__)
      cmds = Toolbar.commands
      menu = UI.menu('Extensions').add_submenu('石割付 Stone Layout')
      menu.add_item(cmds[:generate])
      menu.add_item(cmds[:edit])
      menu.add_item(cmds[:settings])
      menu.add_item(cmds[:schedule])
      menu.add_separator
      menu.add_item('整合性チェック') { Commands.check }
      menu.add_item('ログを表示') { Commands.show_log }
      Toolbar.install

      UI.add_context_menu_handler do |cm|
        sel = Sketchup.active_model.selection
        if sel.any? { |e| ModelStore.layout_group?(e) || ModelStore.stone_group?(e) }
          cm.add_item('石割付: 目地を編集') { Commands.edit }
          cm.add_item('石割付: 設定を変更...') { Commands.settings }
          cm.add_item('石割付: 石寸法一覧...') { Commands.schedule }
        elsif sel.grep(Sketchup::Face).any?
          cm.add_item('石割付を生成...') { Commands.generate }
        end
      end
      file_loaded(__FILE__)
    end
  end
end
