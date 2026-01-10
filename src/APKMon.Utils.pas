unit APKMon.Utils;

interface

uses
  SysUtils, Classes, APKMon.Console;

type
  TLogColor = (lcDefault, lcGreen, lcRed, lcYellow, lcBlue, lcMagenta, lcCyan);

procedure LogMessage(const Msg: string; Color: TLogColor = lcDefault);
procedure FindFilesRecursive(const Directory, Extension: string; Files: TStringList);
procedure FindDprFilesRecursive(const Directory: string; Files: TStringList);
function StartsText(const ASubText, AText: string): Boolean;
function IsHelpParam(const Param: string): Boolean;
procedure ShowHelp;

implementation

procedure LogMessage(const Msg: string; Color: TLogColor = lcDefault);
const
  Colors: array[TLogColor] of string = ('', #27'[32m', #27'[31m', #27'[33m', #27'[34m', #27'[35m', #27'[36m');
var
  FormattedMsg: string;
begin
  FormattedMsg := FormatDateTime('hh:nn:ss', Now) + ' ' + Msg;
  if Console.Initialized then
    Console.WriteLine(FormattedMsg, Colors[Color])
  else
  begin
    if Color <> lcDefault then
      Writeln(Colors[Color], FormattedMsg, #27'[0m')
    else
      Writeln(FormattedMsg);
  end;
end;

procedure FindFilesRecursive(const Directory, Extension: string; Files: TStringList);
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

procedure FindDprFilesRecursive(const Directory: string; Files: TStringList);
var
  SearchRec: TSearchRec;
  SearchPath: string;
begin
  SearchPath := IncludeTrailingPathDelimiter(Directory);

  // Find .dpr files (exclude .dproj which also matches *.dpr pattern on Windows)
  if FindFirst(SearchPath + '*.dpr', faAnyFile, SearchRec) = 0 then
  begin
    try
      repeat
        if ((SearchRec.Attr and faDirectory) = 0) and
           SameText(ExtractFileExt(SearchRec.Name), '.dpr') then
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

function StartsText(const ASubText, AText: string): Boolean;
begin
  Result := (Length(ASubText) <= Length(AText)) and
            SameText(Copy(AText, 1, Length(ASubText)), ASubText);
end;

function IsHelpParam(const Param: string): Boolean;
var
  P: string;
begin
  P := LowerCase(Param);
  Result := (P = 'help') or (P = '-help') or (P = '--help') or
            (P = '/help') or (P = '-h') or (P = '--h') or (P = '/h') or (P = '/?');
end;

procedure ShowHelp;
begin
  Writeln('=== APK Deploy Monitor ===');
  Writeln;
  Writeln('Usage: apkmon [options]');
  Writeln;
  Writeln('Options:');
  Writeln('  --help, -h, /?, help   Show this help message');
  Writeln;
  Writeln('Interactive commands (during monitoring):');
  Writeln('  list                   Show current projects');
  Writeln('  build all|<name>       Build all or specific project');
  Writeln('  deploy all|<name>      Deploy all or specific project');
  Writeln('  bd all|<name>          Build and deploy all or specific project');
  Writeln('  pause                  Pause auto-detection');
  Writeln('  resume                 Resume auto-detection');
  Writeln('  devices                List connected devices (USB and WiFi)');
  Writeln('  pair <ip>:<port>       Pair with WiFi device (Android 11+)');
  Writeln('  connect <ip>:<port>    Connect to WiFi device');
  Writeln('  disconnect [<ip>:<port>] Disconnect WiFi device(s)');
  Writeln('  logcat [filter]        Start logcat (optional package filter)');
  Writeln('  logcat -s <device> [filter] Start logcat on specific device');
  Writeln('  logcat stop            Stop logcat');
  Writeln('  logcat pause           Pause logcat output');
  Writeln('  logcat resume          Resume logcat output');
  Writeln('  logcat clear           Clear logcat buffer');
  Writeln('  logcat status          Show logcat status');
  Writeln('  record start <device>  Start screen recording on device');
  Writeln('  record stop            Stop recording and save');
  Writeln('  record status          Show recording status');
  Writeln('  record output <path>   Set output folder for recordings');
  Writeln('  add <project>          Add a new project to monitor');
  Writeln('  help                   Show commands help');
  Writeln('  quit                   Exit');
  Writeln;
  Writeln('Description:');
  Writeln('  Monitors a directory for .so file changes and automatically');
  Writeln('  builds and/or deploys Delphi Android projects to connected devices.');
  Writeln('  Supports both USB and WiFi connected devices (Android 11+ for WiFi).');
end;

end.
