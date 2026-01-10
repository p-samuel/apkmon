unit APKMon.ADB;

interface

uses
  Windows, SysUtils, Classes,
  APKMon.Types, APKMon.Utils;

type
  TADBExecutor = class
  public
    function ExecuteCommand(const Command: string; ShowOutput: Boolean = True; TimeoutMs: DWORD = 0): Boolean;
    function GetCommandOutput(const Command: string): string;
    function GetDevices: TStringList;
    function GetMatchingDevices(const TargetABI: string = ''): TStringList;
    function GetDeviceABI(const DeviceId: string): string;
    function GetEmulator(const TargetABI: string = ''): string;
    function IsABICompatible(const TargetAbi, DeviceAbiList: string): Boolean;
  end;

implementation

{ TADBExecutor }

function TADBExecutor.ExecuteCommand(const Command: string; ShowOutput: Boolean = True; TimeoutMs: DWORD = 0): Boolean;
var
  StartupInfo: TStartupInfo;
  ProcessInfo: TProcessInformation;
  ExitCode: DWORD;
  WaitResult: DWORD;
  ActualTimeout: DWORD;
begin
  Result := False;

  if ShowOutput then
    LogMessage('Executing: ' + Command, lcBlue);

  ZeroMemory(@StartupInfo, SizeOf(StartupInfo));
  StartupInfo.cb := SizeOf(StartupInfo);
  StartupInfo.dwFlags := STARTF_USESHOWWINDOW;
  StartupInfo.wShowWindow := SW_HIDE;

  if CreateProcess(nil, PChar(Command), nil, nil, False, 0, nil, nil, StartupInfo, ProcessInfo) then
  begin
    try
      // Determine timeout: use provided, or default based on command type
      if TimeoutMs > 0 then
        ActualTimeout := TimeoutMs
      else if Pos('msbuild', LowerCase(Command)) > 0 then
        ActualTimeout := 60000
      else
        ActualTimeout := 30000;

      WaitResult := WaitForSingleObject(ProcessInfo.hProcess, ActualTimeout);

      if WaitResult = WAIT_OBJECT_0 then
      begin
        GetExitCodeProcess(ProcessInfo.hProcess, ExitCode);
        Result := ExitCode = 0;
      end
      else
      begin
        // Timeout occurred
        LogMessage('Command timed out, terminating process', lcRed);
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
    LogMessage('Failed to create process for command: ' + Command, lcRed);
  end;
end;

function TADBExecutor.GetCommandOutput(const Command: string): string;
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
          LogMessage('Timeout waiting for command: ' + Command, lcRed);
        end;
      finally
        CloseHandle(ProcessInfo.hProcess);
        CloseHandle(ProcessInfo.hThread);
      end;
    end
    else
      LogMessage('Failed to create process for command output: ' + Command, lcRed);
  finally
    if WritePipe <> 0 then CloseHandle(WritePipe);
    CloseHandle(ReadPipe);
  end;
end;

function TADBExecutor.GetDevices: TStringList;
var
  Output: string;
  Lines: TStringList;
  i: Integer;
  Line, DeviceId, State: string;
begin
  Result := TStringList.Create;

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

      // Extract device id and state
      DeviceId := Trim(Copy(Line, 1, Pos(#9, Line + #9) - 1));
      if DeviceId = '' then
        DeviceId := Trim(Copy(Line, 1, Pos(' ', Line + ' ') - 1));

      State := Trim(StringReplace(Line, DeviceId, '', []));
      State := Trim(StringReplace(State, #9, ' ', [rfReplaceAll]));

      // Accept only "device" state (skip offline/unauthorized)
      if (DeviceId <> '') and (Pos('device', LowerCase(State)) > 0) then
        Result.Add(DeviceId);
    end;
  finally
    Lines.Free;
  end;
end;

function TADBExecutor.GetMatchingDevices(const TargetABI: string = ''): TStringList;
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
    LogMessage('No devices found via adb', lcYellow);
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
          LogMessage(Format('Device %s selected (ABI match: %s)', [DeviceId, Abis]), lcBlue);
        end
        else if Abis <> '' then
          LogMessage(Format('Skipping device %s due to ABI mismatch (%s)', [DeviceId, Abis]), lcYellow);
      end
      else
      begin
        Result.Add(DeviceId);
        LogMessage('Device ' + DeviceId + ' added (no ABI filter)', lcBlue);
      end;
    end;

    if Result.Count = 0 then
      LogMessage('No devices matched the required ABI. Start an ARM-compatible device/emulator.', lcRed);
  finally
    Lines.Free;
  end;
end;

function TADBExecutor.GetDeviceABI(const DeviceId: string): string;
begin
  Result := Trim(GetCommandOutput(Format('adb -s %s shell getprop ro.product.cpu.abilist', [DeviceId])));

  if Result = '' then
    Result := Trim(GetCommandOutput(Format('adb -s %s shell getprop ro.product.cpu.abi', [DeviceId])));

  if Result <> '' then
    LogMessage(Format('Device %s ABI list: %s', [DeviceId, Result]), lcBlue)
  else
    LogMessage('Unable to read device ABI information', lcYellow);
end;

function TADBExecutor.GetEmulator(const TargetABI: string = ''): string;
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
            LogMessage(Format('Selected emulator %s (ABI match: %s)', [Result, Abis]), lcBlue);
            Exit;
          end
          else if Abis <> '' then
            LogMessage(Format('Skipping emulator %s due to ABI mismatch (%s)', [DeviceId, Abis]), lcYellow);
        end;

        // Fallback to the first emulator if no ABI match is found
        if Result = '' then
          Result := DeviceId;
      end;
    end;

    if (Result <> '') and (TargetABI <> '') then
      LogMessage('No emulator ABI matched, using first available: ' + Result, lcYellow)
    else if Result <> '' then
      LogMessage('Found emulator: ' + Result, lcBlue);
  finally
    Lines.Free;
  end;
end;

function TADBExecutor.IsABICompatible(const TargetAbi, DeviceAbiList: string): Boolean;
var
  TargetLower, DeviceLower: string;
begin
  TargetLower := LowerCase(TargetAbi);
  DeviceLower := LowerCase(DeviceAbiList);

  Result := Pos(TargetLower, DeviceLower) > 0;
end;

end.
