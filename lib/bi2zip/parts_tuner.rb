# frozen_string_literal: true

module Bi2zip
  # Picks the parts value (chunk width) that minimises the total output for a
  # given input. Walks the full legal range (4..16) and keeps whichever value
  # produces the smallest bi2zip stream. Brute force: the range is small but
  # each trial runs the full compressor, so this is the slow part of :auto.
  module PartsTuner
    module_function

    def best(bytes:, algorithms:, zlb:, max_passes:)
      Compress::PARTS_RANGE.map do |parts|
        Compress.call(
          bytes: bytes, parts: parts, algorithms: algorithms,
          zlb: zlb, max_passes: max_passes,
        )
      end.min_by { |r| r.bytes.bytesize }
    end
  end
end
