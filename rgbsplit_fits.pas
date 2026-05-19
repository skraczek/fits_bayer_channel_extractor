program rawsplit_fits;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, Math;

type
  TDoubleImage = array of array of Double;

  TFitsHeader = record
    Cards: TStringList;
    Width: Integer;
    Height: Integer;
    BitPix: Integer;
    NAxis: Integer;
    BayerPat: string;
    BScale: Double;
    BZero: Double;
    HeaderBytes: Int64;
  end;

  TRawColour = (rcRed, rcGreen, rcBlue);

function Pad2880(n: Int64): Int64;
begin
  Result := ((n + 2879) div 2880) * 2880;
end;

function CardKey(const card: string): string;
begin
  Result := Trim(Copy(card, 1, 8));
end;

function CardValueRaw(const card: string): string;
var
  p, slashPos: Integer;
begin
  Result := '';
  p := Pos('=', card);
  if p <= 0 then Exit;

  Result := Trim(Copy(card, p + 1, MaxInt));
  slashPos := Pos('/', Result);
  if slashPos > 0 then
    Result := Trim(Copy(Result, 1, slashPos - 1));
end;

function StripQuotes(s: string): string;
begin
  s := Trim(s);
  if (Length(s) >= 2) and (s[1] = '''') then
  begin
    Delete(s, 1, 1);
    if Pos('''', s) > 0 then
      s := Copy(s, 1, Pos('''', s) - 1);
  end;
  Result := Trim(s);
end;

function GetKeywordStr(h: TFitsHeader; const key, def: string): string;
var
  i: Integer;
begin
  Result := def;
  for i := 0 to h.Cards.Count - 1 do
    if SameText(CardKey(h.Cards[i]), key) then
      Exit(StripQuotes(CardValueRaw(h.Cards[i])));
end;

function GetKeywordInt(h: TFitsHeader; const key: string; def: Integer): Integer;
var
  s: string;
begin
  s := GetKeywordStr(h, key, '');
  if s = '' then Exit(def);
  Result := StrToIntDef(s, def);
end;

function GetKeywordFloat(h: TFitsHeader; const key: string; def: Double): Double;
var
  s: string;
  fs: TFormatSettings;
begin
  s := GetKeywordStr(h, key, '');
  if s = '' then Exit(def);
  fs := DefaultFormatSettings;
  fs.DecimalSeparator := '.';
  Result := StrToFloatDef(StringReplace(s, 'D', 'E', [rfReplaceAll]), def, fs);
end;

function NormaliseBayer(s: string): string;
begin
  Result := UpperCase(Trim(s));
  if Pos('RGGB', Result) > 0 then Result := 'RGGB' else
  if Pos('GRBG', Result) > 0 then Result := 'GRBG' else
  if Pos('GBRG', Result) > 0 then Result := 'GBRG' else
  if Pos('BGGR', Result) > 0 then Result := 'BGGR' else
    Result := '';
end;

procedure ReadFitsHeader(fs: TFileStream; out h: TFitsHeader);
var
  buf: array[0..79] of AnsiChar;
  card: string;
  cardsRead: Int64;
begin
  h.Cards := TStringList.Create;
  cardsRead := 0;

  repeat
    if fs.Read(buf, 80) <> 80 then
      raise Exception.Create('Unexpected EOF while reading FITS header');

    SetString(card, PAnsiChar(@buf[0]), 80);
    h.Cards.Add(card);
    Inc(cardsRead);

  until CardKey(card) = 'END';

  h.HeaderBytes := Pad2880(cardsRead * 80);
  fs.Position := h.HeaderBytes;

  h.Width := GetKeywordInt(h, 'NAXIS1', 0);
  h.Height := GetKeywordInt(h, 'NAXIS2', 0);
  h.NAxis := GetKeywordInt(h, 'NAXIS', 0);
  h.BitPix := GetKeywordInt(h, 'BITPIX', 0);
  h.BScale := GetKeywordFloat(h, 'BSCALE', 1.0);
  h.BZero := GetKeywordFloat(h, 'BZERO', 0.0);

  h.BayerPat := NormaliseBayer(GetKeywordStr(h, 'BAYERPAT', ''));
  if h.BayerPat = '' then
    h.BayerPat := NormaliseBayer(GetKeywordStr(h, 'COLORTYP', ''));

  if (h.Width <= 0) or (h.Height <= 0) then
    raise Exception.Create('Invalid FITS dimensions');

  if h.NAxis <> 2 then
    raise Exception.Create('Only 2D raw mono FITS files are supported');

  if h.BayerPat = '' then
    raise Exception.Create('BAYERPAT/COLORTYP not found or unsupported');
end;

function ReadBE16(fs: TFileStream): SmallInt;
var
  b: array[0..1] of Byte;
  u: Word;
begin
  fs.ReadBuffer(b, 2);
  u := (Word(b[0]) shl 8) or Word(b[1]);
  Result := SmallInt(u);
end;

function ReadBE32Int(fs: TFileStream): LongInt;
var
  b: array[0..3] of Byte;
  u: LongWord;
begin
  fs.ReadBuffer(b, 4);
  u := (LongWord(b[0]) shl 24) or (LongWord(b[1]) shl 16) or
       (LongWord(b[2]) shl 8) or LongWord(b[3]);
  Result := LongInt(u);
end;

function ReadBE32Float(fs: TFileStream): Single;
var
  b: array[0..3] of Byte;
  u: LongWord;
begin
  fs.ReadBuffer(b, 4);
  u := (LongWord(b[0]) shl 24) or (LongWord(b[1]) shl 16) or
       (LongWord(b[2]) shl 8) or LongWord(b[3]);
  Move(u, Result, 4);
end;

procedure LoadFitsImage(const fileName: string; out h: TFitsHeader; out img: TDoubleImage);
var
  fs: TFileStream;
  x, y: Integer;
  bytesPerPixel: Integer;
  dataBytes, p: Int64;
  buf: array of Byte;
  u16: Word;
  i16: SmallInt;
  u32: LongWord;
  i32: LongInt;
  s32: Single;
  v: Double;
begin
  fs := TFileStream.Create(fileName, fmOpenRead or fmShareDenyWrite);
  try
    ReadFitsHeader(fs, h);

    bytesPerPixel := Abs(h.BitPix) div 8;
    dataBytes := Int64(h.Width) * h.Height * bytesPerPixel;
    SetLength(buf, dataBytes);
    if dataBytes > 0 then
      fs.ReadBuffer(buf[0], dataBytes);
    SetLength(img, h.Height, h.Width);

    p := 0;
    for y := 0 to h.Height - 1 do
      for x := 0 to h.Width - 1 do
      begin
        case h.BitPix of
          8:
            begin
              v := buf[p];
              Inc(p, 1);
            end;

          16:
            begin
              u16 := (Word(buf[p]) shl 8) or Word(buf[p + 1]);
              i16 := SmallInt(u16);
              v := i16;
              Inc(p, 2);
            end;

          32:
            begin
              u32 := (LongWord(buf[p]) shl 24) or
                     (LongWord(buf[p + 1]) shl 16) or
                     (LongWord(buf[p + 2]) shl 8) or
                     LongWord(buf[p + 3]);
              i32 := LongInt(u32);
              v := i32;
              Inc(p, 4);
            end;

          -32:
            begin
              u32 := (LongWord(buf[p]) shl 24) or
                     (LongWord(buf[p + 1]) shl 16) or
                     (LongWord(buf[p + 2]) shl 8) or
                     LongWord(buf[p + 3]);
              Move(u32, s32, 4);
              v := s32;
              Inc(p, 4);
            end;

        else
          raise Exception.Create('Unsupported BITPIX: ' + IntToStr(h.BitPix));
        end;

        img[y, x] := v * h.BScale + h.BZero;
      end;

  finally
    fs.Free;
  end;
end;

procedure BayerOffsets(const pattern: string; colour: TRawColour;
  out x1, y1, x2, y2: Integer; out twoGreens: Boolean);
begin
  twoGreens := False;
  x2 := 0;
  y2 := 0;

  if pattern = 'RGGB' then
    case colour of
      rcRed:   begin x1 := 0; y1 := 0; end;
      rcBlue:  begin x1 := 1; y1 := 1; end;
      rcGreen: begin x1 := 1; y1 := 0; x2 := 0; y2 := 1; twoGreens := True; end;
    end
  else if pattern = 'GRBG' then
    case colour of
      rcRed:   begin x1 := 1; y1 := 0; end;
      rcBlue:  begin x1 := 0; y1 := 1; end;
      rcGreen: begin x1 := 0; y1 := 0; x2 := 1; y2 := 1; twoGreens := True; end;
    end
  else if pattern = 'GBRG' then
    case colour of
      rcRed:   begin x1 := 0; y1 := 1; end;
      rcBlue:  begin x1 := 1; y1 := 0; end;
      rcGreen: begin x1 := 0; y1 := 0; x2 := 1; y2 := 1; twoGreens := True; end;
    end
  else if pattern = 'BGGR' then
    case colour of
      rcRed:   begin x1 := 1; y1 := 1; end;
      rcBlue:  begin x1 := 0; y1 := 0; end;
      rcGreen: begin x1 := 1; y1 := 0; x2 := 0; y2 := 1; twoGreens := True; end;
    end
  else
    raise Exception.Create('Unsupported Bayer pattern: ' + pattern);
end;

function ColourSuffix(c: TRawColour): string;
begin
  case c of
    rcRed: Result := 'TR';
    rcGreen: Result := 'TG';
    rcBlue: Result := 'TB';
  end;
end;

procedure ExtractRawColour(const src: TDoubleImage; const pattern: string;
  colour: TRawColour; out dst: TDoubleImage);
var
  x, y, outW, outH: Integer;
  x1, y1, x2, y2: Integer;
  twoGreens: Boolean;
begin
  outH := Length(src) div 2;
  outW := Length(src[0]) div 2;
  SetLength(dst, outH, outW);

  BayerOffsets(pattern, colour, x1, y1, x2, y2, twoGreens);

  for y := 0 to outH - 1 do
    for x := 0 to outW - 1 do
      if twoGreens then
        dst[y, x] := (src[y * 2 + y1, x * 2 + x1] +
                      src[y * 2 + y2, x * 2 + x2]) / 2
      else
        dst[y, x] := src[y * 2 + y1, x * 2 + x1];
end;

function FitsCard(const key, value, comment: string): string;
var
  s: string;
begin
  if key = 'END' then
    s := 'END'
  else if comment <> '' then
    s := Format('%-8s= %-20s / %s', [key, value, comment])
  else
    s := Format('%-8s= %s', [key, value]);

  while Length(s) < 80 do s := s + ' ';
  Result := Copy(s, 1, 80);
end;

procedure WriteCard(fs: TFileStream; const card: string);
begin
  fs.WriteBuffer(PAnsiChar(AnsiString(card))^, 80);
end;

procedure WriteBE32Float(fs: TFileStream; value: Single);
var
  u: LongWord;
  b: array[0..3] of Byte;
begin
  Move(value, u, 4);
  b[0] := Byte((u shr 24) and $FF);
  b[1] := Byte((u shr 16) and $FF);
  b[2] := Byte((u shr 8) and $FF);
  b[3] := Byte(u and $FF);
  fs.WriteBuffer(b, 4);
end;

procedure ExpandInputPattern(const pattern: string; files: TStrings);
var
  sr: TSearchRec;
  dir: string;
begin
  if (Pos('*', pattern) = 0) and (Pos('?', pattern) = 0) then
  begin
    files.Add(pattern);
    Exit;
  end;

  dir := ExtractFilePath(pattern);
  if dir = '' then dir := '.';

  if FindFirst(pattern, faAnyFile and not faDirectory, sr) = 0 then
  begin
    repeat
      files.Add(IncludeTrailingPathDelimiter(dir) + sr.Name);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

procedure WriteBE16Raw(fs: TFileStream; value: SmallInt);
var
  u: Word;
  b: array[0..1] of Byte;
begin
  u := Word(value);
  b[0] := Byte((u shr 8) and $FF);
  b[1] := Byte(u and $FF);
  fs.WriteBuffer(b, 2);
end;

procedure WriteBE32Raw(fs: TFileStream; value: LongInt);
var
  u: LongWord;
  b: array[0..3] of Byte;
begin
  u := LongWord(value);
  b[0] := Byte((u shr 24) and $FF);
  b[1] := Byte((u shr 16) and $FF);
  b[2] := Byte((u shr 8) and $FF);
  b[3] := Byte(u and $FF);
  fs.WriteBuffer(b, 4);
end;

function MakeFitsCard(const key, value, comment: string): string;
var
  s: string;
begin
  if comment <> '' then
    s := Format('%-8s= %-20s / %s', [key, value, comment])
  else
    s := Format('%-8s= %s', [key, value]);

  while Length(s) < 80 do s := s + ' ';
  Result := Copy(s, 1, 80);
end;

procedure UpdateOrAddHeaderCard(cards: TStringList; const key, value, comment: string);
var
  i, endIndex: Integer;
  key8: string;
begin
  key8 := Copy(key + '        ', 1, 8);
  endIndex := cards.Count;

  for i := 0 to cards.Count - 1 do
  begin
    if CardKey(cards[i]) = 'END' then
    begin
      endIndex := i;
      Break;
    end;

    if Copy(cards[i], 1, 8) = key8 then
    begin
      cards[i] := MakeFitsCard(key, value, comment);
      Exit;
    end;
  end;

  cards.Insert(endIndex, MakeFitsCard(key, value, comment));
end;

procedure WriteCopiedHeader(fs: TFileStream; const srcHeader: TFitsHeader;
  outWidth, outHeight: Integer; const filterName: string);
var
  cards: TStringList;
  i: Integer;
  headerBytes, padBytes: Int64;
  zero: Byte;
  hasEnd: Boolean;
begin
  cards := TStringList.Create;
  try
    cards.Assign(srcHeader.Cards);

    UpdateOrAddHeaderCard(cards, 'NAXIS', '2', 'number of data axes');
    UpdateOrAddHeaderCard(cards, 'NAXIS1', IntToStr(outWidth), 'length of x axis');
    UpdateOrAddHeaderCard(cards, 'NAXIS2', IntToStr(outHeight), 'length of y axis');
    UpdateOrAddHeaderCard(cards, 'FILTER', '''' + filterName + '''', 'Extracted raw Bayer colour');

    hasEnd := False;
    for i := 0 to cards.Count - 1 do
      if CardKey(cards[i]) = 'END' then
      begin
        hasEnd := True;
        Break;
      end;

    if not hasEnd then
      cards.Add('END' + StringOfChar(' ', 77));

    for i := 0 to cards.Count - 1 do
      WriteCard(fs, Copy(cards[i] + StringOfChar(' ', 80), 1, 80));

    headerBytes := fs.Position;
    zero := 0;
    padBytes := Pad2880(headerBytes) - headerBytes;
    while padBytes > 0 do
    begin
      fs.WriteBuffer(zero, 1);
      Dec(padBytes);
    end;
  finally
    cards.Free;
  end;
end;

procedure WriteSameBitpixFits(const fileName: string; const img: TDoubleImage;
  const sourceName, filterName, bayerPattern: string; const srcHeader: TFitsHeader);
var
  fs: TFileStream;
  x, y: Integer;
  headerBytes, dataBytes, padBytes, p: Int64;
  zero: Byte;
  v: Double;
  bytesPerPixel: Integer;
  outBuf: array of Byte;
  i16: SmallInt;
  u16: Word;
  i32: LongInt;
  u32: LongWord;
  s32: Single;
  fsFmt: TFormatSettings;

  function FloatFitsStr(d: Double): string;
  begin
    Result := FloatToStr(d, fsFmt);
  end;

begin
  fsFmt := DefaultFormatSettings;
  fsFmt.DecimalSeparator := '.';

  fs := TFileStream.Create(fileName, fmCreate);
  try
    zero := 0;
    WriteCopiedHeader(fs, srcHeader, Length(img[0]), Length(img), filterName);

    bytesPerPixel := Abs(srcHeader.BitPix) div 8;
    dataBytes := Int64(Length(img)) * Length(img[0]) * bytesPerPixel;
    SetLength(outBuf, dataBytes);

    p := 0;
    for y := 0 to High(img) do
      for x := 0 to High(img[y]) do
      begin
        v := (img[y, x] - srcHeader.BZero) / srcHeader.BScale;

        case srcHeader.BitPix of
          8:
            begin
              if v < 0 then v := 0;
              if v > 255 then v := 255;
              outBuf[p] := Byte(Round(v));
              Inc(p, 1);
            end;

          16:
            begin
              if v < -32768 then v := -32768;
              if v > 32767 then v := 32767;
              i16 := SmallInt(Round(v));
              u16 := Word(i16);
              outBuf[p] := Byte((u16 shr 8) and $FF);
              outBuf[p + 1] := Byte(u16 and $FF);
              Inc(p, 2);
            end;

          32:
            begin
              if v < Low(LongInt) then v := Low(LongInt);
              if v > High(LongInt) then v := High(LongInt);
              i32 := LongInt(Round(v));
              u32 := LongWord(i32);
              outBuf[p] := Byte((u32 shr 24) and $FF);
              outBuf[p + 1] := Byte((u32 shr 16) and $FF);
              outBuf[p + 2] := Byte((u32 shr 8) and $FF);
              outBuf[p + 3] := Byte(u32 and $FF);
              Inc(p, 4);
            end;

          -32:
            begin
              s32 := Single(img[y, x]);
              Move(s32, u32, 4);
              outBuf[p] := Byte((u32 shr 24) and $FF);
              outBuf[p + 1] := Byte((u32 shr 16) and $FF);
              outBuf[p + 2] := Byte((u32 shr 8) and $FF);
              outBuf[p + 3] := Byte(u32 and $FF);
              Inc(p, 4);
            end;

        else
          raise Exception.Create('Unsupported output BITPIX: ' + IntToStr(srcHeader.BitPix));
        end;
      end;

    if dataBytes > 0 then
      fs.WriteBuffer(outBuf[0], dataBytes);

    padBytes := Pad2880(dataBytes) - dataBytes;
    while padBytes > 0 do
    begin
      fs.WriteBuffer(zero, 1);
      Dec(padBytes);
    end;

  finally
    fs.Free;
  end;
end;

procedure ProcessOneFile(const inputFile, outputDir: string; colour: TRawColour);
var
  h: TFitsHeader;
  src, dst: TDoubleImage;
  outName, suffix: string;
  t0: QWord;
begin
  h.Cards := nil;
  t0 := GetTickCount64;

  try
    LoadFitsImage(inputFile, h, src);
    ExtractRawColour(src, h.BayerPat, colour, dst);

    suffix := ColourSuffix(colour);
    outName := IncludeTrailingPathDelimiter(outputDir) +
      ChangeFileExt(ExtractFileName(inputFile), '_' + suffix + '.fits');
    WriteSameBitpixFits(outName, dst, inputFile, suffix, h.BayerPat, h);
  finally
    if Assigned(h.Cards) then h.Cards.Free;
    src := nil;
    dst := nil;
  end;
end;

procedure Usage;
begin
  Writeln('Usage: rawsplit_fits --filter TR|TG|TB|ALL --out <folder> <fits files...>');
end;

var
  i, startFiles, processed: Integer;
  outDir, filter: string;
  inputs: TStringList;
  c: TRawColour;

begin
  outDir := '';
  filter := '';
  startFiles := 0;

  i := 1;
  while i <= ParamCount do
  begin
    if SameText(ParamStr(i), '--out') then
    begin
      Inc(i);
      if i <= ParamCount then outDir := ParamStr(i);
    end
    else if SameText(ParamStr(i), '--filter') then
    begin
      Inc(i);
      if i <= ParamCount then filter := UpperCase(ParamStr(i));
    end
    else
    begin
      startFiles := i;
      Break;
    end;
    Inc(i);
  end;

  if (outDir = '') or (filter = '') or (startFiles = 0) then
  begin
    Usage;
    Halt(1);
  end;

  ForceDirectories(outDir);

  inputs := TStringList.Create;
  try
    for i := startFiles to ParamCount do
      ExpandInputPattern(ParamStr(i), inputs);

    if inputs.Count = 0 then
      raise Exception.Create('No input files');

    processed := 0;

    for i := 0 to inputs.Count - 1 do
    begin
      Write(#13, 'Processing ', i + 1, '/', inputs.Count);

      if filter = 'ALL' then
      begin
        ProcessOneFile(inputs[i], outDir, rcRed);
        ProcessOneFile(inputs[i], outDir, rcGreen);
        ProcessOneFile(inputs[i], outDir, rcBlue);
      end
      else
      begin
        if filter = 'TR' then c := rcRed else
        if filter = 'TG' then c := rcGreen else
        if filter = 'TB' then c := rcBlue else
          raise Exception.Create('Unknown filter: ' + filter);

        ProcessOneFile(inputs[i], outDir, c);
      end;

      Inc(processed);
    end;

    Writeln;
    Writeln('Files processed: ', processed, '/', inputs.Count);
    Writeln('Saved to: ', ExpandFileName(outDir));

  finally
    inputs.Free;
  end;
end.