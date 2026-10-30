# frozen_string_literal: true

require 'json'

module Higeotoko
  module StoneLayout
    # 石寸法一覧・数量集計のダイアログ。CSV 書き出しと、種別ごとの石の選択ができる。
    class ScheduleDialog
      HTML = File.join(__dir__, 'html', 'schedule.html')

      def self.show(controller)
        new(controller).show
      end

      def initialize(controller)
        @ctrl = controller
      end

      def show
        @dialog = UI::HtmlDialog.new(dialog_title: '石寸法一覧', preferences_key: 'Higeotoko_StoneLayout_schedule',
                                     width: 640, height: 720, resizable: true, style: UI::HtmlDialog::STYLE_UTILITY)
        @dialog.set_file(HTML)
        @dialog.add_action_callback('ready') { |_ctx| safely { push } }
        @dialog.add_action_callback('export') { |_ctx| safely { export } }
        @dialog.add_action_callback('select') { |_ctx, code| safely { select_type(code.to_s) } }
        @dialog.add_action_callback('density') do |_ctx, value|
          safely do
            @ctrl.change_settings('density' => Float(value))
            push
          end
        end
        @dialog.add_action_callback('close') { |_ctx| @dialog&.close }
        @dialog.set_on_closed { @dialog = nil }
        @dialog.show
        self
      end

      private

      def result
        @ctrl.refresh!
        Core::Schedule.build(@ctrl.doc)
      end

      def push
        @result = result
        data = Core::Schedule.to_h(@result).merge('title' => @ctrl.group.name)
        @dialog&.execute_script("render(#{JSON.generate(data)})")
      end

      def export
        @result ||= result
        name = "#{@ctrl.group.name}_石寸法一覧.csv"
        dir = File.dirname(@ctrl.model.path.to_s) if @ctrl.model.respond_to?(:path) && !@ctrl.model.path.to_s.empty?
        path = UI.savepanel('石寸法一覧を CSV に書き出す', dir || '', name)
        return unless path

        path = "#{path}.csv" unless path.downcase.end_with?('.csv')
        File.binwrite(path, Core::Schedule.to_csv(@result, @ctrl.group.name).encode('UTF-8'))
        report('message' => "書き出しました: #{path}")
      end

      # その種別の石をモデル上で選択する
      def select_type(code)
        @result ||= result
        ids = @result.rows.select { |r| r.type == code }.map(&:panel_id)
        idx = @ctrl.index
        groups = ids.filter_map { |id| idx[id] }.select(&:valid?)
        sel = @ctrl.model.selection
        sel.clear
        sel.add(groups)
        report('message' => "種別 #{code} の石 #{groups.size} 枚を選択しました")
      end

      def report(h)
        @dialog&.execute_script("report(#{JSON.generate(h)})")
      end

      def safely
        yield
      rescue ArgumentError, TypeError => e
        report('error' => "値が不正です: #{e.message}")
      rescue Core::Error => e
        report('error' => e.message)
      rescue StandardError => e
        Core::Log.error("寸法一覧の操作に失敗: #{e.class}: #{e.message}", at: (e.backtrace || []).first(4))
        report('error' => "#{e.class}: #{e.message}（詳細は Ruby コンソール）")
      end
    end
  end
end
