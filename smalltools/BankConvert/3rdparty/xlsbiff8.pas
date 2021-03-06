{
xlsbiff8.pas

Writes an Excel 8 file

An Excel worksheet stream consists of a number of subsequent records.
To ensure a properly formed file, the following order must be respected:

1st record:        BOF
2nd to Nth record: Any record
Last record:       EOF

Excel 8 files are OLE compound document files, and must be written using the
fpOLE library.

Records Needed to Make a BIFF8 File Microsoft Excel Can Use:

Required Records:

BOF - Set the 6 byte offset to 0x0005 (workbook globals)
Window1
FONT - At least five of these records must be included
XF - At least 15 Style XF records and 1 Cell XF record must be included
STYLE
BOUNDSHEET - Include one BOUNDSHEET record per worksheet
EOF

BOF - Set the 6 byte offset to 0x0010 (worksheet)
INDEX
DIMENSIONS
WINDOW2
EOF

The row and column numbering in BIFF files is zero-based.

Excel file format specification obtained from:

http://sc.openoffice.org/excelfileformat.pdf

AUTHORS:  Felipe Monteiro de Carvalho
          Jose Mejuto
}
unit xlsbiff8;

{$ifdef fpc}
  {$mode delphi}
{$endif}

// The new OLE code is much better, so always use it
{$define USE_NEW_OLE}
{.$define XLSDEBUG}

interface

uses
  Classes, SysUtils, fpcanvas, DateUtils,
  fpspreadsheet, xlscommon,
  {$ifdef USE_NEW_OLE}
  fpolebasic,
  {$else}
  fpolestorage,
  {$endif}
  fpsutils, lazutf8;

type
  TXFRecordData = class
  public
    FormatIndex: Integer;
  end;

  TFormatRecordData = class
  public
    Index: Integer;
    FormatString: widestring;
  end;

  { TsSpreadBIFF8Reader }

  TsSpreadBIFF8Reader = class(TsSpreadBIFFReader)
  private
    RecordSize: Word;
    PendingRecordSize: SizeInt;
    FWorksheet: TsWorksheet;
    FWorksheetNames: TStringList;
    FCurrentWorksheet: Integer;
    FSharedStringTable: TStringList;
    FXFList: TFPList; // of TXFRecordData
    FFormatList: TFPList; // of TFormatRecordData
    function DecodeRKValue(const ARK: DWORD): Double;
    // Tries to find if a number cell is actually a date/datetime/time cell
    // and retrieve the value
    function IsDate(Number: Double; ARow: WORD;
      ACol: WORD; AXFIndex: WORD; var ADateTime: TDateTime): boolean;
    function ReadWideString(const AStream: TStream; const ALength: WORD): WideString; overload;
    function ReadWideString(const AStream: TStream; const AUse8BitLength: Boolean): WideString; overload;
    procedure ReadWorkbookGlobals(AStream: TStream; AData: TsWorkbook);
    procedure ReadWorksheet(AStream: TStream; AData: TsWorkbook);
    procedure ReadBoundsheet(AStream: TStream);

    procedure ReadRKValue(const AStream: TStream);
    procedure ReadMulRKValues(const AStream: TStream);
    procedure ReadRowColXF(const AStream: TStream; out ARow,ACol,AXF: WORD);
    function ReadString(const AStream: TStream; const ALength: WORD): UTF8String;
    procedure ReadRichString(const AStream: TStream);
    procedure ReadSST(const AStream: TStream);
    procedure ReadLabelSST(const AStream: TStream);
    // Read XF record
    procedure ReadXF(const AStream: TStream);
    // Read FORMAT record (cell formatting)
    procedure ReadFormat(const AStream: TStream);
    // Finds format record for XF record pointed to by cell
    // Will not return info for built-in formats
    function  FindFormatRecordForCell(const AXFIndex: Integer): TFormatRecordData;
    // Workbook Globals records
    // procedure ReadCodepage in xlscommon
    // procedure ReadDateMode in xlscommon
    procedure ReadFont(const AStream: TStream);
  public
    constructor Create; override;
    destructor Destroy; override;
    { General reading methods }
    procedure ReadFromFile(AFileName: string; AData: TsWorkbook); override;
    procedure ReadFromStream(AStream: TStream; AData: TsWorkbook); override;
    { Record writing methods }
    procedure ReadFormula(AStream: TStream); override;
    procedure ReadLabel(AStream: TStream); override;
    procedure ReadNumber(AStream: TStream); override;
  end;

  { TsSpreadBIFF8Writer }

  TsSpreadBIFF8Writer = class(TsSpreadBIFFWriter)
  private
    // Writes index to XF record according to cell's formatting
    procedure WriteXFIndex(AStream: TStream; ACell: PCell);
    procedure WriteXFFieldsForFormattingStyles(AStream: TStream);
  protected
    procedure AddDefaultFormats(); override;
  public
//    constructor Create;
//    destructor Destroy; override;
    { General writing methods }
    procedure WriteToFile(const AFileName: string; AData: TsWorkbook;
      const AOverwriteExisting: Boolean = False); override;
    procedure WriteToStream(AStream: TStream; AData: TsWorkbook); override;
    { Record writing methods }
    procedure WriteBOF(AStream: TStream; ADataType: Word);
    function  WriteBoundsheet(AStream: TStream; ASheetName: string): Int64;
    // procedure WriteCodepage in xlscommon; Workbook Globals record
    procedure WriteDateTime(AStream: TStream; const ARow, ACol: Cardinal; const AValue: TDateTime; ACell: PCell); override;
    // procedure WriteDateMode in xlscommon; Workbook Globals record
    procedure WriteDimensions(AStream: TStream; AWorksheet: TsWorksheet);
    procedure WriteEOF(AStream: TStream);
    procedure WriteFont(AStream: TStream; AFont: TFPCustomFont);
    procedure WriteFormula(AStream: TStream; const ARow, ACol: Cardinal; const AFormula: TsFormula; ACell: PCell); override;
    procedure WriteIndex(AStream: TStream);
    procedure WriteLabel(AStream: TStream; const ARow, ACol: Cardinal; const AValue: string; ACell: PCell); override;
    procedure WriteNumber(AStream: TStream; const ARow, ACol: Cardinal; const AValue: double; ACell: PCell); override;
    procedure WritePalette(AStream: TStream);
    procedure WriteRPNFormula(AStream: TStream; const ARow, ACol: Cardinal; const AFormula: TsRPNFormula; ACell: PCell); override;
    procedure WriteStyle(AStream: TStream);
    procedure WriteWindow1(AStream: TStream);
    procedure WriteWindow2(AStream: TStream; ASheetSelected: Boolean);
    procedure WriteXF(AStream: TStream; AFontIndex: Word;
      AFormatIndex: Word; AXF_TYPE_PROT, ATextRotation: Byte; ABorders: TsCellBorders;
      AddBackground: Boolean = False; ABackgroundColor: TsColor = scSilver);
  end;

implementation

const
  { Excel record IDs }
  INT_EXCEL_ID_BOF        = $0809;
  INT_EXCEL_ID_BOUNDSHEET = $0085; // Renamed to SHEET in the latest OpenOffice docs
  INT_EXCEL_ID_EOF        = $000A;
  INT_EXCEL_ID_DIMENSIONS = $0200;
  INT_EXCEL_ID_FONT       = $0031;
  INT_EXCEL_ID_FORMULA    = $0006;
  INT_EXCEL_ID_INDEX      = $020B;
  INT_EXCEL_ID_LABEL      = $0204;
  INT_EXCEL_ID_NUMBER     = $0203;
  INT_EXCEL_ID_STYLE      = $0293;
  INT_EXCEL_ID_WINDOW1    = $003D;
  INT_EXCEL_ID_WINDOW2    = $023E;
  INT_EXCEL_ID_XF         = $00E0;
  INT_EXCEL_ID_RSTRING    = $00D6;
  INT_EXCEL_ID_RK         = $027E;
  INT_EXCEL_ID_MULRK      = $00BD;
  INT_EXCEL_ID_SST        = $00FC; //BIFF8 only
  INT_EXCEL_ID_CONTINUE   = $003C;
  INT_EXCEL_ID_LABELSST   = $00FD; //BIFF8 only
  INT_EXCEL_ID_PALETTE    = $0092;
  INT_EXCEL_ID_CODEPAGE   = $0042;
  INT_EXCEL_ID_FORMAT     = $041E;

  { Cell Addresses constants }
  MASK_EXCEL_ROW          = $3FFF;
  MASK_EXCEL_COL_BITS_BIFF8=$00FF;
  MASK_EXCEL_RELATIVE_ROW = $4000;
  MASK_EXCEL_RELATIVE_COL = $8000;

  { BOF record constants }
  INT_BOF_BIFF8_VER       = $0600;
  INT_BOF_WORKBOOK_GLOBALS= $0005;
  INT_BOF_VB_MODULE       = $0006;
  INT_BOF_SHEET           = $0010;
  INT_BOF_CHART           = $0020;
  INT_BOF_MACRO_SHEET     = $0040;
  INT_BOF_WORKSPACE       = $0100;
  INT_BOF_BUILD_ID        = $1FD2;
  INT_BOF_BUILD_YEAR      = $07CD;

  { FONT record constants }
  INT_FONT_WEIGHT_NORMAL  = $0190;
  INT_FONT_WEIGHT_BOLD    = $02BC;

  { FORMULA record constants }
  MASK_FORMULA_RECALCULATE_ALWAYS  = $0001;
  MASK_FORMULA_RECALCULATE_ON_OPEN = $0002;
  MASK_FORMULA_SHARED_FORMULA      = $0008;

  { STYLE record constants }
  MASK_STYLE_BUILT_IN     = $8000;

  { WINDOW1 record constants }
  MASK_WINDOW1_OPTION_WINDOW_HIDDEN             = $0001;
  MASK_WINDOW1_OPTION_WINDOW_MINIMISED          = $0002;
  MASK_WINDOW1_OPTION_HORZ_SCROLL_VISIBLE       = $0008;
  MASK_WINDOW1_OPTION_VERT_SCROLL_VISIBLE       = $0010;
  MASK_WINDOW1_OPTION_WORKSHEET_TAB_VISIBLE     = $0020;

  { WINDOW2 record constants }
  MASK_WINDOW2_OPTION_SHOW_FORMULAS             = $0001;
  MASK_WINDOW2_OPTION_SHOW_GRID_LINES           = $0002;
  MASK_WINDOW2_OPTION_SHOW_SHEET_HEADERS        = $0004;
  MASK_WINDOW2_OPTION_PANES_ARE_FROZEN          = $0008;
  MASK_WINDOW2_OPTION_SHOW_ZERO_VALUES          = $0010;
  MASK_WINDOW2_OPTION_AUTO_GRIDLINE_COLOR       = $0020;
  MASK_WINDOW2_OPTION_COLUMNS_RIGHT_TO_LEFT     = $0040;
  MASK_WINDOW2_OPTION_SHOW_OUTLINE_SYMBOLS      = $0080;
  MASK_WINDOW2_OPTION_REMOVE_SPLITS_ON_UNFREEZE = $0100;
  MASK_WINDOW2_OPTION_SHEET_SELECTED            = $0200;
  MASK_WINDOW2_OPTION_SHEET_ACTIVE              = $0400;

  { XF substructures }

  { XF_TYPE_PROT - XF Type and Cell protection (3 Bits) - BIFF3-BIFF8 }
  MASK_XF_TYPE_PROT_LOCKED            = $1;
  MASK_XF_TYPE_PROT_FORMULA_HIDDEN    = $2;
  MASK_XF_TYPE_PROT_STYLE_XF          = $4; // 0 = CELL XF

  { XF_USED_ATTRIB - Attributes from parent Style XF (6 Bits) - BIFF3-BIFF8
  
    In a CELL XF a cleared bit means that the parent attribute is used,
    while a set bit indicates that the data in this XF is used

    In a STYLE XF a cleared bit means that the data in this XF is used,
    while a set bit indicates that the attribute should be ignored }
  MASK_XF_USED_ATTRIB_NUMBER_FORMAT   = $04;
  MASK_XF_USED_ATTRIB_FONT            = $08;
  MASK_XF_USED_ATTRIB_TEXT            = $10;
  MASK_XF_USED_ATTRIB_BORDER_LINES    = $20;
  MASK_XF_USED_ATTRIB_BACKGROUND      = $40;
  MASK_XF_USED_ATTRIB_CELL_PROTECTION = $80;

  { XF_VERT_ALIGN }
  MASK_XF_VERT_ALIGN_TOP              = $00;
  MASK_XF_VERT_ALIGN_CENTRED          = $10;
  MASK_XF_VERT_ALIGN_BOTTOM           = $20;
  MASK_XF_VERT_ALIGN_JUSTIFIED        = $30;

  { XF_ROTATION }
  XF_ROTATION_HORIZONTAL                 = 0;
  XF_ROTATION_90_DEGREE_COUNTERCLOCKWISE = 90;
  XF_ROTATION_90_DEGREE_CLOCKWISE        = 180;

  { XF record constants }
  MASK_XF_TYPE_PROT                   = $0007;
  MASK_XF_TYPE_PROT_PARENT            = $FFF0;

  MASK_XF_VERT_ALIGN                  = $70;

{
  Exported functions
}

{ TsSpreadBIFF8Writer }

{ Index to XF record, according to formatting }
procedure TsSpreadBIFF8Writer.WriteXFIndex(AStream: TStream; ACell: PCell);
var
  lIndex: Integer;
  lXFIndex: Word;
begin
  // First try the fast methods for default formats
  if ACell^.UsedFormattingFields = [] then
  begin
    AStream.WriteWord(WordToLE(15)); //XF15; see TsSpreadBIFF8Writer.AddDefaultFormats
    Exit;
  end;

  if ACell^.UsedFormattingFields = [uffTextRotation] then
  begin
    case ACell^.TextRotation of
      rt90DegreeCounterClockwiseRotation: AStream.WriteWord(WordToLE(16)); //XF_16
      rt90DegreeClockwiseRotation: AStream.WriteWord(WordToLE(17)); //XF_17
    else
      AStream.WriteWord(WordToLE(15)); //XF_15
    end;
    Exit;
  end;

  {
  uffNumberFormat does not seem to have default XF indexes, but perhaps look at XF_21
  if ACell^.UsedFormattingFields = [uffNumberFormat] then
  begin
    case ACell^.NumberFormat of
      nfShortDate:     AStream.WriteWord(WordToLE(???)); //what XF index?
      nfShortDateTime: AStream.WriteWord(WordToLE(???)); //what XF index?
    else
      AStream.WriteWord(WordToLE(15)); //e.g. nfGeneral: XF_15
    end;
    Exit;
  end;
  }

  if ACell^.UsedFormattingFields = [uffBold] then
  begin
    AStream.WriteWord(WordToLE(18)); //XF_18
    Exit;
  end;

  // If not, then we need to search in the list of dynamic formats
  lIndex := FindFormattingInList(ACell);
  // Carefully check the index
  if (lIndex < 0) or (lIndex > Length(FFormattingStyles)) then
    raise Exception.Create('[TsSpreadBIFF8Writer.WriteXFIndex] Invalid Index, this should not happen!');

  lXFIndex := FFormattingStyles[lIndex].Row;

  AStream.WriteWord(WordToLE(lXFIndex));
end;

procedure TsSpreadBIFF8Writer.WriteXFFieldsForFormattingStyles(AStream: TStream);
var
  i: Integer;
  lFontIndex: Word;
  lFormatIndex: Word; //number format
  lTextRotation: Byte;
  lBorders: TsCellBorders;
  lAddBackground: Boolean;
  lBackgroundColor: TsColor;
begin
  // The first 4 styles were already added
  for i := 4 to Length(FFormattingStyles) - 1 do
  begin
    // Default styles
    lFontIndex := 0;
    lFormatIndex := 0; //General format (one of the built-in number formats)
    lTextRotation := XF_ROTATION_HORIZONTAL;
    lBorders := [];
    lAddBackground := False;
    lBackgroundColor := FFormattingStyles[i].BackgroundColor;

    // Now apply the modifications.
    if uffNumberFormat in FFormattingStyles[i].UsedFormattingFields then
    begin
      case FFormattingStyles[i].NumberFormat of
      nfGeneral:       lFormatIndex := FORMAT_GENERAL;
      nfShortDate:     lFormatIndex := FORMAT_SHORT_DATE;
      nfShortDateTime: lFormatIndex := FORMAT_SHORT_DATETIME;
      end;
    end;

    if uffBorder in FFormattingStyles[i].UsedFormattingFields then
      lBorders := FFormattingStyles[i].Border;

    if uffTextRotation in FFormattingStyles[i].UsedFormattingFields then
    begin
      case FFormattingStyles[i].TextRotation of
      trHorizontal:                       lTextRotation := XF_ROTATION_HORIZONTAL;
      rt90DegreeClockwiseRotation:        lTextRotation := XF_ROTATION_90_DEGREE_CLOCKWISE;
      rt90DegreeCounterClockwiseRotation: lTextRotation := XF_ROTATION_90_DEGREE_COUNTERCLOCKWISE;
      end;
    end;

    if uffBold in FFormattingStyles[i].UsedFormattingFields then
      lFontIndex := 1;

    if uffBackgroundColor in FFormattingStyles[i].UsedFormattingFields then
      lAddBackground := True;

    // And finally write the style
    WriteXF(AStream, lFontIndex, lFormatIndex, 0, lTextRotation, lBorders, lAddBackground, lBackgroundColor);
  end;
end;

{@@
  These are default style formats which are added as XF fields regardless of being used
  in the document or not.
}
procedure TsSpreadBIFF8Writer.AddDefaultFormats();
begin
  NextXFIndex := 21;

  SetLength(FFormattingStyles, 6);

  // XF0..XF14: Normal style, Row Outline level 1..7,
  // Column Outline level 1..7.

  // XF15 - Default cell format, no formatting (4.6.2)
  FFormattingStyles[0].UsedFormattingFields := [];
  FFormattingStyles[0].Row := 15;

  // XF16 - Rotated
  FFormattingStyles[1].UsedFormattingFields := [uffTextRotation];
  FFormattingStyles[1].Row := 16;
  FFormattingStyles[1].TextRotation := rt90DegreeCounterClockwiseRotation;

  // XF17 - Rotated
  FFormattingStyles[2].UsedFormattingFields := [uffTextRotation];
  FFormattingStyles[2].Row := 17;
  FFormattingStyles[2].TextRotation := rt90DegreeClockwiseRotation;

  // XF18 - Bold
  FFormattingStyles[3].UsedFormattingFields := [uffBold];
  FFormattingStyles[3].Row := 18;
end;

{*******************************************************************
*  TsSpreadBIFF8Writer.WriteToFile ()
*
*  DESCRIPTION:    Writes an Excel BIFF8 file to the disc
*
*                  The BIFF 8 writer overrides this method because
*                  BIFF 8 is written as an OLE document, and our
*                  current OLE document writing method involves:
*
*                  1 - Writing the BIFF data to a memory stream
*
*                  2 - Write the memory stream data to disk using
*                      COM functions
*
*******************************************************************}
procedure TsSpreadBIFF8Writer.WriteToFile(const AFileName: string;
  AData: TsWorkbook; const AOverwriteExisting: Boolean);
var
  MemStream: TMemoryStream;
  OutputStorage: TOLEStorage;
  OLEDocument: TOLEDocument;
begin
  MemStream := TMemoryStream.Create;
  OutputStorage := TOLEStorage.Create;
  try
    WriteToStream(MemStream, AData);

    // Only one stream is necessary for any number of worksheets
    OLEDocument.Stream := MemStream;

    OutputStorage.WriteOLEFile(AFileName, OLEDocument, AOverwriteExisting, 'Workbook');
  finally
    MemStream.Free;
    OutputStorage.Free;
  end;
end;

{*******************************************************************
*  TsSpreadBIFF8Writer.WriteToStream ()
*
*  DESCRIPTION:    Writes an Excel BIFF8 record structure
*
*                  Be careful as this method doesn't write the OLE
*                  part of the document, just the BIFF records
*
*******************************************************************}
procedure TsSpreadBIFF8Writer.WriteToStream(AStream: TStream; AData: TsWorkbook);
var
  FontData: TFPCustomFont;
  MyData: TMemoryStream;
  CurrentPos: Int64;
  Boundsheets: array of Int64;
  i, len: Integer;
begin
  { Write workbook globals }

  WriteBOF(AStream, INT_BOF_WORKBOOK_GLOBALS);

  WriteWindow1(AStream);

  FontData := TFPCustomFont.Create;
  try
    FontData.Name := 'Arial';

    // FONT0 - normal
    WriteFont(AStream, FontData);
    // FONT1 - bold
    FontData.Bold := True;
    WriteFont(AStream, FontData);
    FontData.Bold := False;
    // FONT2
    WriteFont(AStream, FontData);
    // FONT3
    WriteFont(AStream, FontData);
    // FONT5
    WriteFont(AStream, FontData);
  finally
   FontData.Free;
  end;
  
  // PALETTE
  WritePalette(AStream);

  // XF0
  WriteXF(AStream, 0, 0, MASK_XF_TYPE_PROT_STYLE_XF, XF_ROTATION_HORIZONTAL, []);
  // XF1
  WriteXF(AStream, 0, 0, MASK_XF_TYPE_PROT_STYLE_XF, XF_ROTATION_HORIZONTAL, []);
  // XF2
  WriteXF(AStream, 0, 0, MASK_XF_TYPE_PROT_STYLE_XF, XF_ROTATION_HORIZONTAL, []);
  // XF3
  WriteXF(AStream, 0, 0, MASK_XF_TYPE_PROT_STYLE_XF, XF_ROTATION_HORIZONTAL, []);
  // XF4
  WriteXF(AStream, 0, 0, MASK_XF_TYPE_PROT_STYLE_XF, XF_ROTATION_HORIZONTAL, []);
  // XF5
  WriteXF(AStream, 0, 0, MASK_XF_TYPE_PROT_STYLE_XF, XF_ROTATION_HORIZONTAL, []);
  // XF6
  WriteXF(AStream, 0, 0, MASK_XF_TYPE_PROT_STYLE_XF, XF_ROTATION_HORIZONTAL, []);
  // XF7
  WriteXF(AStream, 0, 0, MASK_XF_TYPE_PROT_STYLE_XF, XF_ROTATION_HORIZONTAL, []);
  // XF8
  WriteXF(AStream, 0, 0, MASK_XF_TYPE_PROT_STYLE_XF, XF_ROTATION_HORIZONTAL, []);
  // XF9
  WriteXF(AStream, 0, 0, MASK_XF_TYPE_PROT_STYLE_XF, XF_ROTATION_HORIZONTAL, []);
  // XF10
  WriteXF(AStream, 0, 0, MASK_XF_TYPE_PROT_STYLE_XF, XF_ROTATION_HORIZONTAL, []);
  // XF11
  WriteXF(AStream, 0, 0, MASK_XF_TYPE_PROT_STYLE_XF, XF_ROTATION_HORIZONTAL, []);
  // XF12
  WriteXF(AStream, 0, 0, MASK_XF_TYPE_PROT_STYLE_XF, XF_ROTATION_HORIZONTAL, []);
  // XF13
  WriteXF(AStream, 0, 0, MASK_XF_TYPE_PROT_STYLE_XF, XF_ROTATION_HORIZONTAL, []);
  // XF14
  WriteXF(AStream, 0, 0, MASK_XF_TYPE_PROT_STYLE_XF, XF_ROTATION_HORIZONTAL, []);
  // XF15 - Default, no formatting
  WriteXF(AStream, 0, 0, 0, XF_ROTATION_HORIZONTAL, []);
  // XF16 - Rotated
  WriteXF(AStream, 0, 0, 0, XF_ROTATION_90_DEGREE_COUNTERCLOCKWISE, []);
  // XF17 - Rotated
  WriteXF(AStream, 0, 0, 0, XF_ROTATION_90_DEGREE_CLOCKWISE, []);
  // XF18 - Bold
  WriteXF(AStream, 1, 0, 0, XF_ROTATION_HORIZONTAL, []);
  // Add all further non-standard/built-in formatting styles
  ListAllFormattingStyles(AData);
  WriteXFFieldsForFormattingStyles(AStream);

  WriteStyle(AStream);

  // A BOUNDSHEET for each worksheet
  for i := 0 to AData.GetWorksheetCount - 1 do
  begin
    len := Length(Boundsheets);
    SetLength(Boundsheets, len + 1);
    Boundsheets[len] := WriteBoundsheet(AStream, AData.GetWorksheetByIndex(i).Name);
  end;
  
  WriteEOF(AStream);

  { Write each worksheet }

  for i := 0 to AData.GetWorksheetCount - 1 do
  begin
    { First goes back and writes the position of the BOF of the
      sheet on the respective BOUNDSHEET record }
    CurrentPos := AStream.Position;
    AStream.Position := Boundsheets[i];
    AStream.WriteDWord(DWordToLE(DWORD(CurrentPos)));
    AStream.Position := CurrentPos;

    WriteBOF(AStream, INT_BOF_SHEET);

    WriteIndex(AStream);

    WriteDimensions(AStream, AData.GetWorksheetByIndex(i));

    WriteWindow2(AStream, True);

    WriteCellsToStream(AStream, AData.GetWorksheetByIndex(i).Cells);

    WriteEOF(AStream);
  end;
  
  { Cleanup }
  
  SetLength(Boundsheets, 0);
end;

{*******************************************************************
*  TsSpreadBIFF8Writer.WriteBOF ()
*
*  DESCRIPTION:    Writes an Excel 8 BOF record
*
*                  This must be the first record on an Excel 8 stream
*
*******************************************************************}
procedure TsSpreadBIFF8Writer.WriteBOF(AStream: TStream; ADataType: Word);
begin
  { BIFF Record header }
  AStream.WriteWord(WordToLE(INT_EXCEL_ID_BOF));
  AStream.WriteWord(WordToLE(16)); //total record size

  { BIFF version. Should only be used if this BOF is for the workbook globals }
  { OpenOffice rejects to correctly read xls files if this field is
    omitted as docs. says, or even if it is being written to zero value,
    Not tested with Excel, but MSExcel reader opens it as expected }
  AStream.WriteWord(WordToLE(INT_BOF_BIFF8_VER));

  { Data type }
  AStream.WriteWord(WordToLE(ADataType));

  { Build identifier, must not be 0 }
  AStream.WriteWord(WordToLE(INT_BOF_BUILD_ID));

  { Build year, must not be 0 }
  AStream.WriteWord(WordToLE(INT_BOF_BUILD_YEAR));

  { File history flags }
  AStream.WriteDWord(DWordToLE(0));

  { Lowest Excel version that can read all records in this file 5?}
  AStream.WriteDWord(DWordToLE(0)); //?????????
end;

{*******************************************************************
*  TsSpreadBIFF8Writer.WriteBoundsheet ()
*
*  DESCRIPTION:    Writes an Excel 8 BOUNDSHEET record
*
*                  Always located on the workbook globals substream.
*
*                  One BOUNDSHEET is written for each worksheet.
*
*  RETURNS:        The stream position where the absolute stream position
*                  of the BOF of this sheet should be written (4 bytes size).
*
*******************************************************************}
function TsSpreadBIFF8Writer.WriteBoundsheet(AStream: TStream; ASheetName: string): Int64;
var
  Len: Byte;
  WideSheetName: WideString;
begin
  WideSheetName:=UTF8Decode(ASheetName);
  Len := Length(WideSheetName);

  { BIFF Record header }
  AStream.WriteWord(WordToLE(INT_EXCEL_ID_BOUNDSHEET));
  AStream.WriteWord(WordToLE(6 + 1 + 1 + Len * Sizeof(WideChar)));

  { Absolute stream position of the BOF record of the sheet represented
    by this record }
  Result := AStream.Position;
  AStream.WriteDWord(DWordToLE(0));

  { Visibility }
  AStream.WriteByte(0);

  { Sheet type }
  AStream.WriteByte(0);

  { Sheet name: Unicode string char count 1 byte }
  AStream.WriteByte(Len);
  {String flags}
  AStream.WriteByte(1);
  AStream.WriteBuffer(WideStringToLE(WideSheetName)[1], Len * Sizeof(WideChar));
end;

{*******************************************************************
*  TsSpreadBIFF8Writer.WriteDateTime ()
*
*  DESCRIPTION:    Writes a date/time/datetime to an
*                  Excel 8 NUMBER record, with a date/time format
*                  (There is no separate date record type in xls)
*******************************************************************}
procedure TsSpreadBIFF8Writer.WriteDateTime(AStream: TStream; const ARow,
  ACol: Cardinal; const AValue: TDateTime; ACell: PCell);
var
  ExcelDateSerial: double;
begin
  ExcelDateSerial:=ConvertDateTimeToExcelDateTime(AValue,FDateMode);
  // fpspreadsheet must already have set formatting to a date/datetime format, so
  // this will get written out as a pointer to the relevant XF record.
  // In the end, dates in xls are just numbers with a format. Pass it on to WriteNumber:
  WriteNumber(AStream,ARow,ACol,ExcelDateSerial,ACell);
end;

{
  Writes an Excel 8 DIMENSIONS record

  nm = (rl - rf - 1) / 32 + 1 (using integer division)

  Excel, OpenOffice and FPSpreadsheet ignore the dimensions written in this record,
  but some other applications really use them, so they need to be correct.

  See bug 18886: excel5 files are truncated when imported
}
procedure TsSpreadBIFF8Writer.WriteDimensions(AStream: TStream; AWorksheet: TsWorksheet);
var
  lLastCol: Word;
  lLastRow: Integer;
begin
  { BIFF Record header }
  AStream.WriteWord(WordToLE(INT_EXCEL_ID_DIMENSIONS));
  AStream.WriteWord(WordToLE(14));

  { Index to first used row }
  AStream.WriteDWord(DWordToLE(0));

  { Index to last used row, increased by 1 }
  lLastRow := GetLastRowIndex(AWorksheet)+1;
  AStream.WriteDWord(DWordToLE(lLastRow)); // Old dummy value: 33

  { Index to first used column }
  AStream.WriteWord(WordToLE(0));

  { Index to last used column, increased by 1 }
  lLastCol := GetLastColIndex(AWorksheet)+1;
  AStream.WriteWord(WordToLE(lLastCol)); // Old dummy value: 10

  { Not used }
  AStream.WriteWord(WordToLE(0));
end;

{*******************************************************************
*  TsSpreadBIFF8Writer.WriteEOF ()
*
*  DESCRIPTION:    Writes an Excel 8 EOF record
*
*                  This must be the last record on an Excel 8 stream
*
*******************************************************************}
procedure TsSpreadBIFF8Writer.WriteEOF(AStream: TStream);
begin
  { BIFF Record header }
  AStream.WriteWord(WordToLE(INT_EXCEL_ID_EOF));
  AStream.WriteWord(WordToLE($0000));
end;

{*******************************************************************
*  TsSpreadBIFF8Writer.WriteFont ()
*
*  DESCRIPTION:    Writes an Excel 8 FONT record
*
*                  The font data is passed in an instance of TFPCustomFont
*
*******************************************************************}
procedure TsSpreadBIFF8Writer.WriteFont(AStream: TStream; AFont: TFPCustomFont);
var
  Len: Byte;
  WideFontName: WideString;
begin
  WideFontName:=AFont.Name;
  Len := Length(WideFontName);

  { BIFF Record header }
  AStream.WriteWord(WordToLE(INT_EXCEL_ID_FONT));
  AStream.WriteWord(WordToLE(14 + 1 + 1 + Len * Sizeof(WideChar)));

  { Height of the font in twips = 1/20 of a point }
  AStream.WriteWord(WordToLE(200));

  { Option flags }
  if AFont.Bold then AStream.WriteWord(WordToLE(1))
  else AStream.WriteWord(WordToLE(0));

  { Colour index }
  AStream.WriteWord(WordToLE($7FFF));

  { Font weight }
  if AFont.Bold then AStream.WriteWord(WordToLE(INT_FONT_WEIGHT_BOLD))
  else AStream.WriteWord(WordToLE(INT_FONT_WEIGHT_NORMAL));

  { Escapement type }
  AStream.WriteWord(WordToLE(0));

  { Underline type }
  AStream.WriteByte(0);

  { Font family }
  AStream.WriteByte(0);

  { Character set }
  AStream.WriteByte(0);

  { Not used }
  AStream.WriteByte(0);

  { Font name: Unicodestring, char count in 1 byte }
  AStream.WriteByte(Len);
  { Widestring flags, 1=regular unicode LE string }
  AStream.WriteByte(1);
  AStream.WriteBuffer(WideStringToLE(WideFontName)[1], Len * Sizeof(WideChar));
end;

{*******************************************************************
*  TsSpreadBIFF8Writer.WriteFormula ()
*
*  DESCRIPTION:    Writes an Excel 5 FORMULA record
*
*                  To input a formula to this method, first convert it
*                  to RPN, and then list all it's members in the
*                  AFormula array
*
*******************************************************************}
procedure TsSpreadBIFF8Writer.WriteFormula(AStream: TStream; const ARow,
  ACol: Cardinal; const AFormula: TsFormula; ACell: PCell);
{var
  FormulaResult: double;
  i: Integer;
  RPNLength: Word;
  TokenArraySizePos, RecordSizePos, FinalPos: Int64;}
begin
(*  RPNLength := 0;
  FormulaResult := 0.0;

  { BIFF Record header }
  AStream.WriteWord(WordToLE(INT_EXCEL_ID_FORMULA));
  RecordSizePos := AStream.Position;
  AStream.WriteWord(WordToLE(22 + RPNLength));

  { BIFF Record data }
  AStream.WriteWord(WordToLE(ARow));
  AStream.WriteWord(WordToLE(ACol));

  { Index to XF Record }
  AStream.WriteWord($0000);

  { Result of the formula in IEE 754 floating-point value }
  AStream.WriteBuffer(FormulaResult, 8);

  { Options flags }
  AStream.WriteWord(WordToLE(MASK_FORMULA_RECALCULATE_ALWAYS));

  { Not used }
  AStream.WriteDWord(0);

  { Formula }

  { The size of the token array is written later,
    because it's necessary to calculate if first,
    and this is done at the same time it is written }
  TokenArraySizePos := AStream.Position;
  AStream.WriteWord(RPNLength);

  { Formula data (RPN token array) }
  for i := 0 to Length(AFormula) - 1 do
  begin
    { Token identifier }
    AStream.WriteByte(AFormula[i].TokenID);
    Inc(RPNLength);

    { Additional data }
    case AFormula[i].TokenID of

    { binary operation tokens }

    INT_EXCEL_TOKEN_TADD, INT_EXCEL_TOKEN_TSUB, INT_EXCEL_TOKEN_TMUL,
     INT_EXCEL_TOKEN_TDIV, INT_EXCEL_TOKEN_TPOWER: begin end;

    INT_EXCEL_TOKEN_TNUM:
    begin
      AStream.WriteBuffer(AFormula[i].DoubleValue, 8);
      Inc(RPNLength, 8);
    end;

    INT_EXCEL_TOKEN_TREFR, INT_EXCEL_TOKEN_TREFV, INT_EXCEL_TOKEN_TREFA:
    begin
      AStream.WriteWord(AFormula[i].Row and MASK_EXCEL_ROW);
      AStream.WriteByte(AFormula[i].Col);
      Inc(RPNLength, 3);
    end;

    end;
  end;

  { Write sizes in the end, after we known them }
  FinalPos := AStream.Position;
  AStream.position := TokenArraySizePos;
  AStream.WriteByte(RPNLength);
  AStream.Position := RecordSizePos;
  AStream.WriteWord(WordToLE(22 + RPNLength));
  AStream.position := FinalPos;*)
end;

procedure TsSpreadBIFF8Writer.WriteRPNFormula(AStream: TStream; const ARow,
  ACol: Cardinal; const AFormula: TsRPNFormula; ACell: PCell);
var
  FormulaResult: double;
  i: Integer;
  RPNLength: Word;
  TokenArraySizePos, RecordSizePos, FinalPos: Int64;
  TokenID: Byte;
  lSecondaryID: Word;
begin
  RPNLength := 0;
  FormulaResult := 0.0;

  { BIFF Record header }
  AStream.WriteWord(WordToLE(INT_EXCEL_ID_FORMULA));
  RecordSizePos := AStream.Position;
  AStream.WriteWord(WordToLE(22 + RPNLength));

  { BIFF Record data }
  AStream.WriteWord(WordToLE(ARow));
  AStream.WriteWord(WordToLE(ACol));

  { Index to XF record, according to formatting }
  //AStream.WriteWord(0);
  WriteXFIndex(AStream, ACell);

  { Result of the formula in IEE 754 floating-point value }
  AStream.WriteBuffer(FormulaResult, 8);

  { Options flags }
  AStream.WriteWord(WordToLE(MASK_FORMULA_RECALCULATE_ALWAYS));

  { Not used }
  AStream.WriteDWord(0);

  { Formula }

  { The size of the token array is written later,
    because it's necessary to calculate if first,
    and this is done at the same time it is written }
  TokenArraySizePos := AStream.Position;
  AStream.WriteWord(RPNLength);

  { Formula data (RPN token array) }
  for i := 0 to Length(AFormula) - 1 do
  begin
    { Token identifier }
    TokenID := FormulaElementKindToExcelTokenID(AFormula[i].ElementKind, lSecondaryID);
    AStream.WriteByte(TokenID);
    Inc(RPNLength);

    { Additional data }
    case TokenID of
    { Operand Tokens }
    INT_EXCEL_TOKEN_TREFR, INT_EXCEL_TOKEN_TREFV, INT_EXCEL_TOKEN_TREFA: { fekCell }
    begin
      AStream.WriteWord(AFormula[i].Row);
      AStream.WriteWord(AFormula[i].Col and MASK_EXCEL_COL_BITS_BIFF8);
      Inc(RPNLength, 4);
    end;

    INT_EXCEL_TOKEN_TAREA_R: { fekCellRange }
    begin
      {
      Cell range address, BIFF8:
      Offset Size Contents
      0 2 Index to first row (0???65535) or offset of first row (method [B], -32768???32767)
      2 2 Index to last row (0???65535) or offset of last row (method [B], -32768???32767)
      4 2 Index to first column or offset of first column, with relative flags (see table above)
      6 2 Index to last column or offset of last column, with relative flags (see table above)
      }
      AStream.WriteWord(WordToLE(AFormula[i].Row));
      AStream.WriteWord(WordToLE(AFormula[i].Row2));
      AStream.WriteWord(WordToLE(AFormula[i].Col));
      AStream.WriteWord(WordToLE(AFormula[i].Col2));
      Inc(RPNLength, 8);
    end;

    INT_EXCEL_TOKEN_TNUM: { fekNum }
    begin
      AStream.WriteBuffer(AFormula[i].DoubleValue, 8);
      Inc(RPNLength, 8);
    end;

    { binary operation tokens }
    INT_EXCEL_TOKEN_TADD, INT_EXCEL_TOKEN_TSUB, INT_EXCEL_TOKEN_TMUL,
     INT_EXCEL_TOKEN_TDIV, INT_EXCEL_TOKEN_TPOWER: begin end;

    { Other operations }
    INT_EXCEL_TOKEN_TATTR: { fekOpSUM }
    begin
      // Uniry SUM Operation
      AStream.WriteByte($10);
      AStream.WriteByte(0);
      AStream.WriteByte(0);
      Inc(RPNLength, 3);
    end;

    // Functions
    INT_EXCEL_TOKEN_FUNC_R, INT_EXCEL_TOKEN_FUNC_V, INT_EXCEL_TOKEN_FUNC_A:
    begin
      AStream.WriteWord(lSecondaryID);
      Inc(RPNLength, 2);
    end;

    else
    end;
  end;

  { Write sizes in the end, after we known them }
  FinalPos := AStream.Position;
  AStream.position := TokenArraySizePos;
  AStream.WriteByte(RPNLength);
  AStream.Position := RecordSizePos;
  AStream.WriteWord(WordToLE(22 + RPNLength));
  AStream.position := FinalPos;
end;

{*******************************************************************
*  TsSpreadBIFF8Writer.WriteIndex ()
*
*  DESCRIPTION:    Writes an Excel 8 INDEX record
*
*                  nm = (rl - rf - 1) / 32 + 1 (using integer division)
*
*******************************************************************}
procedure TsSpreadBIFF8Writer.WriteIndex(AStream: TStream);
begin
  { BIFF Record header }
  AStream.WriteWord(WordToLE(INT_EXCEL_ID_INDEX));
  AStream.WriteWord(WordToLE(16));

  { Not used }
  AStream.WriteDWord(DWordToLE(0));

  { Index to first used row, rf, 0 based }
  AStream.WriteDWord(DWordToLE(0));

  { Index to first row of unused tail of sheet, rl, last used row + 1, 0 based }
  AStream.WriteDWord(DWordToLE(0));

  { Absolute stream position of the DEFCOLWIDTH record of the current sheet.
    If it doesn't exist, the offset points to where it would occur. }
  AStream.WriteDWord(DWordToLE($00));

  { Array of nm absolute stream positions of the DBCELL record of each Row Block }
  
  { OBS: It seems to be no problem just ignoring this part of the record }
end;

{*******************************************************************
*  TsSpreadBIFF8Writer.WriteLabel ()
*
*  DESCRIPTION:    Writes an Excel 8 LABEL record
*
*                  Writes a string to the sheet
*                  If the string length exceeds 32758 bytes, the string
*                  will be silently truncated.
*
*******************************************************************}
procedure TsSpreadBIFF8Writer.WriteLabel(AStream: TStream; const ARow,
  ACol: Cardinal; const AValue: string; ACell: PCell);
const
  //limit for this format: 32767 bytes - header (see reclen below):
  //37267-8-1=32758
  MaxBytes=32758;
var
  L, RecLen: Word;
  TextTooLong: boolean=false;
  WideValue: WideString;
begin
  WideValue := UTF8Decode(AValue); //to UTF16
  if WideValue = '' then
  begin
    // Badly formatted UTF8String (maybe ANSI?)
    if Length(AValue)<>0 then begin
      //Quite sure it was an ANSI string written as UTF8, so raise exception.
      Raise Exception.CreateFmt('Expected UTF8 text but probably ANSI text found in cell [%d,%d]',[ARow,ACol]);
    end;
    Exit;
  end;

  if Length(WideValue)>MaxBytes then
  begin
    // Rather than lose data when reading it, let the application programmer deal
    // with the problem or purposefully ignore it.
    TextTooLong := true;
    SetLength(WideValue,MaxBytes); //may corrupt the string (e.g. in surrogate pairs), but... too bad.
  end;
  L := Length(WideValue);

  { BIFF Record header }
  AStream.WriteWord(WordToLE(INT_EXCEL_ID_LABEL));
  RecLen := 8 + 1 + L * SizeOf(WideChar);
  AStream.WriteWord(WordToLE(RecLen));

  { BIFF Record data }
  AStream.WriteWord(WordToLE(ARow));
  AStream.WriteWord(WordToLE(ACol));

  { Index to XF record, according to formatting }
  WriteXFIndex(AStream, ACell);

  { Byte String with 16-bit size }
  AStream.WriteWord(WordToLE(L));

  { Byte flags. 1 means regular Unicode LE encoding}
  AStream.WriteByte(1);
  AStream.WriteBuffer(WideStringToLE(WideValue)[1], L * Sizeof(WideChar));

  {
  //todo: keep a log of errors and show with an exception after writing file or something.
  We can't just do the following
  if TextTooLong then
    Raise Exception.CreateFmt('Text value exceeds %d character limit in cell [%d,%d]. Text has been truncated.',[MaxBytes,ARow,ACol]);
  because the file wouldn't be written.
  }
end;

{*******************************************************************
*  TsSpreadBIFF8Writer.WriteNumber ()
*
*  DESCRIPTION:    Writes an Excel 8 NUMBER record
*
*                  Writes a number (64-bit floating point) to the sheet
*
*******************************************************************}
procedure TsSpreadBIFF8Writer.WriteNumber(AStream: TStream; const ARow,
  ACol: Cardinal; const AValue: double; ACell: PCell);
begin
  { BIFF Record header }
  AStream.WriteWord(WordToLE(INT_EXCEL_ID_NUMBER));
  AStream.WriteWord(WordToLE(14)); //total record size

  { BIFF Record data }
  AStream.WriteWord(WordToLE(ARow));
  AStream.WriteWord(WordToLE(ACol));

  { Index to XF record, according to formatting }
  WriteXFIndex(AStream, ACell);

  { IEE 754 floating-point value (is different in BIGENDIAN???) }
  AStream.WriteBuffer(AValue, 8);
end;

procedure TsSpreadBIFF8Writer.WritePalette(AStream: TStream);
begin
  { BIFF Record header }
  AStream.WriteWord(WordToLE(INT_EXCEL_ID_PALETTE));
  AStream.WriteWord(WordToLE(2+4*56));

  { Number of colors }
  AStream.WriteWord(WordToLE(56));

  { Now the colors, first the standard 16 from Excel }
  AStream.WriteDWord(DWordToLE($000000)); // $08
  AStream.WriteDWord(DWordToLE($FFFFFF));
  AStream.WriteDWord(DWordToLE($FF0000));
  AStream.WriteDWord(DWordToLE($00FF00));
  AStream.WriteDWord(DWordToLE($0000FF));
  AStream.WriteDWord(DWordToLE($FFFF00));
  AStream.WriteDWord(DWordToLE($FF00FF));
  AStream.WriteDWord(DWordToLE($00FFFF));
  AStream.WriteDWord(DWordToLE($800000));
  AStream.WriteDWord(DWordToLE($008000));
  AStream.WriteDWord(DWordToLE($000080));
  AStream.WriteDWord(DWordToLE($808000));
  AStream.WriteDWord(DWordToLE($800080));
  AStream.WriteDWord(DWordToLE($008080));
  AStream.WriteDWord(DWordToLE($C0C0C0));
  AStream.WriteDWord(DWordToLE($808080)); //$17

  { Now some colors which we define ourselves }

  AStream.WriteDWord(DWordToLE($E6E6E6)); //$18 //todo: shouldn't we write $18..$3F and add this color later? see 5.74.3 Built-In Default Colour Tables
  AStream.WriteDWord(DWordToLE($CCCCCC)); //$19 //todo: shouldn't we write $18..$3F and add this color later? see 5.74.3 Built-In Default Colour Tables

  { And padding }
  AStream.WriteDWord(DWordToLE($FFFFFF));
  AStream.WriteDWord(DWordToLE($FFFFFF));
  AStream.WriteDWord(DWordToLE($FFFFFF));
  AStream.WriteDWord(DWordToLE($FFFFFF));
  AStream.WriteDWord(DWordToLE($FFFFFF));
  AStream.WriteDWord(DWordToLE($FFFFFF));

  AStream.WriteDWord(DWordToLE($FFFFFF)); //$20
  AStream.WriteDWord(DWordToLE($FFFFFF));
  AStream.WriteDWord(DWordToLE($FFFFFF));
  AStream.WriteDWord(DWordToLE($FFFFFF));
  AStream.WriteDWord(DWordToLE($FFFFFF));
  AStream.WriteDWord(DWordToLE($FFFFFF));
  AStream.WriteDWord(DWordToLE($FFFFFF));
  AStream.WriteDWord(DWordToLE($FFFFFF));

  AStream.WriteDWord(DWordToLE($FFFFFF));
  AStream.WriteDWord(DWordToLE($FFFFFF));
  AStream.WriteDWord(DWordToLE($FFFFFF));
  AStream.WriteDWord(DWordToLE($FFFFFF));
  AStream.WriteDWord(DWordToLE($FFFFFF));
  AStream.WriteDWord(DWordToLE($FFFFFF));
  AStream.WriteDWord(DWordToLE($FFFFFF));
  AStream.WriteDWord(DWordToLE($FFFFFF));

  AStream.WriteDWord(DWordToLE($FFFFFF)); //$30
  AStream.WriteDWord(DWordToLE($FFFFFF));
  AStream.WriteDWord(DWordToLE($FFFFFF));
  AStream.WriteDWord(DWordToLE($FFFFFF));
  AStream.WriteDWord(DWordToLE($FFFFFF));
  AStream.WriteDWord(DWordToLE($FFFFFF));
  AStream.WriteDWord(DWordToLE($FFFFFF));
  AStream.WriteDWord(DWordToLE($FFFFFF));

  AStream.WriteDWord(DWordToLE($FFFFFF));
  AStream.WriteDWord(DWordToLE($FFFFFF));
  AStream.WriteDWord(DWordToLE($FFFFFF));
  AStream.WriteDWord(DWordToLE($FFFFFF));
  AStream.WriteDWord(DWordToLE($FFFFFF));
  AStream.WriteDWord(DWordToLE($FFFFFF));
  AStream.WriteDWord(DWordToLE($FFFFFF));
  AStream.WriteDWord(DWordToLE($FFFFFF));
end;

{*******************************************************************
*  TsSpreadBIFF8Writer.WriteStyle ()
*
*  DESCRIPTION:    Writes an Excel 8 STYLE record
*
*                  Registers the name of a user-defined style or
*                  specific options for a built-in cell style.
*
*******************************************************************}
procedure TsSpreadBIFF8Writer.WriteStyle(AStream: TStream);
begin
  { BIFF Record header }
  AStream.WriteWord(WordToLE(INT_EXCEL_ID_STYLE));
  AStream.WriteWord(WordToLE(4));

  { Index to style XF and defines if it's a built-in or used defined style }
  AStream.WriteWord(WordToLE(MASK_STYLE_BUILT_IN));

  { Built-in cell style identifier }
  AStream.WriteByte($00);

  { Level if the identifier for a built-in style is RowLevel or ColLevel, $FF otherwise }
  AStream.WriteByte($FF);
end;

{*******************************************************************
*  TsSpreadBIFF8Writer.WriteWindow1 ()
*
*  DESCRIPTION:    Writes an Excel 8 WINDOW1 record
*
*                  This record contains general settings for the
*                  document window and global workbook settings.
*
*                  The values written here are reasonable defaults,
*                  which should work for most sheets.
*
*******************************************************************}
procedure TsSpreadBIFF8Writer.WriteWindow1(AStream: TStream);
begin
  { BIFF Record header }
  AStream.WriteWord(WordToLE(INT_EXCEL_ID_WINDOW1));
  AStream.WriteWord(WordToLE(18));

  { Horizontal position of the document window, in twips = 1 / 20 of a point }
  AStream.WriteWord(WordToLE(0));

  { Vertical position of the document window, in twips = 1 / 20 of a point }
  AStream.WriteWord(WordToLE($0069));

  { Width of the document window, in twips = 1 / 20 of a point }
  AStream.WriteWord(WordToLE($339F));

  { Height of the document window, in twips = 1 / 20 of a point }
  AStream.WriteWord(WordToLE($1B5D));

  { Option flags }
  AStream.WriteWord(WordToLE(
   MASK_WINDOW1_OPTION_HORZ_SCROLL_VISIBLE or
   MASK_WINDOW1_OPTION_VERT_SCROLL_VISIBLE or
   MASK_WINDOW1_OPTION_WORKSHEET_TAB_VISIBLE));

  { Index to active (displayed) worksheet }
  AStream.WriteWord(WordToLE($00));

  { Index of first visible tab in the worksheet tab bar }
  AStream.WriteWord(WordToLE($00));

  { Number of selected worksheets }
  AStream.WriteWord(WordToLE(1));

  { Width of worksheet tab bar (in 1/1000 of window width).
    The remaining space is used by the horizontal scroll bar }
  AStream.WriteWord(WordToLE(600));
end;

{*******************************************************************
*  TsSpreadBIFF8Writer.WriteWindow2 ()
*
*  DESCRIPTION:    Writes an Excel 8 WINDOW2 record
*
*                  This record contains aditional settings for the
*                  document window (BIFF2-BIFF4) or for a specific
*                  worksheet (BIFF5-BIFF8).
*
*                  The values written here are reasonable defaults,
*                  which should work for most sheets.
*
*******************************************************************}
procedure TsSpreadBIFF8Writer.WriteWindow2(AStream: TStream;
 ASheetSelected: Boolean);
var
  Options: Word;
begin
  { BIFF Record header }
  AStream.WriteWord(WordToLE(INT_EXCEL_ID_WINDOW2));
  AStream.WriteWord(WordToLE(18));

  { Options flags }
  Options := MASK_WINDOW2_OPTION_SHOW_GRID_LINES or
   MASK_WINDOW2_OPTION_SHOW_SHEET_HEADERS or
   MASK_WINDOW2_OPTION_SHOW_ZERO_VALUES or
   MASK_WINDOW2_OPTION_AUTO_GRIDLINE_COLOR or
   MASK_WINDOW2_OPTION_SHOW_OUTLINE_SYMBOLS or
   MASK_WINDOW2_OPTION_SHEET_ACTIVE;

  if ASheetSelected then Options := Options or MASK_WINDOW2_OPTION_SHEET_SELECTED;

  AStream.WriteWord(WordToLE(Options));

  { Index to first visible row }
  AStream.WriteWord(WordToLE(0));

  { Index to first visible column }
  AStream.WriteWord(WordToLE(0));

  { Grid line index colour }
  AStream.WriteWord(WordToLE(0));

  { Not used }
  AStream.WriteWord(WordToLE(0));

  { Cached magnification factor in page break preview (in percent); 0 = Default (60%) }
  AStream.WriteWord(WordToLE(0));

  { Cached magnification factor in normal view (in percent); 0 = Default (100%) }
  AStream.WriteWord(WordToLE(0));

  { Not used }
  AStream.WriteDWord(DWordToLE(0));
end;

{*******************************************************************
*  TsSpreadBIFF8Writer.WriteXF ()
*
*  DESCRIPTION:    Writes an Excel 8 XF record
*
*
*
*******************************************************************}
procedure TsSpreadBIFF8Writer.WriteXF(AStream: TStream; AFontIndex: Word;
 AFormatIndex: Word; AXF_TYPE_PROT, ATextRotation: Byte; ABorders: TsCellBorders;
 AddBackground: Boolean = False; ABackgroundColor: TsColor = scSilver);
var
  XFOptions: Word;
  XFAlignment, XFOrientationAttrib: Byte;
  XFBorderDWord1, XFBorderDWord2: DWord;
begin
  { BIFF Record header }
  AStream.WriteWord(WordToLE(INT_EXCEL_ID_XF));
  AStream.WriteWord(WordToLE(20));

  { Index to FONT record }
  AStream.WriteWord(WordToLE(AFontIndex));

  { Index to FORMAT record }
  AStream.WriteWord(WordToLE(AFormatIndex));

  { XF type, cell protection and parent style XF }
  XFOptions := AXF_TYPE_PROT and MASK_XF_TYPE_PROT;

  if AXF_TYPE_PROT and MASK_XF_TYPE_PROT_STYLE_XF <> 0 then
   XFOptions := XFOptions or MASK_XF_TYPE_PROT_PARENT;
   
  AStream.WriteWord(WordToLE(XFOptions));

  { Alignment and text break }
  XFAlignment := MASK_XF_VERT_ALIGN_BOTTOM;

  AStream.WriteByte(XFAlignment);

  { Text rotation }
  AStream.WriteByte(ATextRotation); // 0 is horizontal / normal

  { Indentation, shrink and text direction }
  AStream.WriteByte(0);

  { Used attributes }
  XFOrientationAttrib :=
   MASK_XF_USED_ATTRIB_NUMBER_FORMAT or
   MASK_XF_USED_ATTRIB_FONT or
   MASK_XF_USED_ATTRIB_TEXT or
   MASK_XF_USED_ATTRIB_BORDER_LINES or
   MASK_XF_USED_ATTRIB_BACKGROUND or
   MASK_XF_USED_ATTRIB_CELL_PROTECTION;

  AStream.WriteByte(XFOrientationAttrib);

  { Cell border lines and background area }

  // Left and Right line colors, use black
  XFBorderDWord1 := 8 * $10000 {left line - black} + 8 * $800000 {right line - black};

  if cbNorth in ABorders then XFBorderDWord1 := XFBorderDWord1 or $100;
  if cbWest in ABorders  then XFBorderDWord1 := XFBorderDWord1 or $1;
  if cbEast in ABorders  then XFBorderDWord1 := XFBorderDWord1 or $10;
  if cbSouth in ABorders then XFBorderDWord1 := XFBorderDWord1 or $1000;

  AStream.WriteDWord(DWordToLE(XFBorderDWord1));

  // Top and Bottom line colors, use black
  XFBorderDWord2 := 8 {top line - black} + 8 * $80 {bottom line - black};
  // Add a background, if desired
  if AddBackground then XFBorderDWord2 := XFBorderDWord2 or $4000000;
  AStream.WriteDWord(DWordToLE(XFBorderDWord2));
  // Background Pattern Color, always zeroed
  if AddBackground then AStream.WriteWord(WordToLE(FPSColorToEXCELPalette(ABackgroundColor)))
  else AStream.WriteWord(0);
end;

{ TsSpreadBIFF8Reader }

function TsSpreadBIFF8Reader.DecodeRKValue(const ARK: DWORD): Double;
var
  Number: Double;
  Tmp: LongInt;
begin
  if ARK and 2 = 2 then begin
    // Signed integer value
    if LongInt(ARK)<0 then begin
      //Simulates a sar
      Tmp:=LongInt(ARK)*-1;
      Tmp:=Tmp shr 2;
      Tmp:=Tmp*-1;
      Number:=Tmp-1;
    end else begin
      Number:=ARK shr 2;
    end;
  end else begin
    // Floating point value
    // NOTE: This is endian dependent and IEEE dependent (Not checked) (working win-i386)
    (PDWORD(@Number))^:= $00000000;
    (PDWORD(@Number)+1)^:=(ARK and $FFFFFFFC);
  end;
  if ARK and 1 = 1 then begin
    // Encoded value is multiplied by 100
    Number:=Number / 100;
  end;
  Result:=Number;
end;

function TsSpreadBIFF8Reader.IsDate(Number: Double;
  ARow: WORD; ACol: WORD; AXFIndex: WORD; var ADateTime: TDateTime): boolean;
// Try to find out if a cell has a date/time and return
// TheDate if it is
var
  lFormatData: TFormatRecordData;
  lXFData: TXFRecordData;
begin
  result := false;
  // Try to figure out if the number is really a number of a date or time value
  // See: http://www.gaia-gis.it/FreeXL/freexl-1.0.0a-doxy-doc/Format.html
  // Unfornately Excel doesnt give us a direct way to find this,
  // we need to guess by the FORMAT field
  // Note FindFormatRecordForCell will not retrieve default format numbers
  lFormatData := FindFormatRecordForCell(AXFIndex);
  {Record FORMAT, BIFF8 (5.49):
  Offset Size Contents
       0    2 Format index used in other records
  }

  if lFormatData=nil then
  begin
    // No custom format, so first test for default formats
    lXFData := TXFRecordData(FXFList.Items[AXFIndex]);
    if (lXFData.FormatIndex in [14..22, 27..36, 45, 46, 47, 50..58]) then
    begin
      ADateTime := ConvertExcelDateTimeToDateTime(Number, FDateMode);
      Exit(true);
    end;
  end
  else
  begin
    // Check custom formats if they
    // have / in format string (this can fail for custom text formats)
    if (Pos('/', lFormatData.FormatString) > 0) then
    begin
      ADateTime := ConvertExcelDateTimeToDateTime(Number, FDateMode);
      Exit(true);
    end;
  end;
  ADateTime := 0;
end;

function TsSpreadBIFF8Reader.ReadWideString(const AStream: TStream;
  const ALength: WORD): WideString;
var
  StringFlags: BYTE;
  DecomprStrValue: WideString;
  AnsiStrValue: ansistring;
  RunsCounter: WORD;
  AsianPhoneticBytes: DWORD;
  i: Integer;
  j: SizeUInt;
  lLen: SizeInt;
  RecordType: WORD;
  RecordSize: WORD;
  C: char;
begin
  StringFlags:=AStream.ReadByte;
  Dec(PendingRecordSize);
  if StringFlags and 4 = 4 then begin
    //Asian phonetics
    //Read Asian phonetics Length (not used)
    AsianPhoneticBytes:=DWordLEtoN(AStream.ReadDWord);
  end;
  if StringFlags and 8 = 8 then begin
    //Rich string
    RunsCounter:=WordLEtoN(AStream.ReadWord);
    dec(PendingRecordSize,2);
  end;
  if StringFlags and 1 = 1 Then begin
    //String is WideStringLE
    if (ALength*SizeOf(WideChar)) > PendingRecordSize then begin
      SetLength(Result,PendingRecordSize div 2);
      AStream.ReadBuffer(Result[1],PendingRecordSize);
      Dec(PendingRecordSize,PendingRecordSize);
    end else begin
      SetLength(Result,ALength);
      AStream.ReadBuffer(Result[1],ALength * SizeOf(WideChar));
      Dec(PendingRecordSize,ALength * SizeOf(WideChar));
    end;
    Result:=WideStringLEToN(Result);
  end else begin
    //String is 1 byte per char, this is UTF-16 with the high byte ommited because it is zero
    //so decompress and then convert
    lLen:=ALength;
    SetLength(DecomprStrValue, lLen);
    for i := 1 to lLen do
    begin
      C:=WideChar(AStream.ReadByte());
      DecomprStrValue[i] := C;
      Dec(PendingRecordSize);
      if (PendingRecordSize<=0) and (i<lLen) then begin
        //A CONTINUE may happend here
        RecordType := WordLEToN(AStream.ReadWord);
        RecordSize := WordLEToN(AStream.ReadWord);
        if RecordType<>INT_EXCEL_ID_CONTINUE then begin
          Raise Exception.Create('[TsSpreadBIFF8Reader.ReadWideString] Expected CONTINUE record not found.');
        end else begin
          PendingRecordSize:=RecordSize;
          DecomprStrValue:=copy(DecomprStrValue,1,i)+ReadWideString(AStream,ALength-i);
          break;
        end;
      end;
    end;

    Result := DecomprStrValue;
  end;
  if StringFlags and 8 = 8 then begin
    //Rich string (This only happend in BIFF8)
    for j := 1 to RunsCounter do begin
      if (PendingRecordSize<=0) then begin
        //A CONTINUE may happend here
        RecordType := WordLEToN(AStream.ReadWord);
        RecordSize := WordLEToN(AStream.ReadWord);
        if RecordType<>INT_EXCEL_ID_CONTINUE then begin
          Raise Exception.Create('[TsSpreadBIFF8Reader.ReadWideString] Expected CONTINUE record not found.');
        end else begin
          PendingRecordSize:=RecordSize;
        end;
      end;
      AStream.ReadWord;
      AStream.ReadWord;
      dec(PendingRecordSize,2*2);
    end;
  end;
  if StringFlags and 4 = 4 then begin
    //Asian phonetics
    //Read Asian phonetics, discarded as not used.
    SetLength(AnsiStrValue,AsianPhoneticBytes);
    AStream.ReadBuffer(AnsiStrValue[1],AsianPhoneticBytes);
  end;
end;

function TsSpreadBIFF8Reader.ReadWideString(const AStream: TStream;
  const AUse8BitLength: Boolean): WideString;
var
  Len: Word;
  WideName: WideString;
begin
  if AUse8BitLength then
    Len := AStream.ReadByte()
  else
    Len := WordLEtoN(AStream.ReadWord());

  Result := ReadWideString(AStream, Len);
end;

procedure TsSpreadBIFF8Reader.ReadWorkbookGlobals(AStream: TStream;
  AData: TsWorkbook);
var
  SectionEOF: Boolean = False;
  RecordType: Word;
  CurStreamPos: Int64;
begin
  if Assigned(FSharedStringTable) then FreeAndNil(FSharedStringTable);
  while (not SectionEOF) do
  begin
    { Read the record header }
    RecordType := WordLEToN(AStream.ReadWord);
    RecordSize := WordLEToN(AStream.ReadWord);
    PendingRecordSize:=RecordSize;

    CurStreamPos := AStream.Position;

    if RecordType<>INT_EXCEL_ID_CONTINUE then begin
      case RecordType of
       INT_EXCEL_ID_BOF:        ;
       INT_EXCEL_ID_BOUNDSHEET: ReadBoundSheet(AStream);
       INT_EXCEL_ID_EOF:        SectionEOF := True;
       INT_EXCEL_ID_SST:        ReadSST(AStream);
       INT_EXCEL_ID_CODEPAGE:   ReadCodepage(AStream);
       INT_EXCEL_ID_FONT:       ReadFont(AStream);
       INT_EXCEL_ID_XF:         ReadXF(AStream);
       INT_EXCEL_ID_FORMAT:     ReadFormat(AStream);
       INT_EXCEL_ID_DATEMODE:   ReadDateMode(AStream);
      else
        // nothing
      end;
    end;

    // Make sure we are in the right position for the next record
    AStream.Seek(CurStreamPos + RecordSize, soFromBeginning);

    // Check for the end of the file
    if AStream.Position >= AStream.Size then SectionEOF := True;
  end;
end;

procedure TsSpreadBIFF8Reader.ReadWorksheet(AStream: TStream; AData: TsWorkbook);
var
  SectionEOF: Boolean = False;
  RecordType: Word;
  CurStreamPos: Int64;
begin
  FWorksheet := AData.AddWorksheet(FWorksheetNames.Strings[FCurrentWorksheet]);

  while (not SectionEOF) do
  begin
    { Read the record header }
    RecordType := WordLEToN(AStream.ReadWord);
    RecordSize := WordLEToN(AStream.ReadWord);
    PendingRecordSize:=RecordSize;

    CurStreamPos := AStream.Position;

    case RecordType of

    INT_EXCEL_ID_NUMBER:  ReadNumber(AStream);
    INT_EXCEL_ID_LABEL:   ReadLabel(AStream);
    INT_EXCEL_ID_FORMULA: ReadFormula(AStream);
    //(RSTRING) This record stores a formatted text cell (Rich-Text).
    // In BIFF8 it is usually replaced by the LABELSST record. Excel still
    // uses this record, if it copies formatted text cells to the clipboard.
    INT_EXCEL_ID_RSTRING: ReadRichString(AStream);
    // (RK) This record represents a cell that contains an RK value
    // (encoded integer or floating-point value). If a floating-point
    // value cannot be encoded to an RK value, a NUMBER record will be written.
    // This record replaces the record INTEGER written in BIFF2.
    INT_EXCEL_ID_RK:      ReadRKValue(AStream);
    INT_EXCEL_ID_MULRK:   ReadMulRKValues(AStream);
    INT_EXCEL_ID_LABELSST:ReadLabelSST(AStream); //BIFF8 only
    INT_EXCEL_ID_BOF:     ;
    INT_EXCEL_ID_EOF:     SectionEOF := True;
    else
      // nothing
    end;

    // Make sure we are in the right position for the next record
    AStream.Seek(CurStreamPos + RecordSize, soFromBeginning);

    // Check for the end of the file
    if AStream.Position >= AStream.Size then SectionEOF := True;
  end;
end;

procedure TsSpreadBIFF8Reader.ReadBoundsheet(AStream: TStream);
var
  Len: Byte;
  WideName: WideString;
begin
  { Absolute stream position of the BOF record of the sheet represented
    by this record }
  // Just assume that they are in order
  AStream.ReadDWord();

  { Visibility }
  AStream.ReadByte();

  { Sheet type }
  AStream.ReadByte();

  { Sheet name: 8-bit length }
  Len := AStream.ReadByte();

  { Read string with flags }
  WideName:=ReadWideString(AStream,Len);

  FWorksheetNames.Add(UTF8Encode(WideName));
end;

procedure TsSpreadBIFF8Reader.ReadRKValue(const AStream: TStream);
var
  RK: DWORD;
  ARow, ACol, XF: WORD;
  lDateTime: TDateTime;
  Number: Double;
begin
  {Retrieve XF record, row and column}
  ReadRowColXF(AStream,ARow,ACol,XF);

  {Encoded RK value}
  RK:=DWordLEtoN(AStream.ReadDWord);

  {Check RK codes}
  Number:=DecodeRKValue(RK);

  {Find out what cell type, set contenttype and value}
  if IsDate(Number, ARow, ACol, XF, lDateTime) then
    FWorksheet.WriteDateTime(ARow, ACol, lDateTime)
  else
    FWorksheet.WriteNumber(ARow,ACol,Number);
end;

procedure TsSpreadBIFF8Reader.ReadMulRKValues(const AStream: TStream);
var
  ARow, fc,lc,XF: Word;
  lDateTime: TDateTime;
  Pending: integer;
  RK: DWORD;
  Number: Double;
begin
  ARow:=WordLEtoN(AStream.ReadWord);
  fc:=WordLEtoN(AStream.ReadWord);
  Pending:=RecordSize-sizeof(fc)-Sizeof(ARow);
  while Pending > (sizeof(XF)+sizeof(RK)) do begin
    XF:=AStream.ReadWord; //XF record (used for date checking)
    RK:=DWordLEtoN(AStream.ReadDWord);
    Number:=DecodeRKValue(RK);
    {Find out what cell type, set contenttype and value}
    if IsDate(Number, ARow, fc, XF, lDateTime) then
      FWorksheet.WriteDateTime(ARow, fc, lDateTime)
    else
      FWorksheet.WriteNumber(ARow,fc,Number);
    inc(fc);
    dec(Pending,(sizeof(XF)+sizeof(RK)));
  end;
  if Pending=2 then begin
    //Just for completeness
    lc:=WordLEtoN(AStream.ReadWord);
    if lc+1<>fc then begin
      //Stream error... bypass by now
    end;
  end;
end;

procedure TsSpreadBIFF8Reader.ReadRowColXF(const AStream: TStream; out ARow,
  ACol, AXF: WORD);
begin
  { BIFF Record data }
  ARow := WordLEToN(AStream.ReadWord);
  ACol := WordLEToN(AStream.ReadWord);

  { Index to XF record }
  AXF:=WordLEtoN(AStream.ReadWord);
end;

function TsSpreadBIFF8Reader.ReadString(const AStream: TStream;
  const ALength: WORD): UTF8String;
begin
  Result:=UTF16ToUTF8(ReadWideString(AStream, ALength));
end;

constructor TsSpreadBIFF8Reader.Create;
begin
  inherited Create;
  FXFList := TFPList.Create;
  FFormatList := TFPList.Create;
end;

destructor TsSpreadBIFF8Reader.Destroy;
var
  j: integer;
begin
  for j := FXFList.Count-1 downto 0 do TObject(FXFList[j]).Free;
  for j := FFormatList.Count-1 downto 0 do TObject(FFormatList[j]).Free;
  FXFList.Free;
  FFormatList.Free;
  if Assigned(FSharedStringTable) then FSharedStringTable.Free;
end;

procedure TsSpreadBIFF8Reader.ReadFromFile(AFileName: string; AData: TsWorkbook);
var
  MemStream: TMemoryStream;
  OLEStorage: TOLEStorage;
  OLEDocument: TOLEDocument;
begin
  MemStream := TMemoryStream.Create;
  OLEStorage := TOLEStorage.Create;
  try
    // Only one stream is necessary for any number of worksheets
    OLEDocument.Stream := MemStream;
    OLEStorage.ReadOLEFile(AFileName, OLEDocument,'Workbook');

    // Check if the operation succeded
    if MemStream.Size = 0 then raise Exception.Create('FPSpreadsheet: Reading the OLE document failed');

    // Rewind the stream and read from it
    MemStream.Position := 0;
    ReadFromStream(MemStream, AData);

//    Uncomment to verify if the data was correctly optained from the OLE file
//    MemStream.SaveToFile(SysUtils.ChangeFileExt(AFileName, 'bin.xls'));
  finally
    MemStream.Free;
    OLEStorage.Free;
  end;
end;

procedure TsSpreadBIFF8Reader.ReadFromStream(AStream: TStream; AData: TsWorkbook);
var
  BIFF8EOF: Boolean;
begin
  { Initializations }

  FWorksheetNames := TStringList.Create;
  FWorksheetNames.Clear;
  FCurrentWorksheet := 0;
  BIFF8EOF := False;

  { Read workbook globals }

  ReadWorkbookGlobals(AStream, AData);

  // Check for the end of the file
  if AStream.Position >= AStream.Size then BIFF8EOF := True;

  { Now read all worksheets }

  while (not BIFF8EOF) do
  begin
    //Safe to not read beyond assigned worksheet names.
    if FCurrentWorksheet>FWorksheetNames.Count-1 then break;

    ReadWorksheet(AStream, AData);

    // Check for the end of the file
    if AStream.Position >= AStream.Size then BIFF8EOF := True;

    // Final preparations
    Inc(FCurrentWorksheet);
  end;

  { Finalizations }

  FWorksheetNames.Free;
end;

procedure TsSpreadBIFF8Reader.ReadFormula(AStream: TStream);
var
  ARow, ACol, XF: WORD;
  ResultFormula: Double;
  Data: array [0..7] of BYTE;
  Flags: WORD;
  FormulaSize: BYTE;
  i: Integer;
begin
  { BIFF Record header }
  { BIFF Record data }
  { Index to XF Record }
  ReadRowColXF(AStream,ARow,ACol,XF);

  { Result of the formula in IEE 754 floating-point value }
  AStream.ReadBuffer(Data,Sizeof(Data));

  { Options flags }
  Flags:=WordLEtoN(AStream.ReadWord);

  { Not used }
  AStream.ReadDWord;

  { Formula size }
  FormulaSize := WordLEtoN(AStream.ReadWord);

  { Formula data, output as debug info }
{  Write('Formula Element: ');
  for i := 1 to FormulaSize do
    Write(IntToHex(AStream.ReadByte, 2) + ' ');
  WriteLn('');}

  //RPN data not used by now
  AStream.Position:=AStream.Position+FormulaSize;

  if SizeOf(Double)<>8 then Raise Exception.Create('Double is not 8 bytes');
  Move(Data[0],ResultFormula,sizeof(Data));
  FWorksheet.WriteNumber(ARow,ACol,ResultFormula);
end;

procedure TsSpreadBIFF8Reader.ReadLabel(AStream: TStream);
var
  L: Word;
  StringFlags: BYTE;
  ARow, ACol: Word;
  WideStrValue: WideString;
  AnsiStrValue: AnsiString;
begin
  { BIFF Record data }
  ARow := WordLEToN(AStream.ReadWord);
  ACol := WordLEToN(AStream.ReadWord);

  { Index to XF record, not used }
  AStream.ReadWord();

  { Byte String with 16-bit size }
  L := WordLEtoN(AStream.ReadWord());

  { Read string with flags }
  WideStrValue:=ReadWideString(AStream,L);

  { Save the data }
  FWorksheet.WriteUTF8Text(ARow, ACol, UTF16ToUTF8(WideStrValue));
end;

procedure TsSpreadBIFF8Reader.ReadNumber(AStream: TStream);
// Tries to read number from stream and write result to worksheet.
// Needs to check if a number is actually a date format
var
  ARow, ACol, XF: Word;
  AValue: Double;
  lDateTime: TDateTime;
begin
  {Retrieve XF record, row and column}
  ReadRowColXF(AStream,ARow,ACol,XF);

  { IEE 754 floating-point value }
  AStream.ReadBuffer(AValue, 8);

  {Find out what cell type, set contenttype and value}
  if IsDate(AValue, ARow, ACol, XF, lDateTime) then
    FWorksheet.WriteDateTime(ARow, ACol, lDateTime)
  else
    FWorksheet.WriteNumber(ARow,ACol,AValue);
end;

procedure TsSpreadBIFF8Reader.ReadRichString(const AStream: TStream);
var
  L: Word;
  B: WORD;
  ARow, ACol, XF: Word;
  AStrValue: ansistring;
begin
  ReadRowColXF(AStream,ARow,ACol,XF);

  { Byte String with 16-bit size }
  L := WordLEtoN(AStream.ReadWord());
  AStrValue:=ReadString(AStream,L);

  { Save the data }
  FWorksheet.WriteUTF8Text(ARow, ACol, AStrValue);
  //Read formatting runs (not supported)
  B:=WordLEtoN(AStream.ReadWord);
  for L := 0 to B-1 do begin
    AStream.ReadWord; // First formatted character
    AStream.ReadWord; // Index to FONT record
  end;
end;

procedure TsSpreadBIFF8Reader.ReadSST(const AStream: TStream);
var
  Items: DWORD;
  StringLength, CurStrLen: WORD;
  LString: String;
  ContinueIndicator: WORD;
begin
  //Reads the shared string table, only compatible with BIFF8
  if not Assigned(FSharedStringTable) then begin
    //First time SST creation
    FSharedStringTable:=TStringList.Create;

    DWordLEtoN(AStream.ReadDWord); //Apparences not used
    Items:=DWordLEtoN(AStream.ReadDWord);
    Dec(PendingRecordSize,8);
  end else begin
    //A second record must not happend. Garbage so skip.
    Exit;
  end;
  while Items>0 do begin
    StringLength:=0;
    StringLength:=WordLEtoN(AStream.ReadWord);
    Dec(PendingRecordSize,2);
    LString:='';

    // This loop takes care of the string being split between the STT and the CONTINUE, or between CONTINUE records
    while PendingRecordSize>0 do
    begin
      if StringLength>0 then
      begin
        //Read a stream of zero length reads all the stream.
        LString:=LString+ReadString(AStream, StringLength);
      end
      else
      begin
        //String of 0 chars in length, so just read it empty, reading only the mandatory flags
        AStream.ReadByte; //And discard it.
        Dec(PendingRecordSize);
        //LString:=LString+'';
      end;

      // Check if the record finished and we need a CONTINUE record to go on
      if (PendingRecordSize<=0) and (Items>1) then
      begin
        //A Continue will happend, read the
        //tag and continue linking...
        ContinueIndicator:=WordLEtoN(AStream.ReadWord);
        if ContinueIndicator<>INT_EXCEL_ID_CONTINUE then begin
          Raise Exception.Create('[TsSpreadBIFF8Reader.ReadSST] Expected CONTINUE record not found.');
        end;
        PendingRecordSize:=WordLEtoN(AStream.ReadWord);
        CurStrLen := Length(UTF8ToUTF16(LString));
        if StringLength<CurStrLen then Exception.Create('[TsSpreadBIFF8Reader.ReadSST] StringLength<CurStrLen');
        Dec(StringLength, CurStrLen); //Dec the used chars
        if StringLength=0 then break;
      end else begin
        break;
      end;
    end;
    FSharedStringTable.Add(LString);
    {$ifdef XLSDEBUG}
    WriteLn('Adding shared string: ' + LString);
    {$endif}
    dec(Items);
  end;
end;

procedure TsSpreadBIFF8Reader.ReadLabelSST(const AStream: TStream);
var
  ACol,ARow,XF: WORD;
  SSTIndex: DWORD;
begin
  ReadRowColXF(AStream,ARow,ACol,XF);
  SSTIndex:=DWordLEtoN(AStream.ReadDWord);
  if SizeInt(SSTIndex)>=FSharedStringTable.Count then begin
    Raise Exception.CreateFmt('Index %d in SST out of range (0-%d)',[Integer(SSTIndex),FSharedStringTable.Count-1]);
  end;
  FWorksheet.WriteUTF8Text(ARow, ACol, FSharedStringTable[SSTIndex]);
end;

procedure TsSpreadBIFF8Reader.ReadXF(const AStream: TStream);
var
  lData: TXFRecordData;
begin
  lData := TXFRecordData.Create;

  // Record XF, BIFF8:
  // Offset Size Contents
  //      0    2 Index to FONT record (???5.45))
  WordLEtoN(AStream.ReadWord);

  //      2    2 Index to FORMAT record (???5.49))
  lData.FormatIndex := WordLEtoN(AStream.ReadWord);

  {  Offset Size Contents
          4    2 XF type, cell protection, and parent style XF:
  Bit Mask Contents
  2-0 0007H XF_TYPE_PROT ??? XF type, cell protection (see above)
  15-4 FFF0H Index to parent style XF (always FFFH in style XFs)
  6 1 Alignment and text break:
  Bit Mask Contents
  2-0 07H XF_HOR_ALIGN ??? Horizontal alignment (see above)
  3 08H 1 = Text is wrapped at right border
  6-4 70H XF_VERT_ALIGN ??? Vertical alignment (see above)
  7 80H 1 = Justify last line in justified or distibuted text
  7 1 XF_ROTATION: Text rotation angle (see above)
  8 1 Indentation, shrink to cell size, and text direction:
  Bit Mask Contents
  3-0 0FH Indent level
  4 10H 1 = Shrink content to fit into cell
  7-6 C0H Text direction:
  0 = According to context
  35
  ; 1 = Left-to-right; 2 = Right-to-left
  9 1 Flags for used attribute groups:
  ....}

  // Add the XF to the list
  FXFList.Add(lData);
end;

procedure TsSpreadBIFF8Reader.ReadFormat(const AStream: TStream);
var
  lData: TFormatRecordData;
begin
  lData := TFormatRecordData.Create;

  // Record FORMAT, BIFF8 (5.49):
  // Offset Size Contents
  // 0 2 Format index used in other records
  // From BIFF5 on: indexes 0..163 are built in
  lData.Index := WordLEtoN(AStream.ReadWord);

  // 2 var. Number format string (Unicode string, 16-bit string length, ???2.5.3)
  lData.FormatString := ReadWideString(AStream, False);

  // Add to the list
  FFormatList.Add(lData);
end;

function TsSpreadBIFF8Reader.FindFormatRecordForCell(const AXFIndex: Integer
  ): TFormatRecordData;
var
  lXFData: TXFRecordData;
  lFormatData: TFormatRecordData;
  i: Integer;
begin
  Result := nil;
  lXFData := TXFRecordData(FXFList.Items[AXFIndex]);
  for i := 0 to FFormatList.Count-1 do
  begin
    lFormatData := TFormatRecordData(FFormatList.Items[i]);
    if lFormatData.Index = lXFData.FormatIndex then Exit(lFormatData);
  end;
end;

procedure TsSpreadBIFF8Reader.ReadFont(const AStream: TStream);
var
  lCodePage: Word;
  lHeight: Word;
  lOptions: Word;
  Len: Byte;
  lFontName: UTF8String;
begin
  { Height of the font in twips = 1/20 of a point }
  lHeight := AStream.ReadWord(); // WordToLE(200)

  { Option flags }
  lOptions := AStream.ReadWord();

  { Colour index }
  AStream.ReadWord();

  { Font weight }
  AStream.ReadWord();

  { Escapement type }
  AStream.ReadWord();

  { Underline type }
  AStream.ReadByte();

  { Font family }
  AStream.ReadByte();

  { Character set }
  lCodepage := AStream.ReadByte();
  {$ifdef XLSDEBUG}
  WriteLn('Reading Font Codepage='+IntToStr(lCodepage));
  {$endif}

  { Not used }
  AStream.ReadByte();

  { Font name: Unicodestring, char count in 1 byte }
  Len := AStream.ReadByte();
  lFontName := ReadString(AStream, Len);
end;

{*******************************************************************
*  Initialization section
*
*  Registers this reader / writer on fpSpreadsheet
*
*******************************************************************}

initialization

  RegisterSpreadFormat(TsSpreadBIFF8Reader, TsSpreadBIFF8Writer, sfExcel8);

end.

