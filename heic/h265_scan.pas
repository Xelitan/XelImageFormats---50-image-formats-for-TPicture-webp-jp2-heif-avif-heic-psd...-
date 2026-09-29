// BPG decoder -- Free Pascal port of libbpg 0.9.8
// Coefficient scan order tables.
// Corresponds to: the scan tables at the top of libavcodec/hevc_cabac.c
//
// The 2-D tables of the reference ([2][2], [4][4], [8][8]) are flattened here;
// index them as [(y << k) + x].
unit h265_scan;

{$mode Delphi}
{$H+}
{$RANGECHECKS OFF}

interface

{$i scan_tables.inc}

implementation

end.
