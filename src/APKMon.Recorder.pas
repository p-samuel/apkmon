unit APKMon.Recorder;

interface

uses
  Windows, SysUtils, Classes, DateUtils,
  APKMon.Types, APKMon.Utils, APKMon.ADB;

type
  TRecordingState = (rsIdle, rsRecording, rsStopping, rsPulling);

  TScreenRecorderThread = class(TThread)
  private
    FDeviceId: string;
    FSessionId: string;
    FSegmentIndex: Integer;
    FSegmentPaths: TStringList;
    FStopRequested: Boolean;
    FCurrentProcess: TProcessInformation;
    FStartTime: TDateTime;
    function GetCurrentDevicePath: string;
    procedure StartSegmentRecording;
    procedure WaitForSegmentEnd;
  protected
    procedure Execute; override;
  public
    constructor Create(const DeviceId, SessionId: string);
    destructor Destroy; override;
    procedure RequestStop;
    procedure Stop;
    property DeviceId: string read FDeviceId;
    property SessionId: string read FSessionId;
    property SegmentPaths: TStringList read FSegmentPaths;
    property StartTime: TDateTime read FStartTime;
    property StopRequested: Boolean read FStopRequested;
  end;

  TScreenRecorderManager = class
  private
    FRecorderThread: TScreenRecorderThread;
    FADBExecutor: TADBExecutor;
    FOutputFolder: string;
    FState: TRecordingState;
    FCurrentDeviceId: string;
    procedure StopRecordingProcess;
    procedure PullAndMergeSegments;
    procedure CleanupDeviceFiles;
    function MergeSegmentsWithFFmpeg(const TempFolder, OutputFile: string; const Segments: TStringList): Boolean;
  public
    constructor Create(ADBExecutor: TADBExecutor);
    destructor Destroy; override;
    procedure StartRecording(const DeviceId: string);
    procedure StopRecording;
    procedure Shutdown;
    procedure SetOutputFolder(const Folder: string);
    function GetOutputFolder: string;
    function IsRecording: Boolean;
    function GetStatus: string;
    function GetRecordingDuration: Integer;
    property OutputFolder: string read FOutputFolder write SetOutputFolder;
    property State: TRecordingState read FState;
  end;

implementation

uses
  IOUtils, APKMon.Config;

{ TScreenRecorderThread }

constructor TScreenRecorderThread.Create(const DeviceId, SessionId: string);
begin
  inherited Create(True);
  FDeviceId := DeviceId;
  FSessionId := SessionId;
  FSegmentIndex := 0;
  FSegmentPaths := TStringList.Create;
  FStopRequested := False;
  FillChar(FCurrentProcess, SizeOf(TProcessInformation), 0);
  FreeOnTerminate := False;
end;

destructor TScreenRecorderThread.Destroy;
begin
  Stop;
  FSegmentPaths.Free;
  inherited Destroy;
end;

function TScreenRecorderThread.GetCurrentDevicePath: string;
begin
  Result := Format('/sdcard/apkmon_rec_%s_%d.mp4', [FSessionId, FSegmentIndex]);
end;

procedure TScreenRecorderThread.StartSegmentRecording;
var
  StartupInfo: TStartupInfo;
  Command: string;
  DevicePath: string;
begin
  DevicePath := GetCurrentDevicePath;
  FSegmentPaths.Add(DevicePath);

  // Build screenrecord command with high bitrate for 60fps
  Command := Format('adb -s %s shell screenrecord --bit-rate 20000000 %s',
    [FDeviceId, DevicePath]);

  FillChar(StartupInfo, SizeOf(TStartupInfo), 0);
  StartupInfo.cb := SizeOf(TStartupInfo);
  StartupInfo.dwFlags := STARTF_USESHOWWINDOW;
  StartupInfo.wShowWindow := SW_HIDE;

  FillChar(FCurrentProcess, SizeOf(TProcessInformation), 0);

  if not CreateProcess(nil, PChar(Command), nil, nil, False, CREATE_NO_WINDOW,
    nil, nil, StartupInfo, FCurrentProcess) then
  begin
    LogMessage('Failed to start screenrecord: ' + SysErrorMessage(GetLastError), lcRed);
    FStopRequested := True;
  end;
end;

procedure TScreenRecorderThread.WaitForSegmentEnd;
var
  WaitResult: DWORD;
begin
  // Wait for process to end (either 180s limit or external kill)
  while not FStopRequested do
  begin
    WaitResult := WaitForSingleObject(FCurrentProcess.hProcess, 500);
    if WaitResult = WAIT_OBJECT_0 then
      Break; // Process ended (180s limit reached or killed)
  end;

  // Clean up process handles
  if FCurrentProcess.hProcess <> 0 then
  begin
    CloseHandle(FCurrentProcess.hProcess);
    CloseHandle(FCurrentProcess.hThread);
    FillChar(FCurrentProcess, SizeOf(TProcessInformation), 0);
  end;
end;

procedure TScreenRecorderThread.Execute;
begin
  FStartTime := Now;
  LogMessage(Format('Screen recording started on device %s', [FDeviceId]), lcGreen);

  // Recording loop - auto-chain segments
  while not FStopRequested do
  begin
    StartSegmentRecording;

    if FStopRequested then
      Break;

    WaitForSegmentEnd;

    if not FStopRequested then
    begin
      // Segment ended due to 180s limit, start next segment
      Inc(FSegmentIndex);
      LogMessage(Format('Starting recording segment %d...', [FSegmentIndex + 1]), lcBlue);
    end;
  end;

  LogMessage('Screen recording stopped', lcYellow);
end;

procedure TScreenRecorderThread.RequestStop;
begin
  FStopRequested := True;
end;

procedure TScreenRecorderThread.Stop;
begin
  FStopRequested := True;

  // Terminate the local adb shell process if running
  if FCurrentProcess.hProcess <> 0 then
    TerminateProcess(FCurrentProcess.hProcess, 0);
end;

{ TScreenRecorderManager }

constructor TScreenRecorderManager.Create(ADBExecutor: TADBExecutor);
begin
  inherited Create;
  FADBExecutor := ADBExecutor;
  FRecorderThread := nil;
  FOutputFolder := Config.RecordingOutputFolder;  // Load from config
  FState := rsIdle;
  FCurrentDeviceId := '';
end;

destructor TScreenRecorderManager.Destroy;
begin
  Shutdown;
  inherited Destroy;
end;

procedure TScreenRecorderManager.StartRecording(const DeviceId: string);
var
  SessionId: string;
  Devices: TStringList;
begin
  if DeviceId = '' then
  begin
    LogMessage('Error: Device ID is required. Usage: record start <device-id>', lcRed);
    LogMessage('Use "devices" command to list connected devices.', lcYellow);
    Exit;
  end;

  if FState <> rsIdle then
  begin
    LogMessage('Recording is already in progress. Use "record stop" first.', lcYellow);
    Exit;
  end;

  if FOutputFolder = '' then
  begin
    LogMessage('Error: Output folder not set. Use "record output <path>" first.', lcRed);
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

  // Generate unique session ID
  SessionId := FormatDateTime('yyyymmdd_hhnnss', Now);
  FCurrentDeviceId := DeviceId;

  // Create and start recording thread
  FRecorderThread := TScreenRecorderThread.Create(DeviceId, SessionId);
  FRecorderThread.Start;
  FState := rsRecording;
end;

procedure TScreenRecorderManager.StopRecordingProcess;
var
  PIDOutput, PID: string;
  WaitCount: Integer;
begin
  PIDOutput := FADBExecutor.GetCommandOutput(Format('adb -s %s shell pidof screenrecord', [FCurrentDeviceId]));
  PID := Trim(PIDOutput);
  if PID <> '' then begin
    // Send SIGINT (2) to gracefully stop screenrecord (writes moov atom)
    FADBExecutor.ExecuteCommand(Format('adb -s %s shell kill -2 %s', [FCurrentDeviceId, PID]), False);
    // Poll until screenrecord exits (up to 5 seconds)
    for WaitCount := 1 to 10 do begin
      Sleep(500);
      PIDOutput := FADBExecutor.GetCommandOutput(Format('adb -s %s shell pidof screenrecord', [FCurrentDeviceId]));
      if Trim(PIDOutput) = '' then
        Break;
    end;
  end;
end;

procedure TScreenRecorderManager.PullAndMergeSegments;
var
  i: Integer;
  DevicePath, LocalPath, TempFolder, OutputFile: string;
  LocalSegments: TStringList;
  PullSuccess: Boolean;
begin
  if (FRecorderThread = nil) or (FRecorderThread.SegmentPaths.Count = 0) then
  begin
    LogMessage('No segments to pull.', lcYellow);
    Exit;
  end;

  FState := rsPulling;
  LogMessage(Format('Pulling %d segment(s) from device...', [FRecorderThread.SegmentPaths.Count]), lcBlue);

  // Create temp folder for segments
  TempFolder := TPath.Combine(FOutputFolder, 'temp_' + FRecorderThread.SessionId);
  if not DirectoryExists(TempFolder) then
    ForceDirectories(TempFolder);

  LocalSegments := TStringList.Create;
  try
    PullSuccess := True;

    // Pull each segment
    for i := 0 to FRecorderThread.SegmentPaths.Count - 1 do
    begin
      DevicePath := FRecorderThread.SegmentPaths[i];
      LocalPath := TPath.Combine(TempFolder, Format('segment_%d.mp4', [i]));

      // Use 5 minute timeout for large video file pulls
      if FADBExecutor.ExecuteCommand(
        Format('adb -s %s pull "%s" "%s"', [FCurrentDeviceId, DevicePath, LocalPath]), False, 300000) then
      begin
        if FileExists(LocalPath) then
          LocalSegments.Add(LocalPath)
        else
        begin
          LogMessage(Format('Warning: Segment %d was not pulled successfully.', [i]), lcYellow);
          PullSuccess := False;
        end;
      end
      else
      begin
        LogMessage(Format('Failed to pull segment %d from device.', [i]), lcRed);
        PullSuccess := False;
      end;
    end;

    if LocalSegments.Count = 0 then
    begin
      LogMessage('No segments were pulled successfully.', lcRed);
      Exit;
    end;

    // Generate output filename
    OutputFile := TPath.Combine(FOutputFolder,
      Format('recording_%s.mp4', [FRecorderThread.SessionId]));

    if LocalSegments.Count = 1 then
    begin
      // Single segment - just move it
      if RenameFile(LocalSegments[0], OutputFile) then
        LogMessage('Recording saved: ' + OutputFile, lcGreen)
      else
      begin
        // Try copy if rename fails (cross-drive)
        if CopyFile(PChar(LocalSegments[0]), PChar(OutputFile), False) then
        begin
          DeleteFile(LocalSegments[0]);
          LogMessage('Recording saved: ' + OutputFile, lcGreen);
        end
        else
          LogMessage('Failed to save recording.', lcRed);
      end;
    end
    else
    begin
      // Multiple segments - merge with ffmpeg
      LogMessage(Format('Merging %d segments...', [LocalSegments.Count]), lcBlue);
      if MergeSegmentsWithFFmpeg(TempFolder, OutputFile, LocalSegments) then
        LogMessage('Recording saved: ' + OutputFile, lcGreen)
      else
        LogMessage('Failed to merge segments. Individual segments kept in: ' + TempFolder, lcRed);
    end;

    // Clean up temp folder if merge was successful
    if FileExists(OutputFile) then
    begin
      for i := 0 to LocalSegments.Count - 1 do
        DeleteFile(LocalSegments[i]);
      RemoveDir(TempFolder);

      // Clean up device files
      CleanupDeviceFiles;
    end;

  finally
    LocalSegments.Free;
  end;
end;

function TScreenRecorderManager.MergeSegmentsWithFFmpeg(const TempFolder, OutputFile: string;
  const Segments: TStringList): Boolean;
var
  ListFile: string;
  i: Integer;
  FileList: TStringList;
  Command: string;
begin
  Result := False;

  // Create concat file list for ffmpeg
  ListFile := TPath.Combine(TempFolder, 'filelist.txt');
  FileList := TStringList.Create;
  try
    for i := 0 to Segments.Count - 1 do
      FileList.Add(Format('file ''%s''', [StringReplace(Segments[i], '\', '/', [rfReplaceAll])]));
    FileList.SaveToFile(ListFile);
  finally
    FileList.Free;
  end;

  // Run ffmpeg to concatenate
  Command := Format('ffmpeg -y -f concat -safe 0 -i "%s" -c copy "%s"', [ListFile, OutputFile]);

  if FADBExecutor.ExecuteCommand(Command, False) then
  begin
    Result := FileExists(OutputFile);
    DeleteFile(ListFile);
  end
  else
    LogMessage('ffmpeg merge failed. Is ffmpeg installed and in PATH?', lcRed);
end;

procedure TScreenRecorderManager.CleanupDeviceFiles;
var
  i: Integer;
  DevicePath: string;
begin
  if FRecorderThread = nil then
    Exit;

  LogMessage('Cleaning up device files...', lcBlue);
  for i := 0 to FRecorderThread.SegmentPaths.Count - 1 do
  begin
    DevicePath := FRecorderThread.SegmentPaths[i];
    FADBExecutor.ExecuteCommand(
      Format('adb -s %s shell rm "%s"', [FCurrentDeviceId, DevicePath]), False);
  end;
end;

procedure TScreenRecorderManager.StopRecording;
begin
  if FState <> rsRecording then
  begin
    LogMessage('No recording in progress.', lcYellow);
    Exit;
  end;

  LogMessage('Stopping recording...', lcBlue);
  FState := rsStopping;

  // Prevent thread from starting new segments
  if FRecorderThread <> nil then
    FRecorderThread.RequestStop;

  // Gracefully stop screenrecord on device FIRST (writes moov atom)
  StopRecordingProcess;

  // Now kill local adb process and wait for thread
  if FRecorderThread <> nil then begin
    FRecorderThread.Stop;
    FRecorderThread.WaitFor;
    PullAndMergeSegments;
    FreeAndNil(FRecorderThread);
  end;

  FState := rsIdle;
  FCurrentDeviceId := '';
end;

procedure TScreenRecorderManager.Shutdown;
begin
  if FState = rsRecording then
  begin
    LogMessage('Shutting down - saving active recording...', lcYellow);
    StopRecording;
  end;
end;

procedure TScreenRecorderManager.SetOutputFolder(const Folder: string);
begin
  if FState <> rsIdle then
  begin
    LogMessage('Cannot change output folder while recording.', lcYellow);
    Exit;
  end;

  if Folder = '' then
  begin
    LogMessage('Output folder cannot be empty.', lcRed);
    Exit;
  end;

  if not DirectoryExists(Folder) then
  begin
    if ForceDirectories(Folder) then
      LogMessage('Created output folder: ' + Folder, lcGreen)
    else
    begin
      LogMessage('Failed to create output folder: ' + Folder, lcRed);
      Exit;
    end;
  end;

  FOutputFolder := Folder;
  Config.RecordingOutputFolder := Folder;  // Save to config
  Config.Save;
  LogMessage('Recording output folder set to: ' + Folder, lcGreen);
end;

function TScreenRecorderManager.GetOutputFolder: string;
begin
  Result := FOutputFolder;
end;

function TScreenRecorderManager.IsRecording: Boolean;
begin
  Result := FState = rsRecording;
end;

function TScreenRecorderManager.GetRecordingDuration: Integer;
begin
  if (FState = rsRecording) and (FRecorderThread <> nil) then
    Result := SecondsBetween(Now, FRecorderThread.StartTime)
  else
    Result := 0;
end;

function TScreenRecorderManager.GetStatus: string;
var
  Duration: Integer;
begin
  case FState of
    rsIdle:
      Result := 'Recording: Not active';
    rsRecording:
      begin
        Duration := GetRecordingDuration;
        Result := Format('Recording: Active on %s (%d:%02d:%02d)',
          [FCurrentDeviceId, Duration div 3600, (Duration mod 3600) div 60, Duration mod 60]);
        if FRecorderThread <> nil then
          Result := Result + Format(' [Segment %d]', [FRecorderThread.FSegmentIndex + 1]);
      end;
    rsStopping:
      Result := 'Recording: Stopping...';
    rsPulling:
      Result := 'Recording: Pulling files from device...';
  end;

  if FOutputFolder <> '' then
    Result := Result + ' | Output: ' + FOutputFolder
  else
    Result := Result + ' | Output: Not configured';
end;

end.
