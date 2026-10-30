# frozen_string_literal: true

module Higeotoko
  module StoneLayout
    # 目地の直接編集ツール（Sketchup::Tool インターフェース）。
    #
    # クリック: 部分目地を選択 / Shift+クリック: 通り目地として選択 / Ctrl(Option)+クリック: 追加選択
    # ドラッグ: 目地移動（プレビューは View 描画のみ。確定はマウスを離したとき）
    # 数値入力（VCB）: 選択目地を指定量だけ移動（ドラッグ中なら移動方向に適用）
    # Delete: 選択目地を削除して石を結合 / Esc: ドラッグ取消 → 選択解除
    # 右クリック: 目地追加・削除・ロック・設定・整合性チェック
    class EditTool
      PICK_PX = 7
      SNAP_PX = 10
      DRAG_PX = 3
      DELETE_KEYS = [46, 127].freeze # Windows: Delete=46 / Mac: 127（BackSpace は VCB 入力と衝突するので使わない）

      COLOR_HOVER = 'orange'
      COLOR_SELECT = [0, 120, 255]
      COLOR_PREVIEW = [0, 170, 70]
      COLOR_AFFECTED = [255, 200, 0]
      COLOR_INVALID = 'red'

      attr_reader :controller, :selection, :mode, :message

      def initialize(controller)
        @ctrl = controller
        @selection = []
        @mode = :partial
        @hover = nil
        @drag = nil
        @plan = nil
        @message = nil
        @menu_uv = nil
      end

      # ---- ライフサイクル --------------------------------------------------------

      def activate
        @engine = Core::EditEngine.new(@ctrl.doc)
        @snapper = Core::Snapper.new(@ctrl.doc)
        warn_integrity
        EditPanel.instance.attach(self)
        update_status
      end

      def deactivate(view)
        cancel_drag
        EditPanel.instance.detach(self)
        view.invalidate
      end

      def resume(view)
        sync!
        update_status
        view.invalidate
      end

      def suspend(_view)
        cancel_drag
      end

      def onCancel(_reason, view)
        if @drag
          cancel_drag
          @message = '移動を取り消しました'
        else
          @selection = []
        end
        notify_panel
        update_status
        view.invalidate
      end

      # ---- マウス ----------------------------------------------------------------

      def onMouseMove(flags, x, y, view)
        guard(view) do
          next unless sync!

          if @press && !@drag && @press_piece && !@press_add && (x - @press[0]).abs + (y - @press[1]).abs > DRAG_PX
            start_drag(:press)
          end
          if @drag
            update_drag(x, y, view, flags)
          else
            uv = uv_at(x, y, view)
            @hover = uv && pick(uv, view)
          end
        end
        view.invalidate
      end

      # 2通りの移動に対応する:
      #   押したままドラッグ → 離して確定
      #   クリックで拾う → マウスを動かす → もう一度クリックで確定（SketchUp の移動ツールと同じ）
      def onLButtonDown(flags, x, y, view)
        guard(view) do
          next unless sync!

          if @drag && @drag[:kind] == :click
            update_drag(x, y, view, flags)
            commit_drag
            next
          end

          uv = uv_at(x, y, view)
          piece = uv && pick(uv, view)
          add = (flags & COPY_MODIFIER_MASK) != 0
          through = (flags & CONSTRAIN_MODIFIER_MASK) != 0
          @mode = through ? :through : :partial
          @press_add = add
          if piece
            pieces = through ? @engine.through_pieces(piece) : [piece]
            if add
              @selection = toggle(@selection, pieces)
            elsif !includes_piece?(@selection, piece) || through
              @selection = pieces
            end
            @press = [x, y, uv]
            @press_piece = piece
          else
            @selection = [] unless add
            @menu_uv = uv
            @press = nil
            @press_piece = nil
          end
          @message = nil
          notify_panel
          update_status
        end
        view.invalidate
      end

      def onLButtonUp(_flags, _x, _y, view)
        guard(view) do
          if @drag && @drag[:kind] == :press
            commit_drag
          elsif !@drag && @press && @press_piece && !@press_add && !@selection.empty?
            start_drag(:click) # クリックで拾った。次のクリックで確定
          end
        end
        @press = nil
        @press_piece = nil
        view.invalidate
      end

      def onRButtonDown(_flags, x, y, view)
        guard(view) do
          cancel_drag if @drag
          @menu_uv = uv_at(x, y, view)
        end
      end

      # ---- キーボード ------------------------------------------------------------

      def enableVCB?
        true
      end

      def onUserText(text, view)
        guard(view) { user_text(text) }
        view.invalidate
      end

      def user_text(text)
        mm = Units.parse_length_mm(text)
        return UI.beep if @selection.empty?

        if @drag && !text.strip.start_with?('-', '+') && @drag[:delta].negative?
          mm = -mm # ドラッグ中は動かしている向きに適用
        end
        cancel_drag
        move_selection(mm)
      rescue ArgumentError => e
        @message = "数値が読めません: #{e.message}"
        update_status
      end

      def onKeyDown(key, _repeat, _flags, view)
        del = DELETE_KEYS.include?(key) || (defined?(VK_DELETE) && key == VK_DELETE)
        return false unless del && !@selection.empty?
        return false if @drag && @drag[:kind] == :press

        cancel_drag
        guard(view) { delete_selection }
        view.invalidate
        true
      end

      def getMenu(menu, _flags = nil, _x = nil, _y = nil, _view = nil)
        unless @selection.empty?
          menu.add_item('目地を削除（石を結合）') { delete_selection }
          locked = @selection.any? { |pc| @engine.segment_of(pc)&.locked }
          menu.add_item(locked ? '目地のロックを解除' : '目地をロック') { lock_selection(!locked) }
          menu.add_item(@mode == :through ? '部分目地として扱う' : '通り目地として扱う') { toggle_mode }
          menu.add_separator
        end
        if @menu_uv
          uv = @menu_uv
          menu.add_item('ここに縦目地を追加') { add_joint(uv, :v) }
          menu.add_item('ここに横目地を追加') { add_joint(uv, :h) }
          add_corner_menu(menu, uv)
          menu.add_separator
        end
        menu.add_item('割付設定を変更...') { GenerateDialog.edit(@ctrl) }
        menu.add_item('整合性チェック') { warn_integrity(force: true) }
        menu.add_item('編集を終了') { Sketchup.active_model.select_tool(nil) }
        true
      end

      # ---- 公開操作（編集パネルからも呼ばれる） --------------------------------------

      def move_selection(mm)
        return if @selection.empty?

        plan = @engine.plan_move(@selection, mm, mode: @mode)
        commit(plan, '石割付: 目地移動') { |_| shift_selection(mm) }
      end

      def delete_selection
        piece = @selection.first
        return unless piece

        plan = @engine.plan_delete(piece)
        commit(plan, '石割付: 目地削除') { @selection = [] }
      end

      def add_joint(uv, orient)
        return unless uv

        plan = @engine.plan_add(uv, orient)
        commit(plan, '石割付: 目地追加') { @selection = [] }
      end

      def lock_selection(value)
        plan = @engine.plan_lock(@selection, value, mode: @mode)
        commit(plan, value ? '石割付: 目地ロック' : '石割付: ロック解除')
      end

      def toggle_mode
        @mode = @mode == :through ? :partial : :through
        if @mode == :through && @selection.size == 1
          @selection = @engine.through_pieces(@selection.first)
        elsif @mode == :partial
          @selection = @selection.first(1)
        end
        notify_panel
        Sketchup.active_model.active_view.invalidate
      end

      CORNER_MODES = [%w[miter 留め], %w[win_prev 左の石を勝ちに], %w[win_next 右の石を勝ちに]].freeze
      CORNER_PICK_MM = 400.0

      # 角の近くで右クリック → その角だけ納まりを変える
      def add_corner_menu(menu, uv)
        c = Core::CornerJoint.nearest(@ctrl.doc.surface.profile, uv.x, CORNER_PICK_MM)
        return unless c

        s = @ctrl.doc.settings
        current = s.corner_mode_at(c.index)
        own = s['corner_overrides'].key?(c.index.to_s)
        sub = menu.add_submenu("この角の納まり（#{c.outer ? '出隅' : '入隅'}）")
        CORNER_MODES.each do |mode, label|
          item = sub.add_item(label) { set_corner(c.index, mode) }
          sub.set_validation_proc(item) { current == mode ? MF_CHECKED : MF_ENABLED }
        end
        sub.add_separator
        item = sub.add_item('全体の設定に戻す') { set_corner(c.index, nil) }
        sub.set_validation_proc(item) { own ? MF_ENABLED : MF_GRAYED }
      end

      def set_corner(index, mode)
        @ctrl.set_corner_mode(index, mode)
        @message = nil
      rescue Core::Error => e
        @message = e.message
        UI.messagebox("角の納まりを変更できませんでした。\n#{e.message}")
      ensure
        notify_panel
        update_status
        Sketchup.active_model.active_view.invalidate
      end

      def selection_info
        return nil if @selection.empty?

        pc = @selection.first
        seg = @engine.segment_of(pc)
        {
          'orientation' => pc.orientation == :v ? '縦目地' : '横目地',
          'orient' => pc.orientation.to_s,
          'position' => pc.position.round(1),
          'length' => @selection.sum(&:length).round(1),
          'count' => @selection.size,
          'status' => seg ? seg.status : '-',
          'mode' => @mode == :through ? '通り目地' : '部分目地'
        }
      end

      # ---- 描画 ------------------------------------------------------------------

      def draw(view)
        return unless @ctrl.valid?

        s = draw_offset
        if @drag && @plan
          color = @plan.ok? ? COLOR_PREVIEW : COLOR_INVALID
          @plan.preview_faces.each { |f| draw_polygon(view, f.points, s, COLOR_AFFECTED, 2) } if @plan.ok?
          lines = @plan.ok? ? @plan.preview_lines : naive_moved_lines
          lines.each { |a, b| draw_uv_line(view, a, b, s, color, 4) }
          draw_label(view, @plan.ok? ? drag_label : @plan.errors.first, color)
        else
          @selection.each { |pc| draw_uv_line(view, pc.a, pc.b, s, COLOR_SELECT, 4) }
          draw_uv_line(view, @hover.a, @hover.b, s, COLOR_HOVER, 3) if @hover
        end
      end

      def getExtents
        bb = Geom::BoundingBox.new
        b = @ctrl.group.bounds
        tr = @ctrl.world_transform
        (0..7).each { |i| bb.add(b.corner(i).transform(tr)) }
        bb
      end

      private

      # Undo/Redo で保存データが変わっていたら読み直す（選択は破棄）
      def sync!
        return false unless @ctrl.valid?

        if @ctrl.refresh! || !@engine.doc.equal?(@ctrl.doc)
          @engine = Core::EditEngine.new(@ctrl.doc)
          @snapper = Core::Snapper.new(@ctrl.doc)
          @selection = []
          @hover = nil
          cancel_drag
          notify_panel
        end
        true
      rescue Core::PersistenceError => e
        @message = e.message
        false
      end

      def draw_offset
        _s_in, s_out = @ctrl.doc.settings.s_range
        s_out + 1.0
      end

      def uv_at(x, y, view)
        ray = view.pickray(x, y)
        inv = @ctrl.world_transform.inverse
        o = Units.point_mm(ray[0].transform(inv))
        d = ray[1].transform(inv)
        _s_in, s_out = @ctrl.doc.settings.s_range
        hit = @ctrl.doc.surface.intersect_ray(o, [d.x, d.y, d.z], s_out)
        return nil unless hit

        u = @ctrl.doc.surface.profile.wrap(hit[:u])
        @last_hit_world = Units.point_in(@ctrl.doc.surface.point3d(u, hit[:v], s_out)).transform(@ctrl.world_transform)
        Core::Vec2.new(u, hit[:v])
      end

      def px_to_mm(view, px)
        return 10.0 unless @last_hit_world

        Units.to_mm(view.pixels_to_model(px, @last_hit_world))
      end

      def pick(uv, view)
        @engine.pick(uv, px_to_mm(view, PICK_PX))
      end

      def includes_piece?(list, piece)
        list.any? { |pc| pc.a.near?(piece.a) && pc.b.near?(piece.b) }
      end

      def toggle(list, pieces)
        out = list.dup
        pieces.each do |pc|
          if includes_piece?(out, pc)
            out.reject! { |x| x.a.near?(pc.a) && x.b.near?(pc.b) }
          else
            out << pc
          end
        end
        out
      end

      def start_drag(kind)
        return if @selection.empty? || @press.nil? || @press[2].nil?

        @drag = { origin: @press[2], delta: 0.0, kind: kind }
        @plan = nil
        return unless kind == :click

        Sketchup.status_text = 'マウスを動かして位置を決め、クリックで確定（数値入力も可・Esc で取り消し）'
      end

      def update_drag(x, y, view, flags)
        uv = uv_at(x, y, view)
        return unless uv

        orient = @selection.first.orientation
        raw = orient == :v ? uv.x - @drag[:origin].x : uv.y - @drag[:origin].y
        if @ctrl.doc.periodic? && orient == :v
          l = @ctrl.doc.period
          raw -= l * (raw / l).round
        end
        # Alt(Command) を押している間はスナップしない
        free = (flags & ALT_MODIFIER_MASK) != 0
        snap = free ? Core::Snapper::Result.new(raw, nil) : @snapper.snap(@selection, raw, px_to_mm(view, SNAP_PX))
        @drag[:delta] = snap.delta
        @drag[:snap] = snap.label
        @plan = snap.delta.abs < Core::Tol::POINT ? nil : @engine.plan_move(@selection, snap.delta, mode: @mode)
        Sketchup.vcb_value = Units.format_mm(snap.delta)
        Sketchup.status_text = @plan && !@plan.ok? ? "⚠ #{@plan.errors.first}" : drag_label
      end

      def drag_label
        return '' unless @drag

        txt = format('移動 %+.1f mm', @drag[:delta])
        txt += "（スナップ: #{@drag[:snap]}）" if @drag[:snap]
        txt += " / 変更される石 #{@plan.changed_panel_ids.size + @plan.panel_adds.size} 枚" if @plan&.ok?
        txt
      end

      def commit_drag
        plan = @plan
        delta = @drag[:delta]
        cancel_drag
        if plan.nil?
          @message = nil
          return
        end
        commit(plan, '石割付: 目地移動') { shift_selection(delta) }
      end

      def cancel_drag
        @drag = nil
        @plan = nil
      end

      def commit(plan, name)
        unless plan.ok?
          @message = plan.errors.first
          UI.beep
          update_status
          return
        end
        @ctrl.commit_plan(plan, name)
        @engine = Core::EditEngine.new(@ctrl.doc)
        @snapper = Core::Snapper.new(@ctrl.doc)
        yield if block_given?
        revalidate_selection
        @message = nil
      rescue Core::Error => e
        @message = e.message
        UI.messagebox("編集を確定できませんでした。\n#{e.message}")
      rescue StandardError => e
        report_exception(e, '編集を確定できませんでした')
      ensure
        notify_panel
        update_status
        Sketchup.active_model.active_view.invalidate
      end

      # イベント処理中の予期しないエラーを黙って捨てない
      def guard(view)
        yield
      rescue StandardError => e
        cancel_drag
        report_exception(e, '目地編集でエラーが発生しました')
        view&.invalidate
      end

      def report_exception(e, title)
        Core::Log.error("#{title}: #{e.class}: #{e.message}", at: (e.backtrace || []).first(6))
        @message = "#{title}（#{e.message}）"
        update_status
        return if @error_shown

        @error_shown = true
        UI.messagebox("#{title}。\n#{e.class}: #{e.message}\n\n詳細は ウィンドウ → Ruby コンソール に出力しています。")
      end

      def shift_selection(mm)
        @selection = @selection.map do |pc|
          d = pc.orientation == :v ? Core::Vec2.new(mm, 0) : Core::Vec2.new(0, mm)
          Core::Piece.new(pc.segment_id, pc.a + d, pc.b + d)
        end
      end

      def revalidate_selection
        @selection = @selection.filter_map do |pc|
          mid = (pc.a + pc.b) * 0.5
          @engine.pick(mid, 0.5)
        end
      end

      def naive_moved_lines
        return [] unless @drag

        @selection.map do |pc|
          d = pc.orientation == :v ? Core::Vec2.new(@drag[:delta], 0) : Core::Vec2.new(0, @drag[:delta])
          [pc.a + d, pc.b + d]
        end
      end

      def world_points(a, b, s)
        tr = @ctrl.world_transform
        @ctrl.doc.surface.polyline3d(a, b, s).map { |p| Units.point_in(p).transform(tr) }
      end

      def draw_uv_line(view, a, b, s, color, width)
        pts = world_points(a, b, s)
        return if pts.size < 2

        view.drawing_color = to_color(color)
        view.line_width = width
        view.line_stipple = ''
        view.draw(GL_LINE_STRIP, pts)
      end

      def draw_polygon(view, points, s, color, width)
        Core::Polygon.edges(points).each { |a, b| draw_uv_line(view, a, b, s, color, width) }
      end

      def draw_label(view, text, color)
        return unless text && @last_hit_world

        sp = view.screen_coords(@last_hit_world)
        view.drawing_color = to_color(color)
        view.draw_text(Geom::Point3d.new(sp.x + 16, sp.y - 24, 0), text.to_s)
      end

      def to_color(c)
        c.is_a?(Array) && defined?(Sketchup::Color) ? Sketchup::Color.new(*c) : c
      end

      def update_status
        info = selection_info
        base = '目地をクリック → 動かして → クリックで移動（ドラッグでも可） / Shift: 通り目地 / 数値入力: 正確な移動 / Delete: 削除 / 右クリック: 追加・角の納まり'
        Sketchup.status_text = @message ? "⚠ #{@message}" : (info ? "#{info['mode']} #{info['orientation']} 位置 #{info['position']}mm  |  #{base}" : base)
        Sketchup.vcb_label = '移動量'
      end

      def notify_panel
        EditPanel.instance.refresh(self)
      end

      def warn_integrity(force: false)
        issues = @ctrl.check_integrity
        if issues.empty?
          UI.messagebox('割付データと石の形状は一致しています。') if force
          return
        end
        list = issues.first(8).map(&:message).join("\n")
        msg = "#{issues.size} 件の不整合があります。\n#{list}\n\n" \
              "[はい] 割付データから石を作り直す\n[いいえ] 変更された石を割付から切り離す\n[キャンセル] そのまま続ける"
        case UI.messagebox(msg, MB_YESNOCANCEL)
        when IDYES
          ids = issues.reject { |i| i.kind == :orphan }.map(&:panel_id)
          @ctrl.repair(ids) unless ids.empty?
        when IDNO
          ids = issues.select { |i| i.kind == :modified }.map(&:panel_id)
          @ctrl.detach(ids) unless ids.empty?
        end
        sync!
      rescue Core::Error => e
        UI.messagebox("整合性の修復に失敗しました。\n#{e.message}")
      end
    end
  end
end
