unit unit1;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, FileUtil, Forms, Controls, Graphics, Dialogs, StdCtrls;

type

  { TForm1 }

  TForm1 = class(TForm)
    Button1: TButton;
    Memo1: TMemo;
    procedure Button1Click(Sender: TObject);
  private
    { private declarations }
  public
    { public declarations }
  end; 

var
  Form1: TForm1; 

implementation
uses
  blcksock, synautil, httpsend, dom, xmlread,
  winsock;

{$R *.lfm}

{ TForm1 }

procedure TForm1.Button1Click(Sender: TObject);
var
  UDPSock: TUDPBlockSocket;
  http: THTTPSend;
  rcvs, uri, s, ErrMsgHead: String;
  Prot, User, Pass, Host, Port, Path, Para: string;
  i: integer;
  doc: TXMLDocument;
  list_node, node1, node2: TDOMNode;
  ClientList, sl: TStringList;
begin
  Screen.Cursor:= crHourGlass;
  Memo1.Lines.BeginUpdate;
  ClientList:= TStringList.Create;
  try
    Memo1.Clear;
    try
      UDPSock:= TUDPBlockSocket.Create;
      try
        UDPSock.Family:= SF_IP4;
        ErrMsgHead:= 'M-SEARCH Sent';
        UDPSock.CreateSocket();
        if UDPSock.LastError <> 0 then Raise Exception.Create(UDPSock.LastErrorDesc);
        UDPSock.Bind('0.0.0.0', '0');
        if UDPSock.LastError <> 0 then Raise Exception.Create(UDPSock.LastErrorDesc);
        UDPSock.Connect('239.255.255.250', '1900');
        if UDPSock.LastError <> 0 then Raise Exception.Create(UDPSock.LastErrorDesc);
        s:= 'M-SEARCH * HTTP/1.1' + CRLF +
         'HOST: 239.255.255.250:1900' + CRLF +
         'MAN: "ssdp:discover"' + CRLF +
         'MX: 5' + CRLF +
         'ST: ssdp:all' + CRLF + CRLF;
        UDPSock.SendString(s);
        if UDPSock.LastError <> 0 then Raise Exception.Create(UDPSock.LastErrorDesc);

        while True do begin
          ErrMsgHead:= 'M-SEARCH Recv';
          rcvs:= UDPSock.RecvPacket(5*1000);
          if UDPSock.LastError = WSAETIMEDOUT then Break;
          if UDPSock.LastError <> 0 then Raise Exception.Create(UDPSock.LastErrorDesc);
          if (Pos(LF+'ST:', UpperCase(rcvs)) > 0) and
           (ClientList.IndexOf(UDPSock.GetRemoteSinIP) = -1) then begin
           //= 'URN:SCHEMAS-UPNP-ORG:SERVICE:CONNECTIONMANAGER:1') then begin
            i:= Pos('LOCATION:', UpperCase(rcvs));
            if i > 0 then begin
              s:= Copy(rcvs, i, MaxInt);
              Fetch(s, ':');
              uri:= Trim(Fetch(s, CR));
              ErrMsgHead:= 'GET ' + uri;
              http := THTTPSend.Create;
              try
                http.Sock.Family:= SF_IP4;
                http.UserAgent:= 'UPnP/1.0';
                if http.HTTPMethod('GET', uri) then begin
                  try
                    readXMLFile(doc, http.Document);
                    try
                      ParseURL(uri, Prot, User, Pass, Host, Port, Path, Para);
                      uri:= Prot + '://' + Host + ':' + Port + '/';
                      list_node:= doc.DocumentElement.FindNode('URLBase');
                      if Assigned(list_node) then
                        uri:= list_node.TextContent;
                      list_node:= doc.DocumentElement.FindNode('device');
                      if Assigned(list_node) then
                        list_node:= list_node.FindNode('serviceList');
                      if Assigned(list_node) then begin
                        node1:= list_node.FirstChild;
                        while Assigned(node1) do begin
                          node2:= node1.FirstChild;
                          while Assigned(node2) do begin
                            if (UpperCase(node2.NodeName) = UpperCase('serviceId')) and
                             (UpperCase(node2.TextContent) = UpperCase('urn:upnp-org:serviceId:ConnectionManager')) then begin

                              node2:= node1.FindNode('controlURL');
                              s:= node2.TextContent;
                              if s[1] = '/' then s:= Copy(s, 2, MaxInt);
                              uri:= uri + s;
                              //Memo1.Lines.Add(uri);
                              Break;
                            end;
                            node2:= node2.NextSibling;
                          end;
                          node1:= node1.NextSibling;
                        end;
                      end;
                    finally
                      doc.Free;
                    end;
                  except
                    uri:= '';
                  end;
                end else
                  uri:= '';
                  //  Raise Exception.Create(http.Sock.LastErrorDesc);
              finally
                http.Free;
              end;

              if uri <> '' then begin
                ErrMsgHead:= 'POST ' + uri;
                http := THTTPSend.Create;
                try
                  http.Sock.Family:= SF_IP4;
                  http.UserAgent:= 'UPnP/1.0';
                  http.MimeType:= 'text/xml; charset="utf-8"';
                  http.Headers.Add('SOAPACTION: "urn:schemas-upnp-org:service:ConnectionManager:1#GetProtocolInfo"');
                  s:= '<?xml version="1.0"?>' +
                   '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">' +
                   '<s:Body><u:GetProtocolInfo xmlns:u="urn:schemas-upnp-org:service:ConnectionManager:1">' +
                   '</u:GetProtocolInfo></s:Body></s:Envelope>';
                  http.Document.WriteBuffer(s[1], Length(s));
                  if http.HTTPMethod('POST', uri) then begin
                    //Memo1.Lines.Add(Copy(PChar(http.Document.Memory), 1, http.Document.Size));
                    try
                      readXMLFile(doc, http.Document);
                      try
                        ClientList.Add(UDPSock.GetRemoteSinIP);
                        Memo1.Lines.Add(CRLF+CRLF+'*** クライアント ' +
                         IntToStr(ClientList.Count) + ' ***    ' +
                         'IP Address: ' + UDPSock.GetRemoteSinIP + {'    ' +
                         'Domain Name: ' + UDPSock.ResolveIPToName(UDPSock.GetRemoteSinIP) +} CRLF);
                        Memo1.Lines.Add(rcvs);

                        list_node:= doc.DocumentElement.FindNode('s:Body');
                        if Assigned(list_node) then
                          list_node:= list_node.FindNode('u:GetProtocolInfoResponse');
                        if Assigned(list_node) then begin
                          sl:= TStringList.Create;
                          try
                            node1:= list_node.FindNode('Source');
                            if Assigned(node1) then begin
                              sl.CommaText:= node1.TextContent;
                              Memo1.Lines.AddStrings(sl);
                            end;
                            node1:= list_node.FindNode('Sink');
                            if Assigned(node1) then begin
                              sl.CommaText:= node1.TextContent;
                              Memo1.Lines.AddStrings(sl);
                            end;
                          finally
                            sl.Free;
                          end;
                        end;
                      finally
                        doc.Free;
                      end;
                    except
                    end;
                  end;
                finally
                  http.Free;
                end;
              end;
            end;
          end;
        end;
      finally
        UDPSock.Free;
      end;

    except
      on e: Exception do begin
        Memo1.Lines.Add('***ERROR: ' + ErrMsgHead + ': ' + e.Message);
      end;
    end;
  finally
    ClientList.Free;
    Memo1.Lines.EndUpdate;
    Screen.Cursor:= crDefault;
  end;
end;

end.

