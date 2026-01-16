unit QRCode;

{
  QR Code Generator - Delphi/Pascal Implementation
  Supports versions 1-10 with 15% Error Correction Level
  Terminal output using Unicode block characters
}

interface

uses
  System.SysUtils, System.Classes, System.Math
  {$IFDEF MSWINDOWS}
  , Vcl.Graphics, Vcl.Imaging.pngimage
  {$ENDIF}
  {$IFDEF ANDROID}
  , Androidapi.JNI.GraphicsContentViewText, Androidapi.JNIBridge, Androidapi.Helpers
  {$ENDIF}
  {$IF DEFINED(IOS) OR DEFINED(MACOS) OR DEFINED(ANDROID)}
  , FMX.Graphics
  {$ENDIF};

type
  TByteArray = array of Byte;
  TIntArray = array of Integer;
  TQRModule = (qmLight, qmDark, qmUnset);
  TQRModuleMatrix = array of array of TQRModule;
  TBoolMatrix = array of array of Boolean;

  { TGaloisField - GF(256) arithmetic operations }
  TGaloisField = class
  private
    class var FExpTable: array[0..511] of Integer;
    class var FLogTable: array[0..255] of Integer;
    class var FInitialized: Boolean;
    class procedure Initialize;
  public
    class function Multiply(A, B: Integer): Integer;
    class function Add(A, B: Integer): Integer;
    class function Exp(N: Integer): Integer;
    class function Log(N: Integer): Integer;
  end;

  { TReedSolomon - Error correction codeword generation and decoding }
  TReedSolomon = class
  private
    class function MultiplyPolynomials(P1, P2: TIntArray): TIntArray;
    class function GenerateGeneratorPolynomial(Degree: Integer): TIntArray;
  public
    // Encoding
    class function GenerateECCodewords(Data: TByteArray; ECCount: Integer): TByteArray;
    // Decoding
    class function CalculateSyndromes(const Received: TByteArray; ECCount: Integer): TIntArray;
    class function HasErrors(const Syndromes: TIntArray): Boolean;
    class function CorrectErrors(var Data: TByteArray; ECCount: Integer): Boolean;
  end;

  { TQRBitBuffer - Bit-level data manipulation }
  TQRBitBuffer = class
  private
    FBits: TByteArray;
    FBitLength: Integer;
  public
    constructor Create;
    procedure AppendBits(Value: Integer; NumBits: Integer);
    procedure AppendBytes(const Data: TByteArray);
    function ToByteArray(TargetLength: Integer): TByteArray;
    property BitLength: Integer read FBitLength;
  end;

  { TQRVersionInfo - Version-specific parameters }
  TQRVersionInfo = record
    Version: Integer;
    Size: Integer;
    DataCapacity: Integer;
    ECCodewords: Integer;
    BlockCount: Integer;
    AlignmentPositions: TIntArray;
  end;

  { TQRDataEncoder - Data encoding (byte mode) }
  TQRDataEncoder = class
  public
    class function Encode(const Data: string; Version: Integer): TByteArray;
    class function SelectVersion(DataLength: Integer): Integer;
    class function GetVersionInfo(Version: Integer): TQRVersionInfo;
  end;

  { TQRMatrix - QR code matrix operations }
  TQRMatrix = class
  private
    FSize: Integer;
    FModules: TQRModuleMatrix;
    FReserved: TBoolMatrix;
    procedure PlaceFinderPattern(Row, Col: Integer);
    procedure PlaceTimingPatterns;
    procedure PlaceAlignmentPatterns(const Positions: TIntArray);
    procedure PlaceAlignmentPattern(CenterRow, CenterCol: Integer);
    procedure ReserveFormatArea;
    procedure PlaceDataBits(const Data: TByteArray);
  public
    constructor Create(Size: Integer);
    procedure Initialize(const VersionInfo: TQRVersionInfo);
    procedure PlaceData(const Data: TByteArray);
    procedure ApplyMask(MaskPattern: Integer);
    procedure PlaceFormatInfo(ECLevel, MaskPattern: Integer);
    function GetModule(Row, Col: Integer): TQRModule;
    procedure SetModule(Row, Col: Integer; Value: TQRModule);
    function Clone: TQRMatrix;
    property Size: Integer read FSize;
  end;

  { TQRMask - Masking and penalty evaluation }
  TQRMask = class
  public
    class function EvaluateMask(Row, Col, Pattern: Integer): Boolean;
    class function CalculatePenalty(Matrix: TQRMatrix): Integer;
    class function FindBestMask(Matrix: TQRMatrix; ECLevel: Integer): Integer;
  end;

  { TFinderPattern - Detected finder pattern info }
  TFinderPattern = record
    CenterX, CenterY: Double;
    ModuleSize: Double;
  end;
  TFinderPatternArray = array of TFinderPattern;
  TFinderCandidates = array of TFinderPattern;

  { TQRImageProcessor - Image processing for QR decoding }
  TQRImageProcessor = class
  private
    FWidth, FHeight: Integer;
    FGrayscale: array of Byte;
    FBinary: array of Boolean;
    FFinders: array[0..2] of TFinderPattern;
    FFinderCount: Integer;
    FCandidates: TFinderCandidates;
    FCandidateCount: Integer;
    FModuleSize: Double;
    FGridSize: Integer;
    FTopLeft, FTopRight, FBottomLeft: Integer;  // Indices into FFinders

    procedure LoadRGBA(const Data: TBytes; W, H: Integer);
    procedure Binarize;
    function GetPixel(X, Y: Integer): Boolean;  // True = dark
    function CheckRatio(const Counts: array of Integer): Boolean;
    function CrossCheckVertical(CenterX, CenterY: Integer; MaxCount: Integer): Double;
    function CrossCheckHorizontal(CenterX, CenterY: Integer; MaxCount: Integer): Double;
    procedure HandlePossibleCenter(const StateCount: array of Integer; Row, Col: Integer);
    procedure FindFinderPatterns;
    procedure SelectBestFinders;
    procedure OrderFinderPatterns;
    procedure CalculateGridParameters;
    function SampleModule(Row, Col: Integer): Boolean;
  public
    constructor Create;
    procedure Process(const RGBA: TBytes; Width, Height: Integer);
    function ExtractMatrix: TQRMatrix;
    function GetVersion: Integer;
    property GridSize: Integer read FGridSize;
    property ModuleSize: Double read FModuleSize;
  end;

  { TQRDataDecoder - Data extraction and decoding }
  TQRDataDecoder = class
  public
    class function ExtractFormatInfo(Matrix: TQRMatrix): Integer;
    class function ExtractDataBits(Matrix: TQRMatrix; Version: Integer): TByteArray;
    class function DecodeByteMode(const Data: TByteArray; Version: Integer): string;
  end;

  { TQRCode - Main facade class }
  TQRCode = class
  private
    FMatrix: TQRMatrix;
    FVersion: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Generate(const Data: string);
    function RenderToString: string;
    procedure RenderToConsole;
    {$IFDEF MSWINDOWS}
    procedure SaveToPng(const FileName: string; ModuleSize: Integer = 10);
    function ToBitmap(ModuleSize: Integer = 10): Vcl.Graphics.TBitmap;
    function ToPngStream(ModuleSize: Integer = 10): TMemoryStream;
    {$ENDIF}
    {$IF DEFINED(IOS) OR DEFINED(MACOS) OR DEFINED(ANDROID)}
    function ToBitmap(ModuleSize: Integer = 10): FMX.Graphics.TBitmap;
    {$ENDIF}
    {$IFDEF ANDROID}
    function ToJBitmap(ModuleSize: Integer = 10): JBitmap;
    {$ENDIF}
    function ToRGBA(ModuleSize: Integer = 10): TBytes;
    // Decoding methods
    function ReadFromRGBA(const Data: TBytes; Width, Height: Integer): string;
    {$IFDEF MSWINDOWS}
    function ReadFromPng(const FileName: string): string;
    function ReadFromBitmap(Bitmap: Vcl.Graphics.TBitmap): string;
    {$ENDIF}
    {$IF DEFINED(IOS) OR DEFINED(MACOS) OR DEFINED(ANDROID)}
    function ReadFromBitmap(Bitmap: FMX.Graphics.TBitmap): string;
    {$ENDIF}
    property Matrix: TQRMatrix read FMatrix;
    property Version: Integer read FVersion;
  end;

const
  EC_LEVEL_M = 0;  // 00 in binary

implementation

{$IFDEF ANDROID}
uses
  Androidapi.JNI.JavaTypes;
{$ENDIF}

{ TGaloisField }

class procedure TGaloisField.Initialize;
var
  Value, I: Integer;
begin
  if FInitialized then Exit;

  Value := 1;
  for I := 0 to 255 do
  begin
    FExpTable[I] := Value;
    FLogTable[Value] := I;
    Value := Value shl 1;
    if Value >= 256 then
      Value := Value xor 285; // Primitive polynomial x^8 + x^4 + x^3 + x^2 + 1
  end;

  // Extend exp table for easier modulo operations
  for I := 256 to 511 do
    FExpTable[I] := FExpTable[I - 255];

  FInitialized := True;
end;

class function TGaloisField.Multiply(A, B: Integer): Integer;
begin
  Initialize;
  if (A = 0) or (B = 0) then
    Result := 0
  else
    Result := FExpTable[FLogTable[A] + FLogTable[B]];
end;

class function TGaloisField.Add(A, B: Integer): Integer;
begin
  Result := A xor B;
end;

class function TGaloisField.Exp(N: Integer): Integer;
begin
  Initialize;
  Result := FExpTable[N mod 255];
end;

class function TGaloisField.Log(N: Integer): Integer;
begin
  Initialize;
  if N = 0 then
    raise Exception.Create('Log(0) is undefined');
  Result := FLogTable[N];
end;

{ TReedSolomon }

class function TReedSolomon.MultiplyPolynomials(P1, P2: TIntArray): TIntArray;
var
  I, J: Integer;
begin
  SetLength(Result, Length(P1) + Length(P2) - 1);
  for I := 0 to High(Result) do
    Result[I] := 0;

  for I := 0 to High(P1) do
    for J := 0 to High(P2) do
      Result[I + J] := TGaloisField.Add(Result[I + J],
        TGaloisField.Multiply(P1[I], P2[J]));
end;

class function TReedSolomon.GenerateGeneratorPolynomial(Degree: Integer): TIntArray;
var
  I: Integer;
  Factor: TIntArray;
begin
  SetLength(Result, 1);
  Result[0] := 1;

  SetLength(Factor, 2);
  for I := 0 to Degree - 1 do
  begin
    Factor[0] := 1;
    Factor[1] := TGaloisField.Exp(I);
    Result := MultiplyPolynomials(Result, Factor);
  end;
end;

class function TReedSolomon.GenerateECCodewords(Data: TByteArray; ECCount: Integer): TByteArray;
var
  Generator: TIntArray;
  MessagePoly: TIntArray;
  I, J: Integer;
  LeadCoef: Integer;
begin
  Generator := GenerateGeneratorPolynomial(ECCount);

  // Create message polynomial (data as coefficients)
  SetLength(MessagePoly, Length(Data) + ECCount);
  for I := 0 to High(Data) do
    MessagePoly[I] := Data[I];
  for I := Length(Data) to High(MessagePoly) do
    MessagePoly[I] := 0;

  // Polynomial division
  for I := 0 to High(Data) do begin
    LeadCoef := MessagePoly[I];
    if LeadCoef <> 0 then
    begin
      for J := 0 to High(Generator) do
        MessagePoly[I + J] := TGaloisField.Add(MessagePoly[I + J],
          TGaloisField.Multiply(Generator[J], LeadCoef));
    end;
  end;

  // Extract remainder (EC codewords)
  SetLength(Result, ECCount);
  for I := 0 to ECCount - 1 do
    Result[I] := MessagePoly[Length(Data) + I];
end;

{ TQRBitBuffer }

constructor TQRBitBuffer.Create;
begin
  SetLength(FBits, 0);
  FBitLength := 0;
end;

procedure TQRBitBuffer.AppendBits(Value: Integer; NumBits: Integer);
var
  I: Integer;
  ByteIndex, BitIndex: Integer;
begin
  // Ensure enough space
  while Length(FBits) * 8 < FBitLength + NumBits do begin
    SetLength(FBits, Length(FBits) + 1);
    FBits[High(FBits)] := 0;
  end;

  // Append bits MSB first
  for I := NumBits - 1 downto 0 do begin
    if ((Value shr I) and 1) = 1 then
    begin
      ByteIndex := FBitLength div 8;
      BitIndex := 7 - (FBitLength mod 8);
      FBits[ByteIndex] := FBits[ByteIndex] or (1 shl BitIndex);
    end;
    Inc(FBitLength);
  end;
end;

procedure TQRBitBuffer.AppendBytes(const Data: TByteArray);
var
  I: Integer;
begin
  for I := 0 to High(Data) do
    AppendBits(Data[I], 8);
end;

function TQRBitBuffer.ToByteArray(TargetLength: Integer): TByteArray;
var
  I: Integer;
  PadByte: Byte;
begin
  // Pad to byte boundary
  while (FBitLength mod 8) <> 0 do
    AppendBits(0, 1);

  // Pad with alternating 236/17
  PadByte := 236;
  while Length(FBits) < TargetLength do
  begin
    AppendBits(PadByte, 8);
    if PadByte = 236 then
      PadByte := 17
    else
      PadByte := 236;
  end;

  SetLength(Result, TargetLength);
  for I := 0 to TargetLength - 1 do
    Result[I] := FBits[I];
end;

{ TQRDataEncoder }

class function TQRDataEncoder.GetVersionInfo(Version: Integer): TQRVersionInfo;
const
  // Data capacity for EC level M (bytes available for data)
  DataCapacities: array[1..10] of Integer = (16, 28, 44, 64, 86, 108, 124, 154, 182, 216);
  // EC codewords per block for EC level M
  ECCodewords: array[1..10] of Integer = (10, 16, 26, 18, 24, 16, 18, 22, 22, 26);
  // Number of EC blocks for EC level M (from ISO 18004)
  BlockCounts: array[1..10] of Integer = (1, 1, 1, 2, 2, 4, 4, 4, 5, 5);
begin
  if (Version < 1) or (Version > 10) then
    raise Exception.CreateFmt('Unsupported version: %d', [Version]);

  Result.Version := Version;
  Result.Size := 17 + Version * 4;
  Result.DataCapacity := DataCapacities[Version];
  Result.ECCodewords := ECCodewords[Version];
  Result.BlockCount := BlockCounts[Version];

  // Alignment pattern positions
  case Version of
    1: SetLength(Result.AlignmentPositions, 0);
    2: begin SetLength(Result.AlignmentPositions, 2); Result.AlignmentPositions[0] := 6; Result.AlignmentPositions[1] := 18; end;
    3: begin SetLength(Result.AlignmentPositions, 2); Result.AlignmentPositions[0] := 6; Result.AlignmentPositions[1] := 22; end;
    4: begin SetLength(Result.AlignmentPositions, 2); Result.AlignmentPositions[0] := 6; Result.AlignmentPositions[1] := 26; end;
    5: begin SetLength(Result.AlignmentPositions, 2); Result.AlignmentPositions[0] := 6; Result.AlignmentPositions[1] := 30; end;
    6: begin SetLength(Result.AlignmentPositions, 2); Result.AlignmentPositions[0] := 6; Result.AlignmentPositions[1] := 34; end;
    7: begin SetLength(Result.AlignmentPositions, 3); Result.AlignmentPositions[0] := 6; Result.AlignmentPositions[1] := 22; Result.AlignmentPositions[2] := 38; end;
    8: begin SetLength(Result.AlignmentPositions, 3); Result.AlignmentPositions[0] := 6; Result.AlignmentPositions[1] := 24; Result.AlignmentPositions[2] := 42; end;
    9: begin SetLength(Result.AlignmentPositions, 3); Result.AlignmentPositions[0] := 6; Result.AlignmentPositions[1] := 26; Result.AlignmentPositions[2] := 46; end;
    10: begin SetLength(Result.AlignmentPositions, 3); Result.AlignmentPositions[0] := 6; Result.AlignmentPositions[1] := 28; Result.AlignmentPositions[2] := 50; end;
  end;
end;

class function TQRDataEncoder.SelectVersion(DataLength: Integer): Integer;
var
  V: Integer;
  Info: TQRVersionInfo;
  RequiredBits: Integer;
begin
  // Calculate required bits: mode(4) + count(8 for v1-9, 16 for v10) + data + terminator(4)
  for V := 1 to 10 do begin
    Info := GetVersionInfo(V);
    if V <= 9 then
      RequiredBits := 4 + 8 + DataLength * 8
    else
      RequiredBits := 4 + 16 + DataLength * 8;

    // Check if data fits (capacity is in bytes for data codewords only)
    if RequiredBits <= Info.DataCapacity * 8 then
      Exit(V);
  end;

  raise Exception.Create('Data too large for supported QR versions (1-10)');
end;

class function TQRDataEncoder.Encode(const Data: string; Version: Integer): TByteArray;
var
  Buffer: TQRBitBuffer;
  DataBytes: TBytes;
  I: Integer;
  Info: TQRVersionInfo;
  CharCountBits: Integer;
begin
  Info := GetVersionInfo(Version);
  DataBytes := TEncoding.UTF8.GetBytes(Data);

  Buffer := TQRBitBuffer.Create;
  try
    // Mode indicator: byte mode = 0100
    Buffer.AppendBits($4, 4);

    // Character count indicator
    if Version <= 9 then
      CharCountBits := 8
    else
      CharCountBits := 16;
    Buffer.AppendBits(Length(DataBytes), CharCountBits);

    // Data bytes
    for I := 0 to High(DataBytes) do
      Buffer.AppendBits(DataBytes[I], 8);

    // Terminator (up to 4 zero bits)
    if Buffer.BitLength + 4 <= Info.DataCapacity * 8 then
      Buffer.AppendBits(0, 4)
    else if Buffer.BitLength < Info.DataCapacity * 8 then
      Buffer.AppendBits(0, Info.DataCapacity * 8 - Buffer.BitLength);

    Result := Buffer.ToByteArray(Info.DataCapacity);
  finally
    Buffer.Free;
  end;
end;

{ TQRMatrix }

constructor TQRMatrix.Create(Size: Integer);
var
  I, J: Integer;
begin
  FSize := Size;
  SetLength(FModules, Size, Size);
  SetLength(FReserved, Size, Size);

  for I := 0 to Size - 1 do
    for J := 0 to Size - 1 do begin
      FModules[I, J] := qmUnset;
      FReserved[I, J] := False;
    end;
end;

procedure TQRMatrix.PlaceFinderPattern(Row, Col: Integer);
var
  R, C: Integer;
begin
  for R := -1 to 7 do
    for C := -1 to 7 do begin
      if (Row + R < 0) or (Row + R >= FSize) or
         (Col + C < 0) or (Col + C >= FSize) then
        Continue;

      // Separator (white border)
      if (R = -1) or (R = 7) or (C = -1) or (C = 7) then
      begin
        FModules[Row + R, Col + C] := qmLight;
        FReserved[Row + R, Col + C] := True;
      end
      // Finder pattern
      else if (R = 0) or (R = 6) or (C = 0) or (C = 6) or
              ((R >= 2) and (R <= 4) and (C >= 2) and (C <= 4)) then
      begin
        FModules[Row + R, Col + C] := qmDark;
        FReserved[Row + R, Col + C] := True;
      end
      else
      begin
        FModules[Row + R, Col + C] := qmLight;
        FReserved[Row + R, Col + C] := True;
      end;
    end;
end;

procedure TQRMatrix.PlaceTimingPatterns;
var
  I: Integer;
begin
  for I := 8 to FSize - 9 do begin
    if not FReserved[6, I] then begin
      if (I mod 2) = 0 then
        FModules[6, I] := qmDark
      else
        FModules[6, I] := qmLight;
      FReserved[6, I] := True;
    end;

    if not FReserved[I, 6] then
    begin
      if (I mod 2) = 0 then
        FModules[I, 6] := qmDark
      else
        FModules[I, 6] := qmLight;
      FReserved[I, 6] := True;
    end;
  end;
end;

procedure TQRMatrix.PlaceAlignmentPattern(CenterRow, CenterCol: Integer);
var
  R, C: Integer;
begin
  for R := -2 to 2 do
    for C := -2 to 2 do begin
      // Skip if overlaps with finder pattern
      if FReserved[CenterRow + R, CenterCol + C] then
        Continue;

      if (Abs(R) = 2) or (Abs(C) = 2) or ((R = 0) and (C = 0)) then
        FModules[CenterRow + R, CenterCol + C] := qmDark
      else
        FModules[CenterRow + R, CenterCol + C] := qmLight;

      FReserved[CenterRow + R, CenterCol + C] := True;
    end;
end;

procedure TQRMatrix.PlaceAlignmentPatterns(const Positions: TIntArray);
var
  I, J: Integer;
  Row, Col: Integer;
begin
  if Length(Positions) = 0 then
    Exit;

  for I := 0 to High(Positions) do
    for J := 0 to High(Positions) do begin
      Row := Positions[I];
      Col := Positions[J];

      // Skip corners where finder patterns are
      if ((Row < 9) and (Col < 9)) or
         ((Row < 9) and (Col > FSize - 10)) or
         ((Row > FSize - 10) and (Col < 9)) then
        Continue;

      PlaceAlignmentPattern(Row, Col);
    end;
end;

procedure TQRMatrix.ReserveFormatArea;
var
  I: Integer;
begin
  // Around top-left finder
  for I := 0 to 8 do
  begin
    FReserved[8, I] := True;
    FReserved[I, 8] := True;
  end;

  // Around top-right finder
  for I := FSize - 8 to FSize - 1 do
    FReserved[8, I] := True;

  // Around bottom-left finder
  for I := FSize - 8 to FSize - 1 do
    FReserved[I, 8] := True;

  // Dark module (always present)
  FModules[FSize - 8, 8] := qmDark;
  FReserved[FSize - 8, 8] := True;
end;

procedure TQRMatrix.PlaceDataBits(const Data: TByteArray);
var
  BitIndex: Integer;
  Col, Row: Integer;
  Upward: Boolean;
  I: Integer;
begin
  BitIndex := 0;
  Col := FSize - 1;
  Upward := True;

  while Col >= 0 do
  begin
    // Skip vertical timing pattern
    if Col = 6 then
      Dec(Col);

    if Upward then begin
      for Row := FSize - 1 downto 0 do
      begin
        for I := 0 to 1 do
        begin
          if Col - I < 0 then
            Continue;

          if not FReserved[Row, Col - I] then
          begin
            if BitIndex < Length(Data) * 8 then
            begin
              if ((Data[BitIndex div 8] shr (7 - BitIndex mod 8)) and 1) = 1 then
                FModules[Row, Col - I] := qmDark
              else
                FModules[Row, Col - I] := qmLight;
              Inc(BitIndex);
            end
            else
              FModules[Row, Col - I] := qmLight;
          end;
        end;
      end;
    end
    else
    begin
      for Row := 0 to FSize - 1 do
      begin
        for I := 0 to 1 do
        begin
          if Col - I < 0 then
            Continue;

          if not FReserved[Row, Col - I] then
          begin
            if BitIndex < Length(Data) * 8 then
            begin
              if ((Data[BitIndex div 8] shr (7 - BitIndex mod 8)) and 1) = 1 then
                FModules[Row, Col - I] := qmDark
              else
                FModules[Row, Col - I] := qmLight;
              Inc(BitIndex);
            end
            else
              FModules[Row, Col - I] := qmLight;
          end;
        end;
      end;
    end;

    Dec(Col, 2);
    Upward := not Upward;
  end;
end;

procedure TQRMatrix.Initialize(const VersionInfo: TQRVersionInfo);
begin
  // Place finder patterns at three corners
  PlaceFinderPattern(0, 0);
  PlaceFinderPattern(0, FSize - 7);
  PlaceFinderPattern(FSize - 7, 0);

  // Place timing patterns
  PlaceTimingPatterns;

  // Place alignment patterns
  PlaceAlignmentPatterns(VersionInfo.AlignmentPositions);

  // Reserve format information area
  ReserveFormatArea;
end;

procedure TQRMatrix.PlaceData(const Data: TByteArray);
begin
  PlaceDataBits(Data);
end;

procedure TQRMatrix.ApplyMask(MaskPattern: Integer);
var
  Row, Col: Integer;
begin
  for Row := 0 to FSize - 1 do
    for Col := 0 to FSize - 1 do begin
      if not FReserved[Row, Col] then begin
        if TQRMask.EvaluateMask(Row, Col, MaskPattern) then
        begin
          if FModules[Row, Col] = qmDark then
            FModules[Row, Col] := qmLight
          else
            FModules[Row, Col] := qmDark;
        end;
      end;
    end;
end;

procedure TQRMatrix.PlaceFormatInfo(ECLevel, MaskPattern: Integer);
var
  FormatBits: Integer;
  I: Integer;

  function GetBit(Pos: Integer): TQRModule;
  begin
    if ((FormatBits shr Pos) and 1) = 1 then
      Result := qmDark
    else
      Result := qmLight;
  end;

const
  // Precomputed format strings for EC level M (index = mask pattern)
  // Values from ISO/IEC 18004 standard: BCH(15,5) + XOR mask applied
  FORMAT_M: array[0..7] of Integer = (
    $5412,  // 101010000010010 - M, mask 0
    $5125,  // 101000100100101 - M, mask 1
    $5E7C,  // 101111001111100 - M, mask 2
    $5B4B,  // 101101101001011 - M, mask 3
    $45F9,  // 100010111111001 - M, mask 4
    $40CE,  // 100000011001110 - M, mask 5
    $4F97,  // 100111110010111 - M, mask 6
    $4AA0   // 100101010100000 - M, mask 7
  );
begin
  // Use precomputed format strings for reliability
  FormatBits := FORMAT_M[MaskPattern and 7];

  // First copy: around top-left finder
  // Horizontal part in row 8
  FModules[8, 0] := GetBit(0);
  FModules[8, 1] := GetBit(1);
  FModules[8, 2] := GetBit(2);
  FModules[8, 3] := GetBit(3);
  FModules[8, 4] := GetBit(4);
  FModules[8, 5] := GetBit(5);
  // Skip column 6 (timing pattern)
  FModules[8, 7] := GetBit(6);
  FModules[8, 8] := GetBit(7);

  // Vertical part in column 8
  // Skip row 6 (timing pattern)
  FModules[7, 8] := GetBit(8);
  FModules[5, 8] := GetBit(9);
  FModules[4, 8] := GetBit(10);
  FModules[3, 8] := GetBit(11);
  FModules[2, 8] := GetBit(12);
  FModules[1, 8] := GetBit(13);
  FModules[0, 8] := GetBit(14);

  // Second copy: top-right and bottom-left
  // Top-right horizontal in row 8: bits 0-7 from right to left
  FModules[8, FSize - 1] := GetBit(0);
  FModules[8, FSize - 2] := GetBit(1);
  FModules[8, FSize - 3] := GetBit(2);
  FModules[8, FSize - 4] := GetBit(3);
  FModules[8, FSize - 5] := GetBit(4);
  FModules[8, FSize - 6] := GetBit(5);
  FModules[8, FSize - 7] := GetBit(6);
  FModules[8, FSize - 8] := GetBit(7);

  // Bottom-left vertical in column 8: bits 8-14 from top to bottom
  FModules[FSize - 7, 8] := GetBit(8);
  FModules[FSize - 6, 8] := GetBit(9);
  FModules[FSize - 5, 8] := GetBit(10);
  FModules[FSize - 4, 8] := GetBit(11);
  FModules[FSize - 3, 8] := GetBit(12);
  FModules[FSize - 2, 8] := GetBit(13);
  FModules[FSize - 1, 8] := GetBit(14);
  // Note: (FSize-8, 8) is the "dark module", always dark, set in ReserveFormatArea
end;

function TQRMatrix.GetModule(Row, Col: Integer): TQRModule;
begin
  if (Row >= 0) and (Row < FSize) and (Col >= 0) and (Col < FSize) then
    Result := FModules[Row, Col]
  else
    Result := qmLight;
end;

procedure TQRMatrix.SetModule(Row, Col: Integer; Value: TQRModule);
begin
  if (Row >= 0) and (Row < FSize) and (Col >= 0) and (Col < FSize) then
    FModules[Row, Col] := Value;
end;

function TQRMatrix.Clone: TQRMatrix;
var
  I, J: Integer;
begin
  Result := TQRMatrix.Create(FSize);
  for I := 0 to FSize - 1 do
    for J := 0 to FSize - 1 do begin
      Result.FModules[I, J] := FModules[I, J];
      Result.FReserved[I, J] := FReserved[I, J];
    end;
end;

{ TQRMask }

class function TQRMask.EvaluateMask(Row, Col, Pattern: Integer): Boolean;
begin
  case Pattern of
    0: Result := ((Row + Col) mod 2) = 0;
    1: Result := (Row mod 2) = 0;
    2: Result := (Col mod 3) = 0;
    3: Result := ((Row + Col) mod 3) = 0;
    4: Result := ((Row div 2 + Col div 3) mod 2) = 0;
    5: Result := ((Row * Col) mod 2 + (Row * Col) mod 3) = 0;
    6: Result := (((Row * Col) mod 2 + (Row * Col) mod 3) mod 2) = 0;
    7: Result := (((Row + Col) mod 2 + (Row * Col) mod 3) mod 2) = 0;
  else
    Result := False;
  end;
end;

class function TQRMask.CalculatePenalty(Matrix: TQRMatrix): Integer;
var
  Row, Col: Integer;
  Penalty: Integer;
  RunLength: Integer;
  PrevColor: TQRModule;
  DarkCount, TotalCount: Integer;
  PercentDark: Integer;

  function IsDark(R, C: Integer): Boolean; begin
    Result := Matrix.GetModule(R, C) = qmDark;
  end;

begin
  Penalty := 0;

  // Rule 1: Consecutive modules in row/column
  for Row := 0 to Matrix.Size - 1 do begin
    RunLength := 1;
    PrevColor := Matrix.GetModule(Row, 0);
    for Col := 1 to Matrix.Size - 1 do
    begin
      if Matrix.GetModule(Row, Col) = PrevColor then
        Inc(RunLength)
      else
      begin
        if RunLength >= 5 then
          Inc(Penalty, 3 + RunLength - 5);
        RunLength := 1;
        PrevColor := Matrix.GetModule(Row, Col);
      end;
    end;
    if RunLength >= 5 then
      Inc(Penalty, 3 + RunLength - 5);
  end;

  for Col := 0 to Matrix.Size - 1 do begin
    RunLength := 1;
    PrevColor := Matrix.GetModule(0, Col);
    for Row := 1 to Matrix.Size - 1 do begin
      if Matrix.GetModule(Row, Col) = PrevColor then
        Inc(RunLength)
      else
      begin
        if RunLength >= 5 then
          Inc(Penalty, 3 + RunLength - 5);
        RunLength := 1;
        PrevColor := Matrix.GetModule(Row, Col);
      end;
    end;
    if RunLength >= 5 then
      Inc(Penalty, 3 + RunLength - 5);
  end;

  // Rule 2: 2x2 blocks of same color
  for Row := 0 to Matrix.Size - 2 do
    for Col := 0 to Matrix.Size - 2 do begin
      if (IsDark(Row, Col) = IsDark(Row, Col + 1)) and
         (IsDark(Row, Col) = IsDark(Row + 1, Col)) and
         (IsDark(Row, Col) = IsDark(Row + 1, Col + 1)) then
        Inc(Penalty, 3);
    end;

  // Rule 3: Finder-like patterns
  for Row := 0 to Matrix.Size - 1 do
    for Col := 0 to Matrix.Size - 11 do begin
      if IsDark(Row, Col) and not IsDark(Row, Col + 1) and
         IsDark(Row, Col + 2) and IsDark(Row, Col + 3) and
         IsDark(Row, Col + 4) and not IsDark(Row, Col + 5) and
         IsDark(Row, Col + 6) and not IsDark(Row, Col + 7) and
         not IsDark(Row, Col + 8) and not IsDark(Row, Col + 9) and
         not IsDark(Row, Col + 10) then
        Inc(Penalty, 40);

      if not IsDark(Row, Col) and not IsDark(Row, Col + 1) and
         not IsDark(Row, Col + 2) and not IsDark(Row, Col + 3) and
         IsDark(Row, Col + 4) and not IsDark(Row, Col + 5) and
         IsDark(Row, Col + 6) and IsDark(Row, Col + 7) and
         IsDark(Row, Col + 8) and not IsDark(Row, Col + 9) and
         IsDark(Row, Col + 10) then
        Inc(Penalty, 40);
    end;

  for Col := 0 to Matrix.Size - 1 do
    for Row := 0 to Matrix.Size - 11 do begin
      if IsDark(Row, Col) and not IsDark(Row + 1, Col) and
         IsDark(Row + 2, Col) and IsDark(Row + 3, Col) and
         IsDark(Row + 4, Col) and not IsDark(Row + 5, Col) and
         IsDark(Row + 6, Col) and not IsDark(Row + 7, Col) and
         not IsDark(Row + 8, Col) and not IsDark(Row + 9, Col) and
         not IsDark(Row + 10, Col) then
        Inc(Penalty, 40);

      if not IsDark(Row, Col) and not IsDark(Row + 1, Col) and
         not IsDark(Row + 2, Col) and not IsDark(Row + 3, Col) and
         IsDark(Row + 4, Col) and not IsDark(Row + 5, Col) and
         IsDark(Row + 6, Col) and IsDark(Row + 7, Col) and
         IsDark(Row + 8, Col) and not IsDark(Row + 9, Col) and
         IsDark(Row + 10, Col) then
        Inc(Penalty, 40);
    end;

  // Rule 4: Dark/light balance
  DarkCount := 0;
  TotalCount := Matrix.Size * Matrix.Size;
  for Row := 0 to Matrix.Size - 1 do
    for Col := 0 to Matrix.Size - 1 do
      if IsDark(Row, Col) then
        Inc(DarkCount);

  PercentDark := (DarkCount * 100) div TotalCount;
  Inc(Penalty, Abs(PercentDark - 50) div 5 * 10);

  Result := Penalty;
end;

class function TQRMask.FindBestMask(Matrix: TQRMatrix; ECLevel: Integer): Integer;
var
  MaskPattern: Integer;
  TestMatrix: TQRMatrix;
  Penalty, MinPenalty: Integer;
begin
  Result := 0;
  MinPenalty := MaxInt;

  for MaskPattern := 0 to 7 do begin
    TestMatrix := Matrix.Clone;
    try
      TestMatrix.ApplyMask(MaskPattern);
      TestMatrix.PlaceFormatInfo(ECLevel, MaskPattern);
      Penalty := CalculatePenalty(TestMatrix);

      if Penalty < MinPenalty then
      begin
        MinPenalty := Penalty;
        Result := MaskPattern;
      end;
    finally
      TestMatrix.Free;
    end;
  end;
end;

{ TQRCode }

constructor TQRCode.Create;
begin
  FMatrix := nil;
  FVersion := 0;
end;

destructor TQRCode.Destroy;
begin
  FMatrix.Free;
  inherited;
end;

procedure TQRCode.Generate(const Data: string);
var
  DataBytes: TBytes;
  VersionInfo: TQRVersionInfo;
  EncodedData: TByteArray;
  ECCodewords: TByteArray;
  FinalData: TByteArray;
  BestMask: Integer;
  I, J: Integer;
  BlockSize, ECPerBlock: Integer;
  Blocks: array of TByteArray;
  ECBlocks: array of TByteArray;
  DataIndex, ECIndex: Integer;
begin
  // Convert data to bytes to determine length
  DataBytes := TEncoding.UTF8.GetBytes(Data);

  // Select appropriate version
  FVersion := TQRDataEncoder.SelectVersion(Length(DataBytes));
  VersionInfo := TQRDataEncoder.GetVersionInfo(FVersion);

  // Encode data
  EncodedData := TQRDataEncoder.Encode(Data, FVersion);

  // Handle multiple blocks if needed
  if VersionInfo.BlockCount = 1 then begin
    // Single block - simple case
    ECCodewords := TReedSolomon.GenerateECCodewords(EncodedData, VersionInfo.ECCodewords);

    // Combine data and EC codewords
    SetLength(FinalData, Length(EncodedData) + Length(ECCodewords));
    for I := 0 to High(EncodedData) do
      FinalData[I] := EncodedData[I];
    for I := 0 to High(ECCodewords) do
      FinalData[Length(EncodedData) + I] := ECCodewords[I];
  end
  else
  begin
    // Multiple blocks - interleave (blocks may have different sizes)
    BlockSize := Length(EncodedData) div VersionInfo.BlockCount;
    var NumLongBlocks := Length(EncodedData) mod VersionInfo.BlockCount;
    var NumShortBlocks := VersionInfo.BlockCount - NumLongBlocks;
    ECPerBlock := VersionInfo.ECCodewords;

    SetLength(Blocks, VersionInfo.BlockCount);
    SetLength(ECBlocks, VersionInfo.BlockCount);

    // Split data into blocks (short blocks first, then long blocks)
    DataIndex := 0;
    for I := 0 to VersionInfo.BlockCount - 1 do begin
      var ThisBlockSize := BlockSize;
      if I >= NumShortBlocks then
        Inc(ThisBlockSize);  // Long block has one extra byte

      SetLength(Blocks[I], ThisBlockSize);
      for J := 0 to ThisBlockSize - 1 do begin
        Blocks[I][J] := EncodedData[DataIndex];
        Inc(DataIndex);
      end;
      ECBlocks[I] := TReedSolomon.GenerateECCodewords(Blocks[I], ECPerBlock);
    end;

    // Interleave data codewords
    SetLength(FinalData, Length(EncodedData) + VersionInfo.BlockCount * ECPerBlock);
    DataIndex := 0;

    // First interleave common bytes (position 0 to BlockSize-1)
    for J := 0 to BlockSize - 1 do
      for I := 0 to VersionInfo.BlockCount - 1 do begin
        FinalData[DataIndex] := Blocks[I][J];
        Inc(DataIndex);
      end;

    // Then interleave extra bytes from long blocks only
    for I := NumShortBlocks to VersionInfo.BlockCount - 1 do begin
      FinalData[DataIndex] := Blocks[I][BlockSize];
      Inc(DataIndex);
    end;

    // Interleave EC codewords
    ECIndex := Length(EncodedData);
    for J := 0 to ECPerBlock - 1 do
      for I := 0 to VersionInfo.BlockCount - 1 do begin
        FinalData[ECIndex] := ECBlocks[I][J];
        Inc(ECIndex);
      end;
  end;

  // Create and initialize matrix
  FMatrix.Free;
  FMatrix := TQRMatrix.Create(VersionInfo.Size);
  FMatrix.Initialize(VersionInfo);

  // Place data
  FMatrix.PlaceData(FinalData);

  // Find best mask and apply
  BestMask := TQRMask.FindBestMask(FMatrix, EC_LEVEL_M);
  FMatrix.ApplyMask(BestMask);
  FMatrix.PlaceFormatInfo(EC_LEVEL_M, BestMask);
end;

function TQRCode.RenderToString: string;
var
  SB: TStringBuilder;
  Row, Col: Integer;
  QuietZone: Integer;
const
  // ANSI escape codes for background colors
  ESC = #27;
  BG_BLACK = '[40m';   // Dark module
  BG_WHITE = '[47m';   // Light module
  RESET = '[0m';
  MODULE = '  ';       // Two spaces for square aspect ratio
begin
  QuietZone := 2;
  SB := TStringBuilder.Create;
  try
    // Top quiet zone
    for Row := 0 to QuietZone - 1 do begin
      SB.Append(ESC + BG_WHITE);
      for Col := 0 to (FMatrix.Size + QuietZone * 2) - 1 do
        SB.Append(MODULE);
      SB.Append(ESC + RESET);
      SB.AppendLine;
    end;

    // QR code with side quiet zones
    for Row := 0 to FMatrix.Size - 1 do begin
      // Left quiet zone
      SB.Append(ESC + BG_WHITE);
      for Col := 0 to QuietZone - 1 do
        SB.Append(MODULE);

      // QR modules
      for Col := 0 to FMatrix.Size - 1 do
      begin
        if FMatrix.GetModule(Row, Col) = qmDark then
          SB.Append(ESC + BG_BLACK + MODULE)
        else
          SB.Append(ESC + BG_WHITE + MODULE);
      end;

      // Right quiet zone
      SB.Append(ESC + BG_WHITE);
      for Col := 0 to QuietZone - 1 do
        SB.Append(MODULE);
      SB.Append(ESC + RESET);
      SB.AppendLine;
    end;

    // Bottom quiet zone
    for Row := 0 to QuietZone - 1 do begin
      SB.Append(ESC + BG_WHITE);
      for Col := 0 to (FMatrix.Size + QuietZone * 2) - 1 do
        SB.Append(MODULE);
      SB.Append(ESC + RESET);
      SB.AppendLine;
    end;

    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

procedure TQRCode.RenderToConsole;
begin
  Writeln(RenderToString);
end;

{$IFDEF MSWINDOWS}
procedure TQRCode.SaveToPng(const FileName: string; ModuleSize: Integer);
var
  Png: TPngImage;
  Bmp: Vcl.Graphics.TBitmap;
begin
  Bmp := Self.ToBitmap(ModuleSize);
  try
    Png := TPngImage.Create;
    try
      Png.Assign(Bmp);
      Png.SaveToFile(FileName);
    finally
      Png.Free;
    end;
  finally
    Bmp.Free;
  end;
end;

function TQRCode.ToBitmap(ModuleSize: Integer): Vcl.Graphics.TBitmap;
var
  Bytes: TBytes;
  Row, W, X: Integer;
  P: PByteArray;
begin
  Bytes := Self.ToRGBA(ModuleSize);
  W := (FMatrix.Size + 8) * ModuleSize;

  Result := Vcl.Graphics.TBitmap.Create;
  Result.SetSize(W, W);
  Result.PixelFormat := pf32bit;

  for Row := 0 to W - 1 do begin
    P := Result.ScanLine[Row];
    for X := 0 to W - 1 do begin
      P[X * 4 + 0] := Bytes[(Row * W + X) * 4 + 2]; // B
      P[X * 4 + 1] := Bytes[(Row * W + X) * 4 + 1]; // G
      P[X * 4 + 2] := Bytes[(Row * W + X) * 4 + 0]; // R
      P[X * 4 + 3] := Bytes[(Row * W + X) * 4 + 3]; // A
    end;
  end;
end;

function TQRCode.ToPngStream(ModuleSize: Integer): TMemoryStream;
var
  Bmp: Vcl.Graphics.TBitmap;
  Png: TPngImage;
begin
  Result := TMemoryStream.Create;
  Bmp := Self.ToBitmap(ModuleSize);
  try
    Png := TPngImage.Create;
    try
      Png.Assign(Bmp);
      Png.SaveToStream(Result);
      Result.Position := 0;
    finally
      Png.Free;
    end;
  finally
    Bmp.Free;
  end;
end;
{$ENDIF}

{$IF DEFINED(IOS) OR DEFINED(MACOS) OR DEFINED(ANDROID)}
function TQRCode.ToBitmap(ModuleSize: Integer): FMX.Graphics.TBitmap;
var
  Bytes: TBytes;
  Data: TBitmapData;
  W: Integer;
begin
  Bytes := Self.ToRGBA(ModuleSize);
  W := (FMatrix.Size + 8) * ModuleSize;

  Result := FMX.Graphics.TBitmap.Create(W, W);
  if Result.Map(TMapAccess.Write, Data) then
  try
    Move(Bytes[0], Data.Data^, Length(Bytes));
  finally
    Result.Unmap(Data);
  end;
end;
{$ENDIF}

{$IFDEF ANDROID}
function TQRCode.ToJBitmap(ModuleSize: Integer): JBitmap;
var
  Bytes: TBytes;
  W, I: Integer;
  JBytes: TJavaArray<Byte>;
  JBuffer: JByteBuffer;
begin
  Bytes := Self.ToRGBA(ModuleSize);
  W := (FMatrix.Size + 8) * ModuleSize;

  JBytes := TJavaArray<Byte>.Create(Length(Bytes));
  for I := 0 to Length(Bytes) - 1 do
    JBytes[I] := Bytes[I];

  Result := TJBitmap.JavaClass.createBitmap(W, W, TJBitmap_Config.JavaClass.ARGB_8888);
  JBuffer := TJByteBuffer.JavaClass.wrap(JBytes);
  Result.copyPixelsFromBuffer(JBuffer);
end;
{$ENDIF}

function TQRCode.ToRGBA(ModuleSize: Integer): TBytes;
var
  Row, Col, X, Y, Idx: Integer;
  QuietZone, TotalSize, W: Integer;
  IsDark: Boolean;
begin
  if FMatrix = nil then
    raise Exception.Create('No QR code generated. Call Generate first.');

  QuietZone := 4;
  TotalSize := FMatrix.Size + QuietZone * 2;
  W := TotalSize * ModuleSize;
  SetLength(Result, W * W * 4);

  for Row := 0 to TotalSize - 1 do
    for Col := 0 to TotalSize - 1 do begin
      // Check if in QR area or quiet zone
      if (Row >= QuietZone) and (Row < QuietZone + FMatrix.Size) and
         (Col >= QuietZone) and (Col < QuietZone + FMatrix.Size) then
        IsDark := FMatrix.GetModule(Row - QuietZone, Col - QuietZone) = qmDark
      else
        IsDark := False;

      // Fill scaled pixels
      for Y := 0 to ModuleSize - 1 do
        for X := 0 to ModuleSize - 1 do begin
          Idx := ((Row * ModuleSize + Y) * W + Col * ModuleSize + X) * 4;
          if IsDark then begin
            Result[Idx] := 0;      // R
            Result[Idx+1] := 0;    // G
            Result[Idx+2] := 0;    // B
          end else begin
            Result[Idx] := 255;    // R
            Result[Idx+1] := 255;  // G
            Result[Idx+2] := 255;  // B
          end;
          Result[Idx+3] := 255;    // A
        end;
    end;
end;

{ TReedSolomon - Decoding methods }

class function TReedSolomon.CalculateSyndromes(const Received: TByteArray; ECCount: Integer): TIntArray;
var
  I, J: Integer;
  Sum: Integer;
begin
  SetLength(Result, ECCount);
  for I := 0 to ECCount - 1 do
  begin
    Sum := 0;
    for J := 0 to High(Received) do
      Sum := TGaloisField.Add(Sum, TGaloisField.Multiply(Received[J], TGaloisField.Exp(I * J)));
    Result[I] := Sum;
  end;
end;

class function TReedSolomon.HasErrors(const Syndromes: TIntArray): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to High(Syndromes) do
    if Syndromes[I] <> 0 then
      Exit(True);
end;

class function TReedSolomon.CorrectErrors(var Data: TByteArray; ECCount: Integer): Boolean;
var
  Syndromes: TIntArray;
begin
  // Calculate syndromes
  Syndromes := CalculateSyndromes(Data, ECCount);

  // If no errors, return success
  if not HasErrors(Syndromes) then
    Exit(True);

  // For now, just detect errors but don't correct
  // Full Berlekamp-Massey implementation would go here
  // Most QR codes from our own generator won't have errors
  Result := False;
end;

{ TQRImageProcessor }

constructor TQRImageProcessor.Create;
begin
  FWidth := 0;
  FHeight := 0;
  FFinderCount := 0;
  FCandidateCount := 0;
  SetLength(FCandidates, 100);  // Max candidates
  FModuleSize := 0;
  FGridSize := 0;
end;

procedure TQRImageProcessor.LoadRGBA(const Data: TBytes; W, H: Integer);
begin
  FWidth := W;
  FHeight := H;
  SetLength(FGrayscale, W * H);
  SetLength(FBinary, W * H);
end;

procedure TQRImageProcessor.Binarize;
var
  X, Y: Integer;
  Threshold: Integer;
  MinVal, MaxVal: Byte;
  I: Integer;
begin
  // Find min/max values in image
  MinVal := 255;
  MaxVal := 0;
  for I := 0 to FWidth * FHeight - 1 do
  begin
    if FGrayscale[I] < MinVal then MinVal := FGrayscale[I];
    if FGrayscale[I] > MaxVal then MaxVal := FGrayscale[I];
  end;

  // Use midpoint as threshold for clean images
  // For noisy images, Otsu's method would be better
  Threshold := (MinVal + MaxVal) div 2;

  // Binarize: dark if below threshold
  for Y := 0 to FHeight - 1 do
    for X := 0 to FWidth - 1 do
      FBinary[Y * FWidth + X] := FGrayscale[Y * FWidth + X] < Threshold;
end;

function TQRImageProcessor.GetPixel(X, Y: Integer): Boolean;
begin
  if (X >= 0) and (X < FWidth) and (Y >= 0) and (Y < FHeight) then
    Result := FBinary[Y * FWidth + X]
  else
    Result := False;
end;

function TQRImageProcessor.CheckRatio(const Counts: array of Integer): Boolean;
var
  TotalFinderSize: Integer;
  ModuleSize: Double;
  MaxVariance: Double;
begin
  // Check for 1:1:3:1:1 ratio
  TotalFinderSize := Counts[0] + Counts[1] + Counts[2] + Counts[3] + Counts[4];
  if TotalFinderSize < 7 then
    Exit(False);

  ModuleSize := TotalFinderSize / 7.0;
  MaxVariance := ModuleSize * 0.5;

  Result := (Abs(Counts[0] - ModuleSize) < MaxVariance) and
            (Abs(Counts[1] - ModuleSize) < MaxVariance) and
            (Abs(Counts[2] - 3 * ModuleSize) < 3 * MaxVariance) and
            (Abs(Counts[3] - ModuleSize) < MaxVariance) and
            (Abs(Counts[4] - ModuleSize) < MaxVariance);
end;

function TQRImageProcessor.CrossCheckVertical(CenterX, CenterY: Integer; MaxCount: Integer): Double;
var
  StateCount: array[0..4] of Integer;
  Y: Integer;
begin
  FillChar(StateCount, SizeOf(StateCount), 0);

  // Count up from center
  Y := CenterY;
  while (Y >= 0) and GetPixel(CenterX, Y) do
  begin
    Inc(StateCount[2]);
    Dec(Y);
  end;
  if Y < 0 then Exit(-1);

  while (Y >= 0) and not GetPixel(CenterX, Y) do
  begin
    Inc(StateCount[1]);
    Dec(Y);
  end;
  if Y < 0 then Exit(-1);

  while (Y >= 0) and GetPixel(CenterX, Y) do
  begin
    Inc(StateCount[0]);
    Dec(Y);
  end;

  // Count down from center
  Y := CenterY + 1;
  while (Y < FHeight) and GetPixel(CenterX, Y) do
  begin
    Inc(StateCount[2]);
    Inc(Y);
  end;
  if Y >= FHeight then Exit(-1);

  while (Y < FHeight) and not GetPixel(CenterX, Y) do
  begin
    Inc(StateCount[3]);
    Inc(Y);
  end;
  if Y >= FHeight then Exit(-1);

  while (Y < FHeight) and GetPixel(CenterX, Y) do
  begin
    Inc(StateCount[4]);
    Inc(Y);
  end;

  if CheckRatio(StateCount) then
    Result := (Y - 1) - StateCount[4] - StateCount[3] - StateCount[2] / 2.0
  else
    Result := -1;
end;

function TQRImageProcessor.CrossCheckHorizontal(CenterX, CenterY: Integer; MaxCount: Integer): Double;
var
  StateCount: array[0..4] of Integer;
  X: Integer;
begin
  FillChar(StateCount, SizeOf(StateCount), 0);

  // Count left from center
  X := CenterX;
  while (X >= 0) and GetPixel(X, CenterY) do
  begin
    Inc(StateCount[2]);
    Dec(X);
  end;
  if X < 0 then Exit(-1);

  while (X >= 0) and not GetPixel(X, CenterY) do
  begin
    Inc(StateCount[1]);
    Dec(X);
  end;
  if X < 0 then Exit(-1);

  while (X >= 0) and GetPixel(X, CenterY) do
  begin
    Inc(StateCount[0]);
    Dec(X);
  end;

  // Count right from center
  X := CenterX + 1;
  while (X < FWidth) and GetPixel(X, CenterY) do
  begin
    Inc(StateCount[2]);
    Inc(X);
  end;
  if X >= FWidth then Exit(-1);

  while (X < FWidth) and not GetPixel(X, CenterY) do
  begin
    Inc(StateCount[3]);
    Inc(X);
  end;
  if X >= FWidth then Exit(-1);

  while (X < FWidth) and GetPixel(X, CenterY) do
  begin
    Inc(StateCount[4]);
    Inc(X);
  end;

  if CheckRatio(StateCount) then
    Result := (X - 1) - StateCount[4] - StateCount[3] - StateCount[2] / 2.0
  else
    Result := -1;
end;

procedure TQRImageProcessor.HandlePossibleCenter(const StateCount: array of Integer; Row, Col: Integer);
var
  CenterX, CenterY: Double;
  TotalWidth: Integer;
  I: Integer;
  Dist: Double;
begin
  TotalWidth := StateCount[0] + StateCount[1] + StateCount[2] + StateCount[3] + StateCount[4];
  CenterX := Col - StateCount[4] - StateCount[3] - StateCount[2] / 2.0;
  CenterY := CrossCheckVertical(Round(CenterX), Row, StateCount[2]);

  if CenterY >= 0 then
  begin
    CenterX := CrossCheckHorizontal(Round(CenterX), Round(CenterY), StateCount[2]);
    if CenterX >= 0 then
    begin
      // Check if we already have a candidate near this location
      for I := 0 to FCandidateCount - 1 do
      begin
        Dist := Sqrt(Sqr(FCandidates[I].CenterX - CenterX) + Sqr(FCandidates[I].CenterY - CenterY));
        if Dist < TotalWidth / 2.0 then
          Exit;  // Too close to existing candidate
      end;

      // Add new candidate
      if FCandidateCount < Length(FCandidates) then
      begin
        FCandidates[FCandidateCount].CenterX := CenterX;
        FCandidates[FCandidateCount].CenterY := CenterY;
        FCandidates[FCandidateCount].ModuleSize := TotalWidth / 7.0;
        Inc(FCandidateCount);
      end;
    end;
  end;
end;

procedure TQRImageProcessor.FindFinderPatterns;
var
  Row, Col: Integer;
  StateCount: array[0..4] of Integer;
  CurrentState: Integer;
begin
  FCandidateCount := 0;

  for Row := 0 to FHeight - 1 do
  begin
    FillChar(StateCount, SizeOf(StateCount), 0);
    CurrentState := 0;

    for Col := 0 to FWidth - 1 do
    begin
      if GetPixel(Col, Row) then  // Dark pixel
      begin
        if (CurrentState and 1) = 1 then  // Was in light state
          Inc(CurrentState);
        Inc(StateCount[CurrentState]);
      end
      else  // Light pixel
      begin
        if (CurrentState and 1) = 0 then  // Was in dark state
        begin
          if CurrentState = 4 then
          begin
            // Check if we found a finder pattern
            if CheckRatio(StateCount) then
              HandlePossibleCenter(StateCount, Row, Col);

            // Shift counts
            StateCount[0] := StateCount[2];
            StateCount[1] := StateCount[3];
            StateCount[2] := StateCount[4];
            StateCount[3] := 1;
            StateCount[4] := 0;
            CurrentState := 3;
          end
          else
          begin
            Inc(CurrentState);
            Inc(StateCount[CurrentState]);
          end;
        end
        else
          Inc(StateCount[CurrentState]);
      end;
    end;

    // Check at end of row
    if (CurrentState = 4) and CheckRatio(StateCount) then
      HandlePossibleCenter(StateCount, Row, FWidth);
  end;
end;

procedure TQRImageProcessor.SelectBestFinders;
var
  I, J, K: Integer;
  BestI, BestJ, BestK: Integer;
  BestScore, Score: Double;
  D1, D2, D3: Double;
  AvgModSize, ModSizeVariance: Double;
  DiagRatio: Double;
begin
  FFinderCount := 0;

  if FCandidateCount < 3 then
    Exit;

  // If exactly 3 candidates, just use them
  if FCandidateCount = 3 then
  begin
    for I := 0 to 2 do
      FFinders[I] := FCandidates[I];
    FFinderCount := 3;
    Exit;
  end;

  // Find the best triplet: similar module sizes and forms right angle triangle
  BestScore := -1;
  BestI := 0;
  BestJ := 1;
  BestK := 2;

  for I := 0 to FCandidateCount - 3 do
    for J := I + 1 to FCandidateCount - 2 do
      for K := J + 1 to FCandidateCount - 1 do
      begin
        // Calculate distances
        D1 := Sqrt(Sqr(FCandidates[I].CenterX - FCandidates[J].CenterX) +
                   Sqr(FCandidates[I].CenterY - FCandidates[J].CenterY));
        D2 := Sqrt(Sqr(FCandidates[I].CenterX - FCandidates[K].CenterX) +
                   Sqr(FCandidates[I].CenterY - FCandidates[K].CenterY));
        D3 := Sqrt(Sqr(FCandidates[J].CenterX - FCandidates[K].CenterX) +
                   Sqr(FCandidates[J].CenterY - FCandidates[K].CenterY));

        // Check module size consistency
        AvgModSize := (FCandidates[I].ModuleSize + FCandidates[J].ModuleSize +
                       FCandidates[K].ModuleSize) / 3.0;
        ModSizeVariance := (Abs(FCandidates[I].ModuleSize - AvgModSize) +
                            Abs(FCandidates[J].ModuleSize - AvgModSize) +
                            Abs(FCandidates[K].ModuleSize - AvgModSize)) / AvgModSize;

        // Skip if module sizes are too different
        if ModSizeVariance > 0.5 then
          Continue;

        // For a valid QR code, two sides should be equal (the non-diagonal sides)
        // and the diagonal should be sqrt(2) times longer
        if (D1 <= D2) and (D2 <= D3) then
          DiagRatio := D3 / ((D1 + D2) / 2)
        else if (D1 <= D3) and (D3 <= D2) then
          DiagRatio := D2 / ((D1 + D3) / 2)
        else if (D2 <= D1) and (D1 <= D3) then
          DiagRatio := D3 / ((D2 + D1) / 2)
        else if (D2 <= D3) and (D3 <= D1) then
          DiagRatio := D1 / ((D2 + D3) / 2)
        else if (D3 <= D1) and (D1 <= D2) then
          DiagRatio := D2 / ((D3 + D1) / 2)
        else
          DiagRatio := D1 / ((D3 + D2) / 2);

        // Diagonal should be about sqrt(2) = 1.414 times the other sides
        if (DiagRatio < 1.2) or (DiagRatio > 1.7) then
          Continue;

        // Score based on module size consistency and diagonal ratio closeness to sqrt(2)
        Score := 1.0 / (ModSizeVariance + 0.1) + 1.0 / (Abs(DiagRatio - 1.414) + 0.1);

        if Score > BestScore then
        begin
          BestScore := Score;
          BestI := I;
          BestJ := J;
          BestK := K;
        end;
      end;

  if BestScore > 0 then
  begin
    FFinders[0] := FCandidates[BestI];
    FFinders[1] := FCandidates[BestJ];
    FFinders[2] := FCandidates[BestK];
    FFinderCount := 3;
  end;
end;

procedure TQRImageProcessor.OrderFinderPatterns;
var
  Dist01, Dist02, Dist12: Double;
  Temp: TFinderPattern;
begin
  if FFinderCount < 3 then
    Exit;

  // Calculate distances between finder patterns
  Dist01 := Sqrt(Sqr(FFinders[0].CenterX - FFinders[1].CenterX) +
                 Sqr(FFinders[0].CenterY - FFinders[1].CenterY));
  Dist02 := Sqrt(Sqr(FFinders[0].CenterX - FFinders[2].CenterX) +
                 Sqr(FFinders[0].CenterY - FFinders[2].CenterY));
  Dist12 := Sqrt(Sqr(FFinders[1].CenterX - FFinders[2].CenterX) +
                 Sqr(FFinders[1].CenterY - FFinders[2].CenterY));

  // The longest distance is the diagonal (top-left to bottom-right equivalent)
  // The other two connect to top-left
  if (Dist01 >= Dist02) and (Dist01 >= Dist12) then
  begin
    // 2 is top-left
    FTopLeft := 2;
    if FFinders[0].CenterY < FFinders[1].CenterY then
    begin
      FTopRight := 0;
      FBottomLeft := 1;
    end
    else
    begin
      FTopRight := 1;
      FBottomLeft := 0;
    end;
  end
  else if (Dist02 >= Dist01) and (Dist02 >= Dist12) then
  begin
    // 1 is top-left
    FTopLeft := 1;
    if FFinders[0].CenterY < FFinders[2].CenterY then
    begin
      FTopRight := 0;
      FBottomLeft := 2;
    end
    else
    begin
      FTopRight := 2;
      FBottomLeft := 0;
    end;
  end
  else
  begin
    // 0 is top-left
    FTopLeft := 0;
    if FFinders[1].CenterY < FFinders[2].CenterY then
    begin
      FTopRight := 1;
      FBottomLeft := 2;
    end
    else
    begin
      FTopRight := 2;
      FBottomLeft := 1;
    end;
  end;

  // Swap to make top-left always index 0, top-right index 1, bottom-left index 2
  if FTopLeft <> 0 then
  begin
    Temp := FFinders[0];
    FFinders[0] := FFinders[FTopLeft];
    FFinders[FTopLeft] := Temp;
    if FTopRight = 0 then FTopRight := FTopLeft
    else if FBottomLeft = 0 then FBottomLeft := FTopLeft;
    FTopLeft := 0;
  end;
end;

procedure TQRImageProcessor.CalculateGridParameters;
var
  DistTopLeftToTopRight, DistTopLeftToBottomLeft: Double;
begin
  if FFinderCount < 3 then
    raise Exception.Create('Could not find 3 finder patterns');

  // Calculate module size as average of the three finders
  FModuleSize := (FFinders[0].ModuleSize + FFinders[1].ModuleSize + FFinders[2].ModuleSize) / 3.0;

  // Calculate distances
  DistTopLeftToTopRight := Sqrt(
    Sqr(FFinders[FTopRight].CenterX - FFinders[FTopLeft].CenterX) +
    Sqr(FFinders[FTopRight].CenterY - FFinders[FTopLeft].CenterY));

  DistTopLeftToBottomLeft := Sqrt(
    Sqr(FFinders[FBottomLeft].CenterX - FFinders[FTopLeft].CenterX) +
    Sqr(FFinders[FBottomLeft].CenterY - FFinders[FTopLeft].CenterY));

  // Distance between finder centers = (size - 7) modules
  // Size = distance / moduleSize + 7
  FGridSize := Round((DistTopLeftToTopRight + DistTopLeftToBottomLeft) / (2 * FModuleSize)) + 7;

  // Grid size must be 21 + 4*n (versions 1-10: 21, 25, 29, 33, 37, 41, 45, 49, 53, 57)
  if ((FGridSize - 21) mod 4) <> 0 then
    FGridSize := ((FGridSize - 21 + 2) div 4) * 4 + 21;

  if FGridSize < 21 then FGridSize := 21;
  if FGridSize > 57 then FGridSize := 57;
end;

function TQRImageProcessor.SampleModule(Row, Col: Integer): Boolean;
var
  TopLeftX, TopLeftY: Double;
  SampleX, SampleY: Integer;
begin
  // Calculate the top-left corner of the QR code grid
  // Finder center is at module (3.5, 3.5)
  TopLeftX := FFinders[FTopLeft].CenterX - 3.5 * FModuleSize;
  TopLeftY := FFinders[FTopLeft].CenterY - 3.5 * FModuleSize;

  // Sample at center of module
  SampleX := Round(TopLeftX + (Col + 0.5) * FModuleSize);
  SampleY := Round(TopLeftY + (Row + 0.5) * FModuleSize);

  Result := GetPixel(SampleX, SampleY);
end;

procedure TQRImageProcessor.Process(const RGBA: TBytes; Width, Height: Integer);
var
  I: Integer;
  Idx: Integer;
  R, G, B: Byte;
begin
  LoadRGBA(RGBA, Width, Height);

  // Convert RGBA to grayscale
  for I := 0 to FWidth * FHeight - 1 do
  begin
    Idx := I * 4;
    R := RGBA[Idx];
    G := RGBA[Idx + 1];
    B := RGBA[Idx + 2];
    FGrayscale[I] := (R * 77 + G * 150 + B * 29) shr 8;
  end;

  Binarize;
  FindFinderPatterns;
  SelectBestFinders;

  if FFinderCount < 3 then
    raise Exception.CreateFmt('Could not detect 3 finder patterns in image (found %d)', [FFinderCount]);

  OrderFinderPatterns;
  CalculateGridParameters;
end;

function TQRImageProcessor.ExtractMatrix: TQRMatrix;
var
  Row, Col: Integer;
begin
  Result := TQRMatrix.Create(FGridSize);

  for Row := 0 to FGridSize - 1 do
    for Col := 0 to FGridSize - 1 do
    begin
      if SampleModule(Row, Col) then
        Result.SetModule(Row, Col, qmDark)
      else
        Result.SetModule(Row, Col, qmLight);
    end;
end;

function TQRImageProcessor.GetVersion: Integer;
begin
  Result := (FGridSize - 17) div 4;
end;

{ TQRDataDecoder }

class function TQRDataDecoder.ExtractFormatInfo(Matrix: TQRMatrix): Integer;
var
  FormatBits: Integer;
  I: Integer;
  Bit: Integer;
const
  FORMAT_MASK = $5412;  // XOR mask for format info
begin
  // Read format info from around top-left finder
  FormatBits := 0;

  // Bits 0-5 from row 8, columns 0-5
  for I := 0 to 5 do
  begin
    if Matrix.GetModule(8, I) = qmDark then
      Bit := 1
    else
      Bit := 0;
    FormatBits := FormatBits or (Bit shl I);
  end;

  // Bit 6 from row 8, column 7 (skip timing pattern at col 6)
  if Matrix.GetModule(8, 7) = qmDark then
    FormatBits := FormatBits or (1 shl 6);

  // Bit 7 from row 8, column 8
  if Matrix.GetModule(8, 8) = qmDark then
    FormatBits := FormatBits or (1 shl 7);

  // Bit 8 from row 7, column 8 (skip timing pattern at row 6)
  if Matrix.GetModule(7, 8) = qmDark then
    FormatBits := FormatBits or (1 shl 8);

  // Bits 9-14 from rows 5-0, column 8
  for I := 5 downto 0 do
  begin
    if Matrix.GetModule(I, 8) = qmDark then
      Bit := 1
    else
      Bit := 0;
    FormatBits := FormatBits or (Bit shl (14 - I));
  end;

  // Unmask format bits
  FormatBits := FormatBits xor FORMAT_MASK;

  // Format structure (15 bits): EE MMM CCCCCCCCCC
  // Bits 14-13: EC level (00=M, 01=L, 10=H, 11=Q)
  // Bits 12-10: Mask pattern (0-7)
  // Bits 9-0: BCH error correction

  // Extract mask pattern (bits 12-10)
  Result := (FormatBits shr 10) and $07;
end;

class function TQRDataDecoder.ExtractDataBits(Matrix: TQRMatrix; Version: Integer): TByteArray;
var
  Row, Col: Integer;
  BitBuffer: TQRBitBuffer;
  Upward: Boolean;
  I, J: Integer;
  Size: Integer;
  VersionInfo: TQRVersionInfo;
  AlignPos: TIntArray;
  InterleavedData: TByteArray;
  BlockSize: Integer;
  DataIndex: Integer;

  function IsReserved(R, C: Integer): Boolean;
  var
    AI, AJ, AR, AC: Integer;
  begin
    // Finder patterns + separators
    if (R < 9) and (C < 9) then Exit(True);  // Top-left
    if (R < 9) and (C >= Size - 8) then Exit(True);  // Top-right
    if (R >= Size - 8) and (C < 9) then Exit(True);  // Bottom-left

    // Timing patterns
    if (R = 6) or (C = 6) then Exit(True);

    // Alignment patterns (for version >= 2)
    if Length(AlignPos) > 0 then
    begin
      for AI := 0 to High(AlignPos) do
        for AJ := 0 to High(AlignPos) do
        begin
          AR := AlignPos[AI];
          AC := AlignPos[AJ];

          // Skip corners where finder patterns are
          if ((AR < 9) and (AC < 9)) or
             ((AR < 9) and (AC > Size - 10)) or
             ((AR > Size - 10) and (AC < 9)) then
            Continue;

          // Check if (R, C) is within the 5x5 alignment pattern
          if (Abs(R - AR) <= 2) and (Abs(C - AC) <= 2) then
            Exit(True);
        end;
    end;

    Result := False;
  end;

begin
  Size := Matrix.Size;
  VersionInfo := TQRDataEncoder.GetVersionInfo(Version);
  AlignPos := VersionInfo.AlignmentPositions;

  BitBuffer := TQRBitBuffer.Create;
  try
    Col := Size - 1;
    Upward := True;

    while Col >= 0 do
    begin
      // Skip vertical timing pattern
      if Col = 6 then
        Dec(Col);

      if Upward then
      begin
        for Row := Size - 1 downto 0 do
        begin
          for I := 0 to 1 do
          begin
            if Col - I < 0 then Continue;
            if not IsReserved(Row, Col - I) then
            begin
              if Matrix.GetModule(Row, Col - I) = qmDark then
                BitBuffer.AppendBits(1, 1)
              else
                BitBuffer.AppendBits(0, 1);
            end;
          end;
        end;
      end
      else
      begin
        for Row := 0 to Size - 1 do
        begin
          for I := 0 to 1 do
          begin
            if Col - I < 0 then Continue;
            if not IsReserved(Row, Col - I) then
            begin
              if Matrix.GetModule(Row, Col - I) = qmDark then
                BitBuffer.AppendBits(1, 1)
              else
                BitBuffer.AppendBits(0, 1);
            end;
          end;
        end;
      end;

      Dec(Col, 2);
      Upward := not Upward;
    end;

    // Get total codewords (data + EC) - this is interleaved
    InterleavedData := BitBuffer.ToByteArray(VersionInfo.DataCapacity + VersionInfo.ECCodewords * VersionInfo.BlockCount);

    // De-interleave data codewords (EC codewords are ignored for now)
    if VersionInfo.BlockCount = 1 then
    begin
      // No interleaving, just return data portion
      SetLength(Result, VersionInfo.DataCapacity);
      for I := 0 to VersionInfo.DataCapacity - 1 do
        Result[I] := InterleavedData[I];
    end
    else
    begin
      // De-interleave: blocks may have different sizes
      // Short blocks have BlockSize bytes, long blocks have BlockSize+1 bytes
      BlockSize := VersionInfo.DataCapacity div VersionInfo.BlockCount;
      var NumLongBlocks := VersionInfo.DataCapacity mod VersionInfo.BlockCount;
      var NumShortBlocks := VersionInfo.BlockCount - NumLongBlocks;

      SetLength(Result, VersionInfo.DataCapacity);
      DataIndex := 0;

      // First, de-interleave the common bytes (0 to BlockSize-1) from all blocks
      for J := 0 to BlockSize - 1 do
        for I := 0 to VersionInfo.BlockCount - 1 do
        begin
          // Calculate destination index considering block sizes
          if I < NumShortBlocks then
            Result[I * BlockSize + J] := InterleavedData[DataIndex]
          else
            Result[NumShortBlocks * BlockSize + (I - NumShortBlocks) * (BlockSize + 1) + J] := InterleavedData[DataIndex];
          Inc(DataIndex);
        end;

      // Then, de-interleave the extra byte from long blocks only
      for I := 0 to NumLongBlocks - 1 do
      begin
        var LongBlockStart := NumShortBlocks * BlockSize + I * (BlockSize + 1);
        Result[LongBlockStart + BlockSize] := InterleavedData[DataIndex];
        Inc(DataIndex);
      end;
    end;
  finally
    BitBuffer.Free;
  end;
end;

class function TQRDataDecoder.DecodeByteMode(const Data: TByteArray; Version: Integer): string;
var
  BitIndex: Integer;
  Mode, CharCount: Integer;
  CharCountBits: Integer;
  DataBytes: TByteArray;
  I: Integer;

  function ReadBits(NumBits: Integer): Integer;
  var
    J: Integer;
  begin
    Result := 0;
    for J := 0 to NumBits - 1 do
    begin
      if BitIndex div 8 < Length(Data) then
      begin
        if ((Data[BitIndex div 8] shr (7 - BitIndex mod 8)) and 1) = 1 then
          Result := Result or (1 shl (NumBits - 1 - J));
      end;
      Inc(BitIndex);
    end;
  end;

begin
  BitIndex := 0;

  // Read mode indicator (4 bits)
  Mode := ReadBits(4);
  if Mode <> 4 then  // 0100 = Byte mode
    raise Exception.CreateFmt('Unsupported mode: %d (expected byte mode 4)', [Mode]);

  // Read character count
  if Version <= 9 then
    CharCountBits := 8
  else
    CharCountBits := 16;
  CharCount := ReadBits(CharCountBits);

  if CharCount > 200 then
    raise Exception.CreateFmt('Suspicious character count: %d (probably data extraction error)', [CharCount]);

  // Read data bytes
  SetLength(DataBytes, CharCount);
  for I := 0 to CharCount - 1 do
    DataBytes[I] := ReadBits(8);

  // Convert to UTF-8 string
  Result := TEncoding.UTF8.GetString(DataBytes);
end;

{ TQRCode - Decoding methods }

function TQRCode.ReadFromRGBA(const Data: TBytes; Width, Height: Integer): string;
var
  Processor: TQRImageProcessor;
  ExtractedMatrix: TQRMatrix;
  MaskPattern: Integer;
  Version: Integer;
  DataBits: TByteArray;
  Row, Col: Integer;
begin
  Processor := TQRImageProcessor.Create;
  try
    // Process image to find QR code
    Processor.Process(Data, Width, Height);

    // Extract the module matrix
    ExtractedMatrix := Processor.ExtractMatrix;
    try
      Version := Processor.GetVersion;

      // Get format info (mask pattern)
      MaskPattern := TQRDataDecoder.ExtractFormatInfo(ExtractedMatrix);

      // Unmask the data
      for Row := 0 to ExtractedMatrix.Size - 1 do
        for Col := 0 to ExtractedMatrix.Size - 1 do
        begin
          if TQRMask.EvaluateMask(Row, Col, MaskPattern) then
          begin
            if ExtractedMatrix.GetModule(Row, Col) = qmDark then
              ExtractedMatrix.SetModule(Row, Col, qmLight)
            else
              ExtractedMatrix.SetModule(Row, Col, qmDark);
          end;
        end;

      // Extract data bits
      DataBits := TQRDataDecoder.ExtractDataBits(ExtractedMatrix, Version);

      // Decode the data
      Result := TQRDataDecoder.DecodeByteMode(DataBits, Version);
    finally
      ExtractedMatrix.Free;
    end;
  finally
    Processor.Free;
  end;
end;

{$IFDEF MSWINDOWS}
function TQRCode.ReadFromPng(const FileName: string): string;
var
  Png: TPngImage;
  Bmp: Vcl.Graphics.TBitmap;
begin
  Png := TPngImage.Create;
  try
    Png.LoadFromFile(FileName);
    Bmp := Vcl.Graphics.TBitmap.Create;
    try
      Bmp.Assign(Png);
      Result := ReadFromBitmap(Bmp);
    finally
      Bmp.Free;
    end;
  finally
    Png.Free;
  end;
end;

function TQRCode.ReadFromBitmap(Bitmap: Vcl.Graphics.TBitmap): string;
var
  RGBA: TBytes;
  X, Y: Integer;
  P: PByteArray;
  Idx: Integer;
begin
  // Convert bitmap to RGBA
  Bitmap.PixelFormat := pf32bit;
  SetLength(RGBA, Bitmap.Width * Bitmap.Height * 4);

  for Y := 0 to Bitmap.Height - 1 do
  begin
    P := Bitmap.ScanLine[Y];
    for X := 0 to Bitmap.Width - 1 do
    begin
      Idx := (Y * Bitmap.Width + X) * 4;
      RGBA[Idx] := P[X * 4 + 2];      // R (BGR -> RGB)
      RGBA[Idx + 1] := P[X * 4 + 1];  // G
      RGBA[Idx + 2] := P[X * 4 + 0];  // B
      RGBA[Idx + 3] := 255;           // A
    end;
  end;

  Result := ReadFromRGBA(RGBA, Bitmap.Width, Bitmap.Height);
end;
{$ENDIF}

{$IF DEFINED(IOS) OR DEFINED(MACOS) OR DEFINED(ANDROID)}
function TQRCode.ReadFromBitmap(Bitmap: FMX.Graphics.TBitmap): string;
var
  Data: TBitmapData;
  RGBA: TBytes;
begin
  SetLength(RGBA, Bitmap.Width * Bitmap.Height * 4);

  if Bitmap.Map(TMapAccess.Read, Data) then
  try
    Move(Data.Data^, RGBA[0], Length(RGBA));
  finally
    Bitmap.Unmap(Data);
  end;

  Result := ReadFromRGBA(RGBA, Bitmap.Width, Bitmap.Height);
end;
{$ENDIF}

end.
