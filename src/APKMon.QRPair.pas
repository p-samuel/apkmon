unit APKMon.QRPair;

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, System.JSON,
  IdHTTPServer, IdContext, IdCustomHTTPServer, IdGlobal, IdStack,
  QRCode, APKMon.ADB, APKMon.Utils, APKMon.Console;

type
  TConnectInfo = record
    IP: string;
    PairPort: Integer;
    Code: string;
    ConnectPort: Integer;
  end;

  TConnectResult = record
    Success: Boolean;
    Message: string;
  end;

  TOnConnectEvent = function(const Info: TConnectInfo): TConnectResult of object;

  TQRHttpServer = class
  private
    FServer: TIdHTTPServer;
    FOnConnect: TOnConnectEvent;
    FPort: Integer;
    procedure HandleRequest(AContext: TIdContext; ARequestInfo: TIdHTTPRequestInfo; AResponseInfo: TIdHTTPResponseInfo);
    procedure AddCORSHeaders(AResponseInfo: TIdHTTPResponseInfo);
    procedure SendJSON(AResponseInfo: TIdHTTPResponseInfo; StatusCode: Integer; const JSON: string);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Start;
    procedure Stop;
    function GetLanIP: string;
    property Port: Integer read FPort;
    property OnConnect: TOnConnectEvent read FOnConnect write FOnConnect;
  end;

  TQRHttpPairing = class
  private
    FADBExecutor: TADBExecutor;
    FServer: TQRHttpServer;
    FEvent: TEvent;
    FLock: TCriticalSection;
    FResult: TConnectResult;
    function HandleConnect(const Info: TConnectInfo): TConnectResult;
  public
    constructor Create(ADBExecutor: TADBExecutor);
    destructor Destroy; override;
    procedure Start;
  end;

  TQRNativePairing = TQRHttpPairing;

implementation

{ TQRHttpServer }

constructor TQRHttpServer.Create;
begin
  inherited Create;
  FServer := TIdHTTPServer.Create(nil);
  FServer.ParseParams := False;
  FServer.OnCommandGet := HandleRequest;
  FServer.OnCommandOther := HandleRequest;
  FServer.DefaultPort := 0;
end;

destructor TQRHttpServer.Destroy;
begin
  Stop;
  FServer.Free;
  inherited Destroy;
end;

function TQRHttpServer.GetLanIP: string;
var
  Addresses: TIdStackLocalAddressList;
  I: Integer;
  Addr: string;
begin
  Result := '127.0.0.1';
  Addresses := TIdStackLocalAddressList.Create;
  try
    GStack.GetLocalAddressList(Addresses);
    for I := 0 to Addresses.Count - 1 do begin
      if Addresses[I].IPVersion = Id_IPv4 then begin
        Addr := Addresses[I].IPAddress;
        if (Addr <> '127.0.0.1') and (Pos('169.254.', Addr) <> 1) then begin
          Result := Addr;
          Exit;
        end;
      end;
    end;
  finally
    Addresses.Free;
  end;
end;

procedure TQRHttpServer.Start;
begin
  FServer.Active := True;
  FPort := FServer.Bindings[0].Port;
end;

procedure TQRHttpServer.Stop;
begin
  if FServer.Active then
    FServer.Active := False;
end;

procedure TQRHttpServer.AddCORSHeaders(AResponseInfo: TIdHTTPResponseInfo);
begin
  AResponseInfo.CustomHeaders.Values['Access-Control-Allow-Origin'] := '*';
  AResponseInfo.CustomHeaders.Values['Access-Control-Allow-Methods'] := 'POST, OPTIONS';
  AResponseInfo.CustomHeaders.Values['Access-Control-Allow-Headers'] := 'Content-Type';
end;

procedure TQRHttpServer.SendJSON(AResponseInfo: TIdHTTPResponseInfo; StatusCode: Integer; const JSON: string);
begin
  AResponseInfo.ResponseNo := StatusCode;
  AResponseInfo.ContentType := 'application/json';
  AResponseInfo.ContentText := JSON;
end;

procedure TQRHttpServer.HandleRequest(AContext: TIdContext; ARequestInfo: TIdHTTPRequestInfo; AResponseInfo: TIdHTTPResponseInfo);
var
  Body: string;
  JSONObj: TJSONObject;
  Info: TConnectInfo;
  ConnResult: TConnectResult;
  PortValue: TJSONValue;
  Bytes: TBytes;
  ResponseJSON: string;
begin
  AddCORSHeaders(AResponseInfo);

  if ARequestInfo.CommandType = hcOption then begin
    AResponseInfo.ResponseNo := 204;
    Exit;
  end;

  if (ARequestInfo.CommandType <> hcPost) or (ARequestInfo.Document <> '/connect') then begin
    SendJSON(AResponseInfo, 404, '{"error":"Not found"}');
    Exit;
  end;

  // Read POST body (raw bytes, decode as UTF-8)
  if (ARequestInfo.PostStream <> nil) and (ARequestInfo.PostStream.Size > 0) then begin
    ARequestInfo.PostStream.Position := 0;
    SetLength(Bytes, ARequestInfo.PostStream.Size);
    ARequestInfo.PostStream.Read(Bytes[0], Length(Bytes));
    Body := TEncoding.UTF8.GetString(Bytes);
  end;

  if Body = '' then
    Body := ARequestInfo.UnparsedParams;

  if Body = '' then begin
    SendJSON(AResponseInfo, 400, '{"error":"Empty body"}');
    Exit;
  end;

  try
    JSONObj := TJSONObject.ParseJSONValue(Body) as TJSONObject;
  except
    SendJSON(AResponseInfo, 400, '{"error":"Invalid JSON"}');
    Exit;
  end;

  if JSONObj = nil then begin
    SendJSON(AResponseInfo, 400, '{"error":"Invalid JSON"}');
    Exit;
  end;

  try
    Info.IP := JSONObj.GetValue<string>('ip', '');
    Info.Code := JSONObj.GetValue<string>('code', '');

    PortValue := JSONObj.GetValue('pairPort');
    if PortValue is TJSONNumber then
      Info.PairPort := TJSONNumber(PortValue).AsInt
    else if PortValue is TJSONString then
      Info.PairPort := StrToIntDef(PortValue.Value, 0)
    else
      Info.PairPort := 0;

    PortValue := JSONObj.GetValue('connectPort');
    if PortValue is TJSONNumber then
      Info.ConnectPort := TJSONNumber(PortValue).AsInt
    else if PortValue is TJSONString then
      Info.ConnectPort := StrToIntDef(PortValue.Value, 0)
    else
      Info.ConnectPort := 0;

    if (Info.IP = '') or (Info.PairPort = 0) or (Info.Code = '') or (Info.ConnectPort = 0) then begin
      SendJSON(AResponseInfo, 400, '{"error":"Missing required fields: ip, pairPort, code, connectPort"}');
      Exit;
    end;

    if Assigned(FOnConnect) then
      ConnResult := FOnConnect(Info)
    else begin
      ConnResult.Success := False;
      ConnResult.Message := 'No handler configured';
    end;

    ResponseJSON := Format('{"success":%s,"message":"%s"}', [LowerCase(BoolToStr(ConnResult.Success, True)), StringReplace(ConnResult.Message, '"', '\"', [rfReplaceAll])]);
    SendJSON(AResponseInfo, 200, ResponseJSON);
  finally
    JSONObj.Free;
  end;
end;

{ TQRHttpPairing }

constructor TQRHttpPairing.Create(ADBExecutor: TADBExecutor);
begin
  inherited Create;
  FADBExecutor := ADBExecutor;
  FEvent := TEvent.Create(nil, True, False, '');
  FLock := TCriticalSection.Create;
end;

destructor TQRHttpPairing.Destroy;
begin
  FLock.Free;
  FEvent.Free;
  inherited Destroy;
end;

function TQRHttpPairing.HandleConnect(const Info: TConnectInfo): TConnectResult;
var
  Output: string;
  ConnectRetry: Integer;
begin
  Result.Success := False;
  Result.Message := '';

  LogMessage(Format('Device connecting: %s (pair port %d, connect port %d)', [Info.IP, Info.PairPort, Info.ConnectPort]), lcCyan);

  // Pair using pairPort + code
  LogMessage(Format('Executing: adb pair %s:%d %s', [Info.IP, Info.PairPort, Info.Code]), lcBlue);
  Output := FADBExecutor.GetCommandOutput(Format('adb pair %s:%d %s', [Info.IP, Info.PairPort, Info.Code]), 10000);
  LogMessage('Pair result: ' + Output, lcDefault);

  if (Pos('Successfully paired', Output) = 0) and (Pos('already paired', LowerCase(Output)) = 0) then begin
    Result.Message := 'Pairing failed: ' + Output;
    FLock.Enter;
    try
      FResult := Result;
    finally
      FLock.Leave;
    end;
    FEvent.SetEvent;
    Exit;
  end;

  // Connect using connectPort with retries
  for ConnectRetry := 1 to 3 do begin
    Sleep(1000);
    LogMessage(Format('Executing: adb connect %s:%d (attempt %d/3)', [Info.IP, Info.ConnectPort, ConnectRetry]), lcBlue);
    Output := FADBExecutor.GetCommandOutput(Format('adb connect %s:%d', [Info.IP, Info.ConnectPort]), 5000);
    LogMessage('Connect result: ' + Output, lcDefault);

    if Pos('connected to', LowerCase(Output)) > 0 then begin
      Result.Success := True;
      Result.Message := Format('Connected to %s:%d', [Info.IP, Info.ConnectPort]);
      Break;
    end;

    if ConnectRetry < 3 then
      LogMessage('Retrying...', lcYellow);
  end;

  if not Result.Success then
    Result.Message := 'Pairing succeeded but connection failed after 3 attempts: ' + Output;

  FLock.Enter;
  try
    FResult := Result;
  finally
    FLock.Leave;
  end;
  FEvent.SetEvent;
end;

procedure TQRHttpPairing.Start;
var
  QR: TQRCode;
  LanIP, URL: string;
  WaitResult: TWaitResult;
begin
  FServer := TQRHttpServer.Create;
  try
    FServer.OnConnect := HandleConnect;
    LanIP := FServer.GetLanIP;
    FServer.Start;
    URL := Format('http://%s:%d/connect', [LanIP, FServer.Port]);

    QR := TQRCode.Create;
    try
      QR.Generate(URL);
      QR.RenderToConsole;
    finally
      QR.Free;
    end;

    Console.Lock;
    try
      Writeln;
      Writeln('Scan this QR code with the APKMon companion app.');
      Writeln;
      Writeln('The app will send your device''s pairing info automatically.');
      Writeln('URL: ', URL);
      Writeln;
      Writeln('Or test with curl:');
      Writeln('  curl -X POST ', URL, ' -H "Content-Type: application/json" \');
      Writeln('    -d "{"ip":"<device-ip>","pairPort":<pair-port>,"code":"<code>","connectPort":<connect-port>}"');
      Writeln;
      Writeln('Waiting for connection (2 min timeout)...');
      Writeln;
    finally
      Console.Unlock;
    end;

    WaitResult := FEvent.WaitFor(120000);

    Console.Lock;
    try
      if WaitResult = wrSignaled then begin
        FLock.Enter;
        try
          if FResult.Success then begin
            Writeln;
            LogMessage(FResult.Message, lcGreen);
            Writeln('Done!');
          end else begin
            Writeln;
            LogMessage(FResult.Message, lcRed);
            Writeln('You can try manually:');
            Writeln('  pair <ip>:<port>');
            Writeln('  connect <ip>:<port>');
          end;
        finally
          FLock.Leave;
        end;
      end else begin
        Writeln;
        LogMessage('Timeout waiting for connection.', lcYellow);
        Writeln('Make sure:');
        Writeln('  - Device and PC are on the same network');
        Writeln('  - The companion app scanned the QR code');
        Writeln('  - Wireless debugging is enabled on the device');
      end;
    finally
      Console.Unlock;
    end;
  finally
    FServer.Free;
    FServer := nil;
  end;
end;

end.
