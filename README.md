# bi2zip

A toy bit-level data compressor in Ruby.

## Install and run

```sh
bundle install

# Compress: writes <input>.bi2zip, or nothing if the result wouldn't shrink the input.
bin/bi2zip foo.bin

# Decompress: writes the original filename (input minus .bi2zip).
# If that file exists, picks the next free `name (N).ext` variant.
# Pass an explicit output path to override.
bin/bi2zip foo.bin.bi2zip
bin/bi2zip foo.bin.bi2zip restored.bin

# Tests
bundle exec rspec
```

Mode is inferred from the input extension: `.bi2zip` → decompress, anything else → compress. `bin/bi2zip --help` lists the compress flags (`--parts`, `--algorithms`, `--zlb`, `--max-passes`); each defaults to `auto`.

## How it works

Slice the input into N-byte chunks (`PARTS=N`), transpose into N parallel bit-strings (stripes), then for each bit-index `i` form an N-bit column from bit `i` of each stripe. Walk left to right and, for the active transform, emit a `1` to the rule stream and drop `column[i]` whenever `forward(transform, column[i]) == column[i+1]`; otherwise emit `0`. Replay in reverse to decompress.

Six transforms: `:eq` (equality), `:inv` (bit flip), `:lshift`/`:rshift` (one-bit rotates), `:lgray`/`:rgray` (binary↔Gray code). Each pass pre-scans every transform on a cloned stripe array and picks the one with the most matches.

The rule stream is RLE-encoded: ones pass through, zero runs become `0` plus a `Z`-bit count field. `Z` is chosen per pass by brute-forcing the legal range.

Auto-tuning:

- `PARTS` and `ZLB` are brute-forced over `4..16`; both tuners walk top-down (`16, 15, 14…`) and bail on the first regression. Assumes the cost curve is mostly unimodal from the top; can miss a better value lower in the range. Pin `--parts N` or `--zlb N` to skip the tuner.
- `max-passes` ranges over `1..10` and stops when the next pass would grow total output (1-step lookahead, not globally optimal).
- The CLI compares total output to input. If output isn't strictly smaller, no files are written and it exits 0 with a stderr line. The library returns a `Result` regardless; the abort is at the CLI boundary.

## On disk

One `.bi2zip` file per compressed input:

```
byte 0           4 bits  PARTS - 4
                 4 bits  reserved (must be zero)
varint           original byte count
varint           stripe bit length

stripes block    PARTS * ceil(stripe_bit_length / 8) raw bytes
leftover         (original_byte_count mod PARTS) bytes from the partial last chunk

pass blocks      zero or more, until EOF:
  byte 0         4 bits  algorithm id
                 4 bits  ZLB - 4
  varint         encoded rule bit length
  bytes          ceil(bit_length / 8) packed rule bits
```

Integer fields use unsigned LEB128 (7 payload bits per byte LSB-first, high bit set on every byte except the last). Pass count is implicit — the decoder stops at EOF.

Decompression replays the pass blocks in reverse order to reconstruct the stripes, then de-interleaves into the original byte stream.

## Results

ratio = `bi2zip output bytes / input bytes`. Below 1 = compressed; at or above 1 = the CLI aborts and writes nothing. All numbers use `auto` defaults; the "parts" column shows what auto picked.

### Real PDFs

`gzip` column is `gzip -9`.

| file | size | bi2zip ratio | bytes saved | gzip ratio | passes |
|---|---|---|---|---|---|
| `1654473342.PDF` | 44.9 KB | 0.976 | 1060 | 0.883 | 5 |
| `Professional Tenant Form.pdf` | 196 KB | 0.995 | 1025 | 0.785 | 7 |
| `Ваш поліс ОСЦПВ.pdf` | 207 KB | 1.000 | 47 | 0.871 | 2 |
| `RA_04166.pdf` | 2.07 MB | 0.999 | 2343 | 0.926 | 4 |

PDFs already contain zlib-compressed object streams, so there's little bit-column structure left to find. `gzip -9` beats bi2zip by 8–22 percentage points on every file.

Wall time on the 2 MB PDF is ~5 minutes under `parts=auto`. Pinning `--parts 16` skips the auto-tune.

### Random data — aborts

| input | parts | passes | would-be ratio | CLI |
|---|---|---|---|---|
| random 10 KB | 13 | 0 | 1.000 | ABORT |
| random 100 KB | 16 | 0 | 1.000 | ABORT |

Auto picks a `PARTS` that produces zero passes; the would-be output is the input plus the global header.

### Constant / low-entropy

| input | parts | passes | ratio | CLI |
|---|---|---|---|---|
| zeros 100 KB | 16 | 10 | 0.064 | OK |
| alternating 0x00/0xFF 100 KB | 16 | 10 | 0.064 | OK |

With `PARTS=16` the alternating input produces constant stripes (stripe 0 all `0x00`, stripe 1 all `0xFF`, …), so every bit-column equals its neighbour and `eq` matches every step.

### Patterned

| input | parts | passes | ratio |
|---|---|---|---|
| `'ABC'` repeating 100 KB | 15 | 4 | 0.467 |

Runs four passes and uses a mix of `eq`, `rshift`, `inv` — the only fixture where non-`eq` transforms drive most of the compression.

### PARTS sweep on the smallest PDF (44.9 KB)

| parts | passes | ratio | CLI |
|---|---|---|---|
| 4 | 1 | 1.044 | ABORT |
| 8 | 1 | 0.994 | OK |
| 12 | 2 | 0.985 | OK |
| 16 | 5 | 0.976 | OK |

`PARTS=4` would have expanded the PDF by 4.4%. Auto skips it and picks 16.

## Repo layout

```
bin/bi2zip                # CLI entry point
lib/bi2zip.rb             # module + version + require graph
lib/bi2zip/
  algorithms.rb           # the six per-column transforms
  gray.rb                 # binary <-> reflected Gray code
  rle.rb                  # run-length encoder/decoder
  varint.rb               # LEB128 encode/decode
  zlb_tuner.rb            # brute-force pick of Z per pass
  parts_tuner.rb          # brute-force pick of PARTS per input
  compress.rb             # multi-pass compressor (incl. max-passes auto)
  decompress.rb           # inverse of compress
  cli.rb                  # OptionParser + mode dispatch + abort gate + filename resolution
spec/                     # RSpec tests
```
