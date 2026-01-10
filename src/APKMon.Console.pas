unit APKMon.Console;

interface

uses
  Windows, SysUtils, Classes, SyncObjs;

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
    FHistory: TStringList;
    FHistoryIndex: Integer;
    FCursorPos: Integer;
    FLock: TCriticalSection;
    procedure UpdateScreenSize;
    procedure MoveCursorTo(Row, Col: SmallInt);
    procedure ClearCurrentLine;
    procedure EnableANSI;
    procedure RedrawInput;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Initialize;
    procedure WriteLine(const Msg: string; const ColorCode: string = '');
    procedure WriteLineRaw(const Msg: string);
    function ReadLine: string;
    procedure RedrawInputLine;
    procedure ClearInputBuffer;
    procedure Lock;
    procedure Unlock;
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
  FHistory := TStringList.Create;
  FHistoryIndex := -1;
  FCursorPos := 0;
  FLock := TCriticalSection.Create;
end;

destructor TConsoleManager.Destroy;
begin
  FLock.Free;
  FHistory.Free;
  inherited Destroy;
end;

procedure TConsoleManager.Lock;
begin
  FLock.Enter;
end;

procedure TConsoleManager.Unlock;
begin
  FLock.Leave;
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
  FLock.Enter;
  try
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
    Write(#27'[0m');  // Reset color after prompt
  finally
    FLock.Leave;
  end;
end;

procedure TConsoleManager.WriteLineRaw(const Msg: string);
begin
  FLock.Enter;
  try
    Writeln(Msg);
  finally
    FLock.Leave;
  end;
end;

procedure TConsoleManager.ClearInputBuffer;
begin
  FInputBuffer := '';
  FCursorPos := 0;
end;

procedure TConsoleManager.RedrawInput;
var
  i: Integer;
begin
  // Move cursor to start of line and clear entire line
  Write(#13);           // Carriage return
  Write(#27'[K');       // Clear from cursor to end of line
  Write(FPrompt);
  Write(FInputBuffer);
  // Move cursor back to correct position if not at end
  if FCursorPos < Length(FInputBuffer) then
  begin
    Write(#13);
    Write(FPrompt);
    for i := 1 to FCursorPos do
      Write(FInputBuffer[i]);
  end;
end;

function TConsoleManager.ReadLine: string;
var
  InputRecord: TInputRecord;
  EventsRead: DWORD;
  Ch: Char;
  Key: Word;
  TempHistory: string;
begin
  FInputBuffer := '';
  FCursorPos := 0;
  FHistoryIndex := FHistory.Count;

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
      Writeln;
      Result := FInputBuffer;
      // Add to history if not empty and not duplicate of last
      if (FInputBuffer <> '') and
         ((FHistory.Count = 0) or (FHistory[FHistory.Count - 1] <> FInputBuffer)) then
        FHistory.Add(FInputBuffer);
      FInputBuffer := '';
      FCursorPos := 0;
      Exit;
    end;

    // Handle Backspace
    if Key = VK_BACK then
    begin
      if FCursorPos > 0 then
      begin
        Delete(FInputBuffer, FCursorPos, 1);
        Dec(FCursorPos);
        RedrawInput;
      end;
      Continue;
    end;

    // Handle Delete
    if Key = VK_DELETE then
    begin
      if FCursorPos < Length(FInputBuffer) then
      begin
        Delete(FInputBuffer, FCursorPos + 1, 1);
        RedrawInput;
      end;
      Continue;
    end;

    // Handle Left Arrow
    if Key = VK_LEFT then
    begin
      if FCursorPos > 0 then
      begin
        Dec(FCursorPos);
        Write(#8);  // Move cursor left
      end;
      Continue;
    end;

    // Handle Right Arrow
    if Key = VK_RIGHT then
    begin
      if FCursorPos < Length(FInputBuffer) then
      begin
        Write(FInputBuffer[FCursorPos + 1]);
        Inc(FCursorPos);
      end;
      Continue;
    end;

    // Handle Home
    if Key = VK_HOME then
    begin
      while FCursorPos > 0 do
      begin
        Dec(FCursorPos);
        Write(#8);
      end;
      Continue;
    end;

    // Handle End
    if Key = VK_END then
    begin
      while FCursorPos < Length(FInputBuffer) do
      begin
        Write(FInputBuffer[FCursorPos + 1]);
        Inc(FCursorPos);
      end;
      Continue;
    end;

    // Handle Up Arrow - previous history
    if Key = VK_UP then
    begin
      if FHistory.Count > 0 then
      begin
        if FHistoryIndex > 0 then
          Dec(FHistoryIndex)
        else
          FHistoryIndex := 0;
        FInputBuffer := FHistory[FHistoryIndex];
        FCursorPos := Length(FInputBuffer);
        RedrawInput;
      end;
      Continue;
    end;

    // Handle Down Arrow - next history
    if Key = VK_DOWN then
    begin
      if FHistoryIndex < FHistory.Count - 1 then
      begin
        Inc(FHistoryIndex);
        FInputBuffer := FHistory[FHistoryIndex];
        FCursorPos := Length(FInputBuffer);
        RedrawInput;
      end
      else if FHistoryIndex = FHistory.Count - 1 then
      begin
        Inc(FHistoryIndex);
        FInputBuffer := '';
        FCursorPos := 0;
        RedrawInput;
      end;
      Continue;
    end;

    // Handle Escape - clear input
    if Key = VK_ESCAPE then
    begin
      FInputBuffer := '';
      FCursorPos := 0;
      FHistoryIndex := FHistory.Count;
      RedrawInput;
      Continue;
    end;

    // Handle printable characters
    if (Ord(Ch) >= 32) and (Ord(Ch) < 127) then
    begin
      // Insert at cursor position
      Insert(Ch, FInputBuffer, FCursorPos + 1);
      Inc(FCursorPos);
      // If at end, just print char; otherwise redraw
      if FCursorPos = Length(FInputBuffer) then
        Write(Ch)
      else
        RedrawInput;
    end;
  end;
end;

initialization
  Console := TConsoleManager.Create;

finalization
  Console.Free;

end.
