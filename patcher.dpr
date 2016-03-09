program patcher;

{$APPTYPE CONSOLE}

uses SysUtils, Windows, PsAPI, Math;

const MAX_PATH = 32767;

var
 ClientProcess: THandle;
 ClientBase: THandle;
 ClientSize: Cardinal;

 FileName: String;

function ExtractFileName(S: PChar): PChar;
begin
Result := StrRScan(S, '\');
if Result = nil then
 Result := S
else
 Inc(Cardinal(Result));
end;

function IsAbsolutePath(S: PChar): Boolean;
begin
{$IFDEF MSWINDOWS}
 Result := ((S^ = '\') and (PChar(Cardinal(S) + 1)^ = '\')) or
           ((S^ = '/') and (PChar(Cardinal(S) + 1)^ = '/')) or
           (StrScan(S, ':') <> nil);
{$ELSE}
 Result := (S^ = '/') or (S^ = '\');
{$ENDIF}
end;

var
 ErrorStrBuf: array[1..8192] of Char;
 
function ErrorStr: PChar;
begin
if not FormatMessage(FORMAT_MESSAGE_FROM_SYSTEM, nil, GetLastError, LANG_USER_DEFAULT, @ErrorStrBuf, SizeOf(ErrorStrBuf), nil) > 0 then
 StrCopy(@ErrorStrBuf, 'Unknown error.');

Result := @ErrorStrBuf;
end;

function GetModuleSize(Module: THandle): Cardinal;
var
 DOSHeader: TImageDosHeader;
 NTHeader: TImageNtHeaders;
 BytesRead: Cardinal;
begin
if ReadProcessMemory(ClientProcess, Pointer(ClientBase), @DOSHeader, SizeOf(DOSHeader), BytesRead) and
   (BytesRead = SizeOf(DOSHeader)) and
   ReadProcessMemory(ClientProcess, Pointer(ClientBase + Cardinal(DOSHeader._lfanew)), @NTHeader, SizeOf(NTHeader), BytesRead) and
   (BytesRead = SizeOf(NTHeader)) then
 Result := NTHeader.OptionalHeader.SizeOfImage
else
 Result := 0;
end;

var
 NotifyBadReadCount: Integer = 0;

function FindMemory(Pattern: Pointer; PatternSize: Cardinal): Pointer;
const
 BUF_SIZE = 4096;
var
 Buf: array[1..BUF_SIZE] of Byte;
 Addr, AddrEnd, NumBytes, BytesRead, I: Cardinal;
begin
Addr := ClientBase;
AddrEnd := ClientBase + ClientSize;

while Addr < AddrEnd do
 begin
  NumBytes := Min(BUF_SIZE, AddrEnd - Addr);
  if ReadProcessMemory(ClientProcess, Pointer(Addr), @Buf, NumBytes, BytesRead) and
     (BytesRead = NumBytes) then
   begin
    for I := 0 to NumBytes - PatternSize do
     if CompareMem(Pointer(Cardinal(@Buf) + I), Pattern, PatternSize) then
      begin
       Result := Pointer(Addr + I);
       Exit;
      end;
   end
  else
   if NotifyBadReadCount <= 10 then
    begin
     Inc(NotifyBadReadCount);
     Writeln('Error: Can''t read ', NumBytes, ' bytes of memory starting from ', Addr, '.');
    end;

  Addr := Addr + NumBytes;
 end;

Result := nil;
end;

procedure SetMemory(Addr, Pattern: Pointer; PatternSize: Cardinal);
var
 BytesWritten: Cardinal;
begin
BytesWritten := 0;
if not WriteProcessMemory(ClientProcess, Addr, Pattern, PatternSize, BytesWritten) or
   (BytesWritten <> PatternSize) then
 begin
  Writeln('Error while writing process memory. Tried to write ', PatternSize, ' bytes, managed to write ', BytesWritten, ' bytes.');
  Writeln('Error: ', ErrorStr);
 end;
end;

var
 NOPArray: array[1..1024] of Byte;

procedure NOPMemory(Addr: Pointer; Size: Cardinal); overload;
begin
if Size > SizeOf(NOPArray) then
 begin
  Writeln('Warning: Tried to NOP more than ', SizeOf(NOPArray), ' bytes. The resulting patch may be totally wrong.');
  Size := SizeOf(NOPArray);
 end;

if NOPArray[1] <> $90 then
 FillChar(NOPArray, SizeOf(NOPArray), $90);

SetMemory(Addr, @NOPArray, Size);
end;

procedure Advance(var Addr: Pointer; Offset: Integer);
begin
Inc(Integer(Addr), Offset);
end;

procedure AssertMemory(Addr: Pointer; const Pattern: array of Byte);
var
 Buf: array[1..1024] of Byte;
 Size, BytesRead: Cardinal;
begin
Size := Length(Pattern);
if Size > SizeOf(Buf) then
 begin
  Writeln('Warning: Tried to assert more than ', SizeOf(Buf), ' bytes. The resulting assertion may be totally wrong.');
  Size := SizeOf(Buf);
 end;

if not ReadProcessMemory(ClientProcess, Addr, @Buf, Size, BytesRead) then
 Writeln('Error while reading process memory through the assertion routine: ', ErrorStr)
else
 if not CompareMem(@Buf, @Pattern[0], Size) then
  begin
   Writeln('Warning: Memory assertion failed. Seems like there was a change in TF2 code. Maybe you should find a new version of this patcher.');
   Writeln('The patching will continue, but it may be incorrect.');
  end;
end;

// input: address of the first loader opcode
procedure PatchImageLoader(Addr: Pointer);
var
 Offset: Byte;
 BytesRead: Cardinal;
 Name: PChar;
 MovXRef: packed record
  Mov: Byte;
  Addr: Pointer;
 end;
begin
AssertMemory(Addr, [$55, $8B, $EC]);
Advance(Addr, 9);
AssertMemory(Addr, [$68]);
NOPMemory(Addr, 5); // patch out the "none" push
Advance(Addr, 9);

AssertMemory(Addr, [$68]);
NOPMemory(Addr, 5); // patch out "op" push (another one)
Advance(Addr, 5);

AssertMemory(Addr, [$E8]);
NOPMemory(Addr, 5); // patch out GetString call
Advance(Addr, 5);

AssertMemory(Addr, [$8B, $F8]);
NOPMemory(Addr, 20); // patch out the first compare
Advance(Addr, 20); // right to the "normal" setup

Writeln('Patched out the string comparison stuff in image pre-load setup routine.');

AssertMemory(Addr, [$C7, $06, $01, $00, $00, $00, $EB]);
Advance(Addr, 7);

if not ReadProcessMemory(ClientProcess, Addr, @Offset, SizeOf(Offset), BytesRead) then
 begin
  Writeln('Can''t read process memory: ', ErrorStr);
  Exit;
 end;

Addr := Pointer(Cardinal(Addr) + Offset + 1);
Writeln('Found the jump offset in pre-loader.');

AssertMemory(Addr, [$6A, $00, $68]);
NOPMemory(Addr, 14); // patch out the GetString call

Writeln('Patched out the original image name getter.');

Name := VirtualAllocEx(ClientProcess, nil, Length(FileName) + 1, MEM_COMMIT or MEM_RESERVE, PAGE_EXECUTE_READWRITE);
if Name = nil then
 begin
  Writeln('Failed to allocate ', Length(FileName) + 1, ' bytes in client.dll address space: ', ErrorStr);
  Exit;
 end;

SetMemory(Name, PChar(FileName), Length(FileName) + 1);

MovXRef.Mov := $B8;
MovXRef.Addr := Name;
SetMemory(Addr, @MovXRef, SizeOf(MovXRef));

Writeln('Set up a memory page and patched the image name getter with a custom one.');

// Now just need to patch the opacity call out.

Advance(Addr, 85); // whooooo!
AssertMemory(Addr, [$D9, $E8, $51]);
Advance(Addr, 2);
NOPMemory(Addr, 9); // this stuff patches out fld1 code
Advance(Addr, 9);
AssertMemory(Addr, [$8B, $CB]);
Advance(Addr, 2);
NOPMemory(Addr, 5);
Advance(Addr, 5);
AssertMemory(Addr, [$5F]);

Writeln('Patched out the opacity call. The loader is fully patched now.');

// and we're done here!
end;

function PerformPatch(Process, Module: THandle): Boolean;
const
 custom_texture_blend_steps: array[0..100] of Char = 'custom_texture_blend_steps'#0;
var
 PushXRef: packed record
  Push: Byte;
  Addr: Pointer;
 end;
 Addr, Loader, KVLast: Pointer;
 BytesRead: Cardinal;
begin
Result := False;

ClientProcess := Process;
ClientBase := Module;
ClientSize := GetModuleSize(Module);

if ClientSize = 0 then
 Writeln('Can''t find client.dll image size.')
else
 begin
  PushXRef.Push := $68;
  PushXRef.Addr := FindMemory(@custom_texture_blend_steps, StrLen(custom_texture_blend_steps));
  if PushXRef.Addr = nil then
   Writeln('Can''t find "custom_texture_blend_steps" pattern in client.dll.')
  else
   begin
    Writeln('Found "custom_texture_blend_steps" pattern: ', IntToHex(Cardinal(PushXRef.Addr), 8));
    Addr := FindMemory(@PushXRef, SizeOf(PushXRef));
    if Addr = nil then
     Writeln('Can''t find xref to "custom_texture_blend_steps" push in client.dll. (Or maybe the patch was already applied?)')
    else
     begin
      Writeln('Found "custom_texture_blend_steps" push xref: ', IntToHex(Cardinal(Addr), 8));

      NOPMemory(Addr, 5); // patching out push
      Advance(Addr, 5);
      AssertMemory(Addr, [$83, $C1, $0C, $E8]);
      NOPMemory(Addr, 8); // add and call
      Advance(Addr, 8);
      AssertMemory(Addr, [$85, $C0, $0F, $84]);
      NOPMemory(Addr, 4); // test and je opcode
      Advance(Addr, 4);

      if not ReadProcessMemory(ClientProcess, Addr, @PushXRef.Addr, SizeOf(PushXRef.Addr), BytesRead) then
       begin
        Writeln('Failed to read process memory near push xref: ', ErrorStr);
        Exit;
       end;

      KVLast := Pointer(Cardinal(Addr) + Cardinal(PushXRef.Addr) + 4);
      if (Cardinal(KVLast) < ClientBase) or (Cardinal(KVLast) >= ClientBase + ClientSize) then
       begin
        Writeln('Found the last KeyValues call, but it leads outside the client module. Aborting the patch.');
        Exit;
       end
      else
       Writeln('Found the last KeyValues call. Saving it for later.');

      NOPMemory(Addr, 4); // finalize NOPing the je param
      Advance(Addr, 4);
      AssertMemory(Addr, [$8B, $C8]); // sanity check
      NOPMemory(Addr, 19); // everything else...
      Advance(Addr, 19);

      Writeln('Found and patched out all KeyValues calls, except for the last one.');

      // class creation

      AssertMemory(Addr, [$FF, $76, $0C, $8B, $CE]);
      Advance(Addr, 38);
      AssertMemory(Addr, [$E8]);
      Advance(Addr, 1);

      if not ReadProcessMemory(ClientProcess, Addr, @PushXRef.Addr, SizeOf(PushXRef.Addr), BytesRead) then
       begin
        Writeln('Failed to read process memory near image loader: ', ErrorStr);
        Exit;
       end;

      Loader := Pointer(Cardinal(Addr) + Cardinal(PushXRef.Addr) + 4);
      if (Cardinal(Loader) < ClientBase) or (Cardinal(Loader) >= ClientBase + ClientSize) then
       begin
        Writeln('Found the decal loader entry point, but it leads outside the client module. Aborting the patch.');
        Exit;
       end
      else
       Writeln('Found the decal loader entry point.');

      // Do decal loader work

      PatchImageLoader(Loader);

      // Now onto that last call...

      Advance(KVLast, -15);
      AssertMemory(KVLast, [$E8]);
      NOPMemory(KVLast, 15);
      Writeln('Patched out the last KeyValues call.');

      Writeln('The client library should be fully patched now.');
      Result := True;
     end;
   end;
 end;
end;

var
 Window: HWND;
 Process: THandle;
 Modules: array[1..4096] of HMODULE;
 I, ReqModules, ProcessID: Cardinal;
 ModuleName: array[1..MAX_PATH] of Char;

begin
Writeln(' -- TF2 decal tool patcher -- ');
Writeln('(c) unnamed ''10, Mar 2016');
Writeln;
Writeln('WARNING: DON''T TRY TO RUN THIS WHILE CONNECTED TO A VAC-SECURED SERVER.');
Writeln('VAC will instantly notice this patch and ban your account as a result.');
Writeln('Just launch TF2, stay in main menu, launch the patcher, apply your decals');
Writeln('and then quit the game.');
Writeln;

if ParamCount = 0 then
 begin
  Writeln('Enter the name for your preferred decal file.');
  Writeln('Either type the absolute path (e.g. "C:\image.png"),');
  Writeln('or use the relative pathing (e.g. "image.png"),');
  Writeln('so the base dir will be ./tf or ./tf/custom directory.');
  Writeln('Image resolution must be 128x128.');

  repeat
   Write('> ');
   Readln(FileName);
   FileName := Trim(FileName);

   if (FileName <> '') and IsAbsolutePath(PChar(FileName)) and not FileExists(FileName) then
    Writeln('Warning: Can''t find the image file - make sure your path is correct. The program will continue anyway.');

  until FileName <> '';
 end
else
 begin
  FileName := ParamStr(1);
  Writeln('Image file name: ', FileName);
 end;

Writeln;

Window := FindWindow(nil, 'Team Fortress 2');
if Window = 0 then
 Writeln('Can''t find TF2 window. You should start the game first.')
else
 begin
  Writeln('Found TF2 window.');
  GetWindowThreadProcessId(Window, @ProcessID);
  Process := OpenProcess(PROCESS_ALL_ACCESS, False, ProcessID);
  if Process = 0 then
   Writeln('Can''t attach to TF2 process: ', ErrorStr)
  else
   begin
    if not EnumProcessModules(Process, @Modules, SizeOf(Modules), ReqModules) then
     Writeln('Can''t enumerate TF2 modules: ', ErrorStr)
    else
     begin
      if ReqModules > SizeOf(Modules) div SizeOf(Modules[1]) then
       Writeln('Warning - too many modules attached to a process. Expected less than ',
               SizeOf(Modules) div SizeOf(Modules[1]), ', got ', ReqModules, '.');

      for I := 1 to ReqModules do
       begin
        if (GetModuleFileNameEx(Process, Modules[I], @ModuleName, SizeOf(ModuleName)) > 0) and
           (StrIComp(ExtractFileName(@ModuleName), 'client.dll') = 0) then
         begin
          Writeln('Found TF2 client.dll (', I, '/', ReqModules, ').');
          Writeln;

          if PerformPatch(Process, Modules[I]) then
           begin
            Writeln;
            Writeln('Patching successful! You can close this window now.')
           end
          else
           begin
            Writeln;
            Writeln('Patching failed... You can close this window now.');
           end;

          CloseHandle(Process);
          Readln;
          Exit;
         end;
       end;

      Writeln('Can''t find TF2 client.dll.');
     end;

    CloseHandle(Process);
   end;
 end;

Readln
end.
