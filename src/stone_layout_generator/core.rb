# frozen_string_literal: true

# Stone Layout Generator - 幾何エンジン（純Ruby / SketchUp非依存）
#
# このファイルを require するだけで、SketchUp なしでも割付エンジン全体が動く。
# 長さの単位はすべて mm（Float）。SketchUp の内部単位（inch）への変換は
# sketchup/units.rb だけが担当する。
module Higeotoko
  module StoneLayout
    module Core
    end
  end
end

dir = File.join(__dir__, 'core')
%w[
  version
  tolerance
  errors
  log
  geometry/vec2
  geometry/geom2
  geometry/polygon
  geometry/spatial_grid
  geometry/arrangement
  geometry/polygon_ops
  surface/profile_segments
  surface/profile
  surface/profile_builder
  surface/surface_definition
  layout/settings
  layout/joint_segment
  panel/panel
  panel/outline_builder
  layout/face_extractor
  layout/layout_document
  layout/auto_layout
  layout/layout_builder
  layout/working_set
  layout/edit_plan
  layout/edit_engine
  layout/snapper
  mesh/mesh
  mesh/corner_joint
  mesh/stone_mesh
  mesh/stone_geometry
  persistence/serializer
].each { |f| require File.join(dir, f) }
