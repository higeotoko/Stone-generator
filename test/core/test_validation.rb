# frozen_string_literal: true

require_relative '../test_helper'

# 仕様 18-8: 例外処理
class TestValidation < Minitest::Test
  include StoneTestHelpers

  def test_zero_and_negative_values
    assert_match(/ゼロ/, Settings.new('stone_width' => 0).validate.join)
    assert_match(/負/, Settings.new('thickness' => -30).validate.join)
    assert_raises(InvalidInput) { flat_doc('thickness' => -1) }
    assert_raises(InvalidInput) { Settings.new('stone_width' => 'abc') }
    refute_empty Settings.new('joint_v' => 1000).validate
  end

  def test_discontinuous_profile
    assert_raises(InvalidInput) do
      Profile.new([LineSegment2.new(v2(0, 0), v2(10, 0)), LineSegment2.new(v2(20, 0), v2(30, 0))])
    end
  end

  def test_zero_length_segment
    assert_raises(InvalidInput) { LineSegment2.new(v2(0, 0), v2(0, 0)) }
  end

  def test_hairpin_profile_cannot_be_thickened
    prof = Profile.new([LineSegment2.new(v2(0, 0), v2(1000, 0)), LineSegment2.new(v2(1000, 0), v2(0, 0))])
    assert_raises(GeometryError) { prof.offset_point(1000, -30) }
  end

  def test_inner_corner_fold_detected
    # 出隅（左折）で内側へ厚みを付けると、角の近くだけを跨ぐ短い石は背面が折り返す
    prof = Profile.new([LineSegment2.new(v2(0, 0), v2(1000, 0)), LineSegment2.new(v2(1000, 0), v2(1000, 1000))])
    surf = SurfaceDefinition.rectangle(prof, 0, 600)
    mesher = StoneMesh.new(surf, -30, 0)
    outline = [v2(990, 0), v2(1010, 0), v2(1010, 600), v2(990, 600)]
    assert_raises(GeometryError) { mesher.build(outline) }
    # 十分に長い石なら角を跨いでも成立する（L字断面の石）
    long = [v2(500, 0), v2(1500, 0), v2(1500, 600), v2(500, 600)]
    assert mesher.build(long).manifold?
  end

  def test_settings_merge_and_layout_change_detection
    s = Settings.new
    refute s.layout_changed?(s.merge('thickness' => 40))
    assert s.layout_changed?(s.merge('stone_width' => 800))
  end
end
