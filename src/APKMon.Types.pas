unit APKMon.Types;

interface

uses
  Windows, SysUtils, Generics.Collections;

type
  TBuildConfig = (bcDebug, bcRelease);
  TDeployAction = (daBuild, daDeploy, daBuildAndDeploy);
  TTargetPlatform = (tpAndroid32, tpAndroid64);

  TProjectInfo = record
    ProjectFile: string;
    PackageName: string;
  end;

  FILE_NOTIFY_INFORMATION = record
    NextEntryOffset: DWORD;
    Action: DWORD;
    FileNameLength: DWORD;
    FileName: array[0..0] of WideChar;
  end;
  PFILE_NOTIFY_INFORMATION = ^FILE_NOTIFY_INFORMATION;

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

implementation

{ TConditionalHelper<T> }

class function TConditionalHelper<T>.IfThen(Condition: Boolean; const TrueValue, FalseValue: T): T;
begin
  if Condition then
    Result := TrueValue
  else
    Result := FalseValue;
end;

{ TEnumMapper<TEnum> }

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

end.
