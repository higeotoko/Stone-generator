# frozen_string_literal: true

module Higeotoko
  module StoneLayout
    # Core::Mesh → SketchUp の石グループ。
    #
    # 元データ（LayoutDocument）は変更しない。石グループは何度でも破棄・再生成できる。
    # 石グループ自体は再生成時も同じ Group を使い回す（利用者が付けたタグ・材質を保つ）。
    class GeometryBuilder
      def initialize(layout_group, doc)
        @group = layout_group
        @doc = doc
      end

      # built_list: [Core::StoneGeometry::Built], index: panel_id => Group
      def rebuild(built_list, index)
        built_list.each do |b|
          panel = @doc.panels[b.panel_id]
          stone = index[b.panel_id]
          if stone&.valid?
            stone.entities.clear!
          else
            stone = @group.entities.add_group
            index[b.panel_id] = stone
          end
          stone.name = format('Stone_%04d', panel.label)
          fill(stone.entities, b.mesh)
          apply_material(stone, panel)
          ModelStore.tag_stone(stone, @doc, panel, signature(b.mesh))
          write_attributes(stone, b, panel)
        end
      end

      def remove(ids, index)
        ids.each do |id|
          g = index.delete(id)
          g.erase! if g&.valid?
        end
      end

      # 石グループの形状シグネチャ（bbox を 0.1mm 単位で丸めたもの）
      def signature(mesh)
        lo, hi = mesh.bbox
        (lo + hi).map { |c| (c * 10).round }.join(',')
      end

      # 0.1mm 単位のシグネチャ同士を、丸め誤差（±1）を許して比べる
      def same_signature?(a, b)
        return false unless a && b

        x = a.split(',').map(&:to_i)
        y = b.split(',').map(&:to_i)
        x.size == y.size && x.zip(y).all? { |p, q| (p - q).abs <= 1 }
      end

      def current_signature(stone)
        bb = stone.bounds
        [bb.min.x, bb.min.y, bb.min.z, bb.max.x, bb.max.y, bb.max.z].map { |c| (Units.to_mm(c) * 10).round }.join(',')
      end

      private

      def fill(ents, mesh)
        pts = mesh.points.map { |p| Units.point_in(p) }
        soft = {}
        failed = 0
        mesh.polygons.each do |pl|
          begin
            face = ents.add_face(pl.indices.map { |i| pts[i] })
          rescue ArgumentError => e
            failed += 1
            Core::Log.warn("面を作れませんでした: #{e.message}", points: pl.indices.map { |i| mesh.points[i].map { |c| c.round(3) } })
            next
          end
          next unless face

          n = mesh.normal_of(pl)
          face.reverse! if face.normal.dot(Geom::Vector3d.new(*n)).negative?
          k = pl.indices.size
          pl.soft.each_with_index do |s, i|
            next unless s

            a = pl.indices[i]
            b = pl.indices[(i + 1) % k]
            soft[a < b ? [a, b] : [b, a]] = true
          end
        end
        raise Core::GeometryError, "石の面を #{failed} 枚作れませんでした（Ruby コンソールに詳細）" if failed.positive?
        return if soft.empty?

        lookup = {}
        mesh.points.each_with_index { |p, i| lookup[key_mm(p)] = i }
        ents.grep(Sketchup::Edge).each do |e|
          a = lookup[key_mm(Units.point_mm(e.start.position))]
          b = lookup[key_mm(Units.point_mm(e.end.position))]
          next unless a && b && soft[a < b ? [a, b] : [b, a]]

          e.soft = true
          e.smooth = true
        end
      end

      def key_mm(p)
        p.map { |c| (c * 100).round }
      end

      def apply_material(stone, panel)
        name = panel.material || @doc.settings['material']
        return unless name && !name.empty?

        mats = @group.model.materials
        mat = mats[name] || mats.add(name)
        stone.material = mat
      end

      def write_attributes(stone, built, panel)
        d = ModelStore::DICT
        stone.set_attribute(d, 'label', panel.label)
        stone.set_attribute(d, 'thickness_mm', @doc.settings['thickness'])
        stone.set_attribute(d, 'face_area_m2', (built.face_area / 1.0e6).round(5))
        stone.set_attribute(d, 'volume_m3', (built.volume / 1.0e9).round(6))
        bb = panel.bbox
        stone.set_attribute(d, 'u_range_mm', [bb[0].round(1), bb[2].round(1)])
        stone.set_attribute(d, 'v_range_mm', [bb[1].round(1), bb[3].round(1)])
      end
    end
  end
end
