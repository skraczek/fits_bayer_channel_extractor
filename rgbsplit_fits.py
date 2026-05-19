#!/usr/bin/env python3
import argparse
import glob
import os
import struct
import sys
from dataclasses import dataclass, field
from enum import Enum


class RawColour(Enum):
    RED = "TR"
    GREEN = "TG"
    BLUE = "TB"


@dataclass
class FitsHeader:
    cards: list[str] = field(default_factory=list)
    width: int = 0
    height: int = 0
    bitpix: int = 0
    naxis: int = 0
    bayerpat: str = ""
    bscale: float = 1.0
    bzero: float = 0.0
    header_bytes: int = 0


def pad2880(n: int) -> int:
    return ((n + 2879) // 2880) * 2880


def card_key(card: str) -> str:
    return card[:8].strip()


def card_value_raw(card: str) -> str:
    p = card.find("=")
    if p < 0:
        return ""
    value = card[p + 1:].strip()
    slash = value.find("/")
    if slash >= 0:
        value = value[:slash].strip()
    return value


def strip_quotes(s: str) -> str:
    s = s.strip()
    if len(s) >= 2 and s[0] == "'":
        s = s[1:]
        p = s.find("'")
        if p >= 0:
            s = s[:p]
    return s.strip()


def get_keyword_str(h: FitsHeader, key: str, default: str) -> str:
    for card in h.cards:
        if card_key(card).upper() == key.upper():
            return strip_quotes(card_value_raw(card))
    return default


def get_keyword_int(h: FitsHeader, key: str, default: int) -> int:
    s = get_keyword_str(h, key, "")
    if not s:
        return default
    try:
        return int(s)
    except ValueError:
        return default


def get_keyword_float(h: FitsHeader, key: str, default: float) -> float:
    s = get_keyword_str(h, key, "")
    if not s:
        return default
    try:
        return float(s.replace("D", "E").replace("d", "e"))
    except ValueError:
        return default


def normalise_bayer(s: str) -> str:
    s = s.strip().upper()
    for pat in ("RGGB", "GRBG", "GBRG", "BGGR"):
        if pat in s:
            return pat
    return ""


def read_fits_header(f) -> FitsHeader:
    h = FitsHeader()

    while True:
        raw = f.read(80)
        if len(raw) != 80:
            raise RuntimeError("Unexpected EOF while reading FITS header")

        card = raw.decode("ascii", errors="replace")
        h.cards.append(card)

        if card_key(card) == "END":
            break

    h.header_bytes = pad2880(len(h.cards) * 80)
    f.seek(h.header_bytes)

    h.width = get_keyword_int(h, "NAXIS1", 0)
    h.height = get_keyword_int(h, "NAXIS2", 0)
    h.naxis = get_keyword_int(h, "NAXIS", 0)
    h.bitpix = get_keyword_int(h, "BITPIX", 0)
    h.bscale = get_keyword_float(h, "BSCALE", 1.0)
    h.bzero = get_keyword_float(h, "BZERO", 0.0)

    h.bayerpat = normalise_bayer(get_keyword_str(h, "BAYERPAT", ""))
    if not h.bayerpat:
        h.bayerpat = normalise_bayer(get_keyword_str(h, "COLORTYP", ""))

    if h.width <= 0 or h.height <= 0:
        raise RuntimeError("Invalid FITS dimensions")
    if h.naxis != 2:
        raise RuntimeError("Only 2D raw mono FITS files are supported")
    if not h.bayerpat:
        raise RuntimeError("BAYERPAT/COLORTYP not found or unsupported")

    return h


def load_fits_image(filename: str):
    with open(filename, "rb") as f:
        h = read_fits_header(f)
        bpp = abs(h.bitpix) // 8
        data_bytes = h.width * h.height * bpp
        buf = f.read(data_bytes)

    if len(buf) != data_bytes:
        raise RuntimeError("Unexpected EOF while reading FITS data")

    img = []
    p = 0

    for _y in range(h.height):
        row = []
        for _x in range(h.width):
            if h.bitpix == 8:
                v = buf[p]
                p += 1
            elif h.bitpix == 16:
                v = struct.unpack(">h", buf[p:p + 2])[0]
                p += 2
            elif h.bitpix == 32:
                v = struct.unpack(">i", buf[p:p + 4])[0]
                p += 4
            elif h.bitpix == -32:
                v = struct.unpack(">f", buf[p:p + 4])[0]
                p += 4
            else:
                raise RuntimeError(f"Unsupported BITPIX: {h.bitpix}")

            row.append(v * h.bscale + h.bzero)
        img.append(row)

    return h, img


def bayer_offsets(pattern: str, colour: RawColour):
    if pattern == "RGGB":
        if colour == RawColour.RED:
            return 0, 0, 0, 0, False
        if colour == RawColour.BLUE:
            return 1, 1, 0, 0, False
        return 1, 0, 0, 1, True

    if pattern == "GRBG":
        if colour == RawColour.RED:
            return 1, 0, 0, 0, False
        if colour == RawColour.BLUE:
            return 0, 1, 0, 0, False
        return 0, 0, 1, 1, True

    if pattern == "GBRG":
        if colour == RawColour.RED:
            return 0, 1, 0, 0, False
        if colour == RawColour.BLUE:
            return 1, 0, 0, 0, False
        return 0, 0, 1, 1, True

    if pattern == "BGGR":
        if colour == RawColour.RED:
            return 1, 1, 0, 0, False
        if colour == RawColour.BLUE:
            return 0, 0, 0, 0, False
        return 1, 0, 0, 1, True

    raise RuntimeError(f"Unsupported Bayer pattern: {pattern}")


def extract_raw_colour(src, pattern: str, colour: RawColour):
    out_h = len(src) // 2
    out_w = len(src[0]) // 2
    x1, y1, x2, y2, two_greens = bayer_offsets(pattern, colour)

    dst = [[0.0 for _ in range(out_w)] for _ in range(out_h)]

    for y in range(out_h):
        for x in range(out_w):
            if two_greens:
                dst[y][x] = (
                    src[y * 2 + y1][x * 2 + x1]
                    + src[y * 2 + y2][x * 2 + x2]
                ) / 2.0
            else:
                dst[y][x] = src[y * 2 + y1][x * 2 + x1]

    return dst


def make_fits_card(key: str, value: str = "", comment: str = "") -> str:
    if key == "END":
        s = "END"
    elif comment:
        s = f"{key:<8}= {value:<20} / {comment}"
    else:
        s = f"{key:<8}= {value}"
    return (s + " " * 80)[:80]


def update_or_add_header_card(cards, key: str, value: str, comment: str):
    key8 = (key + " " * 8)[:8]
    end_index = len(cards)

    for i, card in enumerate(cards):
        if card_key(card) == "END":
            end_index = i
            break

        if card[:8] == key8:
            cards[i] = make_fits_card(key, value, comment)
            return

    cards.insert(end_index, make_fits_card(key, value, comment))


def write_copied_header(f, src_header: FitsHeader, out_width: int, out_height: int, filter_name: str):
    cards = list(src_header.cards)

    update_or_add_header_card(cards, "NAXIS", "2", "number of data axes")
    update_or_add_header_card(cards, "NAXIS1", str(out_width), "length of x axis")
    update_or_add_header_card(cards, "NAXIS2", str(out_height), "length of y axis")
    update_or_add_header_card(cards, "FILTER", f"'{filter_name}'", "Extracted raw Bayer colour")

    if not any(card_key(card) == "END" for card in cards):
        cards.append("END" + " " * 77)

    for card in cards:
        f.write((card + " " * 80)[:80].encode("ascii", errors="replace"))

    pad = pad2880(f.tell()) - f.tell()
    if pad:
        f.write(b"\0" * pad)


def clamp(v, lo, hi):
    return max(lo, min(hi, v))


def write_same_bitpix_fits(filename: str, img, src_header: FitsHeader, filter_name: str):
    with open(filename, "wb") as f:
        write_copied_header(f, src_header, len(img[0]), len(img), filter_name)

        out = bytearray()

        for row in img:
            for px in row:
                v = (px - src_header.bzero) / src_header.bscale

                if src_header.bitpix == 8:
                    out.append(int(round(clamp(v, 0, 255))))
                elif src_header.bitpix == 16:
                    out.extend(struct.pack(">h", int(round(clamp(v, -32768, 32767)))))
                elif src_header.bitpix == 32:
                    out.extend(struct.pack(">i", int(round(clamp(v, -2147483648, 2147483647)))))
                elif src_header.bitpix == -32:
                    out.extend(struct.pack(">f", float(px)))
                else:
                    raise RuntimeError(f"Unsupported output BITPIX: {src_header.bitpix}")

        f.write(out)

        pad = pad2880(len(out)) - len(out)
        if pad:
            f.write(b"\0" * pad)


def collect_fits_files(input_path: str):
    if os.path.isdir(input_path):
        patterns = ["*.fit", "*.fits", "*.fts", "*.FIT", "*.FITS", "*.FTS"]
        files = []
        for pat in patterns:
            files.extend(glob.glob(os.path.join(input_path, pat)))
        return sorted(set(files))

    if "*" in input_path or "?" in input_path:
        return sorted(glob.glob(input_path))

    return [input_path]


def output_dir_for_filter(input_path: str, suffix: str):
    input_path = os.path.normpath(input_path)

    if os.path.isdir(input_path):
        parent = os.path.dirname(input_path)
        folder = os.path.basename(input_path)
    else:
        parent = os.path.dirname(input_path) or "."
        folder = os.path.basename(parent)

    return os.path.join(parent, f"{folder}_{suffix}")


def ask_filters():
    print("Which transformations do you want?")
    print("Available: TR, TG, TB, ALL")
    answer = input("Enter filters, e.g. TG or TR,TG or ALL: ").strip().upper()

    if answer == "ALL":
        return [RawColour.RED, RawColour.GREEN, RawColour.BLUE]

    parts = [p.strip() for p in answer.replace(";", ",").split(",") if p.strip()]
    colours = []

    for part in parts:
        if part == "TR":
            colours.append(RawColour.RED)
        elif part == "TG":
            colours.append(RawColour.GREEN)
        elif part == "TB":
            colours.append(RawColour.BLUE)
        else:
            raise RuntimeError(f"Unknown filter: {part}")

    if not colours:
        raise RuntimeError("No filters selected")

    return colours


def process_one_file(input_file: str, output_dir: str, colour: RawColour):
    h, src = load_fits_image(input_file)
    dst = extract_raw_colour(src, h.bayerpat, colour)

    suffix = colour.value
    base = os.path.splitext(os.path.basename(input_file))[0]
    out_name = os.path.join(output_dir, f"{base}_{suffix}.fits")

    write_same_bitpix_fits(out_name, dst, h, suffix)

    st = os.stat(input_file)
    os.utime(out_name, (st.st_atime, st.st_mtime))


def main(argv):
    if len(argv) >= 1:
        input_path = argv[0]
    else:
        input_path = input("Input folder or FITS pattern: ").strip()

    input_files = collect_fits_files(input_path)

    if not input_files:
        raise RuntimeError("No input files")

    colours = ask_filters()

    output_dirs = {}
    for colour in colours:
        suffix = colour.value
        out_dir = output_dir_for_filter(input_path, suffix)

        if os.path.exists(out_dir) and not os.path.isdir(out_dir):
            raise RuntimeError(f"Output path exists but is not a folder: {out_dir}")

        os.makedirs(out_dir, exist_ok=True)
        output_dirs[colour] = out_dir

    processed_ok = []

    for i, input_file in enumerate(input_files, 1):
        print(f"\rProcessing {i}/{len(input_files)}: {os.path.basename(input_file)}", end="", flush=True)

        for colour in colours:
            process_one_file(input_file, output_dirs[colour], colour)

        processed_ok.append(input_file)

    print()
    print(f"Files processed: {len(processed_ok)}/{len(input_files)}")

    for colour in colours:
        print(f"Saved {colour.value} to: {os.path.abspath(output_dirs[colour])}")

    print("Input files left unchanged.")

if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except Exception as exc:
        print(f"Error: {exc}", file=sys.stderr)
        sys.exit(1)