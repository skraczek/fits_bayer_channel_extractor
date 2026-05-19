# FITS Bayer Channel Extractor

A Python utility for extracting individual Bayer colour channels (`TR`, `TG`, `TB`) from monochrome RAW FITS astrophotography files while preserving the original FITS metadata and bit depth.

Supports common Bayer patterns:

- `RGGB`
- `GRBG`
- `GBRG`
- `BGGR`

The program creates separate FITS files containing:

- **TR** → Red channel
- **TG** → Green channel (averaged from both green pixels)
- **TB** → Blue channel

---

# Features

- Reads RAW monochrome Bayer FITS images
- Preserves original FITS headers
- Preserves original BITPIX format
- Supports:
  - 8-bit
  - 16-bit
  - 32-bit integer
  - 32-bit float FITS images
- Automatically detects Bayer pattern from:
  - `BAYERPAT`
  - `COLORTYP`
- Batch processing support
- Keeps original files unchanged
- Preserves file timestamps
- Creates organised output folders automatically

---

# Requirements

- Python 3.9+
- No external dependencies required

Uses only the Python standard library.

---

# Installation

Clone or download the script.

Example:

```bash
git clone https://github.com/yourname/fits-bayer-extractor.git
cd fits-bayer-extractor
```

Or simply place the script somewhere convenient.

---

# Usage

## Basic Usage

```bash
python3 rgbsplit_fits.py /path/to/fits/files
```

You can also use:

```bash
python3 rgbsplit_fits.py "*.fits"
```

Or launch without arguments:

```bash
python3 rgbsplit_fits.py
```

The program will then ask for the input path interactively.

---

# Filter Selection

After launch, the program asks which Bayer channels to extract:

```text
Which transformations do you want?
Available: TR, TG, TB, ALL
Enter filters, e.g. TG or TR,TG or ALL:
```

Examples:

| Input | Result |
|---|---|
| `TR` | Extract red channel |
| `TG` | Extract green channel |
| `TB` | Extract blue channel |
| `TR,TG` | Extract red and green |
| `ALL` | Extract all channels |

---

# Output Structure

For an input folder:

```text
lights/
```

The program creates:

```text
lights_TR/
lights_TG/
lights_TB/
```

Each folder contains extracted FITS files.

Example output:

```text
M42_001_TR.fits
M42_001_TG.fits
M42_001_TB.fits
```

---

# Bayer Extraction Logic

The script extracts pixels directly from the Bayer mosaic.

Example for `RGGB`:

```text
R G
G B
```

Extraction rules:

| Channel | Pixels Used |
|---|---|
| TR | Red pixels |
| TG | Average of both green pixels |
| TB | Blue pixels |

Resulting images are half resolution:

```text
output width  = input width / 2
output height = input height / 2
```

---

# FITS Header Handling

The original FITS header is copied and updated with:

- `NAXIS`
- `NAXIS1`
- `NAXIS2`
- `FILTER`

Example:

```text
FILTER = 'TR'
```

Most original metadata remains unchanged.

---

# Supported FITS Formats

| BITPIX | Type |
|---|---|
| `8` | Unsigned 8-bit |
| `16` | Signed 16-bit |
| `32` | Signed 32-bit integer |
| `-32` | 32-bit floating point |

---

# Example Workflow

## Extract all channels from a folder

```bash
python3 extract_bayer.py ./lights
```

Select:

```text
ALL
```

Result:

```text
lights_TR/
lights_TG/
lights_TB/
```

---

# Error Handling

The program reports clear errors for:

- Missing FITS files
- Unsupported Bayer patterns
- Invalid FITS headers
- Unsupported BITPIX formats
- Corrupted FITS data

Example:

```text
Error: BAYERPAT/COLORTYP not found or unsupported
```

---

# Notes

- Only 2D monochrome RAW FITS files are supported
- Debayered RGB FITS files are not supported
- Original files are never modified
- FITS data is read using big-endian byte order as required by the FITS standard

---

# License

MIT License

```text
MIT License

Copyright (c) 2026 Your Name

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software...
```

---

# Possible Future Improvements

- Multithreaded processing
- Optional compression
- CFA visualisation
- Support for 64-bit FITS formats
- Demosaicing modes
- Command-line filter selection
- Progress bar support

---

# Example Command Session

```text
$ python3 extract_bayer.py ./lights

Which transformations do you want?
Available: TR, TG, TB, ALL
Enter filters, e.g. TG or TR,TG or ALL: ALL

Processing 12/12: M42_001.fits

Files processed: 12/12
Saved TR to: /data/lights_TR
Saved TG to: /data/lights_TG
Saved TB to: /data/lights_TB

Input files left unchanged.
```
