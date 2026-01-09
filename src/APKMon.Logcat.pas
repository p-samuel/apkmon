unit APKMon.Logcat;

interface

uses
  Windows, SysUtils, Classes,
  APKMon.Types, APKMon.Utils, APKMon.ADB;

type
  TLogcatThread = class(TThread)
  private
    FDeviceId: string;
    FFilter: string;
    FPaused: Boolean;
    FStopRequested: Boolean;
    FReadPipe, FWritePipe: THandle;
    FProcessInfo: TProcessInformation;
    procedure OutputLine(const Line: string);
  protected
    procedure Execute; override;
  public
    constructor Create(const DeviceId, Filter: string);
    destructor Destroy; override;
    procedure PauseOutput;
    procedure ResumeOutput;
    procedure Stop;
    property IsPaused: Boolean read FPaused;
    property DeviceId: string read FDeviceId;
    property Filter: string read FFilter;
  end;

  TLogcatManager = class
  private
    FLogcatThread: TLogcatThread;
    FADBExecutor: TADBExecutor;
    FAutoPaused: Boolean;
  public
    constructor Create(ADBExecutor: TADBExecutor);
    destructor Destroy; override;
    procedure Start(const DeviceId, Filter: string);
    procedure Stop;
    procedure Pause;
    procedure Resume;
    procedure AutoPause;
    procedure AutoResume;
    procedure Clear(const DeviceId: string);
    function IsRunning: Boolean;
    function IsPaused: Boolean;
    function GetStatus: string;
  end;

implementation

{ TLogcatThread }

constructor TLogcatThread.Create(const DeviceId, Filter: string);
begin
  inherited Create(True); // Create suspended
  FDeviceId := DeviceId;
  FFilter := Filter;
  FPaused := False;
  FStopRequested := False;
  FReadPipe := 0;
  FWritePipe := 0;
  FreeOnTerminate := False;
end;

destructor TLogcatThread.Destroy;
begin
  Stop;
  inherited Destroy;
end;

procedure TLogcatThread.OutputLine(const Line: string);
begin
  if not FPaused and not FStopRequested then
  begin
    // If filter is set, only output lines containing the filter string
    if (FFilter = '') or (Pos(LowerCase(FFilter), LowerCase(Line)) > 0) then
      LogMessage('[LOGCAT] ' + Line, lcCyan);
  end;
end;

procedure TLogcatThread.Execute;
var
  SecurityAttr: TSecurityAttributes;
  StartupInfo: TStartupInfo;
  Command: string;
  Buffer: array[0..4095] of AnsiChar;
  BytesRead: DWORD;
  Line: string;
  Ch: AnsiChar;
  i: Integer;
begin
  // Set up security attributes for pipe inheritance
  SecurityAttr.nLength := SizeOf(TSecurityAttributes);
  SecurityAttr.bInheritHandle := True;
  SecurityAttr.lpSecurityDescriptor := nil;

  // Create pipe for stdout
  if not CreatePipe(FReadPipe, FWritePipe, @SecurityAttr, 0) then
  begin
    LogMessage('Failed to create pipe for logcat', lcRed);
    Exit;
  end;

  // Ensure the read handle is not inherited
  SetHandleInformation(FReadPipe, HANDLE_FLAG_INHERIT, 0);

  // Set up startup info
  FillChar(StartupInfo, SizeOf(TStartupInfo), 0);
  StartupInfo.cb := SizeOf(TStartupInfo);
  StartupInfo.hStdOutput := FWritePipe;
  StartupInfo.hStdError := FWritePipe;
  StartupInfo.dwFlags := STARTF_USESTDHANDLES or STARTF_USESHOWWINDOW;
  StartupInfo.wShowWindow := SW_HIDE;

  // Build command
  Command := 'adb';
  if FDeviceId <> '' then
    Command := Command + ' -s ' + FDeviceId;
  Command := Command + ' logcat';

  // Create process
  FillChar(FProcessInfo, SizeOf(TProcessInformation), 0);
  if not CreateProcess(nil, PChar(Command), nil, nil, True,
    CREATE_NO_WINDOW, nil, nil, StartupInfo, FProcessInfo) then
  begin
    LogMessage('Failed to start logcat process: ' + SysErrorMessage(GetLastError), lcRed);
    CloseHandle(FReadPipe);
    CloseHandle(FWritePipe);
    FReadPipe := 0;
    FWritePipe := 0;
    Exit;
  end;

  // Close write end of pipe (we only read)
  CloseHandle(FWritePipe);
  FWritePipe := 0;

  LogMessage('Logcat started' +
    TConditionalHelper<string>.IfThen(FDeviceId <> '', ' on device ' + FDeviceId, '') +
    TConditionalHelper<string>.IfThen(FFilter <> '', ' with filter ' + FFilter, ''), lcGreen);

  // Read output
  Line := '';
  while not FStopRequested do
  begin
    if not ReadFile(FReadPipe, Buffer, SizeOf(Buffer), BytesRead, nil) then
      Break;

    if BytesRead = 0 then
      Break;

    for i := 0 to BytesRead - 1 do
    begin
      Ch := Buffer[i];
      if Ch = #10 then
      begin
        OutputLine(Line);
        Line := '';
      end
      else if Ch <> #13 then
        Line := Line + Char(Ch);
    end;
  end;

  // Output any remaining line
  if Line <> '' then
    OutputLine(Line);

  // Clean up process
  if FProcessInfo.hProcess <> 0 then
  begin
    TerminateProcess(FProcessInfo.hProcess, 0);
    CloseHandle(FProcessInfo.hProcess);
    CloseHandle(FProcessInfo.hThread);
  end;

  if FReadPipe <> 0 then
    CloseHandle(FReadPipe);

  LogMessage('Logcat stopped', lcYellow);
end;

procedure TLogcatThread.PauseOutput;
begin
  FPaused := True;
end;

procedure TLogcatThread.ResumeOutput;
begin
  FPaused := False;
end;

procedure TLogcatThread.Stop;
begin
  FStopRequested := True;

  // Terminate the adb process to unblock the read
  if FProcessInfo.hProcess <> 0 then
    TerminateProcess(FProcessInfo.hProcess, 0);
end;

{ TLogcatManager }

constructor TLogcatManager.Create(ADBExecutor: TADBExecutor);
begin
  inherited Create;
  FADBExecutor := ADBExecutor;
  FLogcatThread := nil;
  FAutoPaused := False;
end;

destructor TLogcatManager.Destroy;
begin
  Stop;
  inherited Destroy;
end;

procedure TLogcatManager.Start(const DeviceId, Filter: string);
begin
  if IsRunning then
  begin
    LogMessage('Logcat is already running. Use "logcat stop" first.', lcYellow);
    Exit;
  end;

  FLogcatThread := TLogcatThread.Create(DeviceId, Filter);
  FLogcatThread.Start;
  FAutoPaused := False;
end;

procedure TLogcatManager.Stop;
begin
  if FLogcatThread <> nil then
  begin
    FLogcatThread.Stop;
    FLogcatThread.WaitFor;
    FreeAndNil(FLogcatThread);
    FAutoPaused := False;
  end;
end;

procedure TLogcatManager.Pause;
begin
  if IsRunning then
  begin
    FLogcatThread.PauseOutput;
    LogMessage('Logcat output paused', lcYellow);
  end
  else
    LogMessage('Logcat is not running', lcYellow);
end;

procedure TLogcatManager.Resume;
begin
  if IsRunning then
  begin
    FLogcatThread.ResumeOutput;
    FAutoPaused := False;
    LogMessage('Logcat output resumed', lcGreen);
  end
  else
    LogMessage('Logcat is not running', lcYellow);
end;

procedure TLogcatManager.AutoPause;
begin
  if IsRunning and not FLogcatThread.IsPaused then
  begin
    FLogcatThread.PauseOutput;
    FAutoPaused := True;
  end;
end;

procedure TLogcatManager.AutoResume;
begin
  if IsRunning and FAutoPaused then
  begin
    FLogcatThread.ResumeOutput;
    FAutoPaused := False;
  end;
end;

procedure TLogcatManager.Clear(const DeviceId: string);
var
  Command: string;
begin
  Command := 'adb';
  if DeviceId <> '' then
    Command := Command + ' -s ' + DeviceId;
  Command := Command + ' logcat -c';

  FADBExecutor.ExecuteCommand(Command, False);
  LogMessage('Logcat buffer cleared', lcGreen);
end;

function TLogcatManager.IsRunning: Boolean;
begin
  Result := (FLogcatThread <> nil) and not FLogcatThread.Finished;
end;

function TLogcatManager.IsPaused: Boolean;
begin
  Result := IsRunning and FLogcatThread.IsPaused;
end;

function TLogcatManager.GetStatus: string;
begin
  if not IsRunning then
    Result := 'Logcat: Not running'
  else if IsPaused then
    Result := 'Logcat: Running (paused)' +
      TConditionalHelper<string>.IfThen(FLogcatThread.DeviceId <> '', ' on ' + FLogcatThread.DeviceId, '') +
      TConditionalHelper<string>.IfThen(FLogcatThread.Filter <> '', ' filter=' + FLogcatThread.Filter, '')
  else
    Result := 'Logcat: Running' +
      TConditionalHelper<string>.IfThen(FLogcatThread.DeviceId <> '', ' on ' + FLogcatThread.DeviceId, '') +
      TConditionalHelper<string>.IfThen(FLogcatThread.Filter <> '', ' filter=' + FLogcatThread.Filter, '');
end;

end.
