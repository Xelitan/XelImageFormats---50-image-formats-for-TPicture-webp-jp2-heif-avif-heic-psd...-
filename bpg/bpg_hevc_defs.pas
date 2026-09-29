// BPG decoder -- Free Pascal port of libbpg 0.9.8
// HEVC decoder data structures, enums and constants.
// Corresponds to: libavcodec/hevc.h, hevcdsp.h, hevcpred.h
//
// Build configuration of the reference (config.h + Makefile CFLAGS):
//   USE_MSPS, USE_SAO_SMALL_BUFFER, USE_FRAME_DURATION_SEI,
//   USE_VAR_BIT_DEPTH, USE_PRED
//   (USE_MD5, USE_FULL, USE_FUNC_PTR, USE_AV_LOG, USE_BIPRED are OFF)
unit bpg_hevc_defs;

{$mode Delphi}
{$H+}
{$INLINE ON}
{$POINTERMATH ON}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses
  bpg_common, bpg_bits, bpg_cabac;

const
  MAX_DPB_SIZE = 16;
  MAX_REFS = 16;
  MAX_SUB_LAYERS = 7;

  // USE_MSPS is defined
  MAX_VPS_COUNT = 16;
  MAX_SPS_COUNT = 32;
  // USE_PRED is defined
  MAX_DPB_COUNT = 32;
  MAX_PPS_COUNT = 256;

  MAX_SHORT_TERM_RPS_COUNT = 64;
  MAX_CU_SIZE = 128;
  MAX_TRANSFORM_DEPTH = 5;
  MAX_TB_SIZE = 32;
  MAX_LOG2_CTB_SIZE = 6;
  MAX_QP = 51;
  DEFAULT_INTRA_TC_OFFSET = 2;
  HEVC_CONTEXTS = 199;
  MRG_MAX_NUM_CANDS = 5;

  L0 = 0;
  L1 = 1;

  EPEL_EXTRA_BEFORE = 1;
  EPEL_EXTRA_AFTER = 2;
  EPEL_EXTRA = 3;
  QPEL_EXTRA_BEFORE = 3;
  QPEL_EXTRA_AFTER = 4;
  QPEL_EXTRA = 7;

  EDGE_EMU_BUFFER_STRIDE = 80;
  MAX_PB_SIZE = 64;

  // NAL unit types (Table 7-3)
  NAL_TRAIL_N = 0;
  NAL_TRAIL_R = 1;
  NAL_TSA_N = 2;
  NAL_TSA_R = 3;
  NAL_STSA_N = 4;
  NAL_STSA_R = 5;
  NAL_RADL_N = 6;
  NAL_RADL_R = 7;
  NAL_RASL_N = 8;
  NAL_RASL_R = 9;
  NAL_BLA_W_LP = 16;
  NAL_BLA_W_RADL = 17;
  NAL_BLA_N_LP = 18;
  NAL_IDR_W_RADL = 19;
  NAL_IDR_N_LP = 20;
  NAL_CRA_NUT = 21;
  NAL_VPS = 32;
  NAL_SPS = 33;
  NAL_PPS = 34;
  NAL_AUD = 35;
  NAL_EOS_NUT = 36;
  NAL_EOB_NUT = 37;
  NAL_FD_NUT = 38;
  NAL_SEI_PREFIX = 39;
  NAL_SEI_SUFFIX = 40;

  // RPSType
  ST_CURR_BEF = 0;
  ST_CURR_AFT = 1;
  ST_FOLL = 2;
  LT_CURR = 3;
  LT_FOLL = 4;
  NB_RPS_TYPE = 5;

  // SliceType
  B_SLICE = 0;
  P_SLICE = 1;
  I_SLICE = 2;

  // SyntaxElement (context table offsets are derived from this order)
  SAO_MERGE_FLAG = 0;
  SAO_TYPE_IDX = 1;
  SAO_EO_CLASS = 2;
  SAO_BAND_POSITION = 3;
  SAO_OFFSET_ABS = 4;
  SAO_OFFSET_SIGN = 5;
  END_OF_SLICE_FLAG = 6;
  SPLIT_CODING_UNIT_FLAG = 7;
  CU_TRANSQUANT_BYPASS_FLAG = 8;
  SKIP_FLAG = 9;
  CU_QP_DELTA = 10;
  PRED_MODE_FLAG = 11;
  PART_MODE = 12;
  PCM_FLAG = 13;
  PREV_INTRA_LUMA_PRED_FLAG = 14;
  MPM_IDX = 15;
  REM_INTRA_LUMA_PRED_MODE = 16;
  INTRA_CHROMA_PRED_MODE = 17;
  MERGE_FLAG = 18;
  MERGE_IDX = 19;
  INTER_PRED_IDC = 20;
  REF_IDX_L0 = 21;
  REF_IDX_L1 = 22;
  ABS_MVD_GREATER0_FLAG = 23;
  ABS_MVD_GREATER1_FLAG = 24;
  ABS_MVD_MINUS2 = 25;
  MVD_SIGN_FLAG = 26;
  MVP_LX_FLAG = 27;
  NO_RESIDUAL_DATA_FLAG = 28;
  SPLIT_TRANSFORM_FLAG = 29;
  CBF_LUMA = 30;
  CBF_CB_CR = 31;
  TRANSFORM_SKIP_FLAG = 32;
  EXPLICIT_RDPCM_FLAG = 33;
  EXPLICIT_RDPCM_DIR_FLAG = 34;
  LAST_SIGNIFICANT_COEFF_X_PREFIX = 35;
  LAST_SIGNIFICANT_COEFF_Y_PREFIX = 36;
  LAST_SIGNIFICANT_COEFF_X_SUFFIX = 37;
  LAST_SIGNIFICANT_COEFF_Y_SUFFIX = 38;
  SIGNIFICANT_COEFF_GROUP_FLAG = 39;
  SIGNIFICANT_COEFF_FLAG = 40;
  COEFF_ABS_LEVEL_GREATER1_FLAG = 41;
  COEFF_ABS_LEVEL_GREATER2_FLAG = 42;
  COEFF_ABS_LEVEL_REMAINING = 43;
  COEFF_SIGN_FLAG = 44;
  LOG2_RES_SCALE_ABS = 45;
  RES_SCALE_SIGN_FLAG = 46;
  CU_CHROMA_QP_OFFSET_FLAG = 47;
  CU_CHROMA_QP_OFFSET_IDX = 48;

  // PartMode
  PART_2Nx2N = 0;
  PART_2NxN = 1;
  PART_Nx2N = 2;
  PART_NxN = 3;
  PART_2NxnU = 4;
  PART_2NxnD = 5;
  PART_nLx2N = 6;
  PART_nRx2N = 7;

  // PredMode
  MODE_INTER = 0;
  MODE_INTRA = 1;
  MODE_SKIP = 2;

  // InterPredIdc
  PRED_L0 = 0;
  PRED_L1 = 1;
  PRED_BI = 2;

  // PredFlag
  PF_INTRA = 0;
  PF_L0 = 1;
  PF_L1 = 2;
  PF_BI = 3;

  // IntraPredMode
  INTRA_PLANAR = 0;
  INTRA_DC = 1;
  INTRA_ANGULAR_2 = 2;
  INTRA_ANGULAR_10 = 10;
  INTRA_ANGULAR_26 = 26;
  INTRA_ANGULAR_34 = 34;

  // SAOType
  SAO_NOT_APPLIED = 0;
  SAO_BAND = 1;
  SAO_EDGE = 2;
  SAO_APPLIED = 3;

  // SAOEOClass
  SAO_EO_HORIZ = 0;
  SAO_EO_VERT = 1;
  SAO_EO_135D = 2;
  SAO_EO_45D = 3;

  // ScanType
  SCAN_DIAG = 0;
  SCAN_HORIZ = 1;
  SCAN_VERT = 2;

  // frame flags
  HEVC_FRAME_FLAG_OUTPUT = 1 shl 0;
  HEVC_FRAME_FLAG_SHORT_REF = 1 shl 1;
  HEVC_FRAME_FLAG_LONG_REF = 1 shl 2;
  HEVC_FRAME_FLAG_BUMPING = 1 shl 3;

  // boundary flags for the deblocking filter
  BOUNDARY_LEFT_SLICE = 1 shl 0;
  BOUNDARY_LEFT_TILE = 1 shl 1;
  BOUNDARY_UPPER_SLICE = 1 shl 2;
  BOUNDARY_UPPER_TILE = 1 shl 3;

  // pixel formats used by the MSPS path (always 16-bit planar internally)
  AV_PIX_FMT_GRAY16LE = 0;
  AV_PIX_FMT_YUV420P16LE = 1;
  AV_PIX_FMT_YUV422P16LE = 2;
  AV_PIX_FMT_YUV444P16LE = 3;

type
  TAVRational = record
    Num, Den: Integer;
  end;

  // Reference-counted plane allocation, standing in for AVBufferRef.
  TBufRef = record
    Data: PByte;
    Size: SizeInt;
    RefCount: Integer;
  end;
  PBufRef = ^TBufRef;

  // Minimal stand-in for AVFrame: three 16-bit planes.
  TAVFrame = record
    Data: array[0..2] of PByte;       // plane base pointers
    Linesize: array[0..2] of Integer; // in bytes
    Buf: array[0..2] of PBufRef;      // reference-counted allocations
    Width, Height: Integer;
    Format: Integer;
    KeyFrame: Integer;
    PictType: Integer;
    // libbpg reuses pts to carry the BPG animation frame duration
    Pts: Int64;
  end;
  PAVFrame = ^TAVFrame;

  TShortTermRPS = record
    num_negative_pics: Cardinal;
    num_delta_pocs: Integer;
    delta_poc: array[0..31] of Int32;
    used: array[0..31] of Byte;
  end;
  PShortTermRPS = ^TShortTermRPS;

  TLongTermRPS = record
    poc: array[0..31] of Integer;
    used: array[0..31] of Byte;
    nb_refs: Byte;
  end;
  PLongTermRPS = ^TLongTermRPS;

  PHEVCFrame = ^THEVCFrame;

  TRefPicList = record
    Ref: array[0..MAX_REFS - 1] of PHEVCFrame;
    List: array[0..MAX_REFS - 1] of Integer;
    isLongTerm: array[0..MAX_REFS - 1] of Integer;
    nb_refs: Integer;
  end;
  PRefPicList = ^TRefPicList;

  TRefPicListTab = record
    refPicList: array[0..1] of TRefPicList;
  end;
  PRefPicListTab = ^TRefPicListTab;
  PPRefPicListTab = ^PRefPicListTab;

  THEVCWindow = record
    left_offset: Integer;
    right_offset: Integer;
    top_offset: Integer;
    bottom_offset: Integer;
  end;

  TVUI = record
    sar: TAVRational;
    // the MSPS path only ever sets `sar`; the remaining VUI fields of the
    // reference struct are not parsed and therefore omitted.
  end;

  TScalingList = record
    // sizeID 0 only needs 8 coeffs and size ID 3 only has 2 arrays, but the
    // reference over-allocates in the same way
    sl: array[0..3, 0..5, 0..63] of Byte;
    sl_dc: array[0..1, 0..5] of Byte;
  end;
  PScalingList = ^TScalingList;

  TTemporalLayer = record
    max_dec_pic_buffering: Integer;
    num_reorder_pics: Integer;
    max_latency_increase: Integer;
  end;

  TPCMInfo = record
    bit_depth: Byte;
    bit_depth_chroma: Byte;
    log2_min_pcm_cb_size: Cardinal;
    log2_max_pcm_cb_size: Cardinal;
    loop_filter_disable_flag: Byte;
  end;

  THEVCSPS = record
    vps_id: Cardinal;
    chroma_format_idc: Integer;
    separate_colour_plane_flag: Byte;

    output_width, output_height: Integer;
    output_window: THEVCWindow;
    pic_conf_win: THEVCWindow;

    bit_depth: Integer;
    pixel_shift: Integer;
    pix_fmt: Integer;

    log2_max_poc_lsb: Cardinal;
    pcm_enabled_flag: Integer;

    // NOTE: declared before max_sub_layers -- in Pascal a record field is in
    // scope for the rest of the record declaration and names are
    // case-insensitive, so the field would otherwise shadow the constant.
    temporal_layer: array[0..MAX_SUB_LAYERS - 1] of TTemporalLayer;
    max_sub_layers: Integer;

    vui: TVUI;

    scaling_list_enable_flag: Byte;
    scaling_list: TScalingList;

    nb_st_rps: Cardinal;
    st_rps: array[0..MAX_SHORT_TERM_RPS_COUNT - 1] of TShortTermRPS;

    amp_enabled_flag: Byte;
    sao_enabled: Byte;

    long_term_ref_pics_present_flag: Byte;
    lt_ref_pic_poc_lsb_sps: array[0..31] of Word;
    used_by_curr_pic_lt_sps_flag: array[0..31] of Byte;
    num_long_term_ref_pics_sps: Byte;

    pcm: TPCMInfo;
    sps_temporal_mvp_enabled_flag: Byte;
    sps_strong_intra_smoothing_enable_flag: Byte;

    log2_min_cb_size: Cardinal;
    log2_diff_max_min_coding_block_size: Cardinal;
    log2_min_tb_size: Cardinal;
    log2_max_trafo_size: Cardinal;
    log2_ctb_size: Cardinal;
    log2_min_pu_size: Cardinal;

    max_transform_hierarchy_depth_inter: Integer;
    max_transform_hierarchy_depth_intra: Integer;

    transform_skip_rotation_enabled_flag: Integer;
    transform_skip_context_enabled_flag: Integer;
    implicit_rdpcm_enabled_flag: Integer;
    explicit_rdpcm_enabled_flag: Integer;
    intra_smoothing_disabled_flag: Integer;
    persistent_rice_adaptation_enabled_flag: Integer;

    width, height: Integer;
    ctb_width, ctb_height, ctb_size: Integer;
    min_cb_width, min_cb_height: Integer;
    min_tb_width, min_tb_height: Integer;
    min_pu_width, min_pu_height: Integer;
    tb_mask: Integer;

    hshift: array[0..2] of Integer;
    vshift: array[0..2] of Integer;

    qp_bd_offset: Integer;
  end;
  PHEVCSPS = ^THEVCSPS;

  THEVCPPS = record
    sps_id: Cardinal;

    sign_data_hiding_flag: Byte;
    cabac_init_present_flag: Byte;

    num_ref_idx_l0_default_active: Integer;
    num_ref_idx_l1_default_active: Integer;
    pic_init_qp_minus26: Integer;

    constrained_intra_pred_flag: Byte;
    transform_skip_enabled_flag: Byte;

    cu_qp_delta_enabled_flag: Byte;
    diff_cu_qp_delta_depth: Integer;

    cb_qp_offset: Integer;
    cr_qp_offset: Integer;
    pic_slice_level_chroma_qp_offsets_present_flag: Byte;
    weighted_pred_flag: Byte;
    weighted_bipred_flag: Byte;
    output_flag_present_flag: Byte;
    transquant_bypass_enable_flag: Byte;

    dependent_slice_segments_enabled_flag: Byte;
    tiles_enabled_flag: Byte;
    entropy_coding_sync_enabled_flag: Byte;

    num_tile_columns: Integer;
    num_tile_rows: Integer;
    uniform_spacing_flag: Byte;
    loop_filter_across_tiles_enabled_flag: Byte;

    seq_loop_filter_across_slices_enabled_flag: Byte;

    deblocking_filter_control_present_flag: Byte;
    deblocking_filter_override_enabled_flag: Byte;
    disable_dbf: Byte;
    beta_offset: Integer;
    tc_offset: Integer;

    scaling_list_data_present_flag: Byte;
    scaling_list: TScalingList;

    lists_modification_present_flag: Byte;
    log2_parallel_merge_level: Integer;
    num_extra_slice_header_bits: Integer;
    slice_header_extension_present_flag: Byte;
    log2_max_transform_skip_block_size: Byte;
    cross_component_prediction_enabled_flag: Byte;
    chroma_qp_offset_list_enabled_flag: Byte;
    diff_cu_chroma_qp_offset_depth: Byte;
    chroma_qp_offset_list_len_minus1: Byte;
    cb_qp_offset_list: array[0..4] of Int8;
    cr_qp_offset_list: array[0..4] of Int8;
    log2_sao_offset_scale_luma: Byte;
    log2_sao_offset_scale_chroma: Byte;

    // inferred parameters
    column_width: PCardinal;
    row_height: PCardinal;
    col_bd: PCardinal;
    row_bd: PCardinal;
    col_idxX: PInteger;

    ctb_addr_rs_to_ts: PInteger;
    ctb_addr_ts_to_rs: PInteger;
    tile_id: PInteger;
    tile_pos_rs: PInteger;
    min_tb_addr_zs: PInteger;
    min_tb_addr_zs_tab: PInteger;
  end;
  PHEVCPPS = ^THEVCPPS;

  TSliceHeader = record
    pps_id: Cardinal;

    slice_segment_addr: Cardinal;
    slice_addr: Cardinal;

    slice_type: Integer;
    pic_order_cnt_lsb: Integer;

    first_slice_in_pic_flag: Byte;
    dependent_slice_segment_flag: Byte;
    pic_output_flag: Byte;
    colour_plane_id: Byte;

    slice_rps: TShortTermRPS;
    short_term_rps: PShortTermRPS;
    long_term_rps: TLongTermRPS;
    list_entry_lx: array[0..1, 0..31] of Cardinal;

    rpl_modification_flag: array[0..1] of Byte;
    no_output_of_prior_pics_flag: Byte;
    slice_temporal_mvp_enabled_flag: Byte;

    nb_refs: array[0..1] of Cardinal;

    slice_sample_adaptive_offset_flag: array[0..2] of Byte;
    mvd_l1_zero_flag: Byte;

    cabac_init_flag: Byte;
    disable_deblocking_filter_flag: Byte;
    slice_loop_filter_across_slices_enabled_flag: Byte;
    collocated_list: Byte;

    collocated_ref_idx: Cardinal;

    slice_qp_delta: Integer;
    slice_cb_qp_offset: Integer;
    slice_cr_qp_offset: Integer;

    cu_chroma_qp_offset_enabled_flag: Byte;

    beta_offset: Integer;
    tc_offset: Integer;

    max_num_merge_cand: Cardinal;

    entry_point_offset: PInteger;
    offset: PInteger;
    size: PInteger;
    num_entry_point_offsets: Integer;

    slice_qp: Int8;

    luma_log2_weight_denom: Byte;
    chroma_log2_weight_denom: Int16;

    luma_weight_l0: array[0..15] of Int16;
    chroma_weight_l0: array[0..15, 0..1] of Int16;
    chroma_weight_l1: array[0..15, 0..1] of Int16;
    luma_weight_l1: array[0..15] of Int16;

    luma_offset_l0: array[0..15] of Int16;
    chroma_offset_l0: array[0..15, 0..1] of Int16;
    luma_offset_l1: array[0..15] of Int16;
    chroma_offset_l1: array[0..15, 0..1] of Int16;

    slice_ctb_addr_rs: Integer;
  end;
  PSliceHeader = ^TSliceHeader;

  TCodingUnit = record
    x, y: Integer;
    pred_mode: Integer;
    part_mode: Integer;
    rqt_root_cbf: Byte;
    pcm_flag: Byte;
    intra_split_flag: Byte;
    max_trafo_depth: Byte;
    cu_transquant_bypass_flag: Byte;
  end;

  TMv = record
    x: Int16;
    y: Int16;
  end;
  PMv = ^TMv;

  TMvField = record
    mv: array[0..1] of TMv;
    ref_idx: array[0..1] of Int8;
    pred_flag: Int8;
  end;
  PMvField = ^TMvField;

  TNeighbourAvailable = record
    cand_bottom_left: Integer;
    cand_left: Integer;
    cand_up: Integer;
    cand_up_left: Integer;
    cand_up_right: Integer;
    cand_up_right_sap: Integer;
  end;

  TPredictionUnit = record
    mpm_idx: Integer;
    rem_intra_luma_pred_mode: Integer;
    intra_pred_mode: array[0..3] of Byte;
    mvd: TMv;
    merge_flag: Byte;
    intra_pred_mode_c: array[0..3] of Byte;
    chroma_mode_c: array[0..3] of Byte;
  end;

  TTransformUnit = record
    cu_qp_delta: Integer;
    res_scale_val: Integer;
    intra_pred_mode: Integer;
    intra_pred_mode_c: Integer;
    chroma_mode_c: Integer;
    is_cu_qp_delta_coded: Byte;
    is_cu_chroma_qp_offset_coded: Byte;
    cu_qp_offset_cb: Int8;
    cu_qp_offset_cr: Int8;
    cross_pf: Byte;
  end;

  TDBParams = record
    beta_offset: Integer;
    tc_offset: Integer;
  end;
  PDBParams = ^TDBParams;

  THEVCFrame = record
    Frame: PAVFrame;
    tab_mvf: PMvField;
    refPicList: PRefPicList;
    rpl_tab: PPRefPicListTab;
    ctb_count: Integer;
    poc: Integer;
    collocated_ref: PHEVCFrame;
    window: THEVCWindow;
    // the reference uses AVBufferRef pools; a single-threaded decoder can own
    // the allocations directly
    tab_mvf_buf: Pointer;
    rpl_tab_buf: Pointer;
    rpl_buf: Pointer;
    // number of RefPicListTab entries in rpl_buf (the reference derives this
    // from AVBufferRef.size)
    rpl_buf_count: Integer;
    sequence: Word;
    flags: Byte;
  end;

  THEVCNAL = record
    rbsp_buffer: PByte;
    rbsp_buffer_size: Integer;
    size: Integer;
    data: PByte;
  end;
  PHEVCNAL = ^THEVCNAL;

  TSAOParams = record
    offset_abs: array[0..2, 0..3] of Integer;
    offset_sign: array[0..2, 0..3] of Integer;
    band_position: array[0..2] of Byte;
    eo_class: array[0..2] of Integer;
    offset_val: array[0..2, 0..4] of Int16;
    type_idx: array[0..2] of Byte;
  end;
  PSAOParams = ^TSAOParams;

  PHEVCContext = ^THEVCContext;

  THEVCLocalContext = record
    cabac_state: array[0..HEVC_CONTEXTS - 1] of Byte;
    stat_coeff: array[0..3] of Byte;
    first_qp_group: Byte;

    gb: TGetBitContext;
    cc: TCABACContext;

    qp_y: Int8;
    curr_qp_y: Int8;
    qPy_pred: Integer;

    tu: TTransformUnit;

    ctb_left_flag: Byte;
    ctb_up_flag: Byte;
    ctb_up_right_flag: Byte;
    ctb_up_left_flag: Byte;
    end_of_tiles_x: Integer;
    end_of_tiles_y: Integer;

    edge_emu_buffer: array[0 .. (MAX_PB_SIZE + 7) * EDGE_EMU_BUFFER_STRIDE * 2 - 1] of Byte;
    edge_emu_buffer2: array[0 .. (MAX_PB_SIZE + 7) * EDGE_EMU_BUFFER_STRIDE * 2 - 1] of Byte;
    tmp: array[0 .. MAX_PB_SIZE * MAX_PB_SIZE - 1] of Int16;

    ct_depth: Integer;
    cu: TCodingUnit;
    pu: TPredictionUnit;
    na: TNeighbourAvailable;

    boundary_flags: Integer;
  end;
  PHEVCLocalContext = ^THEVCLocalContext;

  THEVCContext = record
    width: Integer;
    height: Integer;

    HEVClc: PHEVCLocalContext;

    cabac_state: PByte;
    slice_initialized: Byte;

    frame: PAVFrame;
    output_frame: PAVFrame;

    // USE_SAO_SMALL_BUFFER
    sao_pixel_buffer: PByte;
    sao_pixel_buffer_h: array[0..2] of PByte;
    sao_pixel_buffer_v: array[0..2] of PByte;

    sps: PHEVCSPS;
    pps: PHEVCPPS;
    sps_list: array[0..MAX_SPS_COUNT - 1] of PHEVCSPS;
    pps_list: array[0..MAX_PPS_COUNT - 1] of PHEVCPPS;
    current_sps: PHEVCSPS;

    // candidate references for the current frame
    rps: array[0..4] of TRefPicList;

    sh: TSliceHeader;
    sao: PSAOParams;
    deblock: PDBParams;
    nal_unit_type: Integer;
    temporal_id: Integer;
    ref: PHEVCFrame;
    DPB: array[0..MAX_DPB_COUNT - 1] of THEVCFrame;
    poc: Integer;
    pocTid0: Integer;
    slice_idx: Integer;
    eos: Integer;
    last_eos: Integer;
    max_ra: Integer;
    bs_width: Integer;
    bs_height: Integer;

    is_decoded: Integer;

    qp_y_tab: PInt8;
    horizontal_bs: PByte;
    vertical_bs: PByte;

    tab_slice_address: PInt32;

    // CU
    skip_flag: PByte;
    tab_ct_depth: PByte;
    // PU
    tab_ipm: PByte;

    cbf_luma: PByte;
    is_pcm: PByte;

    filter_slice_edges: PByte;

    seq_decode: Word;
    seq_output: Word;

    wpp_err: Integer;
    skipped_bytes: Integer;
    skipped_bytes_pos: PInteger;
    skipped_bytes_pos_size: Integer;

    skipped_bytes_nal: PInteger;
    skipped_bytes_pos_nal: PPointer;
    skipped_bytes_pos_size_nal: PInteger;

    data: PByte;

    nals: PHEVCNAL;
    nb_nals: Integer;
    nals_allocated: Integer;
    first_nal_type: Integer;

    context_initialized: Byte;
    apply_defdispwin: Integer;
    active_seq_parameter_set_id: Integer;
    nal_length_size: Integer;
    nuh_layer_id: Integer;

    picture_struct: Integer;
    // USE_FRAME_DURATION_SEI
    frame_duration: Word;
  end;

function IS_IDR(S: PHEVCContext): Boolean; inline;
function IS_BLA(S: PHEVCContext): Boolean; inline;
function IS_IRAP(S: PHEVCContext): Boolean; inline;

implementation

function IS_IDR(S: PHEVCContext): Boolean;
begin
  Result := (S^.nal_unit_type = NAL_IDR_W_RADL) or (S^.nal_unit_type = NAL_IDR_N_LP);
end;

function IS_BLA(S: PHEVCContext): Boolean;
begin
  Result := (S^.nal_unit_type = NAL_BLA_W_RADL) or (S^.nal_unit_type = NAL_BLA_W_LP) or
            (S^.nal_unit_type = NAL_BLA_N_LP);
end;

function IS_IRAP(S: PHEVCContext): Boolean;
begin
  Result := (S^.nal_unit_type >= 16) and (S^.nal_unit_type <= 23);
end;

end.
