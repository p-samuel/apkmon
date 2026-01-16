unit APKMon.QRPair;

interface

uses
  System.SysUtils, System.Classes, QRCode, APKMon.ADB;

type
  TQRNativePairing = class
  private
    FADBExecutor: TADBExecutor;
    FServiceName: string;
    FPassword: string;
    function GenerateRandomString(Len: Integer): string;
    function FindServiceInMdns(out IP: string; out PairPort: Integer; out ConnectPort: Integer): Boolean;
    function FindConnectPortForIP(const IP: string): Integer;
  public
    constructor Create(ADBExecutor: TADBExecutor);
    procedure Start;
  end;

implementation

{ TQRNativePairing }

constructor TQRNativePairing.Create(ADBExecutor: TADBExecutor);
begin
  inherited Create;
  FADBExecutor := ADBExecutor;
  // Generate random service name and password
  FServiceName := 'apkmon-' + GenerateRandomString(6);
  FPassword := GenerateRandomString(10);
end;

function TQRNativePairing.GenerateRandomString(Len: Integer): string;
const
  Chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
var
  I: Integer;
begin
  Randomize;
  SetLength(Result, Len);
  for I := 1 to Len do
    Result[I] := Chars[Random(Length(Chars)) + 1];
end;

function TQRNativePairing.FindServiceInMdns(out IP: string; out PairPort: Integer; out ConnectPort: Integer): Boolean;
var
  Output: string;
  Lines: TStringList;
  I, P, ColonPos: Integer;
  Line, AddrPart: string;
  FoundIP: string;
begin
  Result := False;
  IP := '';
  PairPort := 0;
  ConnectPort := 0;
  FoundIP := '';

  // Query mDNS services
  Output := FADBExecutor.GetCommandOutput('adb mdns services', 5000);

  Lines := TStringList.Create;
  try
    Lines.Text := Output;
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Lines[I];

      // Look for our service name in _adb-tls-pairing entries
      if (Pos('_adb-tls-pairing', Line) > 0) and (Pos(FServiceName, Line) > 0) then
      begin
        // Find IP:PORT pattern - look for number.number.number.number:number
        for P := 1 to Length(Line) - 10 do
        begin
          if CharInSet(Line[P], ['0'..'9']) and (Pos('.', Copy(Line, P, 15)) > 0) and (Pos(':', Copy(Line, P, 20)) > 0) then
          begin
            AddrPart := Copy(Line, P, 25);
            ColonPos := Pos(':', AddrPart);
            if ColonPos > 7 then  // At least x.x.x.x:
            begin
              FoundIP := Trim(Copy(AddrPart, 1, ColonPos - 1));
              PairPort := StrToIntDef(Trim(Copy(AddrPart, ColonPos + 1, 5)), 0);
              if (FoundIP <> '') and (PairPort > 0) then
              begin
                IP := FoundIP;
                Result := True;
                Break;
              end;
            end;
          end;
        end;
      end;

      // Also look for _adb-tls-connect with same IP to get connect port
      if (FoundIP <> '') and (Pos('_adb-tls-connect', Line) > 0) and (Pos(FoundIP, Line) > 0) then
      begin
        P := Pos(FoundIP + ':', Line);
        if P > 0 then
        begin
          AddrPart := Copy(Line, P + Length(FoundIP) + 1, 10);
          ConnectPort := StrToIntDef(Trim(AddrPart), 0);
        end;
      end;
    end;
  finally
    Lines.Free;
  end;
end;

function TQRNativePairing.FindConnectPortForIP(const IP: string): Integer;
var
  Output: string;
  Lines: TStringList;
  I, P: Integer;
  Line, AddrPart: string;
begin
  Result := 0;

  // Query mDNS services for fresh connect port
  Output := FADBExecutor.GetCommandOutput('adb mdns services', 5000);

  Lines := TStringList.Create;
  try
    Lines.Text := Output;
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Lines[I];

      // Look for _adb-tls-connect with matching IP
      if (Pos('_adb-tls-connect', Line) > 0) and (Pos(IP, Line) > 0) then
      begin
        P := Pos(IP + ':', Line);
        if P > 0 then
        begin
          AddrPart := Copy(Line, P + Length(IP) + 1, 10);
          Result := StrToIntDef(Trim(AddrPart), 0);
          if Result > 0 then
            Exit;
        end;
      end;
    end;
  finally
    Lines.Free;
  end;
end;

procedure TQRNativePairing.Start;
var
  QR: TQRCode;
  QRData: string;
  IP: string;
  PairPort, ConnectPort: Integer;
  Attempts, ConnectRetry: Integer;
  Output: string;
begin
  // Format: WIFI:T:ADB;S:<service-name>;P:<password>;;
  QRData := Format('WIFI:T:ADB;S:%s;P:%s;;', [FServiceName, FPassword]);

  // Display QR code
  QR := TQRCode.Create;
  try
    QR.Generate(QRData);
    QR.RenderToConsole;
    Writeln;
    Writeln('On your Android device:');
    Writeln('  1. Go to Settings > Developer options > Wireless debugging');
    Writeln('  2. Tap "Pair device with QR code"');
    Writeln('  3. Scan this QR code');
    Writeln;
    Writeln('Service: ', FServiceName);
    Writeln('Password: ', FPassword);
    Writeln;
    Writeln('Waiting for device to appear via mDNS...');
    Writeln('Press Ctrl+C to cancel');
    Writeln;
  finally
    QR.Free;
  end;

  // Poll mDNS for our service (captures both pair and connect ports in one query)
  Attempts := 0;
  while Attempts < 60 do  // 60 attempts * 2 seconds = 2 minutes timeout
  begin
    if FindServiceInMdns(IP, PairPort, ConnectPort) then
    begin
      Writeln('Device found!');
      Writeln('  IP: ', IP);
      Writeln('  Pairing Port: ', PairPort);
      if ConnectPort > 0 then
        Writeln('  Connect Port: ', ConnectPort);
      Writeln;

      // Execute pairing
      Writeln('Executing: adb pair ', IP, ':', PairPort, ' ', FPassword);
      FADBExecutor.ExecuteCommand(Format('adb pair %s:%d %s', [IP, PairPort, FPassword]));

      // Re-query mDNS for fresh connect port after pairing
      Sleep(500);
      ConnectPort := FindConnectPortForIP(IP);
      if ConnectPort > 0 then
        Writeln('  Fresh Connect Port: ', ConnectPort);

      // Connect using discovered port with retry
      if ConnectPort > 0 then
      begin
        for ConnectRetry := 1 to 3 do
        begin
          Sleep(1000);
          Writeln;
          Writeln('Executing: adb connect ', IP, ':', ConnectPort, ' (attempt ', ConnectRetry, '/3)');
          Output := FADBExecutor.GetCommandOutput(Format('adb connect %s:%d', [IP, ConnectPort]), 5000);
          Writeln(Output);
          if Pos('connected to', Output) > 0 then
          begin
            Writeln;
            Writeln('Done!');
            Exit;
          end;
          if ConnectRetry < 3 then
            Writeln('Retrying...');
        end;
        Writeln;
        Writeln('Connection failed after 3 attempts.');
        Writeln('Check your device for the connection port and run:');
        Writeln('  connect <ip>:<port>');
      end
      else
      begin
        Writeln;
        Writeln('Pairing complete! Connection port not discovered.');
        Writeln('Check your device for the connection port and run:');
        Writeln('  connect <ip>:<port>');
      end;
      Exit;
    end;

    Inc(Attempts);
    Write('.');
    Sleep(2000);
  end;

  Writeln;
  Writeln('Timeout waiting for device. Make sure:');
  Writeln('  - Device and PC are on the same network');
  Writeln('  - You scanned the QR code in Wireless debugging settings');
end;

end.
