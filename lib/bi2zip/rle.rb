# frozen_string_literal: true

module Bi2zip
  # Run-length encoding for the bi2zip rule stream.
  #
  # A run of K '1' bits is emitted verbatim as K '1' bits. A run of K '0' bits
  # is emitted as one or more chunks of '0' + ZERO_LEN_BITS-bit length field;
  # an all-zero length field encodes 2**ZERO_LEN_BITS zeros, any other value N
  # encodes N zeros. The scheme is a Huffman-style prefix code that pays off
  # only when zero runs are long; that's a property of the algorithm.
  module RLE
    module_function

    def encode(bits, zero_len_bits:)
      max_zero_run = 1 << zero_len_bits
      out = +''
      i = 0
      while i < bits.length
        bit = bits[i]
        j = i + 1
        j += 1 while j < bits.length && bits[j] == bit
        out << encode_run(bit, j - i, zero_len_bits, max_zero_run)
        i = j
      end
      out
    end

    def decode(encoded, zero_len_bits:)
      max_zero_run = 1 << zero_len_bits
      out = +''
      i = 0
      while i < encoded.length
        case encoded[i]
        when '1'
          out << '1'
          i += 1
        when '0'
          if i + zero_len_bits >= encoded.length
            raise ArgumentError, 'truncated zero-run length field in encoded rules'
          end

          field = encoded[i + 1, zero_len_bits].to_i(2)
          count = field.zero? ? max_zero_run : field
          out << ('0' * count)
          i += 1 + zero_len_bits
        else
          raise ArgumentError, "invalid bit #{encoded[i].inspect} at #{i}"
        end
      end
      out
    end

    def encode_run(bit, count, zero_len_bits, max_zero_run)
      return '1' * count if bit == '1'

      out = +''
      remaining = count
      while remaining.positive?
        chunk = [remaining, max_zero_run].min
        field = chunk == max_zero_run ? 0 : chunk
        out << '0' << format("%0#{zero_len_bits}b", field)
        remaining -= chunk
      end
      out
    end
    private_class_method :encode_run
  end
end
