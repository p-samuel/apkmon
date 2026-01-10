unit APKMon.Config;

interface

uses
  SysUtils, Classes, IniFiles;

type
  TConfigManager = class
  private
    FConfigPath: string;
    FRecordingOutputFolder: string;
    FLastWatchDirectory: string;
    function GetConfigFilePath: string;
  public
    constructor Create;
    procedure Load;
    procedure Save;
    property RecordingOutputFolder: string read FRecordingOutputFolder write FRecordingOutputFolder;
    property LastWatchDirectory: string read FLastWatchDirectory write FLastWatchDirectory;
    property ConfigPath: string read FConfigPath;
  end;

var
  Config: TConfigManager;

implementation

uses
  Windows;

{ TConfigManager }

constructor TConfigManager.Create;
begin
  inherited Create;
  FConfigPath := GetConfigFilePath;
  FRecordingOutputFolder := '';
  FLastWatchDirectory := '';
end;

function TConfigManager.GetConfigFilePath: string;
var
  AppData: string;
  ConfigDir: string;
begin
  // Get %APPDATA% folder using environment variable
  AppData := GetEnvironmentVariable('APPDATA');
  if AppData <> '' then
  begin
    ConfigDir := IncludeTrailingPathDelimiter(AppData) + 'APKMon';
    if not DirectoryExists(ConfigDir) then
      ForceDirectories(ConfigDir);
    Result := ConfigDir + '\config.ini';
  end
  else
  begin
    // Fallback to exe directory
    Result := ExtractFilePath(ParamStr(0)) + 'config.ini';
  end;
end;

procedure TConfigManager.Load;
var
  Ini: TIniFile;
begin
  if not FileExists(FConfigPath) then
    Exit;

  Ini := TIniFile.Create(FConfigPath);
  try
    FRecordingOutputFolder := Ini.ReadString('Recording', 'OutputFolder', '');
    FLastWatchDirectory := Ini.ReadString('General', 'LastWatchDirectory', '');
  finally
    Ini.Free;
  end;
end;

procedure TConfigManager.Save;
var
  Ini: TIniFile;
begin
  Ini := TIniFile.Create(FConfigPath);
  try
    Ini.WriteString('Recording', 'OutputFolder', FRecordingOutputFolder);
    Ini.WriteString('General', 'LastWatchDirectory', FLastWatchDirectory);
  finally
    Ini.Free;
  end;
end;

initialization
  Config := TConfigManager.Create;
  Config.Load;

finalization
  Config.Save;
  Config.Free;

end.
