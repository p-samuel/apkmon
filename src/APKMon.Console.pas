unit APKMon.Console;

interface

uses
  Windows, SysUtils, Classes;

type
  TConsoleManager = class
  private
    FInputBuffer: string;
    FInputHandle: THandle;
    FOutputHandle: THandle;
    FScreenWidth: SmallInt;
    FScreenHeight: SmallInt;
    FPrompt: string;
    FInitialized: Boolean;
    procedure UpdateScreenSize;
    procedure MoveCursorTo(Row, Col: SmallInt);
    procedure ClearCurrentLine;
    procedure EnableANSI;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Initialize;
    procedure WriteLine(const Msg: string; const ColorCode: string = '');
    procedure WriteLineRaw(const Msg: string);
    function ReadLine: string;
    procedure RedrawInputLine;
    procedure ClearInputBuffer;
    property Prompt: string read FPrompt write FPrompt;
    property Initialized: Boolean read FInitialized;
  end;

var
  Console: TConsoleManager;

implementation

{ TConsoleManager }

constructor TConsoleManager.Create;
begin
  inherited Create;
  FInputBuffer := '';
  FPrompt := '> ';
  FInitialized := False;
  FInputHandle := GetStdHandle(STD_INPUT_HANDLE);
  FOutputHandle := GetStdHandle(STD_OUTPUT_HANDLE);
end;

destructor TConsoleManager.Destroy;
begin
  inherited Destroy;
end;

procedure TConsoleManager.EnableANSI;
var
  Mode: DWORD;
begin
  // Enable ANSI escape sequences on Windows 10+
  if GetConsoleMode(FOutputHandle, Mode) then
  begin
    Mode := Mode or $0004; // ENABLE_VIRTUAL_TERMINAL_PROCESSING
    SetConsoleMode(FOutputHandle, Mode);
  end;
end;

procedure TConsoleManager.UpdateScreenSize;
var
  Info: TConsoleScreenBufferInfo;
begin
  if GetConsoleScreenBufferInfo(FOutputHandle, Info) then
  begin
    FScreenWidth := Info.srWindow.Right - Info.srWindow.Left + 1;
    FScreenHeight := Info.srWindow.Bottom - Info.srWindow.Top + 1;
  end
  else
  begin
    FScreenWidth := 80;
    FScreenHeight := 25;
  end;
end;

procedure TConsoleManager.Initialize;
begin
  if FInitialized then
    Exit;
  EnableANSI;
  UpdateScreenSize;
  FInitialized := True;
end;

procedure TConsoleManager.MoveCursorTo(Row, Col: SmallInt);
begin
  // ANSI escape: ESC[row;colH (1-based)
  Write(#27'[', Row, ';', Col, 'H');
end;

procedure TConsoleManager.ClearCurrentLine;
begin
  // ANSI escape: ESC[2K clears entire line
  Write(#27'[2K');
end;

procedure TConsoleManager.RedrawInputLine;
var
  Info: TConsoleScreenBufferInfo;
  CurrentRow: SmallInt;
begin
  if not FInitialized then
    Exit;

  // Get current cursor position to know where we are
  if GetConsoleScreenBufferInfo(FOutputHandle, Info) then
    CurrentRow := Info.dwCursorPosition.Y + 1  // Convert to 1-based
  else
    CurrentRow := FScreenHeight;

  // Save cursor position
  Write(#27'[s');

  // Move to current row, column 1
  MoveCursorTo(CurrentRow, 1);

  // Clear the line and redraw prompt with buffer
  ClearCurrentLine;
  Write(FPrompt + FInputBuffer);

  // Restore cursor position to end of input
  MoveCursorTo(CurrentRow, SmallInt(Length(FPrompt) + Length(FInputBuffer) + 1));
end;

procedure TConsoleManager.WriteLine(const Msg: string; const ColorCode: string = '');
var
  Info: TConsoleScreenBufferInfo;
  CurrentRow: SmallInt;
  OutputLine: string;
begin
  if not FInitialized then
  begin
    // Fallback to simple output if not initialized
    if ColorCode <> '' then
      Writeln(ColorCode, Msg, #27'[0m')
    else
      Writeln(Msg);
    Exit;
  end;

  UpdateScreenSize;

  // Get current cursor position
  if GetConsoleScreenBufferInfo(FOutputHandle, Info) then
    CurrentRow := Info.dwCursorPosition.Y + 1
  else
    CurrentRow := FScreenHeight;

  // Save cursor
  Write(#27'[s');

  // Move to start of current line and clear it
  MoveCursorTo(CurrentRow, 1);
  ClearCurrentLine;

  // Build output line with optional color
  if ColorCode <> '' then
    OutputLine := ColorCode + Msg + #27'[0m'
  else
    OutputLine := Msg;

  // Print the message (this will scroll if at bottom)
  Writeln(OutputLine);

  // Now redraw the input prompt on the new current line
  Write(FPrompt + FInputBuffer);
end;

procedure TConsoleManager.WriteLineRaw(const Msg: string);
begin
  Writeln(Msg);
end;

procedure TConsoleManager.ClearInputBuffer;
begin
  FInputBuffer := '';
end;

function TConsoleManager.ReadLine: string;
var
  InputRecord: TInputRecord;
  EventsRead: DWORD;
  Ch: Char;
  Key: Word;
begin
  FInputBuffer := '';

  // Set console mode for raw input
  SetConsoleMode(FInputHandle, ENABLE_PROCESSED_INPUT);

  while True do
  begin
    // Wait for input
    if not ReadConsoleInput(FInputHandle, InputRecord, 1, EventsRead) then
      Continue;

    if EventsRead = 0 then
      Continue;

    // Only process key down events
    if (InputRecord.EventType <> KEY_EVENT) or (not InputRecord.Event.KeyEvent.bKeyDown) then
      Continue;

    Ch := InputRecord.Event.KeyEvent.UnicodeChar;
    Key := InputRecord.Event.KeyEvent.wVirtualKeyCode;

    // Handle Enter
    if Key = VK_RETURN then
    begin
      Writeln; // Move to next line
      Result := FInputBuffer;
      FInputBuffer := '';
      Exit;
    end;

    // Handle Backspace
    if Key = VK_BACK then
    begin
      if Length(FInputBuffer) > 0 then
      begin
        Delete(FInputBuffer, Length(FInputBuffer), 1);
        // Erase character visually: backspace, space, backspace
        Write(#8' '#8);
      end;
      Continue;
    end;

    // Handle Escape - clear input
    if Key = VK_ESCAPE then
    begin
      FInputBuffer := '';
      RedrawInputLine;
      Continue;
    end;

    // Handle printable characters
    if (Ord(Ch) >= 32) and (Ord(Ch) < 127) then
    begin
      FInputBuffer := FInputBuffer + Ch;
      Write(Ch);
    end;
  end;
end;

initialization
  Console := TConsoleManager.Create;

finalization
  Console.Free;

end.
