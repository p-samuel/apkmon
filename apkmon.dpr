program apkmon;

{$APPTYPE CONSOLE}

uses
  Windows, SysUtils, Classes, Generics.Collections, DateUtils;

type
  TBuildConfig = (bcDebug, bcRelease);
  TDeployAction = (daBuild, daDeploy, daBuildAndDeploy);
  TTargetPlatform = (tpAndroid32, tpAndroid64);

  // Generic helper class for conditional value selection
  TConditionalHelper<T> = class
  public
    class function IfThen(Condition: Boolean; const TrueValue, FalseValue: T): T; static;
  end;

  // Generic enum-to-string mapper
  TEnumMapper<TEnum> = class
  private
    FMappings: TDictionary<TEnum, string>;
  public
    constructor Create;
    destructor Destroy; override;
    procedure AddMapping(EnumValue: TEnum; const StringValue: string);
    function GetString(EnumValue: TEnum): string;
    function GetStringOrDefault(EnumValue: TEnum; const DefaultValue: string = ''): string;
  end;

  FILE_NOTIFY_INFORMATION = record
    NextEntryOffset: DWORD;
    Action: DWORD;
    FileNameLength: DWORD;
    FileName: array[0..0] of WideChar;
  end;
  PFILE_NOTIFY_INFORMATION = ^FILE_NOTIFY_INFORMATION;


class function TConditionalHelper<T>.IfThen(Condition: Boolean; const TrueValue, FalseValue: T): T;
begin
  if Condition then
    Result := TrueValue
  else
    Result := FalseValue;
end;

constructor TEnumMapper<TEnum>.Create;
begin
  inherited Create;
  FMappings := TDictionary<TEnum, string>.Create;
end;

destructor TEnumMapper<TEnum>.Destroy;
begin
  FMappings.Free;
  inherited Destroy;
end;

procedure TEnumMapper<TEnum>.AddMapping(EnumValue: TEnum; const StringValue: string);
begin
  FMappings.AddOrSetValue(EnumValue, StringValue);
end;

function TEnumMapper<TEnum>.GetString(EnumValue: TEnum): string;
begin
  if not FMappings.TryGetValue(EnumValue, Result) then
    raise Exception.CreateFmt('No mapping found for enum value', []);
end;

function TEnumMapper<TEnum>.GetStringOrDefault(EnumValue: TEnum; const DefaultValue: string = ''): string;
begin
  if not FMappings.TryGetValue(EnumValue, Result) then
    Result := DefaultValue;
end;

type
  TProjectInfo = record
    ProjectFile: string;
    PackageName: string;
  end;

  TAPKMonitorThread = class(TThread)
  private
    FWatchDirectory: string;
    FProjectNames: TStringList;
    FBuildConfig: TBuildConfig;
    FDeployAction: TDeployAction;
    FBuildConfigMapper: TEnumMapper<TBuildConfig>;
    FDeployActionMapper: TEnumMapper<TDeployAction>;
    FProjectFiles: TDictionary<string, TProjectInfo>;
    FPendingFiles: TDictionary<string, TDateTime>;
    FFileStabilityDelay: Integer;
    FMaxWaitTime: Integer;
    FBuildInProgress: Boolean;
    FLastBuildTime: TDateTime;
    FBuildCooldownSeconds: Integer;
    FIgnorePatterns: TStringList;
    FProjectLock: TObject;
    procedure InitializeMappers;
    procedure ScanForProjectFiles;
    function FindProjectInfo(const APKPath: string): TProjectInfo;
    function ExtractProjectNameFromAPK(const APKPath: string): string;
    function ExtractPackageNameFromDproj(const ProjectFile: string): string;
    procedure DeployAPK(const APKPath: string);
    function BuildProject(const ProjectFile: string; const Platform: TTargetPlatform): Boolean;
    function GetEmulator(const TargetABI: string = ''): string;
    function GetMatchingDevices(const TargetABI: string = ''): TStringList;
    function ExecuteCommand(const Command: string; ShowOutput: Boolean = True): Boolean;
    function GetCommandOutput(const Command: string): string;
    function GetDeviceABI(const DeviceId: string): string;
    procedure LogMessage(const Msg: string; Color: Integer = 0);
    procedure FindFilesRecursive(const Directory, Extension: string; Files: TStringList);
    function FindAPKFile(const DetectedFilePath: string; const ProjectInfo: TProjectInfo;
                         const Platform: TTargetPlatform): string;
    function FindAPKRecursively(const StartDirectory: string): string;
    function DetermineTargetABI(const APKPath: string; const Platform: TTargetPlatform): string;
    function IsABICompatible(const TargetAbi, DeviceAbiList: string): Boolean;
    function DeterminePlatformFromPath(const FilePath: string): TTargetPlatform;
    function IsFileStable(const FilePath: string): Boolean;
    procedure ProcessPendingFiles;
    function ShouldIgnoreFile(const FilePath: string): Boolean;
    function IsMainBuildOutputFile(const FilePath: string): Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(const WatchDir: string; ProjectNames: TStringList;
                      BuildConfig: TBuildConfig; DeployAction: TDeployAction);
    destructor Destroy; override;
    procedure AddProject(const ProjectName: string);
  end;

  TInputThread = class(TThread)
  private
    FMonitorThread: TAPKMonitorThread;
  protected
    procedure Execute; override;
  public
    constructor Create(MonitorThread: TAPKMonitorThread);
  end;

constructor TAPKMonitorThread.Create(const WatchDir: string; ProjectNames: TStringList;
                                    BuildConfig: TBuildConfig; DeployAction: TDeployAction);
begin
  inherited Create(False);
  FWatchDirectory := WatchDir;
  FBuildConfig := BuildConfig;
  FDeployAction := DeployAction;
  FProjectNames := TStringList.Create;
  FProjectNames.Assign(ProjectNames);
  FProjectFiles := TDictionary<string, TProjectInfo>.Create;
  FPendingFiles := TDictionary<string, TDateTime>.Create;
  FFileStabilityDelay := 3;
  FMaxWaitTime := 6;
  FreeOnTerminate := True;
  FProjectLock := TObject.Create;
  InitializeMappers;
  ScanForProjectFiles;
  FBuildInProgress := False;
  FLastBuildTime := 0;
  FBuildCooldownSeconds := 10;
  FIgnorePatterns := TStringList.Create;
  
  // Add patterns to ignore (architecture-specific build subdirectories)
  FIgnorePatterns.Add('\library\arm64-v8a\');
  FIgnorePatterns.Add('\library\');
  FIgnorePatterns.Add('\library\armeabi-v7a\');
  FIgnorePatterns.Add('\library\armeabi\');
  FIgnorePatterns.Add('\library\mips\');
  FIgnorePatterns.Add('\__history\');
  FIgnorePatterns.Add('\__recovery\');
end;

destructor TAPKMonitorThread.Destroy;
begin
  FBuildConfigMapper.Free;
  FDeployActionMapper.Free;
  FProjectNames.Free;
  FProjectFiles.Free;
  FPendingFiles.Free;
  FIgnorePatterns.Free;
  FProjectLock.Free;
  inherited Destroy;
end;

procedure TAPKMonitorThread.AddProject(const ProjectName: string);
var
  ProjectFilesList: TStringList;
  i: Integer;
  ProjectFile, ProjName, PackageName: string;
  ProjectInfo: TProjectInfo;
begin
  TMonitor.Enter(FProjectLock);
  try
    // Check if already added
    if FProjectNames.IndexOf(ProjectName) >= 0 then
    begin
      LogMessage('Project already being monitored: ' + ProjectName, 3);
      Exit;
    end;

    FProjectNames.Add(ProjectName);
    LogMessage('Added project to monitor list: ' + ProjectName, 1);

    // Scan for the new project file
    ProjectFilesList := TStringList.Create;
    try
      FindFilesRecursive(FWatchDirectory, '.dproj', ProjectFilesList);

      for i := 0 to ProjectFilesList.Count - 1 do
      begin
        ProjectFile := ProjectFilesList[i];
        ProjName := ChangeFileExt(ExtractFileName(ProjectFile), '');

        if SameText(ProjName, ProjectName) then
        begin
          PackageName := ExtractPackageNameFromDproj(ProjectFile);
          ProjectInfo.ProjectFile := ProjectFile;
          ProjectInfo.PackageName := PackageName;
          FProjectFiles.AddOrSetValue(LowerCase(ProjName), ProjectInfo);

          if PackageName <> '' then
            LogMessage(Format('Found project: %s -> %s (Package: %s)', [ProjName, ProjectFile, PackageName]), 1)
          else
            LogMessage(Format('Found project: %s -> %s (Package: Not found)', [ProjName, ProjectFile]), 3);
          Break;
        end;
      end;
    finally
      ProjectFilesList.Free;
    end;
  finally
    TMonitor.Exit(FProjectLock);
  end;
end;

constructor TInputThread.Create(MonitorThread: TAPKMonitorThread);
begin
  inherited Create(False);
  FMonitorThread := MonitorThread;
  FreeOnTerminate := True;
end;

procedure TInputThread.Execute;
var
  Input: string;
begin
  Writeln;
  Writeln('You can add more projects at any time by typing the project name and pressing Enter.');
  Writeln('Type "list" to see current projects, "quit" to exit.');
  Writeln;

  while not Terminated do
  begin
    Write('> ');
    Readln(Input);
    Input := Trim(Input);

    if Input = '' then
      Continue;

    if SameText(Input, 'quit') or SameText(Input, 'exit') then
    begin
      Writeln('Stopping monitor...');
      FMonitorThread.Terminate;
      Break;
    end;

    if SameText(Input, 'list') then
    begin
      Writeln('Current projects: ', FMonitorThread.FProjectNames.CommaText);
      Continue;
    end;

    FMonitorThread.AddProject(Input);
  end;
end;

procedure TAPKMonitorThread.InitializeMappers;
begin
  FBuildConfigMapper := TEnumMapper<TBuildConfig>.Create;
  FBuildConfigMapper.AddMapping(bcDebug, 'Debug');
  FBuildConfigMapper.AddMapping(bcRelease, 'Release');

  FDeployActionMapper := TEnumMapper<TDeployAction>.Create;
  FDeployActionMapper.AddMapping(daBuild, 'Build only');
  FDeployActionMapper.AddMapping(daDeploy, 'Deploy only');
  FDeployActionMapper.AddMapping(daBuildAndDeploy, 'Build and Deploy');
end;

procedure TAPKMonitorThread.FindFilesRecursive(const Directory, Extension: string; Files: TStringList);
var
  SearchRec: TSearchRec;
  SearchPath: string;
begin
  SearchPath := IncludeTrailingPathDelimiter(Directory);

  // Find files with the specified extension
  if FindFirst(SearchPath + '*' + Extension, faAnyFile, SearchRec) = 0 then
  begin
    try
      repeat
        if (SearchRec.Attr and faDirectory) = 0 then
          Files.Add(SearchPath + SearchRec.Name);
      until FindNext(SearchRec) <> 0;
    finally
      FindClose(SearchRec);
    end;
  end;

  // Recursively search subdirectories
  if FindFirst(SearchPath + '*', faDirectory, SearchRec) = 0 then
  begin
    try
      repeat
        if ((SearchRec.Attr and faDirectory) <> 0) and
           (SearchRec.Name <> '.') and (SearchRec.Name <> '..') then
          FindFilesRecursive(SearchPath + SearchRec.Name, Extension, Files);
      until FindNext(SearchRec) <> 0;
    finally
      FindClose(SearchRec);
    end;
  end;
end;

function TAPKMonitorThread.ExtractPackageNameFromDproj(const ProjectFile: string): string;
var
  ProjectContent: TStringList;
  i: Integer;
  Line, PackageName, ProjectDir, ManifestFile: string;
  StartPos, EndPos: Integer;
  ManifestContent: TStringList;
begin
  Result := '';

  if not FileExists(ProjectFile) then
    Exit;

  ProjectContent := TStringList.Create;
  try
    try
      ProjectContent.LoadFromFile(ProjectFile);
      ProjectDir := ExtractFilePath(ProjectFile);

      // Look for Android package name in various possible formats
      for i := 0 to ProjectContent.Count - 1 do
      begin
        Line := Trim(ProjectContent[i]);

        // Format 1: <Android_PackageName>com.example.app</Android_PackageName>
        if Pos('<Android_PackageName>', Line) > 0 then
        begin
          StartPos := Pos('<Android_PackageName>', Line) + Length('<Android_PackageName>');
          EndPos := Pos('</Android_PackageName>', Line);
          if EndPos > StartPos then
          begin
            PackageName := Copy(Line, StartPos, EndPos - StartPos);
            if PackageName <> '' then
            begin
              Result := PackageName; // Keep original case
              Exit;
            end;
          end;
        end

        // Format 2: Look for package attribute in PropertyGroup
        else if (Pos('Android_PackageName', Line) > 0) and (Pos('=', Line) > 0) then
        begin
          StartPos := Pos('"', Line);
          if StartPos > 0 then
          begin
            Inc(StartPos);
            EndPos := Pos('"', Line, StartPos);
            if EndPos > StartPos then
            begin
              PackageName := Copy(Line, StartPos, EndPos - StartPos);
              if (PackageName <> '') and (Pos('.', PackageName) > 0) then
              begin
                Result := PackageName; // Keep original case
                Exit;
              end;
            end;
          end;
        end

        // Format 3: Look for VerInfo_Keys with CFBundleIdentifier
        else if Pos('CFBundleIdentifier', Line) > 0 then
        begin
          StartPos := Pos('=', Line);
          if StartPos > 0 then
          begin
            Inc(StartPos);
            PackageName := Trim(Copy(Line, StartPos, Length(Line)));
            // Remove quotes if present
            if (Length(PackageName) > 2) and (PackageName[1] = '"') and (PackageName[Length(PackageName)] = '"') then
              PackageName := Copy(PackageName, 2, Length(PackageName) - 2);
            if (PackageName <> '') and (Pos('.', PackageName) > 0) then
            begin
              Result := PackageName; // Keep original case
              Exit;
            end;
          end;
        end;
      end;

      // If not found in .dproj, try to find AndroidManifest.template.xml
      ManifestFile := ProjectDir + 'AndroidManifest.template.xml';
      if not FileExists(ManifestFile) then
        ManifestFile := ProjectDir + 'Android\AndroidManifest.template.xml';
      if not FileExists(ManifestFile) then
        ManifestFile := ProjectDir + 'Platform\Android\AndroidManifest.template.xml';

      if FileExists(ManifestFile) then
      begin
        LogMessage('Checking manifest file: ' + ExtractFileName(ManifestFile), 4);
        ManifestContent := TStringList.Create;
        try
          ManifestContent.LoadFromFile(ManifestFile);
          for i := 0 to ManifestContent.Count - 1 do
          begin
            Line := Trim(ManifestContent[i]);
            if Pos('package=', LowerCase(Line)) > 0 then
            begin
              StartPos := Pos('package="', LowerCase(Line));
              if StartPos > 0 then
              begin
                StartPos := Pos('"', Line, StartPos) + 1;
                EndPos := Pos('"', Line, StartPos);
                if EndPos > StartPos then
                begin
                  PackageName := Copy(Line, StartPos, EndPos - StartPos);
                  // Skip template variables like %package%
                  if (PackageName <> '') and (Pos('.', PackageName) > 0) and (Pos('%', PackageName) = 0) then
                  begin
                    Result := PackageName; // Keep original case
                    LogMessage('Found package in manifest: ' + PackageName, 4);
                    Exit;
                  end;
                end;
              end;
            end;
          end;
        finally
          ManifestContent.Free;
        end;
      end;

      // Last resort: generate a default package name based on project name (preserve case)
      if Result = '' then
      begin
        PackageName := 'com.embarcadero.' + ChangeFileExt(ExtractFileName(ProjectFile), '');
        LogMessage('Using default package name: ' + PackageName, 3);
        Result := PackageName;
      end;

    except
      on E: Exception do
        LogMessage('Error reading project file ' + ProjectFile + ': ' + E.Message, 2);
    end;
  finally
    ProjectContent.Free;
  end;
end;

procedure TAPKMonitorThread.ScanForProjectFiles;
var
  ProjectFilesList: TStringList;
  i, j: Integer;
  ProjectFile, ProjectName, PackageName: string;
  ProjectInfo: TProjectInfo;
begin
  LogMessage('Scanning for project files...', 4);

  ProjectFilesList := TStringList.Create;
  try
    // Find all .dproj files recursively
    FindFilesRecursive(FWatchDirectory, '.dproj', ProjectFilesList);

    FProjectFiles.Clear;

    // Match found project files with our project names
    for i := 0 to ProjectFilesList.Count - 1 do
    begin
      ProjectFile := ProjectFilesList[i];
      ProjectName := ChangeFileExt(ExtractFileName(ProjectFile), '');

      // Check if this project name is in our list
      for j := 0 to FProjectNames.Count - 1 do
      begin
        if SameText(ProjectName, FProjectNames[j]) then
        begin
          // Extract package name from .dproj file
          PackageName := ExtractPackageNameFromDproj(ProjectFile);

          ProjectInfo.ProjectFile := ProjectFile;
          ProjectInfo.PackageName := PackageName;

          FProjectFiles.AddOrSetValue(LowerCase(ProjectName), ProjectInfo);

          if PackageName <> '' then
            LogMessage(Format('Found project: %s -> %s (Package: %s)', [ProjectName, ProjectFile, PackageName]), 1)
          else
            LogMessage(Format('Found project: %s -> %s (Package: Not found)', [ProjectName, ProjectFile]), 3);
          Break;
        end;
      end;
    end;

    LogMessage(Format('Found %d matching project files', [FProjectFiles.Count]), 4);
  finally
    ProjectFilesList.Free;
  end;
end;

function TAPKMonitorThread.ExtractProjectNameFromAPK(const APKPath: string): string;
var
  APKName: string;
  PathParts: TStringList;
  i: Integer;
begin
  Result := '';
  APKName := ChangeFileExt(ExtractFileName(APKPath), '');

  // First try: direct match with APK filename
  if FProjectFiles.ContainsKey(LowerCase(APKName)) then
  begin
    Result := LowerCase(APKName);
    Exit;
  end;

  // Second try: look for project name in the path
  PathParts := TStringList.Create;
  try
    PathParts.Delimiter := '\';
    PathParts.DelimitedText := StringReplace(APKPath, '\', PathParts.Delimiter, [rfReplaceAll]);

    for i := 0 to PathParts.Count - 1 do
    begin
      if FProjectFiles.ContainsKey(LowerCase(PathParts[i])) then
      begin
        Result := LowerCase(PathParts[i]);
        Exit;
      end;
    end;

    // Third try: check if any project name is contained in the APK name
    for i := 0 to FProjectNames.Count - 1 do
    begin
      if Pos(LowerCase(FProjectNames[i]), LowerCase(APKName)) > 0 then
      begin
        Result := LowerCase(FProjectNames[i]);
        Exit;
      end;
    end;
  finally
    PathParts.Free;
  end;
end;

function TAPKMonitorThread.FindProjectInfo(const APKPath: string): TProjectInfo;
var
  ProjectName: string;
begin
  Result.ProjectFile := '';
  Result.PackageName := '';

  ProjectName := ExtractProjectNameFromAPK(APKPath);

  if ProjectName <> '' then
  begin
    if FProjectFiles.TryGetValue(ProjectName, Result) then
      LogMessage(Format('Matched APK %s with project %s', [ExtractFileName(APKPath), Result.ProjectFile]), 4)
    else
      LogMessage(Format('Project name found (%s) but no project file mapped', [ProjectName]), 3);
  end
  else
    LogMessage(Format('Could not determine project name for APK: %s', [ExtractFileName(APKPath)]), 3);
end;

procedure TAPKMonitorThread.LogMessage(const Msg: string; Color: Integer = 0);
const
  Colors: array[0..5] of string = ('', #27'[32m', #27'[31m', #27'[33m', #27'[34m', #27'[35m');
begin
  if Color > 0 then
    Writeln(FormatDateTime('hh:nn:ss', Now), ' ', Colors[Color], Msg, #27'[0m')
  else
    Writeln(FormatDateTime('hh:nn:ss', Now), ' ', Msg);
end;

function TAPKMonitorThread.ExecuteCommand(const Command: string; ShowOutput: Boolean = True): Boolean;
var
  StartupInfo: TStartupInfo;
  ProcessInfo: TProcessInformation;
  ExitCode: DWORD;
  WaitResult: DWORD;
begin
  Result := False;

  if ShowOutput then
    LogMessage('Executing: ' + Command, 4);

  ZeroMemory(@StartupInfo, SizeOf(StartupInfo));
  StartupInfo.cb := SizeOf(StartupInfo);
  StartupInfo.dwFlags := STARTF_USESHOWWINDOW;
  StartupInfo.wShowWindow := SW_HIDE;

  if CreateProcess(nil, PChar(Command), nil, nil, False, 0, nil, nil, StartupInfo, ProcessInfo) then
  begin
    try
      // Wait with timeout (60 seconds for build commands, 30 seconds for others)
      WaitResult := WaitForSingleObject(ProcessInfo.hProcess,
        TConditionalHelper<DWORD>.IfThen(Pos('msbuild', LowerCase(Command)) > 0, 60000, 30000));

      if WaitResult = WAIT_OBJECT_0 then
      begin
        GetExitCodeProcess(ProcessInfo.hProcess, ExitCode);
        Result := ExitCode = 0;
      end
      else
      begin
        // Timeout occurred
        LogMessage('Command timed out, terminating process', 2);
        TerminateProcess(ProcessInfo.hProcess, 1);
        Result := False;
      end;
    finally
      CloseHandle(ProcessInfo.hProcess);
      CloseHandle(ProcessInfo.hThread);
    end;
  end
  else
  begin
    LogMessage('Failed to create process for command: ' + Command, 2);
  end;
end;

function TAPKMonitorThread.GetCommandOutput(const Command: string): string;
var
  StartupInfo: TStartupInfo;
  ProcessInfo: TProcessInformation;
  ReadPipe, WritePipe: THandle;
  SecurityAttr: TSecurityAttributes;
  Buffer: array[0..4095] of AnsiChar;
  BytesRead: DWORD;
  CommandLine: string;
  CommandBuffer: array[0..511] of Char;
begin
  Result := '';

  SecurityAttr.nLength := SizeOf(SecurityAttr);
  SecurityAttr.bInheritHandle := True;
  SecurityAttr.lpSecurityDescriptor := nil;

  if not CreatePipe(ReadPipe, WritePipe, @SecurityAttr, 0) then
    Exit;

  try
    ZeroMemory(@StartupInfo, SizeOf(StartupInfo));
    StartupInfo.cb := SizeOf(StartupInfo);
    StartupInfo.dwFlags := STARTF_USESTDHANDLES or STARTF_USESHOWWINDOW;
    StartupInfo.hStdOutput := WritePipe;
    StartupInfo.hStdError := WritePipe;
    StartupInfo.wShowWindow := SW_HIDE;

    CommandLine := 'cmd.exe /C "' + Command + '"';
    StrPCopy(CommandBuffer, CommandLine);

    if CreateProcess(nil, CommandBuffer, nil, nil, True, 0, nil, nil, StartupInfo, ProcessInfo) then
    begin
      try
        CloseHandle(WritePipe);
        WritePipe := 0;

        if WaitForSingleObject(ProcessInfo.hProcess, 10000) = WAIT_OBJECT_0 then
        begin
          if ReadFile(ReadPipe, Buffer, SizeOf(Buffer) - 1, BytesRead, nil) and (BytesRead > 0) then
          begin
            Buffer[BytesRead] := #0;
            Result := Trim(string(Buffer));
          end;
        end
        else
        begin
          TerminateProcess(ProcessInfo.hProcess, 1);
          LogMessage('Timeout waiting for command: ' + Command, 2);
        end;
      finally
        CloseHandle(ProcessInfo.hProcess);
        CloseHandle(ProcessInfo.hThread);
      end;
    end
    else
      LogMessage('Failed to create process for command output: ' + Command, 2);
  finally
    if WritePipe <> 0 then CloseHandle(WritePipe);
    CloseHandle(ReadPipe);
  end;
end;

function TAPKMonitorThread.GetEmulator(const TargetABI: string = ''): string;
var
  Output: string;
  Lines: TStringList;
  i: Integer;
  Line, DeviceId, Abis: string;
begin
  Result := '';

  Output := GetCommandOutput('adb devices');

  if Trim(Output) = '' then
    Exit;

  Lines := TStringList.Create;
  try
    Lines.Text := Output;
    for i := 0 to Lines.Count - 1 do
    begin
      Line := Trim(Lines[i]);

      // Skip header or empty lines
      if (Line = '') or (Pos('list of devices', LowerCase(Line)) = 1) then
        Continue;

      if Pos('emulator', LowerCase(Line)) > 0 then
      begin
        // Extract the device id (first token)
        DeviceId := Trim(Copy(Line, 1, Pos(#9, Line + #9) - 1));
        if DeviceId = '' then
          DeviceId := Trim(Copy(Line, 1, Pos(' ', Line + ' ') - 1));

        if DeviceId = '' then
          Continue;

        if TargetABI <> '' then
        begin
          Abis := GetDeviceABI(DeviceId);
          if (Abis <> '') and IsABICompatible(TargetABI, Abis) then
          begin
            Result := DeviceId;
            LogMessage(Format('Selected emulator %s (ABI match: %s)', [Result, Abis]), 4);
            Exit;
          end
          else if Abis <> '' then
            LogMessage(Format('Skipping emulator %s due to ABI mismatch (%s)', [DeviceId, Abis]), 3);
        end;

        // Fallback to the first emulator if no ABI match is found
        if Result = '' then
          Result := DeviceId;
      end;
    end;

    if (Result <> '') and (TargetABI <> '') then
      LogMessage('No emulator ABI matched, using first available: ' + Result, 3)
    else if Result <> '' then
      LogMessage('Found emulator: ' + Result, 4);
  finally
    Lines.Free;
  end;
end;

function TAPKMonitorThread.GetDeviceABI(const DeviceId: string): string;
begin
  Result := Trim(GetCommandOutput(Format('adb -s %s shell getprop ro.product.cpu.abilist', [DeviceId])));

  if Result = '' then
    Result := Trim(GetCommandOutput(Format('adb -s %s shell getprop ro.product.cpu.abi', [DeviceId])));

  if Result <> '' then
    LogMessage(Format('Device %s ABI list: %s', [DeviceId, Result]), 4)
  else
    LogMessage('Unable to read device ABI information', 3);
end;

function TAPKMonitorThread.GetMatchingDevices(const TargetABI: string = ''): TStringList;
var
  Output: string;
  Lines: TStringList;
  i: Integer;
  Line, DeviceId, State, Abis: string;
begin
  Result := TStringList.Create;

  Output := GetCommandOutput('adb devices');

  if Trim(Output) = '' then
  begin
    LogMessage('No devices found via adb', 3);
    Exit;
  end;

  Lines := TStringList.Create;
  try
    Lines.Text := Output;
    for i := 0 to Lines.Count - 1 do
    begin
      Line := Trim(Lines[i]);

      // Skip header or empty lines
      if (Line = '') or (Pos('list of devices', LowerCase(Line)) = 1) then
        Continue;

      // Extract device id and state
      DeviceId := Trim(Copy(Line, 1, Pos(#9, Line + #9) - 1));
      if DeviceId = '' then
        DeviceId := Trim(Copy(Line, 1, Pos(' ', Line + ' ') - 1));

      State := Trim(StringReplace(Line, DeviceId, '', []));
      State := Trim(StringReplace(State, #9, ' ', [rfReplaceAll]));

      // Accept only "device" state (skip offline/unauthorized)
      if (DeviceId = '') or (Pos('device', LowerCase(State)) = 0) then
        Continue;

      if TargetABI <> '' then
      begin
        Abis := GetDeviceABI(DeviceId);
        if (Abis <> '') and IsABICompatible(TargetABI, Abis) then
        begin
          Result.Add(DeviceId);
          LogMessage(Format('Device %s selected (ABI match: %s)', [DeviceId, Abis]), 4);
        end
        else if Abis <> '' then
          LogMessage(Format('Skipping device %s due to ABI mismatch (%s)', [DeviceId, Abis]), 3);
      end
      else
      begin
        Result.Add(DeviceId);
        LogMessage('Device ' + DeviceId + ' added (no ABI filter)', 4);
      end;
    end;

    if Result.Count = 0 then
      LogMessage('No devices matched the required ABI. Start an ARM-compatible device/emulator.', 2);
  finally
    Lines.Free;
  end;
end;

function TAPKMonitorThread.BuildProject(const ProjectFile: string; const Platform: TTargetPlatform): Boolean;
var
  Command: string;
  PlatformStr: string;
begin
  FBuildInProgress := True;
  try
    PlatformStr := TConditionalHelper<string>.IfThen(Platform = tpAndroid64, 'Android64', 'Android');

    Command := Format('msbuild "%s" /p:Config=%s /target:Deploy /p:platform=%s',
                     [ProjectFile, FBuildConfigMapper.GetString(FBuildConfig), PlatformStr]);

    LogMessage(Format('Building (%s) and deploying project: %s', [PlatformStr, ExtractFileName(ProjectFile)]), 3);
    Result := ExecuteCommand(Command);

    if Result then
      LogMessage('Build and deploy completed successfully', 1)
    else
      LogMessage('Build and deploy failed!', 2);
  finally
    FBuildInProgress := False;
    FLastBuildTime := Now;
  end;
end;

procedure TAPKMonitorThread.DeployAPK(const APKPath: string);
var
  Command: string;
  ProjectInfo: TProjectInfo;
  ActualAPKPath: string;
  TargetABI, DeviceABIList: string;
  TargetPlatform: TTargetPlatform;
  Devices: TStringList;
  DeviceId: string;
begin
  LogMessage('Shared library change detected: ' + ExtractFileName(APKPath), 1);

  // Get project info (includes package name)
  ProjectInfo := FindProjectInfo(APKPath);

  TargetPlatform := DeterminePlatformFromPath(APKPath);
  LogMessage('Detected target platform: ' +
    TConditionalHelper<string>.IfThen(TargetPlatform = tpAndroid64, 'Android64', 'Android'), 4);

  // Build project if needed
  if FDeployAction in [daBuild, daBuildAndDeploy] then
  begin
    if ProjectInfo.ProjectFile <> '' then
    begin
      if not BuildProject(ProjectInfo.ProjectFile, TargetPlatform) then
      begin
        LogMessage('Skipping deployment due to build failure', 2);
        Exit;
      end;
    end
    else
    begin
      LogMessage('No matching project file found, skipping build', 3);
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
      LogMessage('Could not find APK file to install', 2);
      Exit;
    end;

    // Re-evaluate platform based on the actual APK path (in case heuristics differ)
    TargetPlatform := DeterminePlatformFromPath(ActualAPKPath);
    LogMessage('Detected target platform from APK path: ' +
      TConditionalHelper<string>.IfThen(TargetPlatform = tpAndroid64, 'Android64', 'Android'), 4);

    LogMessage('APK to install: ' + ExtractFileName(ActualAPKPath), 1);
    TargetABI := DetermineTargetABI(ActualAPKPath, TargetPlatform);

    if TargetABI <> '' then
      LogMessage('Target ABI: ' + TargetABI, 4);

    LogMessage('Detecting compatible devices...', 4);
    Devices := GetMatchingDevices(TargetABI);
    try
      if Devices.Count = 0 then
      begin
        LogMessage('No compatible devices found for deployment.', 2);
        Exit;
      end;

      LogMessage(Format('Deploying to %d device(s)...', [Devices.Count]), 4);

      for DeviceId in Devices do
      begin
        DeviceABIList := GetDeviceABI(DeviceId);

        if (TargetABI <> '') and (DeviceABIList <> '') and (not IsABICompatible(TargetABI, DeviceABIList)) then
        begin
          LogMessage(Format('Skipping device %s: APK ABI %s not compatible with device ABIs %s.', [DeviceId, TargetABI, DeviceABIList]), 3);
          Continue;
        end;

        LogMessage('Using device: ' + DeviceId, 4);

        // Clear app data if package name is available
        if ProjectInfo.PackageName <> '' then
        begin
          LogMessage('Clearing app data for: ' + ProjectInfo.PackageName, 4);
          Command := Format('adb -s %s shell pm clear %s', [DeviceId, ProjectInfo.PackageName]);
          ExecuteCommand(Command, False);
        end
        else
        begin
          LogMessage('No package name found - skipping app data clear', 3);
        end;

        LogMessage('Installing APK...', 3);
        Command := Format('adb -s %s install -r "%s"', [DeviceId, ActualAPKPath]);
        if ExecuteCommand(Command) then
        begin
          LogMessage(Format('APK installed successfully on %s', [DeviceId]), 1);

          // Start the app if package name is available
          if ProjectInfo.PackageName <> '' then
          begin
            LogMessage('Starting application: ' + ProjectInfo.PackageName, 4);
            Command := Format('adb -s %s shell am start -n %s/com.embarcadero.firemonkey.FMXNativeActivity',
                             [DeviceId, ProjectInfo.PackageName]);
            ExecuteCommand(Command, False);
          end
          else
          begin
            LogMessage('No package name found - skipping app start', 3);
          end;
        end
        else
          LogMessage(Format('APK installation failed on %s', [DeviceId]), 2);
      end;
    finally
      Devices.Free;
    end;
  end;
end;

procedure TAPKMonitorThread.Execute;
var
  DirectoryHandle: THandle;
  Buffer: array[0..1023] of Byte;
  BytesReturned: DWORD;
  Info: PFILE_NOTIFY_INFORMATION;
  Offset: DWORD;
  FileName: WideString;
  FullPath: string;
begin
  DirectoryHandle := CreateFile(
    PChar(FWatchDirectory),
    FILE_LIST_DIRECTORY,
    FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,
    nil,
    OPEN_EXISTING,
    FILE_FLAG_BACKUP_SEMANTICS,
    0
  );

  if DirectoryHandle = INVALID_HANDLE_VALUE then
  begin
    LogMessage('Error opening directory: ' + FWatchDirectory, 2);
    Exit;
  end;

  try
    LogMessage('Monitoring ' + FWatchDirectory + ' for .so changes (recursive)...', 1);
    LogMessage(Format('File stability delay: %d seconds, max wait: %d seconds', [FFileStabilityDelay, FMaxWaitTime]), 4);

    while not Terminated do
    begin
      if ReadDirectoryChangesW(
        DirectoryHandle,
        @Buffer,
        SizeOf(Buffer),
        True, // Recursive monitoring
        FILE_NOTIFY_CHANGE_FILE_NAME or FILE_NOTIFY_CHANGE_SIZE or FILE_NOTIFY_CHANGE_LAST_WRITE,
        @BytesReturned,
        nil,
        nil
      ) then
      begin
        Offset := 0;
        repeat
          Info := PFILE_NOTIFY_INFORMATION(@Buffer[Offset]);
          SetString(FileName, Info^.FileName, Info^.FileNameLength div SizeOf(WideChar));

          // Monitor only .so files
          if LowerCase(ExtractFileExt(FileName)) = '.so' then
          begin
            case Info^.Action of
              FILE_ACTION_ADDED:
              begin
                LogMessage('FILE_ACTION_ADDED: ' + ExtractFileName(FileName), 4);
                FullPath := FWatchDirectory + '\' + FileName;

                if FileExists(FullPath) and not ShouldIgnoreFile(FullPath) then
                begin
                  LogMessage('Shared library created: ' + ExtractFileName(FullPath), 4);

                  // Add to pending files with current timestamp
                  FPendingFiles.AddOrSetValue(FullPath, Now);
                  LogMessage('Added to pending queue: ' + ExtractFileName(FullPath), 4);
                end;
              end;
              FILE_ACTION_REMOVED:
              begin
                LogMessage('FILE_ACTION_REMOVED: ' + ExtractFileName(FileName), 4);
              end;
              FILE_ACTION_MODIFIED:
              begin
                LogMessage('FILE_ACTION_MODIFIED: ' + ExtractFileName(FileName), 4);
              end;
              FILE_ACTION_RENAMED_OLD_NAME:
              begin
                LogMessage('FILE_ACTION_RENAMED_OLD_NAME: ' + ExtractFileName(FileName), 4);
              end;
              FILE_ACTION_RENAMED_NEW_NAME:
              begin
                LogMessage('FILE_ACTION_RENAMED_NEW_NAME: ' + ExtractFileName(FileName), 4);
              end;
            else
              LogMessage('UNKNOWN_ACTION (' + IntToStr(Info^.Action) + '): ' + ExtractFileName(FileName), 4);
            end;
          end;

          Offset := Offset + Info^.NextEntryOffset;
        until Info^.NextEntryOffset = 0;

        // Always check pending files after processing directory changes
        ProcessPendingFiles;
      end
      else
      begin
        LogMessage('Error reading directory changes', 2);
        Break;
      end;
    end;
  finally
    CloseHandle(DirectoryHandle);
  end;
end;

function TAPKMonitorThread.FindAPKFile(const DetectedFilePath: string; const ProjectInfo: TProjectInfo;
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
      SearchPath := ExtractFilePath(DetectedFilePath);
      APKFileName := ProjectName + '.apk';

      // Look for APK in the same directory and parent directories
      while (SearchPath <> '') and (Length(SearchPath) > 3) do
      begin
        APKSearchPaths.Add(SearchPath + APKFileName);
        APKSearchPaths.Add(SearchPath + 'bin\' + APKFileName);
        SearchPath := ExtractFilePath(ExcludeTrailingPathDelimiter(SearchPath));
      end;

      // Check each potential path
      for i := 0 to APKSearchPaths.Count - 1 do
      begin
        if FileExists(APKSearchPaths[i]) then
        begin
          Result := APKSearchPaths[i];
          LogMessage('Found APK at: ' + Result, 4);
          Exit;
        end;
      end;

    finally
      APKSearchPaths.Free;
    end;
  end;

  // Last resort: search recursively from the detected file's directory
  if Result = '' then
  begin
    LogMessage('Searching for APK files recursively...', 4);
    Result := FindAPKRecursively(ExtractFilePath(DetectedFilePath));
  end;
end;

function TAPKMonitorThread.DetermineTargetABI(const APKPath: string; const Platform: TTargetPlatform): string;
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

function TAPKMonitorThread.DeterminePlatformFromPath(const FilePath: string): TTargetPlatform;
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

function TAPKMonitorThread.IsABICompatible(const TargetAbi, DeviceAbiList: string): Boolean;
var
  TargetLower, DeviceLower: string;
begin
  TargetLower := LowerCase(TargetAbi);
  DeviceLower := LowerCase(DeviceAbiList);

  Result := Pos(TargetLower, DeviceLower) > 0;
end;

function TAPKMonitorThread.FindAPKRecursively(const StartDirectory: string): string;
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
        if FProjectFiles.ContainsKey(LowerCase(ProjectName)) then
        begin
          Result := APKFiles[i];
          LogMessage('Found matching APK: ' + Result, 4);
          Exit;
        end;
      end;

      // If no exact match, use the first APK found
      Result := APKFiles[0];
      LogMessage('Using first APK found: ' + Result, 4);
    end;

  finally
    APKFiles.Free;
  end;
end;

function TAPKMonitorThread.IsFileStable(const FilePath: string): Boolean;
var
  FileHandle: THandle;
  FileSize1, FileSize2: Int64;
  FileTime1, FileTime2: TFileTime;
begin
  Result := False;

  if not FileExists(FilePath) then
  begin
    LogMessage('File no longer exists: ' + ExtractFileName(FilePath), 4);
    Exit;
  end;

  // Try to open the file with shared read access first
  FileHandle := CreateFile(PChar(FilePath), GENERIC_READ, FILE_SHARE_READ, nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
  if FileHandle = INVALID_HANDLE_VALUE then
  begin
    LogMessage('Cannot open file for reading: ' + ExtractFileName(FilePath), 4);
    Exit;
  end;

  try
    // Get initial file size and time
    if not GetFileSizeEx(FileHandle, FileSize1) then
    begin
      LogMessage('Cannot get file size: ' + ExtractFileName(FilePath), 4);
      Exit;
    end;
    if not GetFileTime(FileHandle, nil, nil, @FileTime1) then
    begin
      LogMessage('Cannot get file time: ' + ExtractFileName(FilePath), 4);
      Exit;
    end;

    CloseHandle(FileHandle);
    FileHandle := INVALID_HANDLE_VALUE;

    LogMessage(Format('File %s: Size=%d bytes, checking stability...', [ExtractFileName(FilePath), FileSize1]), 4);

    // Wait a short time and check again
    Sleep(500);

    FileHandle := CreateFile(PChar(FilePath), GENERIC_READ, FILE_SHARE_READ, nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
    if FileHandle = INVALID_HANDLE_VALUE then
    begin
      LogMessage('Cannot reopen file for reading: ' + ExtractFileName(FilePath), 4);
      Exit;
    end;

    if not GetFileSizeEx(FileHandle, FileSize2) then
    begin
      LogMessage('Cannot get file size on second check: ' + ExtractFileName(FilePath), 4);
      Exit;
    end;
    if not GetFileTime(FileHandle, nil, nil, @FileTime2) then
    begin
      LogMessage('Cannot get file time on second check: ' + ExtractFileName(FilePath), 4);
      Exit;
    end;

    // File is stable if size and time haven't changed
    Result := (FileSize1 = FileSize2) and
              (FileTime1.dwLowDateTime = FileTime2.dwLowDateTime) and
              (FileTime1.dwHighDateTime = FileTime2.dwHighDateTime);

    if Result then
      LogMessage(Format('File %s is stable (Size: %d bytes)', [ExtractFileName(FilePath), FileSize2]), 1)
    else
      LogMessage(Format('File %s still changing (Size: %d->%d)', [ExtractFileName(FilePath), FileSize1, FileSize2]), 4);

  finally
    if FileHandle <> INVALID_HANDLE_VALUE then
      CloseHandle(FileHandle);
  end;
end;

function TAPKMonitorThread.ShouldIgnoreFile(const FilePath: string): Boolean;
var
  i: Integer;
  NormalizedPath: string;
begin
  Result := False;
  
  if FBuildInProgress then
  begin
    LogMessage('Ignoring file change during build: ' + ExtractFileName(FilePath), 4);
    Result := True;
    Exit;
  end;
  
  if (FLastBuildTime > 0) and (SecondsBetween(Now, FLastBuildTime) < FBuildCooldownSeconds) then
  begin
    LogMessage(Format('Ignoring file change during cooldown: %s', [ExtractFileName(FilePath)]), 4);
    Result := True;
    Exit;
  end;
  
  // Check against ignore patterns
  NormalizedPath := UpperCase(StringReplace(FilePath, '/', '\', [rfReplaceAll]));
  for i := 0 to FIgnorePatterns.Count - 1 do
  begin
    if Pos(FIgnorePatterns[i], NormalizedPath) > 0 then
    begin
      LogMessage('Ignoring file matching pattern ' + FIgnorePatterns[i] + ': ' + ExtractFileName(FilePath), 4);
      Result := True;
      Exit;
    end;
  end;
  
  // Special case for the complex DEBUG + LIBRARY condition
  if (Pos('\DEBUG\', NormalizedPath) > 0) and (Pos('\LIBRARY\', NormalizedPath) > 0) then
  begin
    LogMessage('Ignoring file in DEBUG\LIBRARY path: ' + ExtractFileName(FilePath), 4);
    Result := True;
    Exit;
  end;
end;

function TAPKMonitorThread.IsMainBuildOutputFile(const FilePath: string): Boolean;
var
  NormalizedPath: string;
  ConfigStr: string;
begin
  Result := False;
  NormalizedPath := UpperCase(StringReplace(FilePath, '/', '\', [rfReplaceAll]));
  ConfigStr := UpperCase(FBuildConfigMapper.GetString(FBuildConfig));

  // Only accept .so files that match the pattern: \bin\Android64\Debug\ (or Release)
  // The ignore patterns will handle filtering out unwanted subdirectories
  if (Pos('\BIN\ANDROID64\' + ConfigStr + '\', NormalizedPath) > 0) then
  begin
    Result := True;
    LogMessage('Accepting build .so file: ' + FilePath, 4);
  end;
end;

procedure TAPKMonitorThread.ProcessPendingFiles;
var
  FilePath: string;
  FileTime: TDateTime;
  FilesToProcess: TStringList;
  FilesToRemove: TStringList;
  i: Integer;
  SecondsSinceAdded: Integer;
begin
  if FPendingFiles.Count = 0 then
    Exit;

  FilesToProcess := TStringList.Create;
  FilesToRemove := TStringList.Create;
  try
    // Check which files are ready to process
    for FilePath in FPendingFiles.Keys do
    begin
      if not FileExists(FilePath) then
      begin
        LogMessage('Removing non-existent file from queue: ' + ExtractFileName(FilePath), 4);
        FilesToRemove.Add(FilePath);
        Continue;
      end;

      FileTime := FPendingFiles[FilePath];
      Sleep(FFileStabilityDelay * 1000);
      SecondsSinceAdded := SecondsBetween(Now, FileTime);

      LogMessage(Format('Checking file %s: %d seconds old', [ExtractFileName(FilePath), SecondsSinceAdded]), 4);

      // Check if enough time has passed
      if SecondsSinceAdded >= FFileStabilityDelay then
      begin
        LogMessage(Format('File %s passed time check, checking stability...', [ExtractFileName(FilePath)]), 4);

        if IsFileStable(FilePath) or (SecondsSinceAdded >= FMaxWaitTime) then
        begin
          if SecondsSinceAdded >= FMaxWaitTime then
            LogMessage(Format('File %s reached maximum wait time, processing anyway', [ExtractFileName(FilePath)]), 3);

          FilesToProcess.Add(FilePath);
          LogMessage(Format('File %s is ready for processing', [ExtractFileName(FilePath)]), 1);
        end
        else
        begin
          // Update timestamp to give it more time
          FPendingFiles.AddOrSetValue(FilePath, Now);
          LogMessage(Format('File %s not stable yet, resetting timer', [ExtractFileName(FilePath)]), 4);
        end;
      end;
    end;

    // Remove non-existent files
    for i := 0 to FilesToRemove.Count - 1 do
    begin
      FPendingFiles.Remove(FilesToRemove[i]);
    end;

    // Process stable files
    for i := 0 to FilesToProcess.Count - 1 do
    begin
      FilePath := FilesToProcess[i];
      FPendingFiles.Remove(FilePath);

      LogMessage('Processing stable file: ' + ExtractFileName(FilePath), 1);
      DeployAPK(FilePath);
    end;

  finally
    FilesToProcess.Free;
    FilesToRemove.Free;
  end;
end;

procedure FindDprFilesRecursive(const Directory: string; Files: TStringList);
var
  SearchRec: TSearchRec;
  SearchPath: string;
begin
  SearchPath := IncludeTrailingPathDelimiter(Directory);

  // Find .dpr files
  if FindFirst(SearchPath + '*.dpr', faAnyFile, SearchRec) = 0 then
  begin
    try
      repeat
        if (SearchRec.Attr and faDirectory) = 0 then
          Files.Add(SearchPath + SearchRec.Name);
      until FindNext(SearchRec) <> 0;
    finally
      FindClose(SearchRec);
    end;
  end;

  // Recursively search subdirectories
  if FindFirst(SearchPath + '*', faDirectory, SearchRec) = 0 then
  begin
    try
      repeat
        if ((SearchRec.Attr and faDirectory) <> 0) and
           (SearchRec.Name <> '.') and (SearchRec.Name <> '..') then
          FindDprFilesRecursive(SearchPath + SearchRec.Name, Files);
      until FindNext(SearchRec) <> 0;
    finally
      FindClose(SearchRec);
    end;
  end;
end;

// Main program
var
  WatchDirectory, Input: string;
  ProjectNames: TStringList;
  BuildConfig: TBuildConfig;
  DeployAction: TDeployAction;
  ConfigChoice, ActionChoice, ProjectChoice: Integer;
  BuildConfigMapper: TEnumMapper<TBuildConfig>;
  DeployActionMapper: TEnumMapper<TDeployAction>;
  DprFiles: TStringList;
  i: Integer;
  ProjectName: string;
  MonitorThread: TAPKMonitorThread;
  InputThread: TInputThread;

begin
  Writeln('=== APK Deploy Monitor ===');
  Writeln;

  // Initialize mappers for main program
  BuildConfigMapper := TEnumMapper<TBuildConfig>.Create;
  try
    BuildConfigMapper.AddMapping(bcDebug, 'Debug');
    BuildConfigMapper.AddMapping(bcRelease, 'Release');

    DeployActionMapper := TEnumMapper<TDeployAction>.Create;
    try
      DeployActionMapper.AddMapping(daBuild, 'Build only');
      DeployActionMapper.AddMapping(daDeploy, 'Deploy only');
      DeployActionMapper.AddMapping(daBuildAndDeploy, 'Build and Deploy');

      // Get watch directory
      Writeln('Enter root directory to monitor for shared library (.so) files (will search recursively):');
      Readln(WatchDirectory);

      if not DirectoryExists(WatchDirectory) then
      begin
        Writeln('Directory does not exist: ', WatchDirectory);
        Writeln('Press Enter to exit...');
        Readln;
        Exit;
      end;

      // Get project names
      ProjectNames := TStringList.Create;
      DprFiles := TStringList.Create;
      try
        // Ask how user wants to add projects
        Writeln;
        Writeln('How would you like to add projects?');
        Writeln('1 - Type project names manually');
        Writeln('2 - Search for .dpr files and select from list');
        Writeln('3 - Skip (add projects later during monitoring)');
        Write('Choice (1-3): ');
        Readln(ProjectChoice);

        case ProjectChoice of
          1: begin
            // Original manual entry
            Writeln;
            Writeln('Enter project names to match (without .dproj extension), one per line.');
            Writeln('Leave blank to finish:');
            repeat
              Write('Project name: ');
              Readln(Input);
              if Input <> '' then
                ProjectNames.Add(Trim(Input));
            until Input = '';
          end;

          2: begin
            // Search for .dpr files
            Writeln;
            Writeln('Searching for .dpr files...');
            FindDprFilesRecursive(WatchDirectory, DprFiles);

            if DprFiles.Count = 0 then
            begin
              Writeln('No .dpr files found in the directory.');
              Writeln('You can add projects manually later during monitoring.');
            end
            else
            begin
              Writeln;
              Writeln('Found ', DprFiles.Count, ' .dpr file(s):');
              for i := 0 to DprFiles.Count - 1 do
              begin
                ProjectName := ChangeFileExt(ExtractFileName(DprFiles[i]), '');
                Writeln(Format('  %d - %s', [i + 1, ProjectName]));
                Writeln(Format('      (%s)', [DprFiles[i]]));
              end;

              Writeln;
              Writeln('Options:');
              Writeln('  A - Add all projects');
              Writeln('  Enter numbers separated by commas (e.g., 1,3,5)');
              Writeln('  Leave blank to skip');
              Write('Selection: ');
              Readln(Input);
              Input := Trim(Input);

              if SameText(Input, 'A') then
              begin
                // Add all projects
                for i := 0 to DprFiles.Count - 1 do
                begin
                  ProjectName := ChangeFileExt(ExtractFileName(DprFiles[i]), '');
                  ProjectNames.Add(ProjectName);
                end;
                Writeln('Added all ', ProjectNames.Count, ' projects.');
              end
              else if Input <> '' then
              begin
                // Parse comma-separated numbers
                while Input <> '' do
                begin
                  i := Pos(',', Input);
                  if i > 0 then
                  begin
                    ProjectChoice := StrToIntDef(Trim(Copy(Input, 1, i - 1)), 0);
                    Input := Copy(Input, i + 1, Length(Input));
                  end
                  else
                  begin
                    ProjectChoice := StrToIntDef(Trim(Input), 0);
                    Input := '';
                  end;

                  if (ProjectChoice >= 1) and (ProjectChoice <= DprFiles.Count) then
                  begin
                    ProjectName := ChangeFileExt(ExtractFileName(DprFiles[ProjectChoice - 1]), '');
                    if ProjectNames.IndexOf(ProjectName) < 0 then
                      ProjectNames.Add(ProjectName);
                  end;
                end;
                Writeln('Added ', ProjectNames.Count, ' project(s).');
              end;
            end;
          end;

          3: begin
            Writeln;
            Writeln('No projects added. You can add them during monitoring.');
          end;
        else
          Writeln;
          Writeln('Invalid choice. You can add projects during monitoring.');
        end;

        if ProjectNames.Count = 0 then
        begin
          Writeln('No project names entered. Will monitor APKs but cannot build or auto-manage apps.');
        end
        else
        begin
          Writeln;
          Writeln('Project names to match:');
          for i := 0 to ProjectNames.Count - 1 do
            Writeln('  - ', ProjectNames[i]);
        end;

        // Get build configuration
        Writeln;
        Writeln('Select build configuration:');
        Writeln('1 - Debug');
        Writeln('2 - Release');
        Write('Choice (1-2): ');
        Readln(ConfigChoice);

        case ConfigChoice of
          1: BuildConfig := bcDebug;
          2: BuildConfig := bcRelease;
        else
          BuildConfig := bcDebug;
        end;

        // Get deploy action
        Writeln;
        Writeln('Select action when APK is detected:');
        Writeln('1 - Build only');
        Writeln('2 - Deploy only');
        Writeln('3 - Build and Deploy');
        Write('Choice (1-3): ');
        Readln(ActionChoice);

        case ActionChoice of
          1: DeployAction := daBuild;
          2: DeployAction := daDeploy;
          3: DeployAction := daBuildAndDeploy;
        else
          DeployAction := daBuildAndDeploy;
        end;

        Writeln;
        Writeln('Configuration:');
        Writeln('  Watch Directory: ', WatchDirectory, ' (recursive)');
        Writeln('  Project Names: ', ProjectNames.CommaText);
        Writeln('  Build Config: ', TConditionalHelper<string>.IfThen(
          BuildConfig = bcDebug, 'Debug', 'Release'));
        Writeln('  Action: ', DeployActionMapper.GetString(DeployAction));
        Writeln('  Package Names: Auto-detected from .dproj files');
        Writeln('  Monitoring: .so files only (to avoid infinite loops)');
        Writeln;

        // Start monitoring thread
        MonitorThread := TAPKMonitorThread.Create(WatchDirectory, ProjectNames, BuildConfig, DeployAction);

        // Start input thread for adding projects during monitoring
        InputThread := TInputThread.Create(MonitorThread);

        // Wait for input thread to finish (user typed 'quit')
        while not MonitorThread.Terminated do
          Sleep(100);

      finally
        DprFiles.Free;
        ProjectNames.Free;
      end;

    finally
      DeployActionMapper.Free;
    end;
  finally
    BuildConfigMapper.Free;
  end;
end.


