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

      attr_reader :selection, :mode, :message

      def controller
        @ctrl
      end

      def initialize(controller)
        @ctrl = controller
        @selection = []
        @mode = :partial
        @base_mode = :partial # パネル・右クリックで選んだモード。Shift で一時的に反転
        @hover = nil
        @drag = nil
        @plan = nil
        @message = nil
        @menu_uv = nil
      end

      # ---- ライフサイクル --------------------------------------------------------

      def activate
        engine
        # 割付グループが選択されたままだと、石の線がすべて選択色（青）で表示されて目地のハイライトと紛らわしい
        model = @ctrl.model
        @restore_selection = model.selection.to_a.select(&:valid?)
        model.selection.clear
        warn_integrity
        EditPanel.instance.attach(self)
        update_status
      end

      def deactivate(view)
        cancel_drag
        EditPanel.instance.detach(self)
        restore_selection
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
          Core::Log.info('click', uv: uv, piece: piece && [piece.a, piece.b], radius_mm: px_to_mm(view, PICK_PX).round(1),
                                  nearest_joint_mm: uv && engine.nearest_joint_distance(uv)&.round(1),
                                  stones: @ctrl.doc.panels.size, v_range: [@ctrl.doc.surface.v_min.round(1), @ctrl.doc.surface.v_max.round(1)])
          add = (flags & COPY_MODIFIER_MASK) != 0
          through = (flags & CONSTRAIN_MODIFIER_MASK) != 0
          through = @base_mode == :through ? !through : through
          @mode = through ? :through : :partial
          @press_add = add
          if piece
            pieces = through ? engine.through_pieces(piece) : [piece]
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
          @message = if uv.nil?
                       'クリック位置が石の面に当たっていません（割付グループの位置がずれている可能性があります）'
                     elsif piece.nil?
                       '目地が見つかりません。目地の線にもう少し近づけてクリックしてください'
                     end
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

      # Delete キーで選択中の目地を消す。SketchUp の「削除」ショートカットに取られて
      # onKeyDown が届かない環境があるため、onKeyUp でも受ける（同じ押下で二重に消さない）
      def onKeyDown(key, _repeat, _flags, view)
        Core::Log.info('key down', key: key) if delete_key?(key)
        return false unless delete_key?(key)

        @delete_handled = handle_delete(view)
      end

      def onKeyUp(key, _repeat, _flags, view)
        return false unless delete_key?(key)

        Core::Log.info('key up', key: key)
        if @delete_handled
          @delete_handled = false
          return true
        end
        handle_delete(view)
      end

      def delete_key?(key)
        DELETE_KEYS.include?(key) || (defined?(VK_DELETE) && key == VK_DELETE)
      end

      def handle_delete(view)
        return false if @selection.empty?
        return false if @drag && @drag[:kind] == :press

        cancel_drag
        guard(view) { delete_selection }
        view.invalidate
        true
      end

      def getMenu(menu, _flags = nil, _x = nil, _y = nil, _view = nil)
        unless @selection.empty?
          menu.add_item('目地を削除（石を結合）') { delete_selection }
          locked = @selection.any? { |pc| engine.segment_of(pc)&.locked }
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

        plan = engine.plan_move(@selection, mm, mode: @mode)
        commit(plan, '石割付: 目地移動') { |_| shift_selection(mm) }
      end

      # 選択中の目地をすべて消す（通り目地なら各辺を順に消して 1 つの Undo にまとめる）
      def delete_selection
        return if @selection.empty?

        if @selection.size == 1
          plan = engine.plan_delete(@selection.first)
          return commit(plan, '石割付: 目地削除') { @selection = [] }
        end

        pieces = @selection.dup
        change = @ctrl.commit_sequence('石割付: 目地削除') do |eng|
          pieces.map do |pc|
            cur = eng.pick((pc.a + pc.b) * 0.5, 0.5)
            raise Core::Error, '削除する目地が見つかりません' unless cur

            plan = eng.plan_delete(cur)
            raise Core::Error, plan.errors.first unless plan.ok?

            eng.apply(plan)
          end
        end
        @engine = nil
        @selection = []
        @message = nil
        @done = format('目地を %d 辺 消しました（石 %d 枚を結合）', pieces.size, change.removed.size)
      rescue Core::Error => e
        @message = e.message
        UI.beep
      ensure
        notify_panel
        update_status
        Sketchup.active_model.active_view.invalidate
      end

      def add_joint(uv, orient)
        return unless uv

        plan = engine.plan_add(uv, orient)
        commit(plan, '石割付: 目地追加') { @selection = [] }
      end

      def lock_selection(value)
        plan = engine.plan_lock(@selection, value, mode: @mode)
        commit(plan, value ? '石割付: 目地ロック' : '石割付: ロック解除')
      end

      def toggle_mode
        @mode = @mode == :through ? :partial : :through
        @base_mode = @mode
        if @mode == :through && !@selection.empty?
          @selection = engine.through_pieces(@selection.first)
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
        seg = engine.segment_of(pc)
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
        if @drag && @ext_snap && input_point&.display?
          input_point.draw(view)
          view.tooltip = input_point.tooltip if view.respond_to?(:tooltip=)
        end
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

        reloaded = @ctrl.refresh!
        if reloaded || (@engine && !@engine.doc.equal?(@ctrl.doc))
          @engine = nil
          engine
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

      # 目地編集エンジン。activate より先にマウス操作が届いても使えるよう、必要になった時点で作る
      def engine
        if @engine.nil? || !@engine.doc.equal?(@ctrl.doc)
          @engine = Core::EditEngine.new(@ctrl.doc)
          @snapper = Core::Snapper.new(@ctrl.doc)
        end
        @engine
      end

      def snapper
        engine
        @snapper
      end

      def restore_selection
        list = (@restore_selection || []).select(&:valid?)
        list = [@ctrl.group] if list.empty? && @ctrl.valid?
        sel = @ctrl.model.selection
        sel.clear
        sel.add(list)
      rescue StandardError
        nil
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
        engine.pick(uv, px_to_mm(view, PICK_PX))
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
        ext = free ? nil : external_snap(x, y, view)
        @ext_snap = !ext.nil?
        snap = if free then Core::Snapper::Result.new(raw, nil)
               elsif ext then Core::Snapper::Result.new(*ext)
               else snapper.snap(@selection, raw, px_to_mm(view, SNAP_PX))
               end
        @drag[:delta] = snap.delta
        @drag[:snap] = snap.label
        @plan = snap.delta.abs < Core::Tol::POINT ? nil : engine.plan_move(@selection, snap.delta, mode: @mode)
        Sketchup.vcb_value = Units.format_mm(snap.delta)
        Sketchup.status_text = @plan && !@plan.ok? ? "⚠ #{@plan.errors.first}" : drag_label
      end

      def input_point
        @input ||= defined?(Sketchup::InputPoint) ? Sketchup::InputPoint.new : nil
      end

      VERTICAL_EDGE = 0.995 # |方向ベクトルの z| がこれ以上なら鉛直な線とみなす

      # 別のボリューム（壁・柱・サッシ・下絵など）の端点や線へのスナップ。
      # SketchUp 標準の推定（InputPoint）が拾った点を、壁の展開座標へ投影する。
      #   縦目地: 端点、または鉛直な線 → その点の壁に沿った位置 u
      #   横目地: 端点、または水平な線 → その点の高さ v
      # → [移動量 mm, ラベル] / nil
      def external_snap(x, y, view)
        ip = input_point
        return nil unless ip

        ip.pick(view, x, y)
        return nil unless ip.valid? && ip.degrees_of_freedom < 2

        orient = @selection.first.orientation
        if ip.vertex
          return nil if own_geometry?(ip.vertex)

          label = '他の形状の端点'
        elsif ip.edge
          e = ip.edge
          return nil if own_geometry?(e)

          d = e.end.position - e.start.position
          return nil if d.length.zero?

          vz = (d.z / d.length).abs
          return nil if orient == :v ? vz < VERTICAL_EDGE : vz > 1 - VERTICAL_EDGE

          label = '他の形状の線'
        else
          return nil
        end
        local = Units.point_mm(ip.position.transform(@ctrl.world_transform.inverse))
        pc = @selection.first
        target = if orient == :v
                   @ctrl.doc.surface.profile.project(Core::Vec2.new(local[0], local[1]))[0]
                 else
                   local[2]
                 end
        delta = target - pc.position
        if @ctrl.doc.periodic? && orient == :v
          l = @ctrl.doc.period
          delta -= l * (delta / l).round
        end
        [delta, label]
      rescue StandardError => e
        Core::Log.warn("外部スナップに失敗: #{e.message}")
        nil
      end

      # 石割付自身（割付グループ・石グループ）の形状か
      def own_geometry?(ent)
        e = ent.is_a?(Sketchup::Vertex) ? ent.edges.first : ent
        return false unless e

        defn = e.parent
        return false unless defn.respond_to?(:instances)

        defn.instances.any? do |g|
          g == @ctrl.group || (ModelStore.stone_group?(g) && g.get_attribute(ModelStore::DICT, 'layout_id') == @ctrl.doc.id)
        end
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
        @ext_snap = false
      end

      def commit(plan, name)
        unless plan.ok?
          @message = plan.errors.first
          UI.beep
          update_status
          return
        end
        change = @ctrl.commit_plan(plan, name)
        Core::Log.info("#{name}: 確定", regen: change.regenerate, added: change.added, removed: change.removed)
        @engine = nil
        yield if block_given?
        revalidate_selection
        @message = nil
        @done = format('%s しました（作り直した石 %d 枚）', name.sub('石割付: ', ''), change.regenerate.size + change.added.size)
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
          engine.pick(mid, 0.5)
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
        other = @base_mode == :through ? '部分目地' : '通り目地'
        base = "目地をクリック → 動かして → クリックで移動（ドラッグでも可） / Shift+クリック: #{other} / 数値入力: 正確な移動 / Delete: 削除 / 右クリック: 追加・角の納まり"
        head = if @message then "⚠ #{@message}"
               elsif @done then "✔ #{@done}"
               end
        @done = nil
        body = info ? "#{info['mode']} #{info['orientation']} 位置 #{info['position']}mm  |  #{base}" : base
        Sketchup.status_text = head ? "#{head}  |  #{body}" : body
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
