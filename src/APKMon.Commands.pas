unit APKMon.Commands;

interface

uses
  Windows, SysUtils, Classes, Generics.Collections, DateUtils,
  APKMon.Types, APKMon.Utils, APKMon.ADB, APKMon.Projects, APKMon.Monitor,
  APKMon.Deployer, APKMon.Logcat, APKMon.Recorder, APKMon.FPS, APKMon.Profile,
  APKMon.Console;

type
  TMonitorState = class
  private
    FPaused: Boolean;
    FTerminated: Boolean;
  public
    constructor Create;
    procedure Pause;
    procedure ResumeMonitoring;
    procedure Terminate;
    function IsPaused: Boolean;
    function IsTerminated: Boolean;
  end;

  TInputThread = class(TThread)
  private
    FADBExecutor: TADBExecutor;
    FProjectManager: TProjectManager;
    FDeployer: TAPKDeployer;
    FMonitorState: TMonitorState;
    FPendingProcessor: TPendingFileProcessor;
    FLogcatManager: TLogcatManager;
    FRecorderManager: TScreenRecorderManager;
    FFPSManager: TFPSManager;
    FProfileManager: TProfileManager;

    procedure PrintHelp;
    procedure HandleList;
    procedure HandlePause;
    procedure HandleResume;
    procedure HandleDevices;
    procedure HandlePair(const Param: string);
    procedure HandleConnect(const Param: string);
    procedure HandleDisconnect(const Param: string);
    procedure HandleBuild(const Param: string);
    procedure HandleDeploy(const Param: string);
    procedure HandleBuildAndDeploy(const Param: string);
    procedure HandleLogcat(const Param: string);
    procedure HandleRecord(const Param: string);
    procedure HandleFPS(const Param: string);
    procedure HandleProfile(const Param: string);
  protected
    procedure Execute; override;
  public
    constructor Create(ADBExecutor: TADBExecutor; ProjectManager: TProjectManager;
      Deployer: TAPKDeployer; MonitorState: TMonitorState;
      PendingProcessor: TPendingFileProcessor; LogcatManager: TLogcatManager;
      RecorderManager: TScreenRecorderManager; FPSManager: TFPSManager;
      ProfileManager: TProfileManager);
  end;

implementation

{ TMonitorState }

constructor TMonitorState.Create;
begin
  inherited Create;
  FPaused := False;
  FTerminated := False;
end;

procedure TMonitorState.Pause;
begin
  FPaused := True;
  LogMessage('Auto-detection paused', lcYellow);
end;

procedure TMonitorState.ResumeMonitoring;
begin
  FPaused := False;
  LogMessage('Auto-detection resumed', lcGreen);
end;

procedure TMonitorState.Terminate;
begin
  FTerminated := True;
end;

function TMonitorState.IsPaused: Boolean;
begin
  Result := FPaused;
end;

function TMonitorState.IsTerminated: Boolean;
begin
  Result := FTerminated;
end;

{ TInputThread }

constructor TInputThread.Create(ADBExecutor: TADBExecutor; ProjectManager: TProjectManager;
  Deployer: TAPKDeployer; MonitorState: TMonitorState;
  PendingProcessor: TPendingFileProcessor; LogcatManager: TLogcatManager;
  RecorderManager: TScreenRecorderManager; FPSManager: TFPSManager;
  ProfileManager: TProfileManager);
begin
  inherited Create(False);
  FADBExecutor := ADBExecutor;
  FProjectManager := ProjectManager;
  FDeployer := Deployer;
  FMonitorState := MonitorState;
  FPendingProcessor := PendingProcessor;
  FLogcatManager := LogcatManager;
  FRecorderManager := RecorderManager;
  FFPSManager := FPSManager;
  FProfileManager := ProfileManager;
  FreeOnTerminate := True;
end;

procedure TInputThread.PrintHelp;
begin
  Console.Lock;
  try
    Writeln('Commands:');
    Writeln('  list                - Show current projects');
    Writeln('  build all|<name>    - Build all or specific project');
    Writeln('  deploy all|<name>   - Deploy all or specific project');
    Writeln('  bd all|<name>       - Build and deploy all or specific project');
    Writeln('  pause               - Pause auto-detection');
    Writeln('  resume              - Resume auto-detection');
    Writeln('  devices             - List connected devices (USB and WiFi)');
    Writeln('  pair <ip>:<port>    - Pair with WiFi device (Android 11+)');
    Writeln('  connect <ip>:<port> - Connect to WiFi device');
    Writeln('  disconnect [<ip>:<port>] - Disconnect WiFi device(s)');
    Writeln('  logcat [filter]     - Start logcat (optional package filter)');
    Writeln('  logcat -s <device> [filter] - Start logcat on specific device');
    Writeln('  logcat stop         - Stop logcat');
    Writeln('  logcat pause        - Pause logcat output');
    Writeln('  logcat resume       - Resume logcat output');
    Writeln('  logcat clear        - Clear logcat buffer');
    Writeln('  logcat status       - Show logcat status');
    Writeln('  record start <device> - Start screen recording on device');
    Writeln('  record stop         - Stop recording and save');
    Writeln('  record status       - Show recording status');
    Writeln('  record output <path> - Set output folder for recordings');
    Writeln('  fps <device> <package> - Start FPS monitoring');
    Writeln('  fps stop            - Stop FPS monitoring');
    Writeln('  fps status          - Show FPS monitoring status');
    Writeln('  profile <device> <package> - Start CPU/Memory profiling');
    Writeln('  profile stop        - Stop profiling');
    Writeln('  profile status      - Show profiling status');
    Writeln('  add <project>       - Add a new project to monitor');
    Writeln('  quit                - Exit');
  finally
    Console.Unlock;
  end;
end;

procedure TInputThread.HandleList;
begin
  Writeln('Current projects: ', FProjectManager.ProjectNames.CommaText);
  if FMonitorState.IsPaused then
    Writeln('Auto-detection: PAUSED')
  else
    Writeln('Auto-detection: Active');
end;

procedure TInputThread.HandlePause;
begin
  if FMonitorState.IsPaused then
    Writeln('Auto-detection is already paused.')
  else
    FMonitorState.Pause;
end;

procedure TInputThread.HandleResume;
begin
  if not FMonitorState.IsPaused then
    Writeln('Auto-detection is not paused.')
  else
  begin
    FPendingProcessor.Clear;
    FMonitorState.ResumeMonitoring;
  end;
end;

procedure TInputThread.HandleDevices;
begin
  Writeln('Listing connected devices...');
  Writeln(FADBExecutor.GetCommandOutput('adb devices'));
end;

procedure TInputThread.HandlePair(const Param: string);
var
  PairingCode, OldPrompt: string;
begin
  if Param = '' then
  begin
    Writeln('Usage: pair <ip>:<pairing-port>');
    Writeln('  On your device: Settings > Developer options > Wireless debugging');
    Writeln('  Tap "Pair device with pairing code" to get the IP, port, and 6-digit code');
  end
  else
  begin
    Writeln('Pairing with device at: ' + Param);
    Writeln('Enter the 6-digit pairing code shown on your device:');
    OldPrompt := Console.Prompt;
    Console.Prompt := 'Pairing code: ';
    PairingCode := Trim(Console.ReadLine);
    Console.Prompt := OldPrompt;
    if PairingCode <> '' then
    begin
      Writeln('Executing: adb pair ' + Param + ' ' + PairingCode);
      Writeln(FADBExecutor.GetCommandOutput('adb pair ' + Param + ' ' + PairingCode));
    end
    else
      Writeln('Pairing cancelled.');
  end;
end;

procedure TInputThread.HandleConnect(const Param: string);
begin
  if Param = '' then
  begin
    Writeln('Usage: connect <ip>:<port>');
    Writeln('  Use the IP and port shown in Wireless debugging settings');
    Writeln('  (Note: connection port is different from pairing port)');
  end
  else
  begin
    Writeln('Connecting to device at: ' + Param);
    Writeln(FADBExecutor.GetCommandOutput('adb connect ' + Param));
  end;
end;

procedure TInputThread.HandleDisconnect(const Param: string);
begin
  if Param = '' then
  begin
    Writeln('Disconnecting all WiFi devices...');
    Writeln(FADBExecutor.GetCommandOutput('adb disconnect'));
  end
  else
  begin
    Writeln('Disconnecting device: ' + Param);
    Writeln(FADBExecutor.GetCommandOutput('adb disconnect ' + Param));
  end;
end;

procedure TInputThread.HandleBuild(const Param: string);
var
  i: Integer;
  ProjName: string;
begin
  if SameText(Param, 'all') then
  begin
    Writeln('Building all projects...');
    for i := 0 to FProjectManager.ProjectNames.Count - 1 do
    begin
      ProjName := FProjectManager.ProjectNames[i];
      FDeployer.ExecuteActionOnProject(ProjName, daBuild);
    end;
    Writeln('Build all completed.');
  end
  else
    FDeployer.ExecuteActionOnProject(Param, daBuild);
end;

procedure TInputThread.HandleDeploy(const Param: string);
var
  i: Integer;
  ProjName: string;
begin
  if SameText(Param, 'all') then
  begin
    Writeln('Deploying all projects...');
    for i := 0 to FProjectManager.ProjectNames.Count - 1 do
    begin
      ProjName := FProjectManager.ProjectNames[i];
      FDeployer.ExecuteActionOnProject(ProjName, daDeploy);
    end;
    Writeln('Deploy all completed.');
  end
  else
    FDeployer.ExecuteActionOnProject(Param, daDeploy);
end;

procedure TInputThread.HandleBuildAndDeploy(const Param: string);
var
  i: Integer;
  ProjName: string;
begin
  if SameText(Param, 'all') then
  begin
    Writeln('Building and deploying all projects...');
    for i := 0 to FProjectManager.ProjectNames.Count - 1 do
    begin
      ProjName := FProjectManager.ProjectNames[i];
      FDeployer.ExecuteActionOnProject(ProjName, daBuildAndDeploy);
    end;
    Writeln('Build and deploy all completed.');
  end
  else
    FDeployer.ExecuteActionOnProject(Param, daBuildAndDeploy);
end;

procedure TInputThread.HandleLogcat(const Param: string);
var
  DeviceId, Filter, Rest: string;
  SpacePos: Integer;
begin
  // Parse the parameter
  if Param = '' then
  begin
    // Start logcat with no filter
    FLogcatManager.Start('', '');
  end
  else if SameText(Param, 'stop') then
  begin
    FLogcatManager.Stop;
  end
  else if SameText(Param, 'pause') then
  begin
    FLogcatManager.Pause;
  end
  else if SameText(Param, 'resume') then
  begin
    FLogcatManager.Resume;
  end
  else if SameText(Param, 'clear') then
  begin
    FLogcatManager.Clear('');
  end
  else if SameText(Param, 'status') then
  begin
    Writeln(FLogcatManager.GetStatus);
  end
  else if StartsText('-s ', Param) then
  begin
    // logcat -s <device> [filter]
    Rest := Trim(Copy(Param, 4, MaxInt));
    SpacePos := Pos(' ', Rest);
    if SpacePos > 0 then
    begin
      DeviceId := Copy(Rest, 1, SpacePos - 1);
      Filter := Trim(Copy(Rest, SpacePos + 1, MaxInt));
    end
    else
    begin
      DeviceId := Rest;
      Filter := '';
    end;
    FLogcatManager.Start(DeviceId, Filter);
  end
  else if StartsText('clear ', Param) then
  begin
    // logcat clear <device>
    DeviceId := Trim(Copy(Param, 7, MaxInt));
    FLogcatManager.Clear(DeviceId);
  end
  else
  begin
    // logcat <filter>
    FLogcatManager.Start('', Param);
  end;
end;

procedure TInputThread.HandleRecord(const Param: string);
var
  Rest, DeviceId: string;
begin
  if Param = '' then
  begin
    // Show usage
    Writeln('Usage:');
    Writeln('  record start <device> - Start screen recording on device');
    Writeln('  record stop           - Stop recording and save');
    Writeln('  record status         - Show recording status');
    Writeln('  record output <path>  - Set output folder for recordings');
  end
  else if SameText(Param, 'stop') then
  begin
    FRecorderManager.StopRecording;
  end
  else if SameText(Param, 'status') then
  begin
    Writeln(FRecorderManager.GetStatus);
  end
  else if StartsText('start ', Param) then
  begin
    // record start <device>
    DeviceId := Trim(Copy(Param, 7, MaxInt));
    FRecorderManager.StartRecording(DeviceId);
  end
  else if SameText(Param, 'start') then
  begin
    // record start without device
    Writeln('Error: Device ID is required.');
    Writeln('Usage: record start <device-id>');
    Writeln('Use "devices" command to list connected devices.');
  end
  else if StartsText('output ', Param) then
  begin
    // record output <path>
    Rest := Trim(Copy(Param, 8, MaxInt));
    FRecorderManager.SetOutputFolder(Rest);
  end
  else if SameText(Param, 'output') then
  begin
    // Show current output folder
    if FRecorderManager.GetOutputFolder <> '' then
      Writeln('Output folder: ' + FRecorderManager.GetOutputFolder)
    else
      Writeln('Output folder not configured. Use "record output <path>" to set.');
  end
  else
    Writeln('Unknown record command. Type "record" for help.');
end;

procedure TInputThread.HandleFPS(const Param: string);
var
  DeviceId, PackageName, Rest: string;
  SpacePos: Integer;
begin
  if Param = '' then
  begin
    // Show usage
    Writeln('Usage:');
    Writeln('  fps <device> <package> - Start FPS monitoring');
    Writeln('  fps stop               - Stop FPS monitoring');
    Writeln('  fps status             - Show FPS monitoring status');
  end
  else if SameText(Param, 'stop') then
  begin
    FFPSManager.Stop;
  end
  else if SameText(Param, 'status') then
  begin
    Writeln(FFPSManager.GetStatus);
  end
  else
  begin
    // fps <device> <package>
    Rest := Param;
    SpacePos := Pos(' ', Rest);
    if SpacePos > 0 then
    begin
      DeviceId := Copy(Rest, 1, SpacePos - 1);
      PackageName := Trim(Copy(Rest, SpacePos + 1, MaxInt));
      FFPSManager.Start(DeviceId, PackageName);
    end
    else
    begin
      // Only device provided, no package
      Writeln('Error: Package name is required.');
      Writeln('Usage: fps <device-id> <package-name>');
    end;
  end;
end;

procedure TInputThread.HandleProfile(const Param: string);
var
  DeviceId, PackageName, Rest: string;
  SpacePos: Integer;
begin
  if Param = '' then
  begin
    // Show usage
    Writeln('Usage:');
    Writeln('  profile <device> <package> - Start CPU/Memory profiling');
    Writeln('  profile stop               - Stop profiling');
    Writeln('  profile status             - Show profiling status');
  end
  else if SameText(Param, 'stop') then
  begin
    FProfileManager.Stop;
  end
  else if SameText(Param, 'status') then
  begin
    Writeln(FProfileManager.GetStatus);
  end
  else
  begin
    // profile <device> <package>
    Rest := Param;
    SpacePos := Pos(' ', Rest);
    if SpacePos > 0 then
    begin
      DeviceId := Copy(Rest, 1, SpacePos - 1);
      PackageName := Trim(Copy(Rest, SpacePos + 1, MaxInt));
      FProfileManager.Start(DeviceId, PackageName);
    end
    else
    begin
      // Only device provided, no package
      Writeln('Error: Package name is required.');
      Writeln('Usage: profile <device-id> <package-name>');
    end;
  end;
end;

procedure TInputThread.Execute;
var
  Input, Param: string;
begin
  Writeln;
  PrintHelp;
  Writeln;

  // Initialize console TUI
  Console.Initialize;
  Console.Prompt := '> ';

  while not Terminated do
  begin
    Input := Trim(Console.ReadLine);

    if Input = '' then
      Continue;

    if SameText(Input, 'quit') or SameText(Input, 'exit') then
    begin
      Writeln('Stopping monitor...');
      FMonitorState.Terminate;
      Break;
    end;

    if SameText(Input, 'list') then
    begin
      HandleList;
      Continue;
    end;

    if SameText(Input, 'help') then
    begin
      PrintHelp;
      Continue;
    end;

    if SameText(Input, 'pause') then
    begin
      HandlePause;
      Continue;
    end;

    if SameText(Input, 'resume') then
    begin
      HandleResume;
      Continue;
    end;

    if SameText(Input, 'devices') then
    begin
      HandleDevices;
      Continue;
    end;

    if StartsText('pair ', Input) then
    begin
      Param := Trim(Copy(Input, 6, MaxInt));
      HandlePair(Param);
      Continue;
    end;

    if StartsText('connect ', Input) then
    begin
      Param := Trim(Copy(Input, 9, MaxInt));
      HandleConnect(Param);
      Continue;
    end;

    if StartsText('disconnect', Input) then
    begin
      Param := Trim(Copy(Input, 11, MaxInt));
      HandleDisconnect(Param);
      Continue;
    end;

    if StartsText('build ', Input) then
    begin
      Param := Trim(Copy(Input, 7, MaxInt));
      HandleBuild(Param);
      Continue;
    end;

    if StartsText('deploy ', Input) then
    begin
      Param := Trim(Copy(Input, 8, MaxInt));
      HandleDeploy(Param);
      Continue;
    end;

    if StartsText('bd ', Input) then
    begin
      Param := Trim(Copy(Input, 4, MaxInt));
      HandleBuildAndDeploy(Param);
      Continue;
    end;

    if SameText(Input, 'logcat') then
    begin
      HandleLogcat('');
      Continue;
    end;

    if StartsText('logcat ', Input) then
    begin
      Param := Trim(Copy(Input, 8, MaxInt));
      HandleLogcat(Param);
      Continue;
    end;

    if SameText(Input, 'record') then
    begin
      HandleRecord('');
      Continue;
    end;

    if StartsText('record ', Input) then
    begin
      Param := Trim(Copy(Input, 8, MaxInt));
      HandleRecord(Param);
      Continue;
    end;

    if SameText(Input, 'fps') then
    begin
      HandleFPS('');
      Continue;
    end;

    if StartsText('fps ', Input) then
    begin
      Param := Trim(Copy(Input, 5, MaxInt));
      HandleFPS(Param);
      Continue;
    end;

    if SameText(Input, 'profile') then
    begin
      HandleProfile('');
      Continue;
    end;

    if StartsText('profile ', Input) then
    begin
      Param := Trim(Copy(Input, 9, MaxInt));
      HandleProfile(Param);
      Continue;
    end;

    if StartsText('add ', Input) then
    begin
      Param := Trim(Copy(Input, 5, MaxInt));
      if Param <> '' then
        FProjectManager.AddProject(Param)
      else
        Writeln('Usage: add <projectname>');
      Continue;
    end;

    // Unknown command
    Writeln('Unknown command: ', Input);
    Writeln('Type "help" for available commands.');
  end;
end;

end.
