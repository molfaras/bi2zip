# frozen_string_literal: true

module Bi2zip
  VERSION = '0.1.0'
end

require_relative 'bi2zip/gray'
require_relative 'bi2zip/rle'
require_relative 'bi2zip/varint'
require_relative 'bi2zip/algorithms'
require_relative 'bi2zip/zlb_tuner'
require_relative 'bi2zip/compress'
require_relative 'bi2zip/parts_tuner'
require_relative 'bi2zip/decompress'
