unit APKMon.Profile;

interface

uses
  Windows, SysUtils, Classes, DateUtils, Math,
  APKMon.Types, APKMon.Utils, APKMon.ADB;

type
  TProfileMonitorThread = class(TThread)
  private
    FDeviceId: string;
    FPackageName: string;
    FStopRequested: Boolean;
    FADBExecutor: TADBExecutor;
    FStartTime: TDateTime;
    FPid: string;
    function GetPid: string;
    function GetCpuUsage: string;
    procedure GetMemoryInfo(out Total, Native, JavaHeap: string);
    procedure ParseMemInfo(const Output: string; out Total, Native, JavaHeap: string);
    procedure GetBatteryInfo(out Level, Temperature: string);
  protected
    procedure Execute; override;
  public
    constructor Create(ADBExecutor: TADBExecutor; const DeviceId, PackageName: string);
    procedure Stop;
    property DeviceId: string read FDeviceId;
    property PackageName: string read FPackageName;
    property StartTime: TDateTime read FStartTime;
  end;

  TProfileManager = class
  private
    FThread: TProfileMonitorThread;
    FADBExecutor: TADBExecutor;
    FCurrentDeviceId: string;
    FCurrentPackageName: string;
  public
    constructor Create(ADBExecutor: TADBExecutor);
    destructor Destroy; override;
    procedure Start(const DeviceId, PackageName: string);
    procedure Stop;
    function IsRunning: Boolean;
    function GetStatus: string;
  end;

implementation

{ TProfileMonitorThread }

constructor TProfileMonitorThread.Create(ADBExecutor: TADBExecutor; const DeviceId, PackageName: string);
begin
  inherited Create(True);
  FADBExecutor := ADBExecutor;
  FDeviceId := DeviceId;
  FPackageName := PackageName;
  FStopRequested := False;
  FPid := '';
  FreeOnTerminate := False;
end;

procedure TProfileMonitorThread.Stop;
begin
  FStopRequested := True;
end;

function TProfileMonitorThread.GetPid: string;
var
  Output: string;
begin
  // Get PID of the package
  Output := FADBExecutor.GetCommandOutput(
    Format('adb -s %s shell pidof %s', [FDeviceId, FPackageName]), 3000);
  Result := Trim(Output);
  // Handle multiple PIDs - take the first one
  if Pos(' ', Result) > 0 then
    Result := Copy(Result, 1, Pos(' ', Result) - 1);
end;

function TProfileMonitorThread.GetCpuUsage: string;
var
  Output, Line: string;
  Lines: TStringList;
  i, PctPos: Integer;
begin
  Result := '--';

  if FPid = '' then
    Exit;

  // Use top with 1 iteration to get CPU usage
  Output := FADBExecutor.GetCommandOutput(
    Format('adb -s %s shell top -b -n 1 -p %s', [FDeviceId, FPid]), 3000);

  if Output = '' then
    Exit;

  Lines := TStringList.Create;
  try
    Lines.Text := Output;
    // Find the line with our PID
    for i := 0 to Lines.Count - 1 do
    begin
      Line := Lines[i];
      if Pos(FPid, Line) > 0 then
      begin
        // Parse CPU percentage - typically in format: PID USER PR NI VIRT RES SHR S %CPU %MEM TIME+ ARGS
        // CPU% is usually around position 9 in the output
        Line := Trim(Line);
        // Split by whitespace and find percentage
        while Pos('  ', Line) > 0 do
          Line := StringReplace(Line, '  ', ' ', [rfReplaceAll]);

        // Fields are typically: PID USER PR NI VIRT RES SHR S CPU% MEM% TIME+ NAME
        // Try to extract CPU% (field 9, index 8)
        Lines.Clear;
        Lines.Delimiter := ' ';
        Lines.StrictDelimiter := True;
        Lines.DelimitedText := Line;

        if Lines.Count >= 9 then
        begin
          Result := Lines[8]; // CPU%
          // Remove any non-numeric characters except decimal point
          if (Result <> '') and (Result[Length(Result)] = '%') then
            Result := Copy(Result, 1, Length(Result) - 1);
        end;
        Break;
      end;
    end;
  finally
    Lines.Free;
  end;
end;

procedure TProfileMonitorThread.GetMemoryInfo(out Total, Native, JavaHeap: string);
var
  Output: string;
begin
  Total := '--';
  Native := '--';
  JavaHeap := '--';

  Output := FADBExecutor.GetCommandOutput(
    Format('adb -s %s shell dumpsys meminfo %s', [FDeviceId, FPackageName]), 5000);

  if Output <> '' then
    ParseMemInfo(Output, Total, Native, JavaHeap);
end;

procedure TProfileMonitorThread.ParseMemInfo(const Output: string; out Total, Native, JavaHeap: string);
var
  Lines: TStringList;
  i: Integer;
  Line, LineLower: string;
  TotalPss, NativeHeap, JavaHeapSize: Integer;

  function ExtractFirstNumber(const S: string): Integer;
  var
    NumStr: string;
    j: Integer;
  begin
    Result := 0;
    NumStr := '';
    for j := 1 to Length(S) do
    begin
      if CharInSet(S[j], ['0'..'9']) then
        NumStr := NumStr + S[j]
      else if NumStr <> '' then
        Break;
    end;
    Result := StrToIntDef(NumStr, 0);
  end;

begin
  Total := '--';
  Native := '--';
  JavaHeap := '--';
  TotalPss := 0;
  NativeHeap := 0;
  JavaHeapSize := 0;

  Lines := TStringList.Create;
  try
    Lines.Text := Output;

    for i := 0 to Lines.Count - 1 do
    begin
      Line := Lines[i];
      LineLower := LowerCase(Line);

      // TOTAL line (for PSS) - various formats
      if (Pos('total', LineLower) > 0) and (Pos('pss', LineLower) > 0) then
        TotalPss := Max(TotalPss, ExtractFirstNumber(Line))
      else if Pos('total:', LineLower) > 0 then
        TotalPss := Max(TotalPss, ExtractFirstNumber(Copy(Line, Pos(':', Line) + 1, MaxInt)))
      else if (Pos('total', LineLower) = 1) then
        TotalPss := Max(TotalPss, ExtractFirstNumber(Line))

      // Native Heap (with or without colon)
      else if Pos('native heap', LineLower) > 0 then
      begin
        if Pos(':', LineLower) > 0 then
          NativeHeap := Max(NativeHeap, ExtractFirstNumber(Copy(Line, Pos(':', Line) + 1, MaxInt)))
        else
          NativeHeap := Max(NativeHeap, ExtractFirstNumber(Copy(Line, Pos('heap', LineLower) + 4, MaxInt)));
      end

      // Java/Dalvik Heap
      else if (Pos('java heap', LineLower) > 0) or (Pos('dalvik heap', LineLower) > 0) then
      begin
        if Pos(':', LineLower) > 0 then
          JavaHeapSize := Max(JavaHeapSize, ExtractFirstNumber(Copy(Line, Pos(':', Line) + 1, MaxInt)))
        else
          JavaHeapSize := Max(JavaHeapSize, ExtractFirstNumber(Copy(Line, Pos('heap', LineLower) + 4, MaxInt)));
      end;
    end;

    // Convert KB to MB
    if TotalPss > 0 then
      Total := IntToStr(TotalPss div 1024);
    if NativeHeap > 0 then
      Native := IntToStr(NativeHeap div 1024);
    if JavaHeapSize > 0 then
      JavaHeap := IntToStr(JavaHeapSize div 1024);
  finally
    Lines.Free;
  end;
end;

procedure TProfileMonitorThread.GetBatteryInfo(out Level, Temperature: string);
var
  Output, Line, LineLower: string;
  Lines: TStringList;
  i, ColonPos, TempVal: Integer;
begin
  Level := '--';
  Temperature := '--';

  Output := FADBExecutor.GetCommandOutput(
    Format('adb -s %s shell dumpsys battery', [FDeviceId]), 3000);

  if Output = '' then
    Exit;

  Lines := TStringList.Create;
  try
    Lines.Text := Output;
    for i := 0 to Lines.Count - 1 do
    begin
      Line := Lines[i];
      LineLower := LowerCase(Line);
      ColonPos := Pos(':', Line);

      if (Pos('level', LineLower) > 0) and (ColonPos > 0) then
        Level := Trim(Copy(Line, ColonPos + 1, MaxInt))
      else if (Pos('temperature', LineLower) > 0) and (ColonPos > 0) then
      begin
        TempVal := StrToIntDef(Trim(Copy(Line, ColonPos + 1, MaxInt)), 0);
        Temperature := Format('%.1f', [TempVal / 10.0]);
      end;
    end;
  finally
    Lines.Free;
  end;
end;

procedure TProfileMonitorThread.Execute;
var
  CpuPct, MemTotal, MemNative, MemJavaHeap: string;
  BattLevel, BattTemp: string;
begin
  FStartTime := Now;

  // Get PID first
  FPid := GetPid;
  if FPid = '' then
  begin
    LogMessage(Format('Error: Could not find PID for %s. Is the app running?', [FPackageName]), lcRed);
    Exit;
  end;

  LogMessage(Format('%s  Profile monitoring started for %s (PID: %s) on %s',
    [FormatDateTime('hh:nn:ss', Now), FPackageName, FPid, FDeviceId]), lcGreen);

  // Print header
  LogMessage('time       CPU%  Mem(MB)  Native(MB)  Java(MB)  Batt%  Temp(C)', lcBlue);
  LogMessage('---------------------------------------------------------------', lcBlue);

  while not FStopRequested do
  begin
    // Refresh PID in case app restarted
    if FPid = '' then
    begin
      FPid := GetPid;
      if FPid = '' then
      begin
        LogMessage(Format('%s  App not running', [FormatDateTime('hh:nn:ss', Now)]), lcYellow);
        Sleep(2000);
        Continue;
      end;
    end;

    // Get CPU usage
    CpuPct := GetCpuUsage;

    // Get Memory info
    GetMemoryInfo(MemTotal, MemNative, MemJavaHeap);

    // Get Battery info
    GetBatteryInfo(BattLevel, BattTemp);

    // Display
    LogMessage(Format('%s  %5s%%  %7s  %10s  %8s  %5s%%  %6s',
      [FormatDateTime('hh:nn:ss', Now), CpuPct, MemTotal, MemNative, MemJavaHeap, BattLevel, BattTemp]), lcCyan);

    // Check if process still exists
    if GetPid = '' then
    begin
      LogMessage(Format('%s  App terminated', [FormatDateTime('hh:nn:ss', Now)]), lcYellow);
      FPid := '';
    end;

    // Wait before next sample (2 seconds for less overhead)
    Sleep(2000);
  end;

  LogMessage(Format('%s  Profile monitoring stopped', [FormatDateTime('hh:nn:ss', Now)]), lcYellow);
end;

{ TProfileManager }

constructor TProfileManager.Create(ADBExecutor: TADBExecutor);
begin
  inherited Create;
  FADBExecutor := ADBExecutor;
  FThread := nil;
  FCurrentDeviceId := '';
  FCurrentPackageName := '';
end;

destructor TProfileManager.Destroy;
begin
  Stop;
  inherited Destroy;
end;

procedure TProfileManager.Start(const DeviceId, PackageName: string);
var
  Devices: TStringList;
begin
  if DeviceId = '' then
  begin
    LogMessage('Error: Device ID is required. Usage: profile <device-id> <package-name>', lcRed);
    LogMessage('Use "devices" command to list connected devices.', lcYellow);
    Exit;
  end;

  if PackageName = '' then
  begin
    LogMessage('Error: Package name is required. Usage: profile <device-id> <package-name>', lcRed);
    Exit;
  end;

  if IsRunning then
  begin
    LogMessage('Profile monitoring is already running. Use "profile stop" first.', lcYellow);
    Exit;
  end;

  // Verify device is connected
  Devices := FADBExecutor.GetDevices;
  try
    if Devices.IndexOf(DeviceId) < 0 then
    begin
      LogMessage(Format('Error: Device "%s" not found or not connected.', [DeviceId]), lcRed);
      Exit;
    end;
  finally
    Devices.Free;
  end;

  FCurrentDeviceId := DeviceId;
  FCurrentPackageName := PackageName;

  // Create and start thread
  FThread := TProfileMonitorThread.Create(FADBExecutor, DeviceId, PackageName);
  FThread.Start;
end;

procedure TProfileManager.Stop;
begin
  if FThread = nil then
  begin
    LogMessage('Profile monitoring is not running.', lcYellow);
    Exit;
  end;

  FThread.Stop;
  FThread.WaitFor;
  FreeAndNil(FThread);

  FCurrentDeviceId := '';
  FCurrentPackageName := '';
end;

function TProfileManager.IsRunning: Boolean;
begin
  Result := (FThread <> nil) and not FThread.Finished;
end;

function TProfileManager.GetStatus: string;
var
  Duration: Integer;
begin
  if IsRunning then
  begin
    Duration := SecondsBetween(Now, FThread.StartTime);
    Result := Format('Profile monitoring: Active for %s on %s (%d:%02d:%02d)',
      [FCurrentPackageName, FCurrentDeviceId,
       Duration div 3600, (Duration mod 3600) div 60, Duration mod 60]);
  end
  else
    Result := 'Profile monitoring: Not active';
end;

end.
