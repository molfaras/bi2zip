# frozen_string_literal: true

module Bi2zip
  # Unsigned LEB128 (varint): 7 bits per byte LSB-first, high bit set on
  # every byte except the last. Used by the .bi2zip header and per-pass
  # headers to keep small integers cheap.
  module Varint
    # Cap at 9 bytes (covers values up to 2^63). The values we encode are bit
    # lengths and byte counts on inputs that fit in memory, so any varint that
    # spills past this is malformed input, not a legitimate big value.
    MAX_BYTES = 9

    module_function

    def encode(value)
      raise ArgumentError, "varint value must be non-negative (got #{value})" if value.negative?

      out = ''.b
      loop do
        byte = value & 0x7F
        value >>= 7
        if value.zero?
          out << byte
          return out
        end
        out << (byte | 0x80)
      end
    end

    # Reads one varint starting at `cursor` and returns [value, next_cursor].
    # Raises when the stream ends before the terminating byte (continuation
    # bit cleared) is reached.
    def decode(bytes, cursor)
      value = 0
      shift = 0
      MAX_BYTES.times do
        byte = bytes.getbyte(cursor)
        raise ArgumentError, 'truncated varint' if byte.nil?

        cursor += 1
        value |= (byte & 0x7F) << shift
        return [value, cursor] if (byte & 0x80).zero?

        shift += 7
      end
      raise ArgumentError, "varint exceeds #{MAX_BYTES} bytes"
    end
  end
end
