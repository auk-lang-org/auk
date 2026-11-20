# audio

Audio in pure Auk, covering the audio side of ffmpeg for uncompressed and lossless formats. It decodes and encodes WAV, AIFF/AIFC, AU and FLAC, and probes files. It resamples, remixes channels, filters (biquads, EQ, echo, compressor, limiter, gate, fades, time stretch, pitch shift), measures (stats, EBU R128 loudness, true peak, spectra, silence) and generates signals. Filter chains use ffmpeg's `-af` syntax. Errors are a typed `AErr`.

**Effects:** none. **Dependencies:** none.

```auk
let a = audio.decode(fs.read_bytes("take1.wav")?)?
let clean = a.apply("highpass=f=80,acompressor=threshold=-20dB:ratio=3,loudnorm=I=-16")?
let b = clean.resample(48000).remix(1)
fs.write_bytes("take1.flac", audio.encode(b, audio.Flac, audio.S24)?)?

let i = audio.probe(fs.read_bytes("song.flac")?)?
print("{i.codec} {i.rate} Hz x{i.channels}, {i.duration():.1}s, {i.tags.get("title") else "?"}")
print("{a.loudness().integrated:.1} LUFS, peak {audio.gain_to_db(a.peak()):.1} dBFS")
let beep = audio.source("sine=f=1000:d=0.5")?
```

`examples/aconv.auk` is an ffmpeg-style command line built on it (`aconv -i in.wav -af ... -ar 48000 out.flac`).

## How it was checked

The package was checked against ffmpeg 7 and libFLAC 1.5:
- **Decoders.** Every decoder is bit-exact with ffmpeg on the formats below, including FLAC from `flac -0` to `-8`, `--blocksize=1152`, ffmpeg's `-compression_level 12`, 24-bit and 5.1.
- **Encoders.** Every encoder's output reads back in ffmpeg, and ffprobe reports the right codec and layout.
  - FLAC output passes `flac -t`, which checks the MD5. It compresses about like `flac -5` to `-8`.
  - The A-law and μ-law encoders match ffmpeg byte for byte.
  - IMA ADPCM has the same SNR as ffmpeg's encoder.
- **Filters that match ffmpeg's output.**
  - Exactly (to 1e-15): `volume`, `tremolo`, `acompressor` and `agate` (the same algorithms, ported).
  - To 1 LSB of 16-bit: the biquads (`lowpass`, `highpass`, `bandpass`, `bandreject`, `allpass`, `equalizer`, `bass`, `treble`), `afade`, `aecho`, `adelay`, `pan`, `atrim` and `apad`. ffmpeg runs those in s16.
- **Loudness.** Integrated loudness, LRA and true peak match `ebur128=peak=true` to its displayed precision. Peak, RMS, DC and crest match `astats`.
- **Resampler.** On sines it measures 94–112 dB SNR against the ideal signal.

## API

Bytes are `[int]` (0–255), as in `fs.read_bytes`. Samples are planar floats, nominally -1.0..1.0. Times are in seconds, and levels in dB unless they are named `gain` or `g`.

### Types
- `struct Audio { rate: int, chans: [[float]], tags: {str: str} }`: `chans[c][i]` is frame `i` of channel `c`. Tags have lowercase keys (`title`, `artist`, `album`, `comment`, `date`, `genre`, `track`, ...).
  - `new(rate, chans)` makes an `Audio` with no tags.
  - `a.frames()`, `a.nch()` and `a.duration()` give its size.
- `enum Fmt { U8, S8, S16, S24, S32, F32, F64, Alaw, Ulaw, Ima }`: sample formats.
  - `fmt_named(s): Fmt?` takes ffmpeg's names: `s16`, `s24`, `flt`, `dbl`, `pcm_s24le`, `mulaw`, `adpcm_ima_wav`, ...
  - `codec_name(f, big_endian)` gives ffmpeg's codec name, such as `pcm_s16le`.
- `enum Container { Wav, Aiff, Au, Flac }`. `container_for(path): Container?` picks one by extension.
- `struct Info { container, codec, rate, channels, frames, bits, tags }` and `duration(i)`.
- `enum AErr { Truncated(what), Unsupported(what), Corrupt(why), BadArg(why) }`.
  - `message(e)` gives one line, for example `unsupported: MP3`.

### Reading and writing
- `decode(bytes): Audio!AErr` and `probe(bytes): Info!AErr` recognize the format from the contents.
  - MP3, Ogg, MP4/M4A and Matroska/WebM are recognized and named in the `Unsupported` error.
- `encode(a, container, fmt): [int]!AErr` writes a complete file.

| container | reads | writes |
|---|---|---|
| WAV (RIFF, RF64) | PCM u8/s16/s24/s32 (also 12/20-bit in wider containers), float 32/64, A-law, μ-law, IMA ADPCM, MS ADPCM; WAVE_FORMAT_EXTENSIBLE; LIST/INFO tags | all of those but MS ADPCM; EXTENSIBLE for over 2 channels or 16 bits; `fact` chunk; INFO tags |
| AIFF / AIFF-C | PCM s8–s32, `sowt`, `fl32`, `fl64`, `alaw`, `ulaw`; NAME/AUTH/(c)/ANNO | S8–S32 as AIFF; F32, F64, A-law, μ-law as AIFF-C |
| AU (`.snd`) | μ-law, A-law, s8–s32, f32, f64; the annotation as `comment` | the same |
| FLAC | everything: 4–32 bits, 1–8 channels, fixed or variable blocks, all subframe types, Rice/Rice2, escape codes, wasted bits, stereo decorrelation; CRC-8/CRC-16 checked; Vorbis comments; a leading ID3v2 tag skipped | 8, 16 or 24 bits; LPC up to order 8, fixed predictors, partitioned Rice, best of 4 stereo modes per frame; STREAMINFO with MD5; Vorbis comments |

To write raw samples with no container, use `audio.pcm`:
- `pcm.encode(chans, fmt, big_endian): [int]` interleaves the channels and encodes every frame.
- `pcm.encode_into(&out, chans, fmt, big_endian)` does the same but appends to `out`. That way a header you have already written and the samples share one list, with no copy.
- `pcm.decode(bytes, at, frames, nch, fmt, big_endian): [[float]]` reads samples back.
- Both encoders take the byte-aligned formats plus A-law and μ-law. `Ima` writes nothing, because ADPCM is encoded in blocks.

A WAV whose data chunk is cut short decodes what is there, as ffmpeg does. Every other truncation is `Truncated`. For ADPCM, `fact` caps the frame count.

### Making audio
- `sine(freq, secs, rate)`, `tone(wave, freq, secs, rate, amp)` with `audio.gen.Sine`, `Square`, `Sawtooth` or `Triangle`.
- `chirp(f0, f1, secs, rate, log)`.
- `noise(audio.gen.White | Pink | Brown, secs, rate, amp, seed)`: seeded, so it is reproducible.
- `silence(secs, rate, nch)`.
- `source(spec)` in lavfi syntax: `sine=f=440:d=2:r=48000` (amplitude 1/8, as ffmpeg), `anoisesrc=c=pink:a=0.3:d=5:seed=1`, `anullsrc=cl=5.1:d=1`, `square`, `sawtooth`, `triangle`, `chirp=f0=20:f1=20000:d=5:type=log`.

### Editing
`gain(g)`, `gain_db(db)`, `normalize(peak_db)`, `clip()`, `dc_shift(d)`, `trim(start, end)` (`end` < 0 means to the end), `pad(secs)`, `delay(secs)`, `delay_each([secs])`, `reverse()`, `fade_in(secs)`, `fade_out(secs)`, `fade(in, start, secs, curve)`.
- `concat([a, b])`, `overlay(a, b, at)` and `mix([a, b, ...])` (amix: each input scaled by 1/n, rates and channels converted).
- `resample(rate)`: Kaiser-windowed sinc, as swresample's defaults.
- `set_rate(rate)`: relabel the rate without resampling (asetrate).
- `tempo(factor)`: WSOLA. `pitch(semitones)` keeps the duration.

### Channels
- `remix(n)`: mono goes to the front pair. Stereo goes to mono as the mean (ffmpeg uses 0.707 each, which can clip). 5.1 and quad fold down to stereo with -3 dB centre and surrounds, normalized so the output can't clip.
- `mono()`, `channel(c)`, `pan(matrix)` (output `o` is the sum of `matrix[o][i]` times input `i`), and `widen(m)` (extrastereo).

### Filters and dynamics
- `lowpass(f)`, `highpass(f)`, `bandpass(f, q)`, `notch(f, q)`, `eq(f, q, gain_db)`, `bass(gain_db, f)`, `treble(gain_db, f)`.
- `biquad(kind, f, q, gain_db)` for any RBJ cookbook filter. `audio.fx.design` and `audio.fx.response_db` give the coefficients and the frequency response.
- `echo(in_gain, out_gain, delays, decays)` and `tremolo(f, depth)`.
- `compress(Comp { threshold, ratio, knee, attack, release, makeup, rms })`. `COMP` holds ffmpeg's defaults; update it with `Comp { ratio: 4.0, ..COMP }`.
- `limit(ceiling_db, attack, release)`: a lookahead brickwall limiter. No sample exceeds the ceiling. This is not ffmpeg's alimiter algorithm.
- `gate(threshold_db, ratio, range_db, attack, release)`.
- `loudnorm(lufs, tp_db)`: ffmpeg's loudnorm in linear mode. It applies one gain to reach the target, then limits if the true peak would pass `tp_db`.

### Measuring
- `stats(): [Stats]` gives, per channel: `peak`, `peak_db`, `rms`, `rms_db`, `dc`, `min`, `max`, `crest`, `clipped` and `zero_crossings`. `peak()` is the largest |sample| over all channels.
- `loudness(): Loudness` gives `integrated` (LUFS), `range` (LU), `momentary_max`, `short_term_max` and `true_peak_db`. This is BS.1770-4 with gating; true peak is 4x oversampled.
- `spectrum(size): [float]` gives dBFS per bin, from Hann-windowed frames with 50% overlap. `dominant(): float` gives the strongest frequency in Hz.
- `audio.analyze.fft(&re, &im, inverse)` is a radix-2 FFT.
- `silences(threshold_db, min_secs): [(start, end)]` (silencedetect) and `trim_silence(threshold_db)`.

### Filter graphs: `a.apply("f1=...,f2=...")`
Options are positional (in ffmpeg's order) or named (long or short names), separated by `:`. Lists use `|`. Durations accept `1.5`, `250ms` and `1:02.5`. Gains accept `0.5` or `-6dB`.

| filter | options (defaults) |
|---|---|
| `volume` | volume (1) |
| `lowpass`, `highpass` | f (500 / 3000), w (Q 0.707), p (2; 1 = one-pole), t (`q`, `o` octaves, `h` Hz, `s` slope) |
| `bandpass`, `bandreject`, `allpass` | f (3000), w (0.707), t |
| `equalizer` | f (1000), w (1), g (0) |
| `bass`/`lowshelf`, `treble`/`highshelf` | g, f (100 / 3000), w |
| `aresample` | rate |
| `asetrate` | r |
| `aformat` | sample_rates, channel_layouts (`mono`, `stereo`, `5.1`, `Nc`, ...) |
| `atempo` | tempo (0.25–4) |
| `pitch` | semitones (not in ffmpeg) |
| `atrim` | start, end, duration |
| `apad` | pad_dur, whole_dur |
| `afade` | t (`in`/`out`), st, d, curve (`tri qsin hsin log exp squ cub`) |
| `areverse`, `anull`, `aclip` | |
| `aecho` | in_gain (0.6), out_gain (0.3), delays ms (1000), decays (0.5) |
| `adelay` | delays ms per channel, all=1 |
| `acompressor` | threshold (0.125), ratio (2), knee (2.828), attack ms (20), release ms (250), makeup (1), detection (`rms`/`peak`) |
| `agate` | threshold (0.125), ratio (2), range (0.06125), knee (2.828), attack (20), release (250), makeup, detection |
| `alimiter` | limit (1), attack ms (5), release ms (50), level_in, level_out |
| `loudnorm` | I (-24), TP (-2) |
| `anormalize` | peak dB (-1). `dynaudnorm` is the same peak normalization (not ffmpeg's dynamic one) |
| `silenceremove` | start_threshold (-60dB): trims leading and trailing silence |
| `pan` | `pan=stereo\|c0=0.5*c0+0.5*c1\|c1=c1` |
| `extrastereo` | m (2.5) |
| `tremolo` | f (5), d (0.5) |
| `dcshift` | shift |

Unknown filters, bad values and out-of-range frequencies are `BadArg` errors.

## Limits in 0.1
- **No lossy codecs.** MP3, AAC, Vorbis and Opus can't be decoded or encoded, and there are no Ogg, MP4 or Matroska containers. They are detected and reported as `Unsupported`.
- **FLAC.** It writes 8, 16 or 24 bits, not 32. It doesn't verify the STREAMINFO MD5 on decode (ffmpeg doesn't either). It writes no seek table.
- **Memory.** Everything is in memory. Samples take 8 bytes each, and input bytes do too until core has a bytes type. There is no streaming API.
- **Speed in an `auk build` binary on a laptop.** FLAC encodes at about 25x real time and decodes at about 50x for 44.1 kHz stereo. PCM is far faster. `auk run` (unoptimized JIT) is about 5x slower.
- **Algorithms that differ from ffmpeg's.** `alimiter`, `atempo` (WSOLA, so pitch is kept but the artifacts differ), `loudnorm` (linear mode only), `dynaudnorm`, `silenceremove` (trim only), and `pan` and `remix` defaults.
