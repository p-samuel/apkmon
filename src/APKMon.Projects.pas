unit APKMon.Projects;

interface

uses
  SysUtils, Classes, Generics.Collections,
  APKMon.Types, APKMon.Utils;

type
  TProjectManager = class
  private
    FWatchDirectory: string;
    FProjectNames: TStringList;
    FProjectFiles: TDictionary<string, TProjectInfo>;
    FProjectLock: TObject;
  public
    constructor Create(const WatchDirectory: string);
    destructor Destroy; override;
    procedure ScanForProjectFiles;
    procedure AddProject(const ProjectName: string);
    function FindProjectInfo(const APKPath: string): TProjectInfo;
    function ExtractProjectNameFromAPK(const APKPath: string): string;
    function ExtractPackageNameFromDproj(const ProjectFile: string): string;
    property WatchDirectory: string read FWatchDirectory;
    property ProjectNames: TStringList read FProjectNames;
    property ProjectFiles: TDictionary<string, TProjectInfo> read FProjectFiles;
    property ProjectLock: TObject read FProjectLock;
  end;

implementation

{ TProjectManager }

constructor TProjectManager.Create(const WatchDirectory: string);
begin
  inherited Create;
  FWatchDirectory := WatchDirectory;
  FProjectNames := TStringList.Create;
  FProjectFiles := TDictionary<string, TProjectInfo>.Create;
  FProjectLock := TObject.Create;
end;

destructor TProjectManager.Destroy;
begin
  FProjectNames.Free;
  FProjectFiles.Free;
  FProjectLock.Free;
  inherited Destroy;
end;

procedure TProjectManager.ScanForProjectFiles;
var
  ProjectFilesList: TStringList;
  i, j: Integer;
  ProjectFile, ProjectName, PackageName: string;
  ProjectInfo: TProjectInfo;
begin
  LogMessage('Scanning for project files...', lcBlue);

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
            LogMessage(Format('Found project: %s -> %s (Package: %s)', [ProjectName, ProjectFile, PackageName]), lcGreen)
          else
            LogMessage(Format('Found project: %s -> %s (Package: Not found)', [ProjectName, ProjectFile]), lcYellow);
          Break;
        end;
      end;
    end;

    LogMessage(Format('Found %d matching project files', [FProjectFiles.Count]), lcBlue);
  finally
    ProjectFilesList.Free;
  end;
end;

procedure TProjectManager.AddProject(const ProjectName: string);
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
      LogMessage('Project already being monitored: ' + ProjectName, lcYellow);
      Exit;
    end;

    FProjectNames.Add(ProjectName);
    LogMessage('Added project to monitor list: ' + ProjectName, lcGreen);

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
            LogMessage(Format('Found project: %s -> %s (Package: %s)', [ProjName, ProjectFile, PackageName]), lcGreen)
          else
            LogMessage(Format('Found project: %s -> %s (Package: Not found)', [ProjName, ProjectFile]), lcYellow);
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

function TProjectManager.FindProjectInfo(const APKPath: string): TProjectInfo;
var
  ProjectName: string;
begin
  Result.ProjectFile := '';
  Result.PackageName := '';

  ProjectName := ExtractProjectNameFromAPK(APKPath);

  if ProjectName <> '' then
  begin
    if FProjectFiles.TryGetValue(ProjectName, Result) then
      LogMessage(Format('Matched APK %s with project %s', [ExtractFileName(APKPath), Result.ProjectFile]), lcBlue)
    else
      LogMessage(Format('Project name found (%s) but no project file mapped', [ProjectName]), lcYellow);
  end
  else
    LogMessage(Format('Could not determine project name for APK: %s', [ExtractFileName(APKPath)]), lcYellow);
end;

function TProjectManager.ExtractProjectNameFromAPK(const APKPath: string): string;
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

function TProjectManager.ExtractPackageNameFromDproj(const ProjectFile: string): string;
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
              Result := PackageName;
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
                Result := PackageName;
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
              Result := PackageName;
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
        LogMessage('Checking manifest file: ' + ExtractFileName(ManifestFile), lcBlue);
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
                    Result := PackageName;
                    LogMessage('Found package in manifest: ' + PackageName, lcBlue);
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

      // Last resort: generate a default package name based on project name
      if Result = '' then
      begin
        PackageName := 'com.embarcadero.' + ChangeFileExt(ExtractFileName(ProjectFile), '');
        LogMessage('Using default package name: ' + PackageName, lcYellow);
        Result := PackageName;
      end;

    except
      on E: Exception do
        LogMessage('Error reading project file ' + ProjectFile + ': ' + E.Message, lcRed);
    end;
  finally
    ProjectContent.Free;
  end;
end;

end.
