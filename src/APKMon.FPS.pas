unit APKMon.FPS;

interface

uses
  Windows, SysUtils, Classes, DateUtils, Math,
  APKMon.Types, APKMon.Utils, APKMon.ADB;

type
  TFPSMonitorThread = class(TThread)
  private
    FDeviceId: string;
    FPackageName: string;
    FStopRequested: Boolean;
    FADBExecutor: TADBExecutor;
    FStartTime: TDateTime;
    procedure EnableTimestats;
    procedure DisableTimestats;
    procedure ClearTimestats;
    function GetTimestatsOutput: string;
    procedure ParseAndDisplayFPS(const Output: string);
  protected
    procedure Execute; override;
  public
    constructor Create(ADBExecutor: TADBExecutor; const DeviceId, PackageName: string);
    procedure Stop;
    property DeviceId: string read FDeviceId;
    property PackageName: string read FPackageName;
    property StartTime: TDateTime read FStartTime;
  end;

  TFPSManager = class
  private
    FThread: TFPSMonitorThread;
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

{ TFPSMonitorThread }

constructor TFPSMonitorThread.Create(ADBExecutor: TADBExecutor; const DeviceId, PackageName: string);
begin
  inherited Create(True);
  FADBExecutor := ADBExecutor;
  FDeviceId := DeviceId;
  FPackageName := PackageName;
  FStopRequested := False;
  FreeOnTerminate := False;
end;

procedure TFPSMonitorThread.Stop;
begin
  FStopRequested := True;
end;

procedure TFPSMonitorThread.EnableTimestats;
begin
  FADBExecutor.ExecuteCommand(
    Format('adb -s %s shell dumpsys SurfaceFlinger --timestats -enable', [FDeviceId]), False);
end;

procedure TFPSMonitorThread.DisableTimestats;
begin
  FADBExecutor.ExecuteCommand(
    Format('adb -s %s shell dumpsys SurfaceFlinger --timestats -disable', [FDeviceId]), False);
end;

procedure TFPSMonitorThread.ClearTimestats;
begin
  FADBExecutor.ExecuteCommand(
    Format('adb -s %s shell dumpsys SurfaceFlinger --timestats -clear', [FDeviceId]), False);
end;

function TFPSMonitorThread.GetTimestatsOutput: string;
begin
  // Use 5 second timeout - output streams as it arrives
  Result := FADBExecutor.GetCommandOutput(
    Format('adb -s %s shell dumpsys SurfaceFlinger --timestats -dump', [FDeviceId]), 5000);
end;

procedure TFPSMonitorThread.ParseAndDisplayFPS(const Output: string);
var
  Lines: TStringList;
  i, LayerIdx, EqPos: Integer;
  Line, LayerName: string;
  DisplayHz, RenderHz, TotalFrames: string;
  FPS: Integer;
  Found, FoundDisplay, FoundRender, FoundFrames: Boolean;

  function ExtractValue(const S: string): string;
  var
    P: Integer;
  begin
    // Extract numeric value, handling varying whitespace
    Result := Trim(S);
    // Remove trailing text like ' fps'
    P := Pos(' ', Result);
    if P > 0 then
      Result := Copy(Result, 1, P - 1);
  end;

begin
  Lines := TStringList.Create;
  try
    Lines.Text := Output;
    Found := False;
    LayerIdx := -1;

    // Find the layer that matches the package name
    for i := 0 to Lines.Count - 1 do
    begin
      Line := Lines[i];
      // Look for layerName = SurfaceView[package/ or layerName = package/
      if (Pos('layerName', Line) > 0) and (Pos(FPackageName + '/', Line) > 0) then
      begin
        LayerIdx := i;
        // Extract layer name after '='
        EqPos := Pos('=', Line);
        if EqPos > 0 then
          LayerName := Trim(Copy(Line, EqPos + 1, MaxInt))
        else
          LayerName := Line;
        Found := True;
        Break;
      end;
    end;

    if not Found then
    begin
      LogMessage(Format('%s  --               --     --       --      (layer not found for %s)',
        [FormatDateTime('hh:nn:ss', Now), FPackageName]), lcYellow);
      Exit;
    end;

    // Parse values from lines after the layer name (within reasonable range)
    // Take FIRST match of each (like the bat script does)
    DisplayHz := '--';
    RenderHz := '--';
    TotalFrames := '0';
    FoundDisplay := False;
    FoundRender := False;
    FoundFrames := False;

    for i := LayerIdx to Min(LayerIdx + 350, Lines.Count - 1) do
    begin
      Line := Lines[i];

      // totalFrames = XX (check first - most important)
      if (not FoundFrames) and (Pos('totalFrames', Line) > 0) then
      begin
        EqPos := Pos('=', Line);
        if EqPos > 0 then
        begin
          TotalFrames := ExtractValue(Copy(Line, EqPos + 1, MaxInt));
          FoundFrames := True;
        end;
      end;

      // displayRefreshRate = XX fps
      if (not FoundDisplay) and (Pos('displayRefreshRate', Line) > 0) then
      begin
        EqPos := Pos('=', Line);
        if EqPos > 0 then
        begin
          DisplayHz := ExtractValue(Copy(Line, EqPos + 1, MaxInt));
          FoundDisplay := True;
        end;
      end;

      // renderRate = XX fps
      if (not FoundRender) and (Pos('renderRate', Line) > 0) then
      begin
        EqPos := Pos('=', Line);
        if EqPos > 0 then
        begin
          RenderHz := ExtractValue(Copy(Line, EqPos + 1, MaxInt));
          FoundRender := True;
        end;
      end;

      // Stop early if we found all values
      if FoundDisplay and FoundRender and FoundFrames then
        Break;
    end;

    FPS := StrToIntDef(TotalFrames, 0);

    // Format: HH:MM:SS  FPS: XX   Frames: XX   Display: XXHz   Render: XXHz   Layer: ...
    LogMessage(Format('%s  FPS: %3d   Frames: %5s   Display: %3sHz   Render: %3sHz   Layer: %s',
      [FormatDateTime('hh:nn:ss', Now), FPS, TotalFrames, DisplayHz, RenderHz, LayerName]), lcCyan);
  finally
    Lines.Free;
  end;
end;

procedure TFPSMonitorThread.Execute;
var
  Output: string;
begin
  FStartTime := Now;
  LogMessage(Format('%s  FPS monitoring started for %s on %s',
    [FormatDateTime('hh:nn:ss', Now), FPackageName, FDeviceId]), lcGreen);

  // Print header
  LogMessage('time      FPS         Frames   Display      Render       Layer', lcBlue);
  LogMessage('------------------------------------------------------------------------', lcBlue);

  // Enable timestats
  EnableTimestats;

  try
    while not FStopRequested do
    begin
      // Clear stats
      ClearTimestats;

      // Wait 1 second
      Sleep(1000);

      if FStopRequested then
        Break;

      // Get and parse output
      Output := GetTimestatsOutput;
      ParseAndDisplayFPS(Output);
    end;
  finally
    // Disable timestats on exit
    DisableTimestats;
  end;

  LogMessage(Format('%s  FPS monitoring stopped', [FormatDateTime('hh:nn:ss', Now)]), lcYellow);
end;

{ TFPSManager }

constructor TFPSManager.Create(ADBExecutor: TADBExecutor);
begin
  inherited Create;
  FADBExecutor := ADBExecutor;
  FThread := nil;
  FCurrentDeviceId := '';
  FCurrentPackageName := '';
end;

destructor TFPSManager.Destroy;
begin
  Stop;
  inherited Destroy;
end;

procedure TFPSManager.Start(const DeviceId, PackageName: string);
var
  Devices: TStringList;
begin
  if DeviceId = '' then
  begin
    LogMessage('Error: Device ID is required. Usage: fps <device-id> <package-name>', lcRed);
    LogMessage('Use "devices" command to list connected devices.', lcYellow);
    Exit;
  end;

  if PackageName = '' then
  begin
    LogMessage('Error: Package name is required. Usage: fps <device-id> <package-name>', lcRed);
    Exit;
  end;

  if IsRunning then
  begin
    LogMessage('FPS monitoring is already running. Use "fps stop" first.', lcYellow);
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
  FThread := TFPSMonitorThread.Create(FADBExecutor, DeviceId, PackageName);
  FThread.Start;
end;

procedure TFPSManager.Stop;
begin
  if FThread = nil then
  begin
    LogMessage('FPS monitoring is not running.', lcYellow);
    Exit;
  end;

  FThread.Stop;
  FThread.WaitFor;
  FreeAndNil(FThread);

  FCurrentDeviceId := '';
  FCurrentPackageName := '';
end;

function TFPSManager.IsRunning: Boolean;
begin
  Result := (FThread <> nil) and not FThread.Finished;
end;

function TFPSManager.GetStatus: string;
var
  Duration: Integer;
begin
  if IsRunning then
  begin
    Duration := SecondsBetween(Now, FThread.StartTime);
    Result := Format('FPS monitoring: Active for %s on %s (%d:%02d:%02d)',
      [FCurrentPackageName, FCurrentDeviceId,
       Duration div 3600, (Duration mod 3600) div 60, Duration mod 60]);
  end
  else
    Result := 'FPS monitoring: Not active';
end;

end.
