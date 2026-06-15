# frozen_string_literal: true

module Bi2zip
  # Binary <-> reflected Gray code conversion on fixed-width bit strings.
  module Gray
    def self.encode(binary_string)
      num = binary_string.to_i(2)
      gray = num ^ (num >> 1)
      gray.to_s(2).rjust(binary_string.length, '0')
    end

    def self.decode(gray_string)
      g = gray_string.to_i(2)
      b = g
      shift = 1
      while (g >> shift).positive?
        b ^= (g >> shift)
        shift += 1
      end
      b.to_s(2).rjust(gray_string.length, '0')
    end
  end
end
