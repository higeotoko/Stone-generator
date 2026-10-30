# frozen_string_literal: true

require 'json'

module Higeotoko
  module StoneLayout
    # 初期生成パネル / 既存割付の設定変更パネル（UI::HtmlDialog）
    #
    # mode :create  … 選択面から新規生成（プレビュー → 生成）
    # mode :edit    … 既存割付の石厚・目地幅などを変更（目地位置は保持）。全体再割付も可能
    class GenerateDialog
      HTML = File.join(__dir__, 'html', 'generate.html')

      def self.create(model)
        read = FaceReader.read(model.selection)
        new(:create, surface: read.surface, warnings: read.warnings, entities: model.active_entities).show
      rescue Core::Error => e
        UI.messagebox(e.message)
      end

      def self.edit(controller)
        new(:edit, controller: controller).show
      end

      def initialize(mode, surface: nil, warnings: [], entities: nil, controller: nil)
        @mode = mode
        @surface = surface || controller&.doc&.surface
        @warnings = warnings
        @entities = entities
        @ctrl = controller
        @settings = controller ? controller.doc.settings : (self.class.last_settings || Core::Settings.new)
      end

      class << self
        attr_accessor :last_settings
      end

      def show
        @dialog = UI::HtmlDialog.new(
          dialog_title: @mode == :create ? '石割付の生成' : '石割付の設定',
          preferences_key: "Higeotoko_StoneLayout_#{@mode}",
          width: 380, height: 680, resizable: true, style: UI::HtmlDialog::STYLE_UTILITY
        )
        @dialog.set_file(HTML)
        @dialog.add_action_callback('ready') { |_ctx| init_dialog }
        @dialog.add_action_callback('preview') { |_ctx, json| preview(json) }
        @dialog.add_action_callback('apply') { |_ctx, json| apply(json) }
        @dialog.add_action_callback('relayout') { |_ctx, json| relayout(json) }
        @dialog.add_action_callback('close') { |_ctx| close }
        @dialog.set_on_closed { cleanup }
        @dialog.show
        if @mode == :create
          @preview = PreviewTool.new(@surface)
          Sketchup.active_model.select_tool(@preview)
        end
        self
      end

      private

      def init_dialog
        info = {
          'mode' => @mode.to_s,
          'settings' => @settings.to_h,
          'warnings' => @warnings,
          'surface' => surface_info,
          'manual' => @ctrl ? @ctrl.doc.manual_edits? : false,
          'layout_keys' => Core::Settings::LAYOUT_KEYS,
          'preview' => @ctrl ? preview_data(@ctrl.doc) : nil,
          'stats' => @ctrl ? { 'stones' => @ctrl.doc.panels.size } : nil
        }
        @dialog.execute_script("init(#{JSON.generate(info)})")
      end

      def surface_info
        b = @surface.bbox
        prof = @surface.profile
        arcs = prof.segments.any? { |sg| sg.is_a?(Core::ArcSegment2) }
        kind = if @surface.periodic? then '丸柱'
               elsif arcs then 'R付きの壁'
               elsif prof.corners.any? then '折れ壁'
               else '平面壁'
               end
        {
          'kind' => kind,
          'length' => @surface.u_length.round(1), 'height' => (b[3] - b[1]).round(1),
          'periodic' => @surface.periodic?, 'has_arcs' => arcs, 'has_corners' => prof.corners.any?
        }
      end

      PREVIEW_LIMIT = 6000

      # ダイアログ内の展開図プレビュー用（u, v の線分）
      def preview_data(doc)
        segs = doc.segments.values
        return nil if segs.size > PREVIEW_LIMIT

        {
          'bbox' => doc.surface.bbox.map { |c| c.round(1) },
          'boundary' => doc.surface.boundary.map { |p| [p.x.round(1), p.y.round(1)] },
          'lines' => segs.map { |sg| [sg.a.x.round(1), sg.a.y.round(1), sg.b.x.round(1), sg.b.y.round(1)] }
        }
      end

      def parse(json)
        Core::Settings.new(JSON.parse(json))
      end

      def preview(json)
        s = parse(json)
        errs = s.validate
        return report('error' => errs) unless errs.empty?

        stats, warnings = @preview ? @preview.update(s) : [{}, []]
        report('stats' => stats, 'warnings' => warnings.first(20), 'preview' => @preview&.doc && preview_data(@preview.doc))
      rescue Core::Error => e
        report('error' => [e.message])
      end

      def apply(json)
        s = parse(json)
        if @mode == :create
          model = Sketchup.active_model
          ctrl, _stats, warnings = LayoutController.create(model, @entities, @surface, s)
          self.class.last_settings = s
          close
          model.selection.clear
          model.selection.add(ctrl.group)
          UI.messagebox("#{ctrl.doc.panels.size} 枚の石を生成しました。\n" + warnings.first(10).join("\n")) unless warnings.empty?
          model.select_tool(EditTool.new(ctrl))
        else
          changes = s.to_h.reject { |k, _| Core::Settings::LAYOUT_KEYS.include?(k) }
          @ctrl.change_settings(changes)
          report('message' => '設定を反映しました（目地位置は保持されています）')
        end
      rescue Core::Error => e
        report('error' => e.message.split("\n"))
      end

      def relayout(json)
        return unless @ctrl

        if @ctrl.doc.manual_edits?
          r = UI.messagebox("手動で調整した目地・ロックはすべて破棄され、自動割付からやり直します。\nよろしいですか？", MB_OKCANCEL)
          return unless r == IDOK
        end
        @ctrl.relayout(JSON.parse(json))
        report('message' => "全体を再割付しました（#{@ctrl.doc.panels.size} 枚）")
      rescue Core::Error => e
        report('error' => e.message.split("\n"))
      end

      def report(h)
        @dialog&.execute_script("report(#{JSON.generate(h)})")
      end

      def close
        @dialog&.close
      end

      def cleanup
        model = Sketchup.active_model
        model.select_tool(nil) if @preview&.active
        @preview = nil
        @dialog = nil
      end
    end
  end
end
