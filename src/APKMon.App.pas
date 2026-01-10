unit APKMon.App;

interface

uses
  SysUtils, Classes,
  APKMon.Types, APKMon.Utils, APKMon.Watcher, APKMon.Commands;

type
  TAppRunner = class
  private
    FWatchDirectory: string;
    FProjectNames: TStringList;
    FBuildConfig: TBuildConfig;
    FDeployAction: TDeployAction;
    FBuildConfigMapper: TEnumMapper<TBuildConfig>;
    FDeployActionMapper: TEnumMapper<TDeployAction>;
    function PromptWatchDirectory: string;
    procedure PromptProjectSelection;
    function PromptBuildConfig: TBuildConfig;
    function PromptDeployAction: TDeployAction;
    procedure ShowConfiguration;
    procedure StartMonitoring;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Run;
  end;

implementation

{ TAppRunner }

constructor TAppRunner.Create;
begin
  inherited Create;
  FProjectNames := TStringList.Create;

  FBuildConfigMapper := TEnumMapper<TBuildConfig>.Create;
  FBuildConfigMapper.AddMapping(bcDebug, 'Debug');
  FBuildConfigMapper.AddMapping(bcRelease, 'Release');

  FDeployActionMapper := TEnumMapper<TDeployAction>.Create;
  FDeployActionMapper.AddMapping(daBuild, 'Build only');
  FDeployActionMapper.AddMapping(daDeploy, 'Deploy only');
  FDeployActionMapper.AddMapping(daBuildAndDeploy, 'Build and Deploy');
end;

destructor TAppRunner.Destroy;
begin
  FProjectNames.Free;
  FBuildConfigMapper.Free;
  FDeployActionMapper.Free;
  inherited Destroy;
end;

procedure TAppRunner.Run;
begin
  // Check for help parameter
  if (ParamCount > 0) and IsHelpParam(ParamStr(1)) then
  begin
    ShowHelp;
    Exit;
  end;

  Writeln('=== APK Deploy Monitor ===');
  Writeln;

  // Get watch directory
  FWatchDirectory := PromptWatchDirectory;
  if FWatchDirectory = '' then
    Exit;

  // Get project names
  PromptProjectSelection;

  // Get build configuration
  FBuildConfig := PromptBuildConfig;

  // Get deploy action
  FDeployAction := PromptDeployAction;

  // Show configuration summary
  ShowConfiguration;

  // Start monitoring
  StartMonitoring;
end;

function TAppRunner.PromptWatchDirectory: string;
begin
  Writeln('Enter root directory to monitor for shared library (.so) files (will search recursively):');
  Readln(Result);

  if not DirectoryExists(Result) then
  begin
    Writeln('Directory does not exist: ', Result);
    Writeln('Press Enter to exit...');
    Readln;
    Result := '';
  end;
end;

procedure TAppRunner.PromptProjectSelection;
var
  DprFiles: TStringList;
  ProjectChoice: Integer;
  Input, ProjectName: string;
  i: Integer;
begin
  DprFiles := TStringList.Create;
  try
    Writeln;
    Writeln('How would you like to add projects?');
    Writeln('1 - Type project names manually');
    Writeln('2 - Search for .dpr files and select from list');
    Writeln('3 - Skip (add projects later during monitoring)');
    Write('Choice (1-3): ');
    Readln(ProjectChoice);

    case ProjectChoice of
      1: begin
        // Manual entry
        Writeln;
        Writeln('Enter project names to match (without .dproj extension), one per line.');
        Writeln('Leave blank to finish:');
        repeat
          Write('Project name: ');
          Readln(Input);
          if Input <> '' then
            FProjectNames.Add(Trim(Input));
        until Input = '';
      end;

      2: begin
        // Search for .dpr files
        Writeln;
        Writeln('Searching for .dpr files...');
        FindDprFilesRecursive(FWatchDirectory, DprFiles);

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
              FProjectNames.Add(ProjectName);
            end;
            Writeln('Added all ', FProjectNames.Count, ' projects.');
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
                if FProjectNames.IndexOf(ProjectName) < 0 then
                  FProjectNames.Add(ProjectName);
              end;
            end;
            Writeln('Added ', FProjectNames.Count, ' project(s).');
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

    if FProjectNames.Count = 0 then
    begin
      Writeln('No project names entered. Will monitor APKs but cannot build or auto-manage apps.');
    end
    else
    begin
      Writeln;
      Writeln('Project names to match:');
      for i := 0 to FProjectNames.Count - 1 do
        Writeln('  - ', FProjectNames[i]);
    end;
  finally
    DprFiles.Free;
  end;
end;

function TAppRunner.PromptBuildConfig: TBuildConfig;
var
  ConfigChoice: Integer;
begin
  Writeln;
  Writeln('Select build configuration:');
  Writeln('1 - Debug');
  Writeln('2 - Release');
  Write('Choice (1-2): ');
  Readln(ConfigChoice);

  case ConfigChoice of
    1: Result := bcDebug;
    2: Result := bcRelease;
  else
    Result := bcDebug;
  end;
end;

function TAppRunner.PromptDeployAction: TDeployAction;
var
  ActionChoice: Integer;
begin
  Writeln;
  Writeln('Select action when APK is detected:');
  Writeln('1 - Build only');
  Writeln('2 - Deploy only');
  Writeln('3 - Build and Deploy');
  Write('Choice (1-3): ');
  Readln(ActionChoice);

  case ActionChoice of
    1: Result := daBuild;
    2: Result := daDeploy;
    3: Result := daBuildAndDeploy;
  else
    Result := daBuildAndDeploy;
  end;
end;

procedure TAppRunner.ShowConfiguration;
begin
  Writeln;
  Writeln('Configuration:');
  Writeln('  Watch Directory: ', FWatchDirectory, ' (recursive)');
  Writeln('  Project Names: ', FProjectNames.CommaText);
  Writeln('  Build Config: ', TConditionalHelper<string>.IfThen(
    FBuildConfig = bcDebug, 'Debug', 'Release'));
  Writeln('  Action: ', FDeployActionMapper.GetString(FDeployAction));
  Writeln('  Package Names: Auto-detected from .dproj files');
  Writeln('  Monitoring: .so files only (to avoid infinite loops)');
  Writeln;
end;

procedure TAppRunner.StartMonitoring;
var
  MonitorThread: TAPKMonitorThread;
  InputThread: TInputThread;
begin
  // Start monitoring thread
  MonitorThread := TAPKMonitorThread.Create(FWatchDirectory, FProjectNames, FBuildConfig, FDeployAction);

  // Start input thread for adding projects during monitoring
  InputThread := TInputThread.Create(
    MonitorThread.ADBExecutor,
    MonitorThread.ProjectManager,
    MonitorThread.Deployer,
    MonitorThread.MonitorState,
    MonitorThread.PendingProcessor,
    MonitorThread.LogcatManager,
    MonitorThread.RecorderManager,
    MonitorThread.FPSManager,
    MonitorThread.ProfileManager
  );

  // Wait for input thread to finish (user typed 'quit')
  while not MonitorThread.MonitorState.IsTerminated do
    Sleep(100);

  // Ensure any active recording is saved before exit
  MonitorThread.RecorderManager.Shutdown;
end;

end.
