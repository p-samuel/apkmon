unit APKMon.Monitor;

interface

uses
  Windows, SysUtils, Classes, Generics.Collections, DateUtils,
  APKMon.Types, APKMon.Utils;

type
  TFileStabilityChecker = class
  private
    FIgnorePatterns: TStringList;
    FBuildInProgress: Boolean;
    FLastBuildTime: TDateTime;
    FBuildCooldownSeconds: Integer;
    FBuildConfigStr: string;
  public
    constructor Create(const BuildConfigStr: string);
    destructor Destroy; override;
    function IsFileStable(const FilePath: string): Boolean;
    function ShouldIgnoreFile(const FilePath: string): Boolean;
    function IsMainBuildOutputFile(const FilePath: string): Boolean;
    procedure SetBuildInProgress(Value: Boolean);
    procedure UpdateLastBuildTime;
    property BuildInProgress: Boolean read FBuildInProgress write FBuildInProgress;
    property LastBuildTime: TDateTime read FLastBuildTime write FLastBuildTime;
  end;

  TPendingFileProcessor = class
  private
    FPendingFiles: TDictionary<string, TDateTime>;
    FFileStabilityDelay: Integer;
    FMaxWaitTime: Integer;
    FStabilityChecker: TFileStabilityChecker;
    FOnFileReady: TProc<string>;
  public
    constructor Create(StabilityChecker: TFileStabilityChecker);
    destructor Destroy; override;
    procedure AddPendingFile(const FilePath: string);
    procedure ProcessPendingFiles(IsPaused: Boolean);
    procedure Clear;
    property FileStabilityDelay: Integer read FFileStabilityDelay write FFileStabilityDelay;
    property MaxWaitTime: Integer read FMaxWaitTime write FMaxWaitTime;
    property OnFileReady: TProc<string> read FOnFileReady write FOnFileReady;
    property PendingFiles: TDictionary<string, TDateTime> read FPendingFiles;
  end;

implementation

{ TFileStabilityChecker }

constructor TFileStabilityChecker.Create(const BuildConfigStr: string);
begin
  inherited Create;
  FBuildConfigStr := BuildConfigStr;
  FIgnorePatterns := TStringList.Create;
  FBuildInProgress := False;
  FLastBuildTime := 0;
  FBuildCooldownSeconds := 10;

  // Add patterns to ignore (architecture-specific build subdirectories)
  FIgnorePatterns.Add('\LIBRARY\ARM64-V8A\');
  FIgnorePatterns.Add('\LIBRARY\');
  FIgnorePatterns.Add('\LIBRARY\ARMEABI-V7A\');
  FIgnorePatterns.Add('\LIBRARY\ARMEABI\');
  FIgnorePatterns.Add('\LIBRARY\MIPS\');
  FIgnorePatterns.Add('\__HISTORY\');
  FIgnorePatterns.Add('\__RECOVERY\');
end;

destructor TFileStabilityChecker.Destroy;
begin
  FIgnorePatterns.Free;
  inherited Destroy;
end;

function TFileStabilityChecker.IsFileStable(const FilePath: string): Boolean;
var
  FileHandle: THandle;
  FileSize1, FileSize2: Int64;
  FileTime1, FileTime2: TFileTime;
begin
  Result := False;

  if not FileExists(FilePath) then
  begin
    LogMessage('File no longer exists: ' + ExtractFileName(FilePath), lcBlue);
    Exit;
  end;

  // Try to open the file with shared read access first
  FileHandle := CreateFile(PChar(FilePath), GENERIC_READ, FILE_SHARE_READ, nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
  if FileHandle = INVALID_HANDLE_VALUE then
  begin
    LogMessage('Cannot open file for reading: ' + ExtractFileName(FilePath), lcBlue);
    Exit;
  end;

  try
    // Get initial file size and time
    if not GetFileSizeEx(FileHandle, FileSize1) then
    begin
      LogMessage('Cannot get file size: ' + ExtractFileName(FilePath), lcBlue);
      Exit;
    end;
    if not GetFileTime(FileHandle, nil, nil, @FileTime1) then
    begin
      LogMessage('Cannot get file time: ' + ExtractFileName(FilePath), lcBlue);
      Exit;
    end;

    CloseHandle(FileHandle);
    FileHandle := INVALID_HANDLE_VALUE;

    LogMessage(Format('File %s: Size=%d bytes, checking stability...', [ExtractFileName(FilePath), FileSize1]), lcBlue);

    // Wait a short time and check again
    Sleep(500);

    FileHandle := CreateFile(PChar(FilePath), GENERIC_READ, FILE_SHARE_READ, nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
    if FileHandle = INVALID_HANDLE_VALUE then
    begin
      LogMessage('Cannot reopen file for reading: ' + ExtractFileName(FilePath), lcBlue);
      Exit;
    end;

    if not GetFileSizeEx(FileHandle, FileSize2) then
    begin
      LogMessage('Cannot get file size on second check: ' + ExtractFileName(FilePath), lcBlue);
      Exit;
    end;
    if not GetFileTime(FileHandle, nil, nil, @FileTime2) then
    begin
      LogMessage('Cannot get file time on second check: ' + ExtractFileName(FilePath), lcBlue);
      Exit;
    end;

    // File is stable if size and time haven't changed
    Result := (FileSize1 = FileSize2) and
              (FileTime1.dwLowDateTime = FileTime2.dwLowDateTime) and
              (FileTime1.dwHighDateTime = FileTime2.dwHighDateTime);

    if Result then
      LogMessage(Format('File %s is stable (Size: %d bytes)', [ExtractFileName(FilePath), FileSize2]), lcGreen)
    else
      LogMessage(Format('File %s still changing (Size: %d->%d)', [ExtractFileName(FilePath), FileSize1, FileSize2]), lcBlue);

  finally
    if FileHandle <> INVALID_HANDLE_VALUE then
      CloseHandle(FileHandle);
  end;
end;

function TFileStabilityChecker.ShouldIgnoreFile(const FilePath: string): Boolean;
var
  i: Integer;
  NormalizedPath: string;
begin
  Result := False;

  if FBuildInProgress then
  begin
    LogMessage('Ignoring file change during build: ' + ExtractFileName(FilePath), lcBlue);
    Result := True;
    Exit;
  end;

  if (FLastBuildTime > 0) and (SecondsBetween(Now, FLastBuildTime) < FBuildCooldownSeconds) then
  begin
    LogMessage(Format('Ignoring file change during cooldown: %s', [ExtractFileName(FilePath)]), lcBlue);
    Result := True;
    Exit;
  end;

  // Check against ignore patterns
  NormalizedPath := UpperCase(StringReplace(FilePath, '/', '\', [rfReplaceAll]));
  for i := 0 to FIgnorePatterns.Count - 1 do
  begin
    if Pos(FIgnorePatterns[i], NormalizedPath) > 0 then
    begin
      LogMessage('Ignoring file matching pattern ' + FIgnorePatterns[i] + ': ' + ExtractFileName(FilePath), lcBlue);
      Result := True;
      Exit;
    end;
  end;

  // Special case for the complex DEBUG + LIBRARY condition
  if (Pos('\DEBUG\', NormalizedPath) > 0) and (Pos('\LIBRARY\', NormalizedPath) > 0) then
  begin
    LogMessage('Ignoring file in DEBUG\LIBRARY path: ' + ExtractFileName(FilePath), lcBlue);
    Result := True;
    Exit;
  end;
end;

function TFileStabilityChecker.IsMainBuildOutputFile(const FilePath: string): Boolean;
var
  NormalizedPath: string;
  ConfigStr: string;
begin
  Result := False;
  NormalizedPath := UpperCase(StringReplace(FilePath, '/', '\', [rfReplaceAll]));
  ConfigStr := UpperCase(FBuildConfigStr);

  // Only accept .so files that match the pattern: \bin\Android64\Debug\ (or Release)
  if (Pos('\BIN\ANDROID64\' + ConfigStr + '\', NormalizedPath) > 0) then
  begin
    Result := True;
    LogMessage('Accepting build .so file: ' + FilePath, lcBlue);
  end;
end;

procedure TFileStabilityChecker.SetBuildInProgress(Value: Boolean);
begin
  FBuildInProgress := Value;
end;

procedure TFileStabilityChecker.UpdateLastBuildTime;
begin
  FLastBuildTime := Now;
end;

{ TPendingFileProcessor }

constructor TPendingFileProcessor.Create(StabilityChecker: TFileStabilityChecker);
begin
  inherited Create;
  FPendingFiles := TDictionary<string, TDateTime>.Create;
  FFileStabilityDelay := 3;
  FMaxWaitTime := 6;
  FStabilityChecker := StabilityChecker;
end;

destructor TPendingFileProcessor.Destroy;
begin
  FPendingFiles.Free;
  inherited Destroy;
end;

procedure TPendingFileProcessor.AddPendingFile(const FilePath: string);
begin
  FPendingFiles.AddOrSetValue(FilePath, Now);
  LogMessage('Added to pending queue: ' + ExtractFileName(FilePath), lcBlue);
end;

procedure TPendingFileProcessor.ProcessPendingFiles(IsPaused: Boolean);
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

  // Skip processing when paused
  if IsPaused then
    Exit;

  FilesToProcess := TStringList.Create;
  FilesToRemove := TStringList.Create;
  try
    // Check which files are ready to process
    for FilePath in FPendingFiles.Keys do
    begin
      if not FileExists(FilePath) then
      begin
        LogMessage('Removing non-existent file from queue: ' + ExtractFileName(FilePath), lcBlue);
        FilesToRemove.Add(FilePath);
        Continue;
      end;

      FileTime := FPendingFiles[FilePath];
      Sleep(FFileStabilityDelay * 1000);
      SecondsSinceAdded := SecondsBetween(Now, FileTime);

      LogMessage(Format('Checking file %s: %d seconds old', [ExtractFileName(FilePath), SecondsSinceAdded]), lcBlue);

      // Check if enough time has passed
      if SecondsSinceAdded >= FFileStabilityDelay then
      begin
        LogMessage(Format('File %s passed time check, checking stability...', [ExtractFileName(FilePath)]), lcBlue);

        if FStabilityChecker.IsFileStable(FilePath) or (SecondsSinceAdded >= FMaxWaitTime) then
        begin
          if SecondsSinceAdded >= FMaxWaitTime then
            LogMessage(Format('File %s reached maximum wait time, processing anyway', [ExtractFileName(FilePath)]), lcYellow);

          FilesToProcess.Add(FilePath);
          LogMessage(Format('File %s is ready for processing', [ExtractFileName(FilePath)]), lcGreen);
        end
        else
        begin
          // Update timestamp to give it more time
          FPendingFiles.AddOrSetValue(FilePath, Now);
          LogMessage(Format('File %s not stable yet, resetting timer', [ExtractFileName(FilePath)]), lcBlue);
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

      LogMessage('Processing stable file: ' + ExtractFileName(FilePath), lcGreen);
      if Assigned(FOnFileReady) then
        FOnFileReady(FilePath);
    end;

  finally
    FilesToProcess.Free;
    FilesToRemove.Free;
  end;
end;

procedure TPendingFileProcessor.Clear;
begin
  FPendingFiles.Clear;
end;

end.
