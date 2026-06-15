# frozen_string_literal: true

module Bi2zip
  # Picks the parts value (chunk width) that minimises the total output for a
  # given input. Walks the legal range (4..16) high to low and bails on the
  # first regression: typical inputs peak near the top of the range, so most
  # forward trials are wasted. Heuristic — non-unimodal cost curves can miss a
  # global optimum, traded for the speedup. Ties resolve to the largest parts
  # seen because the loop only updates on strict improvement.
  module PartsTuner
    module_function

    def best(bytes:, algorithms:, zlb:, max_passes:)
      best = nil
      Compress::PARTS_RANGE.to_a.reverse.each do |parts|
        result = Compress.call(
          bytes: bytes, parts: parts, algorithms: algorithms,
          zlb: zlb, max_passes: max_passes,
        )
        break if best && result.bytes.bytesize >= best.bytes.bytesize

        best = result
      end
      best
    end
  end
end
