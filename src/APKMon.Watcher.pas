unit APKMon.Watcher;

interface

uses
  Windows, SysUtils, Classes,
  APKMon.Types, APKMon.Utils, APKMon.ADB, APKMon.Projects, APKMon.Monitor,
  APKMon.Deployer, APKMon.Commands, APKMon.Logcat, APKMon.Recorder, APKMon.FPS,
  APKMon.Profile;

type
  TAPKMonitorThread = class(TThread)
  private
    FWatchDirectory: string;
    FADBExecutor: TADBExecutor;
    FProjectManager: TProjectManager;
    FStabilityChecker: TFileStabilityChecker;
    FPendingProcessor: TPendingFileProcessor;
    FDeployer: TAPKDeployer;
    FMonitorState: TMonitorState;
    FLogcatManager: TLogcatManager;
    FRecorderManager: TScreenRecorderManager;
    FFPSManager: TFPSManager;
    FProfileManager: TProfileManager;
  protected
    procedure Execute; override;
  public
    constructor Create(const WatchDir: string; ProjectNames: TStringList; BuildConfig: TBuildConfig; DeployAction: TDeployAction);
    destructor Destroy; override;
    property ADBExecutor: TADBExecutor read FADBExecutor;
    property ProjectManager: TProjectManager read FProjectManager;
    property Deployer: TAPKDeployer read FDeployer;
    property MonitorState: TMonitorState read FMonitorState;
    property PendingProcessor: TPendingFileProcessor read FPendingProcessor;
    property LogcatManager: TLogcatManager read FLogcatManager;
    property RecorderManager: TScreenRecorderManager read FRecorderManager;
    property FPSManager: TFPSManager read FFPSManager;
    property ProfileManager: TProfileManager read FProfileManager;
  end;

implementation

{ TAPKMonitorThread }

constructor TAPKMonitorThread.Create(const WatchDir: string; ProjectNames: TStringList;
  BuildConfig: TBuildConfig; DeployAction: TDeployAction);
var
  ConfigMapper: TEnumMapper<TBuildConfig>;
begin
  inherited Create(False);
  FWatchDirectory := WatchDir;
  FreeOnTerminate := True;

  // Create components
  FADBExecutor := TADBExecutor.Create;
  FADBExecutor.WarmUp;
  FProjectManager := TProjectManager.Create(WatchDir);
  FProjectManager.ProjectNames.Assign(ProjectNames);

  // Get build config string for stability checker
  ConfigMapper := TEnumMapper<TBuildConfig>.Create;
  try
    ConfigMapper.AddMapping(bcDebug, 'Debug');
    ConfigMapper.AddMapping(bcRelease, 'Release');
    FStabilityChecker := TFileStabilityChecker.Create(ConfigMapper.GetString(BuildConfig));
  finally
    ConfigMapper.Free;
  end;

  FPendingProcessor := TPendingFileProcessor.Create(FStabilityChecker);
  FDeployer := TAPKDeployer.Create(FADBExecutor, FProjectManager, FStabilityChecker, BuildConfig, DeployAction);
  FMonitorState := TMonitorState.Create;
  FLogcatManager := TLogcatManager.Create(FADBExecutor);
  FRecorderManager := TScreenRecorderManager.Create(FADBExecutor);
  FFPSManager := TFPSManager.Create(FADBExecutor);
  FProfileManager := TProfileManager.Create(FADBExecutor);

  // Wire logcat manager to deployer for auto-pause during builds
  FDeployer.SetLogcatManager(FLogcatManager);

  // Set up file ready callback
  FPendingProcessor.OnFileReady := procedure(FilePath: string)
    begin
      FDeployer.DeployAPK(FilePath);
    end;

  // Scan for project files
  FProjectManager.ScanForProjectFiles;
end;

destructor TAPKMonitorThread.Destroy;
begin
  FProfileManager.Free;
  FFPSManager.Free;
  FRecorderManager.Free;
  FLogcatManager.Free;
  FADBExecutor.Free;
  FProjectManager.Free;
  FStabilityChecker.Free;
  FPendingProcessor.Free;
  FDeployer.Free;
  FMonitorState.Free;
  inherited Destroy;
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
    LogMessage('Error opening directory: ' + FWatchDirectory, lcRed);
    Exit;
  end;

  try
    LogMessage('Monitoring ' + FWatchDirectory + ' for .so changes (recursive)...', lcGreen);
    LogMessage(Format('File stability delay: %d seconds, max wait: %d seconds',
      [FPendingProcessor.FileStabilityDelay, FPendingProcessor.MaxWaitTime]), lcBlue);

    while not Terminated and not FMonitorState.IsTerminated do
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
                LogMessage('FILE_ACTION_ADDED: ' + ExtractFileName(FileName), lcBlue);
                FullPath := FWatchDirectory + '\' + FileName;

                if FileExists(FullPath) and
                   not FStabilityChecker.ShouldIgnoreFile(FullPath) and
                   not FMonitorState.IsPaused then
                begin
                  LogMessage('Shared library created: ' + ExtractFileName(FullPath), lcBlue);
                  FPendingProcessor.AddPendingFile(FullPath);
                end;
              end;
              FILE_ACTION_REMOVED:
                LogMessage('FILE_ACTION_REMOVED: ' + ExtractFileName(FileName), lcBlue);
              FILE_ACTION_MODIFIED:
                LogMessage('FILE_ACTION_MODIFIED: ' + ExtractFileName(FileName), lcBlue);
              FILE_ACTION_RENAMED_OLD_NAME:
                LogMessage('FILE_ACTION_RENAMED_OLD_NAME: ' + ExtractFileName(FileName), lcBlue);
              FILE_ACTION_RENAMED_NEW_NAME:
                LogMessage('FILE_ACTION_RENAMED_NEW_NAME: ' + ExtractFileName(FileName), lcBlue);
            else
              LogMessage('UNKNOWN_ACTION (' + IntToStr(Info^.Action) + '): ' + ExtractFileName(FileName), lcBlue);
            end;
          end;

          Offset := Offset + Info^.NextEntryOffset;
        until Info^.NextEntryOffset = 0;

        // Always check pending files after processing directory changes
        FPendingProcessor.ProcessPendingFiles(FMonitorState.IsPaused);
      end
      else
      begin
        LogMessage('Error reading directory changes', lcRed);
        Break;
      end;
    end;
  finally
    CloseHandle(DirectoryHandle);
  end;
end;

end.
