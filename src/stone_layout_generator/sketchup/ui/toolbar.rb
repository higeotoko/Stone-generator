# frozen_string_literal: true

module Higeotoko
  module StoneLayout
    # メニュー・ツールバー・右クリックで共有する UI::Command
    module Toolbar
      IMAGES = File.join(__dir__, '..', '..', 'images')
      SCAN_LIMIT = 50 # 有効/無効の判定で見る選択要素の上限（大量選択でも重くしない）

      module_function

      def commands
        @commands ||= {
          generate: command('石割付を生成', 'generate',
                            '選択した壁面に石を自動で割り付けます（R面・丸柱も可）') { Commands.generate }.tap do |c|
            c.set_validation_proc { state { face_selected? } }
          end,
          edit: command('目地を編集', 'edit',
                        '石割付の目地をドラッグ・数値入力で直接編集します') { Commands.edit }.tap do |c|
            c.set_validation_proc { state { layout_selected? } }
          end,
          settings: command('割付設定を変更', 'settings',
                            '石厚・目地幅などを変更します（調整した目地位置は保持）') { Commands.settings }.tap do |c|
            c.set_validation_proc { state { layout_selected? } }
          end,
          schedule: command('石寸法一覧', 'schedule',
                            '石の寸法・枚数・面積・重量を集計し、CSV に書き出します') { Commands.schedule }.tap do |c|
            c.set_validation_proc { state { layout_selected? } }
          end
        }
      end

      # 有効/無効の判定は SketchUp が頻繁に呼ぶ。失敗しても押せる状態にしてエラーを連発させない
      def state
        yield ? MF_ENABLED : MF_GRAYED
      rescue StandardError
        MF_ENABLED
      end

      def command(label, icon, help, &block)
        cmd = UI::Command.new(label, &block)
        cmd.small_icon = icon_path(icon, 24)
        cmd.large_icon = icon_path(icon, 32)
        cmd.tooltip = label
        cmd.status_bar_text = help
        cmd
      end

      # Windows は SVG（拡大しても綺麗）、Mac は PNG
      def icon_path(name, size)
        svg = File.join(IMAGES, "#{name}.svg")
        return svg if Sketchup.platform == :platform_win && File.exist?(svg)

        File.join(IMAGES, "#{name}_#{size}.png")
      end

      def install
        tb = UI::Toolbar.new('石割付 Stone Layout')
        tb.add_item(commands[:generate])
        tb.add_separator
        tb.add_item(commands[:edit])
        tb.add_item(commands[:settings])
        tb.add_item(commands[:schedule])
        tb.get_last_state == TB_NEVER_SHOWN ? tb.show : tb.restore
        tb
      end

      def face_selected?
        Sketchup.active_model.selection.each_with_index do |e, i|
          return true if e.is_a?(Sketchup::Face)
          return false if i >= SCAN_LIMIT
        end
        false
      end

      def layout_selected?
        return true if EditTool.active&.controller&.valid?

        model = Sketchup.active_model
        (model.active_path || []).each { |e| return true if ModelStore.layout_group?(e) }
        model.selection.each_with_index do |e, i|
          return true if ModelStore.layout_group?(e) || ModelStore.stone_group?(e)
          return false if i >= SCAN_LIMIT
        end
        false
      end
    end
  end
end
