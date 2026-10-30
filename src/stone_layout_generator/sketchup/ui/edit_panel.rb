# frozen_string_literal: true

require 'json'

module Higeotoko
  module StoneLayout
    # 編集モード中の小さな補助パネル。操作の主役は 3D ビュー上の直接操作。
    class EditPanel
      HTML = File.join(__dir__, 'html', 'edit_panel.html')

      def self.instance
        @instance ||= new
      end

      def attach(tool)
        @tool = tool
        ensure_dialog
        refresh(tool)
      end

      def detach(tool)
        return unless @tool.equal?(tool)

        @tool = nil
        @dialog&.close
      end

      def refresh(tool)
        return unless @dialog && @tool.equal?(tool) && @ready

        doc = tool.controller.doc
        info = {
          'selection' => tool.selection_info,
          'mode' => tool.mode.to_s,
          'message' => tool.message,
          'settings' => doc.settings.to_h.slice('thickness', 'joint_v', 'joint_h', 'snap_step'),
          'stats' => doc.stats
        }
        @dialog.execute_script("update(#{JSON.generate(info)})")
      end

      private

      def ensure_dialog
        return if @dialog&.visible?

        @ready = false
        @dialog = UI::HtmlDialog.new(dialog_title: '目地編集', preferences_key: 'Higeotoko_StoneLayout_edit',
                                     width: 280, height: 460, resizable: true, style: UI::HtmlDialog::STYLE_UTILITY)
        @dialog.set_file(HTML)
        @dialog.add_action_callback('ready') do |_ctx|
          @ready = true
          refresh(@tool) if @tool
        end
        @dialog.add_action_callback('move') { |_ctx, text| with_tool { |t| t.move_selection(Units.parse_length_mm(text)) } }
        @dialog.add_action_callback('remove') { |_ctx| with_tool(&:delete_selection) }
        @dialog.add_action_callback('lock') { |_ctx, v| with_tool { |t| t.lock_selection(v == true || v == 'true') } }
        @dialog.add_action_callback('mode') { |_ctx| with_tool(&:toggle_mode) }
        @dialog.add_action_callback('settings') do |_ctx, json|
          with_tool do |t|
            t.controller.change_settings(JSON.parse(json))
            Sketchup.active_model.active_view.invalidate
          end
        end
        @dialog.add_action_callback('dialog') { |_ctx| with_tool { |t| GenerateDialog.edit(t.controller) } }
        @dialog.add_action_callback('finish') { |_ctx| Sketchup.active_model.select_tool(nil) }
        @dialog.set_on_closed { @dialog = nil }
        @dialog.show
      end

      def with_tool
        return unless @tool

        yield @tool
        refresh(@tool)
      rescue ArgumentError, Core::Error => e
        @dialog&.execute_script("showError(#{JSON.generate(e.message)})")
      end
    end
  end
end
