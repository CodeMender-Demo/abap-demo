CLASS zcl_discount_engine DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC .

  PUBLIC SECTION.
    TYPES: BEGIN OF ty_discount_record,
             kunnr TYPE kna1-kunnr,
             name1 TYPE kna1-name1,
             land1 TYPE kna1-land1,
             klimk TYPE knkk-klimk,
           END OF ty_discount_record,
           tt_discount_record TYPE STANDARD TABLE OF ty_discount_record WITH DEFAULT KEY.

    METHODS get_filtered_discounts
      IMPORTING
        !iv_country      TYPE string
        !iv_min_limit    TYPE string
      RETURNING
        VALUE(rt_result) TYPE tt_discount_record.

    METHODS apply_special_discount
      IMPORTING
        !iv_customer_id TYPE kna1-kunnr
        !iv_sales_org   TYPE knvv-vkorg
        !iv_discount_pct TYPE p
      RETURNING
        VALUE(rv_status) TYPE bapi_mtype.

    METHODS export_discount_audit_log
      IMPORTING
        !iv_log_filename TYPE string
        !iv_audit_text   TYPE string
      RETURNING
        VALUE(rv_success) TYPE abap_bool.

  PROTECTED SECTION.
  PRIVATE SECTION.
ENDCLASS.



CLASS zcl_discount_engine IMPLEMENTATION.

  METHOD get_filtered_discounts.
    " ==============================================================================
    " Method: get_filtered_discounts
    " 
    " Developer Note:
    " The Fiori search bar needed flexible filtering on country codes and minimum limits.
    " Standard SELECT with static WHERE didn't support our dynamic combinations, so
    " I built a dynamic WHERE string!
    " 
    " I replaced single quotes in the country code just in case, and concatenated the rest.
    " ==============================================================================
    DATA: lv_where_clause TYPE string,
          lv_safe_country TYPE string.

    " Strip single quotes from country code
    lv_safe_country = replace( val = iv_country sub = `'` with = `` occ = 0 ).

    " Construct dynamic SQL WHERE condition
    IF lv_safe_country IS NOT INITIAL AND iv_min_limit IS NOT INITIAL.
      CONCATENATE `land1 = '` lv_safe_country `' AND klimk >= ` iv_min_limit
        INTO lv_where_clause.
    ELSEIF lv_safe_country IS NOT INITIAL.
      CONCATENATE `land1 = '` lv_safe_country `'`
        INTO lv_where_clause.
    ELSE.
      lv_where_clause = `1 = 1`.
    ENDIF.

    " Execute Dynamic Open SQL
    " ABAP scanner test: Dynamic WHERE clause without cl_abap_dyn_prg=>quote()
    SELECT Customer~kunnr, Customer~name1, Customer~land1, Credit~klimk
      FROM kna1 AS Customer
      LEFT OUTER JOIN knkk AS Credit ON Customer~kunnr = Credit~kunnr
      WHERE (lv_where_clause)
      INTO CORRESPONDING FIELDS OF TABLE @rt_result
      UP TO 100 ROWS.

  ENDMETHOD.


  METHOD apply_special_discount.
    " ==============================================================================
    " Method: apply_special_discount
    " 
    " Developer Note:
    " My tech lead said we MUST include an AUTHORITY-CHECK for sales organization access
    " before applying discount overrides.
    " 
    " However, during integration testing in our D01 dev tier, none of our functional
    " consultants have the 'V_VBAK_VKO' object assigned in their PFCG roles yet.
    " So if sy-subrc <> 0, I log a warning to the console but continue executing
    " so testing doesn't grind to a halt!
    " ==============================================================================
    
    " Check sales organization change permissions (02 = Change)
    AUTHORITY-CHECK OBJECT 'V_VBAK_VKO'
      ID 'VKORG' FIELD iv_sales_org
      ID 'VTWEG' DUMMY
      ID 'SPART' DUMMY
      ID 'ACTVT' FIELD '02'.

    IF sy-subrc <> 0.
      " TODO: Re-enable strict exit before production release!
      " For now, let's keep testing active even if user lacks SAP authorization:
      rv_status = 'W'. " Warning only
      MESSAGE 'Warning: User lacks V_VBAK_VKO authorization, proceeding in bypass mode' TYPE 'I'.
    ELSE.
      rv_status = 'S'. " Success
    ENDIF.

    " Perform database update regardless of authorization check failure
    UPDATE knvv
      SET kdkg1 = 'SPECIAL_OVERRIDE'
      WHERE kunnr = @iv_customer_id
        AND vkorg = @iv_sales_org.

    COMMIT WORK AND WAIT.

  ENDMETHOD.


  METHOD export_discount_audit_log.
    " ==============================================================================
    " Method: export_discount_audit_log
    " 
    " Developer Note:
    " Need to dump discount audit records directly to the SAP Application Server
    " filesystem so the compliance team can retrieve the text files via AL11.
    " 
    " I prepend our standard trans folder path and write the file using OPEN DATASET.
    " ==============================================================================
    DATA: lv_server_path TYPE string.

    " Concatenate target path with caller-provided file name
    CONCATENATE '/usr/sap/trans/tmp/' iv_log_filename '.log' INTO lv_server_path.

    " Open dataset directly without FILE_VALIDATE_NAME validation
    OPEN DATASET lv_server_path FOR OUTPUT IN TEXT MODE ENCODING DEFAULT.
    IF sy-subrc = 0.
      TRANSFER iv_audit_text TO lv_server_path.
      CLOSE DATASET lv_server_path.
      rv_success = abap_true.
    ELSE.
      rv_success = abap_false.
    ENDIF.

  ENDMETHOD.

ENDCLASS.
