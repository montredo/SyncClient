{*******************************************************************************
  Copyright (с) 2014 MontDigital Software <montredo@mail.ru>

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.
*******************************************************************************}

unit uService;

{$MODE OBJFPC}{$H+}

interface

uses
  Classes, SysUtils, FileUtil, SyncObjs, blcksock, httpsend;

type
  TFileArray = record
    FileID: Integer;
    FileName: AnsiString;
    FilePath: AnsiString;
    FileLength: Int64;
    FileCheck: Boolean;
  end;

type
  TServiceType = (stRefresh, stDownload);
  TInsertType = (itNull, itExists, itNotExists);

type

  { TServiceThread }

  TShowRefreshEvent = procedure(AID, AName, AStatus: string;
    AInsertType: TInsertType; ACheck: Boolean) of object;
  TShowStatusEvent = procedure(AIndex: Integer; AStatus: string) of object;

  TServiceThread = class(TThread)
  private
    FOnShowRefresh: TShowRefreshEvent;
    FOnShowStatus: TShowStatusEvent;

    FServiceType: TServiceType;

    FHTTPSend: THTTPSend;

    FID: string;
    FName: string;
    FStatus: string;
    FInsertType: TInsertType;
    FCheck: Boolean;

    FIndex: Integer;

    FServerName: string;
    FFilePath: string;

    FResponseData: string;
    //FRequestData: string;

    FDownloadLength: Int64;
    FDownloadLengthMax: Int64;
    FDownloadIndex: Integer;

    procedure RefreshSync;
    procedure OnRefreshSyncMethod(AID, AName, AStatus: string;
      AInsertType: TInsertType; ACheck: Boolean);

    procedure StatusSync;
    procedure OnStatusSyncMethod(AIndex: Integer; AStatus: string);

    procedure OnCleanHTTPMethod;
    function OnGZipHTTPMethod: string;
    procedure OnHTTPStatusMethod(Sender: TObject; Reason: THookSocketReason;
      const Value: string);

    procedure OnRefreshData(AValue: string);
  protected
    procedure Execute; override;
  public
    constructor Create(CreateSuspended: Boolean);
    destructor Destroy; override;

    property OnShowRefresh: TShowRefreshEvent read FOnShowRefresh write FOnShowRefresh;
    property OnShowStatus: TShowStatusEvent read FOnShowStatus write FOnShowStatus;

    property ServiceType: TServiceType read FServiceType write FServiceType;

    property ServerName: string read FServerName write FServerName;
    property FilePath: string read FFilePath write FFilePath;
  end;

procedure CriticalSectionCreate;
procedure CriticalSectionFree;

var
  CS: TCriticalSection;
  Event: TEvent;

  FFileArray: array of TFileArray;

implementation

uses
  uConsts, synautil, synacode, fpjson, jsonparser;

{$REGION '*** Critical section ***'}

procedure CriticalSectionCreate;
begin
  CS := TCriticalSection.Create;
  Event := TEvent.Create(nil, False, True, '');
end;

procedure CriticalSectionFree;
begin
  CS.Free;
  Event.Free;
end;

{$ENDREGION}

function ConvertBytes(AValue: Int64): string;
begin
  if AValue div 1024 < 1 then Result := FormatFloat('0 "байт"', AValue);
  if AValue div 1024 >= 1 then Result := FormatFloat('0 "KБ"', AValue/1024);
  if AValue div 1024 >= 1024 then Result := FormatFloat('0.00 "МБ"', AValue/1048576);
  if AValue div 734003200 >= 1 then Result := FormatFloat('0.00 "ГБ"', AValue/1073741824);
end;

{ TServiceThread }

constructor TServiceThread.Create(CreateSuspended: Boolean);
begin
  inherited Create(CreateSuspended);

  FHTTPSend := THTTPSend.Create;
end;

destructor TServiceThread.Destroy;
begin
  FHTTPSend.Free;

  inherited Destroy;
end;

procedure TServiceThread.RefreshSync;
begin
  if Assigned(FOnShowRefresh) then
  begin
    FOnShowRefresh(FID, FName, FStatus, FInsertType, FCheck);
  end;
end;

procedure TServiceThread.OnRefreshSyncMethod(AID, AName, AStatus: string;
  AInsertType: TInsertType; ACheck: Boolean);
begin
  FID := AID;
  FName := AName;
  FStatus := AStatus;
  FInsertType := AInsertType;
  FCheck := ACheck;

  Synchronize(@RefreshSync);
end;

procedure TServiceThread.StatusSync;
begin
  if Assigned(FOnShowStatus) then
  begin
    FOnShowStatus(FIndex, FStatus);
  end;
end;

procedure TServiceThread.OnStatusSyncMethod(AIndex: Integer; AStatus: string);
begin
  FIndex := AIndex;
  FStatus := AStatus;

  Synchronize(@StatusSync);
end;

procedure TServiceThread.OnCleanHTTPMethod;
begin
  FHTTPSend.Document.Clear;
  FHTTPSend.Headers.Clear;
  FHTTPSend.Protocol := '1.1';
  FHTTPSend.UserAgent := SUserAgent;
  FHTTPSend.Headers.Add('Accept-Encoding: gzip,deflate');
  FHTTPSend.AddPortNumberToHost := False;
end;

function TServiceThread.OnGZipHTTPMethod: string;
begin
  FHTTPSend.Document.Position := 0;
  Result := ReadStrFromStream(FHTTPSend.Document, FHTTPSend.Document.Size);
  //HeadersToList(FHTTPSend.Headers);
  //if Trim(AnsiLowerCase(FHTTPSend.Headers.Values['Content-Encoding'])) = 'gzip' then
  //  Result := Decompress(Result);
end;

procedure TServiceThread.OnHTTPStatusMethod(Sender: TObject;
  Reason: THookSocketReason; const Value: string);
var
  SFormatString: string;
begin
  case Reason of
    HR_ReadCount:
    begin
      FDownloadLength := FDownloadLength + StrToInt(Value);

      SFormatString := Format('Загрузка - %s/%s',
        [ConvertBytes(FDownloadLength), ConvertBytes(FDownloadLengthMax)]);

      //SFormatString := Format('Загрузка - %d/%d', [FDownloadLength, FDownloadLengthMax]);

      OnStatusSyncMethod(FDownloadIndex, SFormatString);
    end;
  end;
end;

procedure TServiceThread.OnRefreshData(AValue: string);
var
  JSONParser: TJSONParser;
  JSONObject: TJSONObject;
  JSONData: TJSONData;

  SFileID: Integer;
  SFileName: string;
  SFilePath: string;
  SFileLength: Int64;

  DataCount, I: Integer;
begin
  JSONParser := TJSONParser.Create(AValue);
  try
    JSONObject := JSONParser.Parse as TJSONObject;
    try
      if Assigned(JSONObject) then
      begin
        try
          JSONData := JSONObject.FindPath('items');

          for I := 0 to JSONData.Count - 1 do
          begin
            SFileID := JSONData.Items[I].FindPath('file_id').AsInteger;
            SFileName := JSONData.Items[I].FindPath('file_name').AsString;
            SFilePath := JSONData.Items[I].FindPath('file_path').AsString;
            SFileLength := JSONData.Items[I].FindPath('file_length').AsInt64;

            {$REGION '*** Запись данных пользователя в массив ***'}

            DataCount := Length(FFileArray);
            SetLength(FFileArray, DataCount + 1);

            FFileArray[DataCount].FileID := SFileID;
            FFileArray[DataCount].FileName := SFileName;
            FFileArray[DataCount].FilePath := SFilePath;
            FFileArray[DataCount].FileLength := SFileLength;
            FFileArray[DataCount].FileCheck := not FileExistsUTF8(FFilePath + SFilePath + SFileName);

            {$ENDREGION}

          end;
        except
          Exit;
        end;
      end;
    finally
      JSONObject.Free;
    end;
  finally
    JSONParser.Free;
  end;
end;

procedure TServiceThread.Execute;
var
  I: Integer;
begin
  FFilePath := IncludeTrailingBackslash(FFilePath);

  if FServiceType = stRefresh then
  begin
    OnCleanHTTPMethod;
    FHTTPSend.HTTPMethod('GET', 'http://' + FServerName + '/');

    if FHTTPSend.ResultCode = 200 then
    begin
      FResponseData := OnGZipHTTPMethod;
      OnRefreshData(FResponseData);

      for I := Low(FFileArray) to High(FFileArray) do
      begin
        with FFileArray[I] do
        begin
          // synchronization
          if FileCheck then
            OnRefreshSyncMethod(IntToStr(FileID), FilePath + FileName,
              'Не синхронизован', itNotExists, True)
          else
            OnRefreshSyncMethod(IntToStr(FileID), FilePath + FileName,
              'Синхронизован', itExists, False);
        end;
      end;
    end;
  end;

  if FServiceType = stDownload then
  begin
    FHTTPSend.Sock.OnStatus := @OnHTTPStatusMethod;

    for I := Low(FFileArray) to High(FFileArray) do
    begin
      if FFileArray[I].FileCheck = False then
        Continue;

      while True do
      begin
        FDownloadLength := 0;
        FDownloadLengthMax := FFileArray[I].FileLength;
        FDownloadIndex := I;

        OnCleanHTTPMethod;
        FHTTPSend.HTTPMethod('GET', 'http://' + FServerName +
          '/getFile/' + IntToStr(FFileArray[I].FileID) + '/' +
          EncodeURLElement(FFileArray[I].FileName));

        if FHTTPSend.ResultCode = 200 then
        begin
          if DirectoryExistsUTF8(FFilePath + FFileArray[I].FilePath) = False then
            ForceDirectoriesUTF8(FFilePath + FFileArray[I].FilePath);

          FHTTPSend.Document.SaveToFile(UTF8ToSys(FFilePath +
            FFileArray[I].FilePath + FFileArray[I].FileName));

          OnStatusSyncMethod(I, 'Успешно загружено!');

          Break;
        end
        else
        begin
          OnStatusSyncMethod(I, 'Ошибка загрузки!');

          Sleep(500);
        end;
      end;
    end;
  end;
end;

end.

