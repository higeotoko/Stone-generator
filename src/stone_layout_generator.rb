# frozen_string_literal: true

# Stone Layout Generator - SketchUp 拡張の登録ファイル
# このファイルとフォルダ stone_layout_generator/ を SketchUp の Plugins フォルダに置く。
require 'sketchup.rb'
require 'extensions.rb'
require_relative 'stone_layout_generator/core/version'

module Higeotoko
  module StoneLayout
    unless file_loaded?(__FILE__)
      ext = SketchupExtension.new('Stone Layout Generator', File.join(__dir__, 'stone_layout_generator', 'main'))
      ext.description = '壁面・R面・丸柱への石材割付と、目地の直接編集'
      ext.version = VERSION
      ext.creator = 'higeotoko'
      Sketchup.register_extension(ext, true)
      file_loaded(__FILE__)
    end
  end
end
