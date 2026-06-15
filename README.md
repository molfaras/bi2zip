# bi2zip

A toy bit-level data compressor I wrote in Ruby. It's not fast, it's not competitive, and that's fine.

## Why

I've always wanted to write my own compression algorithm. Not to fight `gzip`. `gzip` wins. I just wanted to actually do the work: pack bits, pick a header byte layout, decide what to dedup, eat the trade-offs that show up once the bytes are in front of you. bi2zip is what fell out of a couple of evenings.

## Install and run

```sh
bundle install

# Compress: writes one <input>.bi2zip file, or nothing at all
# if the result wouldn't shrink the input.
bin/bi2zip foo.bin

# Decompress: writes the original filename (input minus .bi2zip).
# If that file already exists, picks the next free `name (N).ext`
# variant. Pass an explicit output path to override.
bin/bi2zip foo.bin.bi2zip
bin/bi2zip foo.bin.bi2zip restored.bin

# Tests
bundle exec rspec
```

Mode is inferred from the input extension. Path ends in `.bi2zip` → decompress. Anything else → compress. `bin/bi2zip --help` lists the compress flags (`--parts`, `--algorithms`, `--zlb`, `--max-passes`). Each defaults to `auto`.

## How I built it

Six stages, roughly in order.

**1. Dedup the obvious thing.** Started with one rule: if two adjacent things are equal, drop one and remember you did. The "things" are bit-columns. Slice the input into N-byte chunks, transpose into N parallel bit-strings (stripes), then for each bit-index `i` form an N-bit "column" by taking bit `i` from each stripe. Walk left to right. If `column[i] == column[i+1]`, drop the left one and emit a `1` to the rule stream. Otherwise keep it and emit a `0`. Replay in reverse to decompress. This worked on repetitive data and missed everything else.

**2. More ways to "match".** Two columns can be related without being literally equal. I added five small invertible transforms: `:inv` (bit flip), `:lshift`/`:rshift` (one-bit rotates), `:lgray`/`:rgray` (binary↔Gray code). A pass picks one transform and walks columns; it matches when `forward(transform, column[i]) == column[i+1]`. Each pass also pre-scans every transform on a cloned stripe array and picks whichever scores the most matches.

**3. Auto-tune the rule stream encoding.** The rule stream is RLE-encoded. Ones pass through as ones. Zero runs become a `0` followed by a `Z`-bit count field. The right `Z` depends on how the zeros cluster. I picked it by hand for a while, hated guessing, brute-forced the legal range per pass. Search is tiny, encoder is cheap.

**4. Auto-tune everything else, then refuse to make things worse.** Same brute-force trick for `PARTS`: try every legal value, keep whichever produces the smallest total output. For `max-passes`, switched from "stop when no matches are found" to "stop when the next pass would grow total output." A 1-step lookahead. Not globally optimal but cheap.

The legal ranges are deliberately narrow: `PARTS` and `ZLB` are `4..16`, `max-passes` is `1..10`. Anything smaller for `PARTS` or `ZLB` blew up on every test and just gave the tuner room to waste cycles. Ten passes is enough for every fixture I've thrown at it. Last gate: the CLI compares total output to input. If the output isn't strictly smaller, no files get written and it exits 0 with a stderr line. The library still returns a `Result` regardless; the abort lives at the CLI boundary.

**5. One file out, not a pile of files.** The first version wrote a `.bi2zip` data file plus one sidecar per pass — `<input>.bi2zip.1.eq.zlb4`, `<input>.bi2zip.2.rshift.zlb5`, and so on. Annoying to copy around, easy to lose. Folded everything into one `.bi2zip` file: global header, then the stripes block, then pass blocks concatenated end-to-end. Pass count is implicit — the decoder reads pass blocks until the stream ends. Integer fields (byte count, bit lengths) switched to unsigned LEB128 varint, so small inputs don't pay for fixed 32-bit fields.

**6. Make the auto tuners stop trying so hard.** `parts=auto` was running the full compressor 16 times per input — once for each `PARTS` value in `4..16`. On the 2 MB PDF that came out to 33 minutes. So I made both tuners walk their range top-down (`PARTS=16, 15, 14…`) and bail the moment a trial does worse than the previous best. For PDFs the answer is `PARTS=16` and the search now stops after 2 trials. 33 minutes became 5. Same trick for `ZLB`. The catch: this assumes the cost curve is mostly unimodal from the top, and on a non-unimodal input it can miss a better value lower in the range. Acceptable trade for the speedup; if you need exhaustive, pin `--parts N` and the tuner doesn't run at all.

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

Integer fields use unsigned LEB128 (7 payload bits per byte LSB-first, high bit set on every byte except the last). The pass count is implicit — the decoder stops when the byte stream ends.

Decompression replays the pass blocks in reverse order to reconstruct the stripes, then de-interleaves into the original byte stream.

## Results

ratio = `bi2zip output bytes / input bytes`. Below 1 = compressed; at or above 1 = the CLI aborts and writes nothing. All numbers use the current `auto` defaults; the "parts" column shows what auto picked.

### Real PDFs from my Documents folder

Four PDFs of varying sizes. The `gzip` column is `gzip -9` for comparison.

| file | size | bi2zip ratio | bytes saved | gzip ratio | passes |
|---|---|---|---|---|---|
| `1654473342.PDF` | 44.9 KB | 0.976 | 1060 | 0.883 | 5 |
| `Professional Tenant Form.pdf` | 196 KB | 0.995 | 1025 | 0.785 | 7 |
| `Ваш поліс ОСЦПВ.pdf` | 207 KB | 1.000 | 47 | 0.871 | 2 |
| `RA_04166.pdf` | 2.07 MB | 0.999 | 2343 | 0.926 | 4 |

bi2zip technically compresses every one of these, but by amounts that don't really matter — 47 bytes off a 200 KB PDF is rounding error. `gzip -9` beats it by 8 to 22 percentage points on every file. PDFs already contain zlib-compressed object streams inside, so whatever bit-column structure is left for bi2zip to find is sparse.

Wall time on the 2 MB PDF is about 5 minutes under `parts=auto` — down from 33 minutes before the tuner learned to bail early (stage 6 above). Pinning `--parts 16` skips the auto-tune entirely if you need it faster still.

### Random data — aborts

| input | parts | passes | would-be ratio | CLI |
|---|---|---|---|---|
| random 10 KB | 13 | 0 | 1.000 | ABORT |
| random 100 KB | 16 | 0 | 1.000 | ABORT |

Auto picks a `PARTS` that produces zero passes; the would-be output is the input plus the global header. Both abort.

### Constant / low-entropy

| input | parts | passes | ratio | CLI |
|---|---|---|---|---|
| zeros 100 KB | 16 | 10 | 0.064 | OK |
| alternating 0x00/0xFF 100 KB | 16 | 10 | 0.064 | OK |

The alternating case matching the all-zeros case used to surprise me: with `PARTS=16` every stripe ends up constant (stripe 0 all `0x00`, stripe 1 all `0xFF`, and so on), so every bit-column equals its neighbour and `eq` matches every step.

### Patterned

| input | parts | passes | ratio |
|---|---|---|---|
| `'ABC'` repeating 100 KB | 15 | 4 | 0.467 |

The `'ABC'` repeating sequence runs four passes and uses a mix of `eq`, `rshift`, `inv` — the only fixture in my set where the non-`eq` transforms drive most of the compression.

### What auto is choosing among

PARTS sweep on the smallest PDF (44.9 KB):

| parts | passes | ratio | CLI |
|---|---|---|---|
| 4 | 1 | 1.044 | ABORT |
| 8 | 1 | 0.994 | OK |
| 12 | 2 | 0.985 | OK |
| 16 | 5 | 0.976 | OK |

`PARTS=4` would have expanded the PDF by 4.4%. Auto skips it and picks 16. The monotonic improvement here is unusual; on noisier inputs you see flat or even slightly-worse jumps near the top of the range. For the PDFs in my Documents folder, the answer was always 16.

## Findings

- **bi2zip technically compresses real PDFs. By a hair.** Every one of the four came out a little smaller than it went in — anywhere from 47 bytes to 2.4%. `gzip -9` shrinks the same files by 8–22%. PDFs already carry zlib-compressed object streams inside, so there isn't much left for a column-based encoder to find.
- **The abort policy earns its keep on real workloads.** Random data, gzip output, and inputs too small to amortise the header all just refuse to write, exit 0, and leave the file alone. Used to be a silent 1–2% expansion.
- **`parts=auto` is still measurable on large inputs, just not painful.** The 2 MB PDF now takes about 5 minutes (was 33 before the early-termination heuristic). The 45 KB PDF takes 8 seconds (was 35). The tuner walks `PARTS=16, 15, 14…` and bails on the first regression; for PDFs that means it stops after 2 trials. If you want exhaustive, pin `--parts N` and the tuner doesn't run.
- **The non-`eq` transforms are still pulling weight on real files.** The PDF pipelines fire 2–7 passes mixing `eq`, `inv`, `rshift`, `lshift`, `rgray`, `lgray`. The gains are small but they're real — and they're the only way bi2zip beats 1.000 on a PDF at all.
- **It is not a serious compressor.** `gzip -9` on the 2 MB PDF is 1.91 MB; bi2zip is 2.06 MB. That's fine. This was a hobby project, not a tool.

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
