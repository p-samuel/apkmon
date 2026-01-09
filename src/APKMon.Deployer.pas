unit APKMon.Deployer;

interface

uses
  SysUtils, Classes,
  APKMon.Types, APKMon.Utils, APKMon.ADB, APKMon.Projects, APKMon.Monitor,
  APKMon.Logcat;

type
  TAPKDeployer = class
  private
    FADBExecutor: TADBExecutor;
    FProjectManager: TProjectManager;
    FStabilityChecker: TFileStabilityChecker;
    FBuildConfig: TBuildConfig;
    FDeployAction: TDeployAction;
    FBuildConfigMapper: TEnumMapper<TBuildConfig>;
    FDeployActionMapper: TEnumMapper<TDeployAction>;
    FLogcatManager: TLogcatManager;
    procedure InitializeMappers;
  public
    constructor Create(ADBExecutor: TADBExecutor; ProjectManager: TProjectManager; StabilityChecker: TFileStabilityChecker; BuildConfig: TBuildConfig; DeployAction: TDeployAction);
    destructor Destroy; override;
    function BuildProject(const ProjectFile: string; const Platform: TTargetPlatform): Boolean;
    procedure DeployAPK(const APKPath: string);
    procedure ExecuteActionOnProject(const ProjectName: string; Action: TDeployAction);
    function FindAPKFile(const DetectedFilePath: string; const ProjectInfo: TProjectInfo;const Platform: TTargetPlatform): string;
    function FindAPKRecursively(const StartDirectory: string): string;
    function DetermineTargetABI(const APKPath: string; const Platform: TTargetPlatform): string;
    function DeterminePlatformFromPath(const FilePath: string): TTargetPlatform;
    procedure SetLogcatManager(ALogcatManager: TLogcatManager);
    property BuildConfigMapper: TEnumMapper<TBuildConfig> read FBuildConfigMapper;
    property DeployActionMapper: TEnumMapper<TDeployAction> read FDeployActionMapper;
    property DeployAction: TDeployAction read FDeployAction;
    property LogcatManager: TLogcatManager read FLogcatManager write FLogcatManager;
  end;

implementation

{ TAPKDeployer }

constructor TAPKDeployer.Create(ADBExecutor: TADBExecutor; ProjectManager: TProjectManager;
  StabilityChecker: TFileStabilityChecker; BuildConfig: TBuildConfig; DeployAction: TDeployAction);
begin
  inherited Create;
  FADBExecutor := ADBExecutor;
  FProjectManager := ProjectManager;
  FStabilityChecker := StabilityChecker;
  FBuildConfig := BuildConfig;
  FDeployAction := DeployAction;
  InitializeMappers;
end;

destructor TAPKDeployer.Destroy;
begin
  FBuildConfigMapper.Free;
  FDeployActionMapper.Free;
  inherited Destroy;
end;

procedure TAPKDeployer.InitializeMappers;
begin
  FBuildConfigMapper := TEnumMapper<TBuildConfig>.Create;
  FBuildConfigMapper.AddMapping(bcDebug, 'Debug');
  FBuildConfigMapper.AddMapping(bcRelease, 'Release');

  FDeployActionMapper := TEnumMapper<TDeployAction>.Create;
  FDeployActionMapper.AddMapping(daBuild, 'Build only');
  FDeployActionMapper.AddMapping(daDeploy, 'Deploy only');
  FDeployActionMapper.AddMapping(daBuildAndDeploy, 'Build and Deploy');
end;

procedure TAPKDeployer.SetLogcatManager(ALogcatManager: TLogcatManager);
begin
  FLogcatManager := ALogcatManager;
end;

function TAPKDeployer.BuildProject(const ProjectFile: string; const Platform: TTargetPlatform): Boolean;
var
  Command: string;
  PlatformStr: string;
begin
  FStabilityChecker.BuildInProgress := True;

  // Auto-pause logcat during build
  if Assigned(FLogcatManager) then
    FLogcatManager.AutoPause;

  try
    PlatformStr := TConditionalHelper<string>.IfThen(Platform = tpAndroid64, 'Android64', 'Android');

    Command := Format('msbuild "%s" /p:Config=%s /target:Deploy /p:platform=%s',
                     [ProjectFile, FBuildConfigMapper.GetString(FBuildConfig), PlatformStr]);

    LogMessage(Format('Building (%s) and deploying project: %s', [PlatformStr, ExtractFileName(ProjectFile)]), lcYellow);
    Result := FADBExecutor.ExecuteCommand(Command);

    if Result then
      LogMessage('Build and deploy completed successfully', lcGreen)
    else
      LogMessage('Build and deploy failed!', lcRed);
  finally
    FStabilityChecker.BuildInProgress := False;
    FStabilityChecker.UpdateLastBuildTime;

    // Auto-resume logcat after build
    if Assigned(FLogcatManager) then
      FLogcatManager.AutoResume;
  end;
end;

procedure TAPKDeployer.DeployAPK(const APKPath: string);
var
  Command: string;
  ProjectInfo: TProjectInfo;
  ActualAPKPath: string;
  TargetABI, DeviceABIList: string;
  TargetPlatform: TTargetPlatform;
  Devices: TStringList;
  DeviceId: string;
begin
  LogMessage('Shared library change detected: ' + ExtractFileName(APKPath), lcGreen);

  // Get project info (includes package name)
  ProjectInfo := FProjectManager.FindProjectInfo(APKPath);

  TargetPlatform := DeterminePlatformFromPath(APKPath);
  LogMessage('Detected target platform: ' +
    TConditionalHelper<string>.IfThen(TargetPlatform = tpAndroid64, 'Android64', 'Android'), lcBlue);

  // Build project if needed
  if FDeployAction in [daBuild, daBuildAndDeploy] then
  begin
    if ProjectInfo.ProjectFile <> '' then
    begin
      if not BuildProject(ProjectInfo.ProjectFile, TargetPlatform) then
      begin
        LogMessage('Skipping deployment due to build failure', lcRed);
        Exit;
      end;
    end
    else
    begin
      LogMessage('No matching project file found, skipping build', lcYellow);
      if FDeployAction = daBuild then
        Exit; // If build-only and no project file, nothing to do
    end;
  end;

  // Deploy if needed
  if FDeployAction in [daDeploy, daBuildAndDeploy] then
  begin
    // Find the actual APK file to install
    ActualAPKPath := FindAPKFile(APKPath, ProjectInfo, TargetPlatform);

    if ActualAPKPath = '' then
    begin
      LogMessage('Could not find APK file to install', lcRed);
      Exit;
    end;

    // Re-evaluate platform based on the actual APK path (in case heuristics differ)
    TargetPlatform := DeterminePlatformFromPath(ActualAPKPath);
    LogMessage('Detected target platform from APK path: ' +
      TConditionalHelper<string>.IfThen(TargetPlatform = tpAndroid64, 'Android64', 'Android'), lcBlue);

    LogMessage('APK to install: ' + ExtractFileName(ActualAPKPath), lcGreen);
    TargetABI := DetermineTargetABI(ActualAPKPath, TargetPlatform);

    if TargetABI <> '' then
      LogMessage('Target ABI: ' + TargetABI, lcBlue);

    LogMessage('Detecting compatible devices...', lcBlue);
    Devices := FADBExecutor.GetMatchingDevices(TargetABI);
    try
      if Devices.Count = 0 then
      begin
        LogMessage('No compatible devices found for deployment.', lcRed);
        Exit;
      end;

      LogMessage(Format('Deploying to %d device(s)...', [Devices.Count]), lcBlue);

      for DeviceId in Devices do
      begin
        DeviceABIList := FADBExecutor.GetDeviceABI(DeviceId);

        if (TargetABI <> '') and (DeviceABIList <> '') and (not FADBExecutor.IsABICompatible(TargetABI, DeviceABIList)) then
        begin
          LogMessage(Format('Skipping device %s: APK ABI %s not compatible with device ABIs %s.', [DeviceId, TargetABI, DeviceABIList]), lcYellow);
          Continue;
        end;

        LogMessage('Using device: ' + DeviceId, lcBlue);

        // Clear app data if package name is available
        if ProjectInfo.PackageName <> '' then
        begin
          LogMessage('Clearing app data for: ' + ProjectInfo.PackageName, lcBlue);
          Command := Format('adb -s %s shell pm clear %s', [DeviceId, ProjectInfo.PackageName]);
          FADBExecutor.ExecuteCommand(Command, False);
        end
        else
        begin
          LogMessage('No package name found - skipping app data clear', lcYellow);
        end;

        LogMessage('Installing APK...', lcYellow);
        Command := Format('adb -s %s install -r "%s"', [DeviceId, ActualAPKPath]);
        if FADBExecutor.ExecuteCommand(Command) then
        begin
          LogMessage(Format('APK installed successfully on %s', [DeviceId]), lcGreen);

          // Start the app if package name is available
          if ProjectInfo.PackageName <> '' then
          begin
            LogMessage('Starting application: ' + ProjectInfo.PackageName, lcBlue);
            Command := Format('adb -s %s shell am start -n %s/com.embarcadero.firemonkey.FMXNativeActivity',
                             [DeviceId, ProjectInfo.PackageName]);
            FADBExecutor.ExecuteCommand(Command, False);
          end
          else
          begin
            LogMessage('No package name found - skipping app start', lcYellow);
          end;
        end
        else
          LogMessage(Format('APK installation failed on %s', [DeviceId]), lcRed);
      end;
    finally
      Devices.Free;
    end;
  end;
end;

procedure TAPKDeployer.ExecuteActionOnProject(const ProjectName: string; Action: TDeployAction);
var
  ProjectInfo: TProjectInfo;
  Platform: TTargetPlatform;
  APKPath, TargetABI, Command, DeviceABIList: string;
  Devices: TStringList;
  DeviceId: string;
begin
  TMonitor.Enter(FProjectManager.ProjectLock);
  try
    if not FProjectManager.ProjectFiles.TryGetValue(LowerCase(ProjectName), ProjectInfo) then
    begin
      LogMessage('Project not found: ' + ProjectName, lcRed);
      Exit;
    end;
  finally
    TMonitor.Exit(FProjectManager.ProjectLock);
  end;

  Platform := tpAndroid64; // Default platform
  LogMessage(Format('Executing %s on project: %s', [FDeployActionMapper.GetString(Action), ProjectName]), lcGreen);

  // Build if needed
  if Action in [daBuild, daBuildAndDeploy] then
  begin
    if ProjectInfo.ProjectFile <> '' then
    begin
      if not BuildProject(ProjectInfo.ProjectFile, Platform) then
      begin
        LogMessage('Build failed for: ' + ProjectName, lcRed);
        if Action = daBuild then
          Exit;
      end;
    end
    else
    begin
      LogMessage('No project file found for: ' + ProjectName, lcRed);
      if Action = daBuild then
        Exit;
    end;
  end;

  // Deploy if needed
  if Action in [daDeploy, daBuildAndDeploy] then
  begin
    APKPath := FindAPKFile('', ProjectInfo, Platform);
    if APKPath = '' then
    begin
      LogMessage('Could not find APK for: ' + ProjectName, lcRed);
      Exit;
    end;

    LogMessage('APK to install: ' + ExtractFileName(APKPath), lcGreen);
    TargetABI := DetermineTargetABI(APKPath, Platform);

    if TargetABI <> '' then
      LogMessage('Target ABI: ' + TargetABI, lcBlue);

    LogMessage('Detecting compatible devices...', lcBlue);
    Devices := FADBExecutor.GetMatchingDevices(TargetABI);
    try
      if Devices.Count = 0 then
      begin
        LogMessage('No compatible devices found for deployment.', lcRed);
        Exit;
      end;

      LogMessage(Format('Deploying to %d device(s)...', [Devices.Count]), lcBlue);

      for DeviceId in Devices do
      begin
        DeviceABIList := FADBExecutor.GetDeviceABI(DeviceId);

        if (TargetABI <> '') and (DeviceABIList <> '') and (not FADBExecutor.IsABICompatible(TargetABI, DeviceABIList)) then
        begin
          LogMessage(Format('Skipping device %s: APK ABI %s not compatible with device ABIs %s.', [DeviceId, TargetABI, DeviceABIList]), lcYellow);
          Continue;
        end;

        LogMessage('Using device: ' + DeviceId, lcBlue);

        // Clear app data if package name is available
        if ProjectInfo.PackageName <> '' then
        begin
          LogMessage('Clearing app data for: ' + ProjectInfo.PackageName, lcBlue);
          Command := Format('adb -s %s shell pm clear %s', [DeviceId, ProjectInfo.PackageName]);
          FADBExecutor.ExecuteCommand(Command, False);
        end;

        LogMessage('Installing APK...', lcYellow);
        Command := Format('adb -s %s install -r "%s"', [DeviceId, APKPath]);
        if FADBExecutor.ExecuteCommand(Command) then
        begin
          LogMessage(Format('APK installed successfully on %s', [DeviceId]), lcGreen);

          // Start the app if package name is available
          if ProjectInfo.PackageName <> '' then
          begin
            LogMessage('Starting application: ' + ProjectInfo.PackageName, lcBlue);
            Command := Format('adb -s %s shell am start -n %s/com.embarcadero.firemonkey.FMXNativeActivity',
                             [DeviceId, ProjectInfo.PackageName]);
            FADBExecutor.ExecuteCommand(Command, False);
          end;
        end
        else
          LogMessage(Format('APK installation failed on %s', [DeviceId]), lcRed);
      end;
    finally
      Devices.Free;
    end;
  end;
end;

function TAPKDeployer.FindAPKFile(const DetectedFilePath: string; const ProjectInfo: TProjectInfo;
  const Platform: TTargetPlatform): string;
var
  ProjectName: string;
  APKSearchPaths: TStringList;
  i: Integer;
  SearchPath, APKFileName: string;
  ConfigStr, PlatformStr: string;
begin
  Result := '';

  // If the detected file is already an APK, use it
  if LowerCase(ExtractFileExt(DetectedFilePath)) = '.apk' then
  begin
    if FileExists(DetectedFilePath) then
      Result := DetectedFilePath;
    Exit;
  end;

  // Otherwise, we need to find the corresponding APK file
  if ProjectInfo.ProjectFile <> '' then
  begin
    ProjectName := ChangeFileExt(ExtractFileName(ProjectInfo.ProjectFile), '');
    ConfigStr := FBuildConfigMapper.GetString(FBuildConfig);
    PlatformStr := TConditionalHelper<string>.IfThen(Platform = tpAndroid64, 'Android64', 'Android');

    APKSearchPaths := TStringList.Create;
    try
      // Common APK locations relative to project file
      APKSearchPaths.Add(ExtractFilePath(ProjectInfo.ProjectFile) + Format('bin\%s\%s\%s\bin\%s.apk', [PlatformStr, ConfigStr, ProjectName, ProjectName]));
      APKSearchPaths.Add(ExtractFilePath(ProjectInfo.ProjectFile) + Format('bin\%s\%s\bin\%s.apk', [PlatformStr, ConfigStr, ProjectName]));
      APKSearchPaths.Add(ExtractFilePath(ProjectInfo.ProjectFile) + Format('bin\%s\%s\%s.apk', [PlatformStr, ConfigStr, ProjectName]));
      APKSearchPaths.Add(ExtractFilePath(ProjectInfo.ProjectFile) + Format('%s\%s\%s.apk', [PlatformStr, ConfigStr, ProjectName]));

      // Search in the same directory as the detected file
      if DetectedFilePath <> '' then
      begin
        SearchPath := ExtractFilePath(DetectedFilePath);
        APKFileName := ProjectName + '.apk';

        // Look for APK in the same directory and parent directories
        while (SearchPath <> '') and (Length(SearchPath) > 3) do
        begin
          APKSearchPaths.Add(SearchPath + APKFileName);
          APKSearchPaths.Add(SearchPath + 'bin\' + APKFileName);
          SearchPath := ExtractFilePath(ExcludeTrailingPathDelimiter(SearchPath));
        end;
      end;

      // Check each potential path
      for i := 0 to APKSearchPaths.Count - 1 do
      begin
        if FileExists(APKSearchPaths[i]) then
        begin
          Result := APKSearchPaths[i];
          LogMessage('Found APK at: ' + Result, lcBlue);
          Exit;
        end;
      end;

    finally
      APKSearchPaths.Free;
    end;
  end;

  // Last resort: search recursively from the detected file's directory
  if (Result = '') and (DetectedFilePath <> '') then
  begin
    LogMessage('Searching for APK files recursively...', lcBlue);
    Result := FindAPKRecursively(ExtractFilePath(DetectedFilePath));
  end;
end;

function TAPKDeployer.FindAPKRecursively(const StartDirectory: string): string;
var
  APKFiles: TStringList;
  i: Integer;
  ProjectName: string;
begin
  Result := '';

  APKFiles := TStringList.Create;
  try
    FindFilesRecursive(StartDirectory, '.apk', APKFiles);

    if APKFiles.Count > 0 then
    begin
      // Try to find APK that matches one of our project names
      for i := 0 to APKFiles.Count - 1 do
      begin
        ProjectName := ChangeFileExt(ExtractFileName(APKFiles[i]), '');
        if FProjectManager.ProjectFiles.ContainsKey(LowerCase(ProjectName)) then
        begin
          Result := APKFiles[i];
          LogMessage('Found matching APK: ' + Result, lcBlue);
          Exit;
        end;
      end;

      // If no exact match, use the first APK found
      Result := APKFiles[0];
      LogMessage('Using first APK found: ' + Result, lcBlue);
    end;

  finally
    APKFiles.Free;
  end;
end;

function TAPKDeployer.DetermineTargetABI(const APKPath: string; const Platform: TTargetPlatform): string;
var
  UpperPath: string;
begin
  UpperPath := UpperCase(StringReplace(APKPath, '/', '\', [rfReplaceAll]));

  // Prefer explicit platform hint
  if Platform = tpAndroid64 then
    Exit('arm64-v8a')
  else if Platform = tpAndroid32 then
    Exit('armeabi-v7a');

  if Pos('\ANDROID64\', UpperPath) > 0 then
    Result := 'arm64-v8a'
  else if Pos('\ANDROID\', UpperPath) > 0 then
    Result := 'armeabi-v7a'
  else
    Result := 'arm64-v8a'; // Default for current Android64 deployments
end;

function TAPKDeployer.DeterminePlatformFromPath(const FilePath: string): TTargetPlatform;
var
  UpperPath: string;
begin
  UpperPath := UpperCase(StringReplace(FilePath, '/', '\', [rfReplaceAll]));

  if Pos('\ANDROID64\', UpperPath) > 0 then
    Result := tpAndroid64
  else if Pos('\ANDROID 64', UpperPath) > 0 then
    Result := tpAndroid64
  else if (Pos('\ANDROID\', UpperPath) > 0) or (Pos('\ANDROID32\', UpperPath) > 0) then
    Result := tpAndroid32
  else
    Result := tpAndroid64; // Default to 64-bit if unclear
end;

end.
