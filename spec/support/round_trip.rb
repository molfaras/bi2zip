# frozen_string_literal: true

module Bi2zipSupport
  module RoundTrip
    module_function

    def round_trip(bytes, parts: :auto, algorithms: Bi2zip::Algorithms::ALL,
                   zlb: :auto, max_passes: :auto)
      result = Bi2zip::Compress.call(
        bytes: bytes, parts: parts, algorithms: algorithms,
        zlb: zlb, max_passes: max_passes,
      )
      restored = Bi2zip::Decompress.call(bytes: result.bytes)
      [result, restored]
    end

    def fixtures
      {
        'empty input' => [],
        'single byte' => [0xAB],
        'exactly PARTS bytes' => (1..12).to_a,
        'PARTS + 1 bytes (one leftover)' => (1..13).to_a,
        'two full chunks of zeros' => Array.new(24, 0),
        'two full chunks of 0xFF' => Array.new(24, 0xFF),
        'alternating 0x00 / 0xFF chunks' => Array.new(36) { |i| (i / 12).even? ? 0x00 : 0xFF },
        'random 257 bytes (seed 42)' => Random.new(42).bytes(257).bytes,
        'random 1000 bytes (seed 7)' => Random.new(7).bytes(1000).bytes,
      }
    end
  end
end
