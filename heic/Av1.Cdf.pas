unit Av1.Cdf;

// AV1 CDF (probability) context.
//
// Mirrors dav1d's CdfContext field-for-field (src/cdf.h) as a packed record, so
// the default tables — dumped from dav1d and embedded in Av1.CdfData.inc — load
// with a single Move. CDFs are inverse Q15 (dav1d convention); the msac decoder
// adapts them in place during a tile.
//
// Reference: dav1d src/cdf.h, src/cdf.c.

{$mode delphi}{$H+}
{$PACKRECORDS 2}

interface

uses
  SysUtils;

const
  N_INTRA_PRED_MODES = 13;
  N_UV_INTRA_PRED_MODES = 14;
  N_PARTITIONS = 10;
  N_BL_LEVELS = 5;
  N_TX_SIZES = 5;
  N_BS_SIZES = 22;
  N_COMP_INTER_PRED_MODES = 8;
  N_MV_JOINTS = 4;
  N_SWITCHABLE_FILTERS = 3;
  AV1_MAX_SEGMENTS = 8;

type
  TCdfModeContext = record
    y_mode: array[0..3, 0..15] of Word;
    uv_mode: array[0..1, 0..12, 0..15] of Word;
    wedge_idx: array[0..8, 0..15] of Word;
    partition: array[0..4, 0..3, 0..15] of Word;
    cfl_alpha: array[0..5, 0..15] of Word;
    txtp_inter1: array[0..1, 0..15] of Word;
    txtp_inter2: array[0..15] of Word;
    txtp_intra1: array[0..1, 0..12, 0..7] of Word;
    txtp_intra2: array[0..2, 0..12, 0..7] of Word;
    cfl_sign: array[0..7] of Word;
    angle_delta: array[0..7, 0..7] of Word;
    filter_intra: array[0..7] of Word;
    comp_inter_mode: array[0..7, 0..7] of Word;
    seg_id: array[0..2, 0..7] of Word;
    pal_sz: array[0..1, 0..6, 0..7] of Word;
    color_map: array[0..1, 0..6, 0..4, 0..7] of Word;
    filter: array[0..1, 0..7, 0..3] of Word;
    txsz: array[0..3, 0..2, 0..3] of Word;
    motion_mode: array[0..21, 0..3] of Word;
    delta_q: array[0..3] of Word;
    delta_lf: array[0..4, 0..3] of Word;
    interintra_mode: array[0..3, 0..3] of Word;
    restore_switchable: array[0..3] of Word;
    restore_wiener: array[0..1] of Word;
    restore_sgrproj: array[0..1] of Word;
    interintra: array[0..6, 0..1] of Word;
    interintra_wedge: array[0..6, 0..1] of Word;
    txtp_inter3: array[0..3, 0..1] of Word;
    use_filter_intra: array[0..21, 0..1] of Word;
    newmv_mode: array[0..5, 0..1] of Word;
    globalmv_mode: array[0..1, 0..1] of Word;
    refmv_mode: array[0..5, 0..1] of Word;
    drl_bit: array[0..2, 0..1] of Word;
    intra: array[0..3, 0..1] of Word;
    comp: array[0..4, 0..1] of Word;
    comp_dir: array[0..4, 0..1] of Word;
    jnt_comp: array[0..5, 0..1] of Word;
    mask_comp: array[0..5, 0..1] of Word;
    wedge_comp: array[0..8, 0..1] of Word;
    ref: array[0..5, 0..2, 0..1] of Word;
    comp_fwd_ref: array[0..2, 0..2, 0..1] of Word;
    comp_bwd_ref: array[0..1, 0..2, 0..1] of Word;
    comp_uni_ref: array[0..2, 0..2, 0..1] of Word;
    txpart: array[0..6, 0..2, 0..1] of Word;
    skip: array[0..2, 0..1] of Word;
    skip_mode: array[0..2, 0..1] of Word;
    seg_pred: array[0..2, 0..1] of Word;
    obmc: array[0..21, 0..1] of Word;
    pal_y: array[0..6, 0..2, 0..1] of Word;
    pal_uv: array[0..1, 0..1] of Word;
    intrabc: array[0..1] of Word;
  end;

  TCdfCoefContext = record
    eob_bin_16: array[0..1, 0..1, 0..7] of Word;
    eob_bin_32: array[0..1, 0..1, 0..7] of Word;
    eob_bin_64: array[0..1, 0..1, 0..7] of Word;
    eob_bin_128: array[0..1, 0..1, 0..7] of Word;
    eob_bin_256: array[0..1, 0..1, 0..15] of Word;
    eob_bin_512: array[0..1, 0..15] of Word;
    eob_bin_1024: array[0..1, 0..15] of Word;
    eob_base_tok: array[0..4, 0..1, 0..3, 0..3] of Word;
    base_tok: array[0..4, 0..1, 0..40, 0..3] of Word;
    br_tok: array[0..3, 0..1, 0..20, 0..3] of Word;
    eob_hi_bit: array[0..4, 0..1, 0..10, 0..1] of Word;
    skip: array[0..4, 0..12, 0..1] of Word;
    dc_sign: array[0..1, 0..2, 0..1] of Word;
  end;

  TCdfMvComponent = record
    classes: array[0..15] of Word;
    class0_fp: array[0..1, 0..3] of Word;
    classN_fp: array[0..3] of Word;
    class0_hp: array[0..1] of Word;
    classN_hp: array[0..1] of Word;
    class0: array[0..1] of Word;
    classN: array[0..9, 0..1] of Word;
    sign: array[0..1] of Word;
    pad: array[0..7] of Word;   // dav1d ALIGN(classes,32) pads the struct to 64 words
  end;

  TCdfMvContext = record
    comp: array[0..1] of TCdfMvComponent;
    joint: array[0..3] of Word;
  end;

  TCdfContext = record
    m: TCdfModeContext;
    kfym: array[0..4, 0..4, 0..15] of Word;
    coef: TCdfCoefContext;
    mv, dmv: TCdfMvContext;
  end;
  PCdfContext = ^TCdfContext;

// Returns the qcat index (0..3) for a base_q_idx, per dav1d get_qcat_idx.
function QCatIdx(AQ: Integer): Integer;

// Loads the default CDF tables for the given qcat into ACdf.
procedure LoadCdfDefault(var ACdf: TCdfContext; AQCat: Integer);

implementation

{$I Av1.CdfData.inc}

function QCatIdx(AQ: Integer): Integer;
begin
  if AQ <= 20 then Result := 0
  else if AQ <= 60 then Result := 1
  else if AQ <= 120 then Result := 2
  else Result := 3;
end;

procedure LoadCdfDefault(var ACdf: TCdfContext; AQCat: Integer);
begin
  Assert(SizeOf(TCdfContext) = 6870 * 2, 'TCdfContext size mismatch');
  Move(CDF_DEFAULT[AQCat][0], ACdf, SizeOf(TCdfContext));
end;

end.
