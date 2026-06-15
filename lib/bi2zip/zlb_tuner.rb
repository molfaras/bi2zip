# frozen_string_literal: true

require_relative 'rle'

module Bi2zip
  # Picks the zero-run length-field width that minimises the encoded rules
  # length for a given raw-rules bit-string. Walks the legal range (4..16) end
  # to end and keeps whichever ZLB yields the shortest output. Brute force —
  # the range is small and the encoder is cheap. Ties resolve to the smallest
  # ZLB seen because the loop only updates on strict improvement.
  module ZlbTuner
    # Mirrors Bi2zip::Compress::ZLB_RANGE. Keep them in sync.
    ZLB_RANGE = (4..16).freeze

    module_function

    def best(raw_rules)
      ZLB_RANGE.each_with_object([nil, nil]) do |zlb, acc|
        encoded = RLE.encode(raw_rules, zero_len_bits: zlb)
        if acc[1].nil? || encoded.length < acc[1].length
          acc[0] = zlb
          acc[1] = encoded
        end
      end
    end
  end
end
