# frozen_string_literal: true

module Higeotoko::StoneLayout::Core
  # 石寸法一覧・数量集計（発注・積算用）。
  #
  # 寸法は石の実輪郭（目地幅・逃げを差し引いたもの）の展開寸法:
  #   幅 = 断面に沿った長さ（曲面では基準面の弧長）、高さ = 鉛直方向の長さ
  # 体積・重量は 3D 形状から計算するので、角の納まり（留め・勝ち負け）も反映される。
  # 同じ形状・寸法・厚さ・備考の石を 1 つの種別にまとめ、枚数の多い順に A, B, C … を付ける。
  module Schedule
    Row = Struct.new(:panel_id, :label, :type, :shape, :width, :height, :thickness,
                     :area, :volume, :weight, :u0, :u1, :v0, :v1, :note)
    Type = Struct.new(:code, :shape, :width, :height, :thickness, :note, :count, :area, :volume, :weight, :labels)
    Result = Struct.new(:rows, :types, :totals, :errors, :detached)

    MODE_NAMES = { 'miter' => '留め', 'win_prev' => '左勝ち', 'win_next' => '右勝ち' }.freeze

    module_function

    def build(doc)
      geo = StoneGeometry.new(doc)
      density = doc.settings['density']
      thickness = doc.settings['thickness']
      rows = []
      errors = []
      detached = 0
      doc.panels.values.sort_by(&:label).each do |p|
        if p.detached?
          detached += 1
          next
        end
        begin
          b = geo.build(p)
        rescue GeometryError => e
          errors << e.message
          next
        end
        ob = Polygon.bbox(b.outline)
        vol_m3 = b.volume / 1.0e9
        rows << Row.new(p.id, format('Stone_%04d', p.label), nil, shape_of(doc, b.outline),
                        (ob[2] - ob[0]).round(1), (ob[3] - ob[1]).round(1), thickness,
                        (b.face_area / 1.0e6).round(4), vol_m3.round(6), (vol_m3 * density * 1000).round(1),
                        ob[0].round(1), ob[2].round(1), ob[1].round(1), ob[3].round(1), note_of(doc, p))
      end
      types = classify(rows)
      totals = {
        'count' => rows.size,
        'types' => types.size,
        'area' => rows.sum(&:area).round(3),
        'volume' => rows.sum(&:volume).round(6),
        'weight' => rows.sum(&:weight).round(1),
        'density' => density,
        'thickness' => thickness
      }
      Result.new(rows, types, totals, errors, detached)
    end

    # 形状: 矩形 / 異形 / 曲面 R…（曲面は異形と併記）
    def shape_of(doc, outline)
      pts, = Polygon.simplify(outline)
      rect = pts.size == 4 && Polygon.edges(pts).all? { |a, b| (a.x - b.x).abs <= Tol::POINT || (a.y - b.y).abs <= Tol::POINT }
      base = rect ? '矩形' : '異形'
      u0, u1 = outline.map(&:x).minmax
      radii = []
      doc.surface.profile.each_segment_in(u0 + Tol::POINT, u1 - Tol::POINT) do |seg|
        radii << seg.radius.round unless !seg.is_a?(ArcSegment2) || radii.include?(seg.radius.round)
      end
      radii.empty? ? base : "#{base}・曲面 R#{radii.join('/R')}"
    end

    def note_of(doc, panel)
      notes = []
      CornerJoint.corners(doc.surface.profile).each do |c|
        next unless CornerJoint.at?(doc.surface, panel.bbox[0], c.u) || CornerJoint.at?(doc.surface, panel.bbox[2], c.u)

        notes << "#{c.outer ? '出隅' : '入隅'}#{MODE_NAMES[doc.settings.corner_mode_at(c.index)]}"
      end
      notes << '開口まわり' if panel.flags.include?('O')
      notes.join(' / ')
    end

    def classify(rows)
      groups = rows.group_by { |r| [r.shape, r.width, r.height, r.thickness, r.note] }
      ordered = groups.sort_by { |(shape, w, h, _t, note), list| [-list.size, shape, -w, -h, note] }
      ordered.each_with_index.map do |((shape, w, h, t, note), list), i|
        code = type_code(i)
        list.each { |r| r.type = code }
        Type.new(code, shape, w, h, t, note, list.size, list.sum(&:area).round(4), list.sum(&:volume).round(6),
                 list.sum(&:weight).round(1), list.map(&:label))
      end
    end

    # 0 → A, 25 → Z, 26 → AA …
    def type_code(i)
      s = +''
      n = i
      loop do
        s.prepend((65 + n % 26).chr)
        n = n / 26 - 1
        break if n.negative?
      end
      s
    end

    def to_h(result)
      {
        'totals' => result.totals,
        'types' => result.types.map { |t| t.to_h.transform_keys(&:to_s) },
        'rows' => result.rows.map { |r| r.to_h.transform_keys(&:to_s) },
        'errors' => result.errors,
        'detached' => result.detached
      }
    end

    # Excel でそのまま開ける CSV（UTF-8 BOM 付き）
    def to_csv(result, title)
      lines = []
      t = result.totals
      lines << row([title])
      lines << row(['合計', "#{t['count']} 枚", "#{t['types']} 種別", "表面積 #{t['area']} m2",
                    "体積 #{t['volume']} m3", "重量 #{t['weight']} kg（比重 #{t['density']}）"])
      lines << ''
      lines << row(%w[種別 形状 幅(mm) 高さ(mm) 厚さ(mm) 枚数 表面積計(m2) 体積計(m3) 重量計(kg) 備考 石番号])
      result.types.each do |ty|
        lines << row([ty.code, ty.shape, ty.width, ty.height, ty.thickness, ty.count, ty.area, ty.volume, ty.weight,
                      ty.note, ty.labels.join(' ')])
      end
      lines << ''
      lines << row(%w[石番号 種別 形状 幅(mm) 高さ(mm) 厚さ(mm) 表面積(m2) 体積(m3) 重量(kg) 位置u始(mm) 位置u終(mm) 位置v始(mm) 位置v終(mm) 備考])
      result.rows.each do |r|
        lines << row([r.label, r.type, r.shape, r.width, r.height, r.thickness, r.area, r.volume, r.weight,
                      r.u0, r.u1, r.v0, r.v1, r.note])
      end
      unless result.errors.empty?
        lines << ''
        lines << row(['形状を作れなかった石'])
        result.errors.each { |e| lines << row([e]) }
      end
      "﻿" + lines.join("\r\n") + "\r\n"
    end

    def row(values)
      values.map { |v| csv_cell(v) }.join(',')
    end

    def csv_cell(v)
      s = v.is_a?(Float) && v == v.round ? v.round.to_s : v.to_s
      s =~ /[",\r\n]/ ? "\"#{s.gsub('"', '""')}\"" : s
    end
  end
end
