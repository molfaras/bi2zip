# frozen_string_literal: true

require_relative 'rle'

module Bi2zip
  # Picks the zero-run length-field width that minimises the encoded rules
  # length for a given raw-rules bit-string. Walks the legal range (4..16) high
  # to low and bails on the first regression: typical rule streams favour the
  # top of the range, so most forward trials are wasted. Heuristic — non-
  # unimodal cost curves can miss a global optimum, traded for the speedup.
  # Ties resolve to the largest ZLB seen because the loop walks high to low
  # and only updates on strict improvement.
  module ZlbTuner
    # Mirrors Bi2zip::Compress::ZLB_RANGE. Keep them in sync.
    ZLB_RANGE = (4..16).freeze

    module_function

    def best(raw_rules)
      best_zlb = nil
      best_encoded = nil
      ZLB_RANGE.to_a.reverse.each do |zlb|
        encoded = RLE.encode(raw_rules, zero_len_bits: zlb)
        break if best_encoded && encoded.length >= best_encoded.length

        best_zlb = zlb
        best_encoded = encoded
      end
      [best_zlb, best_encoded]
    end
  end
end
