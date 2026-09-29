unit JpegComponentInfo;

// LEPTON - JPEG encoder/decoder
// Based on Microsoft's code in Ruby
// Author: www.xelitan.com/
// License: Apache 2.0
//

{$mode delphi}
{$H+}
{$modeswitch advancedrecords}

interface

type
  TComponentInfo = record
    QTableIndex: Byte;
    HuffDC: Byte;
    HuffAC: Byte;
    SFV: LongWord;
    SFH: LongWord;
    MBS: LongWord;
    BCV: LongWord;
    BCH: LongWord;
    BC: LongWord;
    NCV: LongWord;
    NCH: LongWord;
    NC: LongWord;
    SID: LongWord;
    JID: Byte;
    class function Default: TComponentInfo; static;
  end;

implementation

class function TComponentInfo.Default: TComponentInfo;
begin
  Result.QTableIndex := $FF;
  Result.HuffDC := $FF;
  Result.HuffAC := $FF;
  Result.SFV := High(LongWord);
  Result.SFH := High(LongWord);
  Result.MBS := High(LongWord);
  Result.BCV := High(LongWord);
  Result.BCH := High(LongWord);
  Result.BC := High(LongWord);
  Result.NCV := High(LongWord);
  Result.NCH := High(LongWord);
  Result.NC := High(LongWord);
  Result.SID := High(LongWord);
  Result.JID := $FF;
end;

end.
